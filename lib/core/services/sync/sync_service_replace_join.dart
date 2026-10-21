part of 'sync_service.dart';

/// What a replace and join (issue #3482, spec section 6.4.1) came to.
enum ReplaceJoinOutcome {
  /// This device's library is now the account's.
  replaced,

  /// The account holds no library this device can read.
  noLibrary,

  /// A device published the library from a newer schema; this build must
  /// update first, or it would drop what it cannot read.
  newerSchema,

  /// The library is encrypted and this device holds no key for it yet.
  needsPassphrase,
}

class ReplaceJoinResult {
  const ReplaceJoinResult(this.outcome, {this.newerSchemaPeerNames = const {}});

  final ReplaceJoinOutcome outcome;

  /// The devices that published from a newer schema, by id, for
  /// [ReplaceJoinOutcome.newerSchema].
  final Map<String, String> newerSchemaPeerNames;
}

/// The account's library, downloaded and checked, with nothing changed on
/// this device yet. [dispose] deletes its downloaded files; applying it
/// does too.
class ReplaceJoinPrepared {
  ReplaceJoinPrepared._(
    this._sink, {
    required this.marker,
    required this.baseFilePaths,
    required this.baseExportedAt,
    required this.changesets,
    required this.cursors,
  });

  /// A library with nothing in it, for tests of the steps around the
  /// replace.
  @visibleForTesting
  factory ReplaceJoinPrepared.empty() => ReplaceJoinPrepared._(
    BasePartFileSink(),
    marker: null,
    baseFilePaths: const [],
    baseExportedAt: const [],
    changesets: const [],
    cursors: const [],
  );

  final BasePartFileSink _sink;

  /// The library's current epoch, or null for a library never replaced.
  final LibraryEpochMarker? marker;
  final List<String> baseFilePaths;
  final List<int> baseExportedAt;
  final List<SyncPayload> changesets;
  final List<({String deviceId, int baseSeq, int appliedThrough})> cursors;

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final path in baseFilePaths) {
      await _sink.deleteQuietly(path);
    }
  }
}

/// Replace and join: this device's library is replaced by the one in its
/// sync account, the way a retired device rejoins (cloud wins), without
/// replaying anything local. Two calls, so the caller can take its backup
/// once the library is proven readable and before anything changes.
extension SyncServiceReplaceJoin on SyncService {
  /// Downloads and checks the account's library; changes nothing here.
  /// Exactly one of the two fields is set.
  Future<({ReplaceJoinPrepared? prepared, ReplaceJoinResult? refused})>
  prepareReplaceJoin() async {
    final provider = _cloudProvider;
    if (provider == null) {
      throw StateError('Replace and join needs a sync account');
    }
    final folderId = await provider.getOrCreateSyncFolder();
    final deviceId = await _syncRepository.getDeviceId();
    const needsPassphrase = ReplaceJoinResult(
      ReplaceJoinOutcome.needsPassphrase,
    );
    final LibraryEpochMarker? marker;
    try {
      marker = await readLibraryEpochMarker(provider);
    } on SyncEncryptionRequired {
      return (prepared: null, refused: needsPassphrase);
    }
    // The collector skips a manifest it cannot read, so a locked library
    // would look like no library at all: ask first.
    if (await _peerLibraryIsLocked(provider, folderId, deviceId)) {
      return (prepared: null, refused: needsPassphrase);
    }
    // This device's own manifest is left out: a library it published once
    // (an earlier Combine) must not bring the replaced dives back.
    final sources = await _collectEpochBaseSources(
      provider,
      folderId,
      marker?.epochId,
      excludeDeviceIds: {deviceId},
    );
    if (sources.newerSchemaPeerDeviceIds.isNotEmpty) {
      return (
        prepared: null,
        refused: ReplaceJoinResult(
          ReplaceJoinOutcome.newerSchema,
          newerSchemaPeerNames: {
            for (final id in sources.newerSchemaPeerDeviceIds)
              id: sources.newerSchemaPeerNames[id] ?? id,
          },
        ),
      );
    }
    if (sources.baseFilePaths.isEmpty) {
      return (
        prepared: null,
        refused: const ReplaceJoinResult(ReplaceJoinOutcome.noLibrary),
      );
    }
    return (
      prepared: ReplaceJoinPrepared._(
        _baseSink,
        marker: marker,
        baseFilePaths: sources.baseFilePaths,
        baseExportedAt: sources.baseExportedAt,
        changesets: sources.changesets,
        cursors: sources.cursors,
      ),
      refused: null,
    );
  }

  /// Replaces this device's library with [prepared] in one transaction:
  /// the apply, this device's accounts the library lacks put back, and the
  /// sync bookkeeping re-based on the library. An error before it commits
  /// leaves the database as it was. Always disposes [prepared].
  ///
  /// [afterApplyForTest] runs last inside the transaction; a throw there
  /// stands in for a crash mid-replace.
  Future<ReplaceJoinResult> applyReplaceJoin(
    ReplaceJoinPrepared prepared, {
    void Function()? afterApplyForTest,
  }) async {
    final provider = _cloudProvider;
    if (provider == null) {
      await prepared.dispose();
      throw StateError('Replace and join needs a sync account');
    }
    final db = DatabaseService.instance.database;
    final keptAccounts = <String>[];
    try {
      final roster = await db.select(db.connectedAccounts).get();
      await _serializer.applyInDeferredFkTransaction(() async {
        await _adoptApplyStreaming(
          baseFilePaths: prepared.baseFilePaths,
          baseExportedAt: prepared.baseExportedAt,
          changesets: prepared.changesets,
        );
        // The roster syncs, so the apply removed this device's accounts the
        // library has not seen yet. They are this device's, kept (spec
        // 6.4.1 step 4), and join the library's roster on the next sync.
        final present = {
          for (final row in await db.select(db.connectedAccounts).get()) row.id,
        };
        for (final row in roster) {
          if (present.contains(row.id)) continue;
          await db.into(db.connectedAccounts).insert(row);
          keptAccounts.add(row.id);
        }
        await _syncRepository.resetSyncState(clearDeletionLog: true);
        final cursorStore = PeerCursorStore(db);
        for (final c in prepared.cursors) {
          await cursorStore.upsert(
            peerDeviceId: c.deviceId,
            provider: provider.providerId,
            baseSeqApplied: c.baseSeq,
            lastSeqApplied: c.appliedThrough,
          );
        }
        // The library is exactly what its devices published, so this
        // device never uploads it again as its own base.
        await _publishStateStore.markAdoptedPendingBase(
          provider.providerId,
          await _syncRepository.maxRowHlc(),
        );
        afterApplyForTest?.call();
      });
    } finally {
      await prepared.dispose();
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in keptAccounts) {
      await _syncRepository.markRecordPending(
        entityType: 'connectedAccounts',
        recordId: id,
        localUpdatedAt: now,
      );
    }
    final marker = prepared.marker;
    if (marker != null) {
      await _syncRepository.setLastAcceptedEpochId(marker.epochId);
      await _epochStore?.setLastAccepted(marker);
    }
    SyncClock.instance.reset();
    await _flushAfterRun('replace and join');
    _log.info('Replaced this device\'s library with the account\'s');
    return const ReplaceJoinResult(ReplaceJoinOutcome.replaced);
  }

  /// Whether another device's manifest in [folderId] is an envelope this
  /// device cannot open. With the library key held, the provider decrypts
  /// on download and no envelope reaches here.
  Future<bool> _peerLibraryIsLocked(
    CloudStorageProvider provider,
    String folderId,
    String deviceId,
  ) async {
    final files = await provider.listFiles(
      folderId: folderId,
      namePattern: ChangesetLogLayout.prefix,
    );
    for (final f in files) {
      final id = ChangesetLogLayout.deviceIdOf(f.name);
      if (id == null || id == deviceId) continue;
      if (f.name != ChangesetLogLayout.manifestName(id)) continue;
      return SyncEnvelope.hasMagic(await provider.downloadFile(f.id));
    }
    return false;
  }
}
