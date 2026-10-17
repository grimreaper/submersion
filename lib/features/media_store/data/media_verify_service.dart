import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/media_store/media_key_reference.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/network_status_service.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media_store/data/media_key_references.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/data/orphan_delete_policy.dart';

/// Outcome of one Verify Library run (orphan-prevention spec 6.3).
class VerifyLibraryReport {
  /// Every stored object the sweep listed, across all three namespaces.
  ///
  /// A photo is stored as an original plus a thumbnail, and as a rendition
  /// too when it was compressed, so this is two to three times the number
  /// of photos. The per-namespace counts below are what make it explainable
  /// to someone who knows how many photos they have.
  final int objectsChecked;
  final int originalsChecked;
  final int thumbsChecked;
  final int renditionsChecked;
  final int orphansRemoved;
  final int bytesReclaimed;
  final int sessionsAborted;
  final int repairsQueued;

  /// Bytes across every listed object, duplicate copies included: the store's
  /// size as far as Submersion's own namespaces go.
  final int totalBytes;

  /// Bytes whose delete was (or, in a dry run, would be) allowed now. Equal
  /// to [bytesReclaimed] in a run that deletes and suffers no failures.
  final int reclaimableBytes;

  /// Unreferenced bytes the policy held back: inside the safety wait, or
  /// deferred because this device is not caught up.
  final int waitingBytes;

  /// True when the policy allowed no deletes at all this run.
  final bool deferred;

  /// True when the store listed an object without a size, so the byte
  /// figures above are a floor rather than the truth.
  final bool sizesUnknown;

  const VerifyLibraryReport({
    required this.objectsChecked,
    required this.originalsChecked,
    required this.thumbsChecked,
    required this.renditionsChecked,
    required this.orphansRemoved,
    required this.bytesReclaimed,
    required this.sessionsAborted,
    required this.repairsQueued,
    this.totalBytes = 0,
    this.reclaimableBytes = 0,
    this.waitingBytes = 0,
    this.deferred = false,
    this.sizesUnknown = false,
  });
}

/// True when an opportunistic verify sweep should run (orphan-prevention
/// spec 6.4): unmetered network and no fleet-wide sweep in the last 30
/// days. Pure so the gating is unit-testable apart from the runtime.
bool shouldAutoVerify({
  required DateTime? lastSweepAt,
  required NetworkKind network,
  required DateTime now,
}) {
  if (network != NetworkKind.unmetered) return false;
  if (lastSweepAt == null) return true;
  // The stamp is synced, so a device with a broken clock can plant a
  // FUTURE timestamp fleet-wide. Within ordinary cross-device skew a
  // slightly-future stamp means "someone just swept" (skip); beyond that
  // it is bogus and must not suppress the cadence until real time catches
  // up - run, and this device's completion stamp overwrites it.
  if (lastSweepAt.isAfter(now.add(const Duration(days: 1)))) return true;
  return now.difference(lastSweepAt) >= const Duration(days: 30);
}

/// Verify Library sweep (orphan-prevention spec section 6): reconciles the
/// store's namespaces against the media table.
///
/// Deletion needs BOTH unreferenced-ness and age (the 7-day grace window
/// protects rows still in flight from unsynced devices); repair needs only
/// absence (additive and idempotent). Every step is idempotent, so an
/// interrupted run simply resumes on the next one.
class MediaVerifyService {
  MediaVerifyService({
    required MediaObjectStore store,
    required MediaRepository mediaRepository,
    required MediaTransferQueueRepository queue,
    DateTime Function() now = DateTime.now,
  }) : _store = store,
       _mediaRepository = mediaRepository,
       _queue = queue,
       _now = now;

  static const graceWindow = Duration(days: 7);
  static const staleSessionAge = Duration(days: 7);

  static const _objectsPrefix = 'smv1/objects/';
  static const _thumbsPrefix = 'smv1/thumbs/';
  static const _renditionsPrefix = 'smv1/renditions/';

  final MediaObjectStore _store;
  final MediaRepository _mediaRepository;
  final MediaTransferQueueRepository _queue;
  final DateTime Function() _now;
  final _log = LoggerService.forClass(MediaVerifyService);

  /// Runs one sweep.
  ///
  /// [policy] decides when an unreferenced object may go; null keeps the
  /// original behaviour (7-day grace, nothing else). A [dryRun] lists and
  /// measures only: no deletes, no reverse repair, no session reap.
  ///
  /// [deleteGuard] is asked before every delete; once it returns false the
  /// sweep deletes nothing more. The reference set is read once, at the
  /// start, so a sync that starts during the listing may bring rows it does
  /// not have: the caller's guard reports that.
  Future<VerifyLibraryReport> run({
    void Function(int objectsChecked)? onProgress,
    OrphanDeletePolicy? policy,
    bool dryRun = false,
    bool Function()? deleteGuard,
  }) async {
    final now = _now();
    final rules = policy ?? OrphanDeletePolicy.unrestricted(now);
    final references = await _mediaRepository.getContentReferences();

    var objectsChecked = 0;
    var orphansRemoved = 0;
    var bytesReclaimed = 0;
    var totalBytes = 0;
    var reclaimableBytes = 0;
    var waitingBytes = 0;
    var sizesUnknown = false;

    // Hashes actually present per tier, for reverse repair below.
    final presentOriginals = <String>{};
    final presentThumbs = <String>{};
    final presentRenditions = <String>{};

    // Every namespace is listed before anything is deleted: whether a
    // sibling may go depends on whether a copy some row resolves to exists
    // in ANY namespace (the resolver falls back across extension variants,
    // StoreKeys.objectKeyPrefix), and a key listed more than once (two
    // devices racing one key on Google Drive) has to be counted first.
    final listings = <StoreNamespace, Map<String, _Listed>>{};
    final listedCounts = <StoreNamespace, int>{};
    for (final ns in StoreNamespace.values) {
      final prefix = _prefixFor(ns);
      final keys = <String, _Listed>{};
      var listed = 0;
      await for (final info in _store.list(prefix)) {
        listed++;
        objectsChecked++;
        onProgress?.call(objectsChecked);
        final listedSize = info.sizeBytes;
        if (listedSize == null) sizesUnknown = true;
        totalBytes += listedSize ?? 0;
        final prev = keys[info.key];
        keys[info.key] = _Listed(prev?.info ?? info, (prev?.copies ?? 0) + 1);
      }
      listings[ns] = keys;
      listedCounts[ns] = listed;
    }

    // Hashes with at least one copy a row resolves to, in originals or
    // renditions. A sibling under any other hash may be the only copy left.
    final usable = <String>{};
    for (final ns in const [
      StoreNamespace.objects,
      StoreNamespace.renditions,
    ]) {
      for (final key in listings[ns]!.keys) {
        final parsed = _parseKey(key, _prefixFor(ns));
        if (parsed == null) continue;
        final refs = references[parsed.hash];
        if (refs != null &&
            isKeyReferenced(
              namespace: ns,
              extension: parsed.extension,
              refs: refs,
            )) {
          usable.add(parsed.hash);
        }
      }
    }

    var guardTripped = false;
    bool mayDelete() {
      if (guardTripped) return false;
      if (deleteGuard != null && !deleteGuard()) guardTripped = true;
      return !guardTripped;
    }

    Future<void> deleteCopies(String key, int copies, int size) async {
      for (var i = 0; i < copies; i++) {
        if (!mayDelete()) return;
        try {
          await _store.delete(key);
          orphansRemoved++;
          bytesReclaimed += size;
        } on Exception catch (e) {
          // Best-effort per object; a miss stays for the next sweep.
          _log.warning('Verify sweep delete failed for $key', error: e);
          return;
        }
      }
    }

    for (final ns in StoreNamespace.values) {
      final present = switch (ns) {
        StoreNamespace.objects => presentOriginals,
        StoreNamespace.thumbs => presentThumbs,
        StoreNamespace.renditions => presentRenditions,
      };
      for (final listed in listings[ns]!.values) {
        final info = listed.info;
        final size = info.sizeBytes ?? 0;
        final parsed = _parseKey(info.key, _prefixFor(ns));
        if (parsed == null) continue; // malformed keys are never deleted
        final refs = references[parsed.hash] ?? const <MediaKeyReference>[];
        if (refs.isNotEmpty) present.add(parsed.hash);

        final referenced = isKeyReferenced(
          namespace: ns,
          extension: parsed.extension,
          refs: refs,
        );
        // A sibling of a photo still in use goes only when a copy the
        // resolver will use is present; otherwise it may be the last one.
        final keep =
            referenced || (refs.isNotEmpty && !usable.contains(parsed.hash));
        if (keep) {
          // Extra copies of one key hold identical bytes: drop all but one.
          // Only a store that can hold copies is asked, and it re-resolves
          // them itself, so a listing that merely repeats a key never costs
          // the only copy (see DuplicateKeyStore).
          final extras = listed.copies - 1;
          if (_store case final DuplicateKeyStore store when extras > 0) {
            if (!rules.deletesAllowed) {
              waitingBytes += extras * size;
            } else if (dryRun) {
              reclaimableBytes += extras * size;
            } else {
              if (!mayDelete()) continue;
              try {
                final removed = await store.deleteExtraCopies(info.key);
                orphansRemoved += removed;
                bytesReclaimed += removed * size;
                reclaimableBytes += removed * size;
              } on Exception catch (e) {
                _log.warning(
                  'Removing duplicate copies failed for ${info.key}',
                  error: e,
                );
              }
            }
          }
          continue;
        }

        if (rules.verdictFor(info.lastModified) != OrphanVerdict.delete) {
          waitingBytes +=
              (_store is DuplicateKeyStore ? listed.copies : 1) * size;
          continue;
        }
        // Only a store that can hold copies holds more than one; elsewhere a
        // repeated key is a listing artefact and one delete removes it.
        final copies = _store is DuplicateKeyStore ? listed.copies : 1;
        reclaimableBytes += copies * size;
        if (!dryRun) await deleteCopies(info.key, copies, size);
      }
    }
    final originalsChecked = listedCounts[StoreNamespace.objects]!;
    final thumbsChecked = listedCounts[StoreNamespace.thumbs]!;
    final renditionsChecked = listedCounts[StoreNamespace.renditions]!;

    if (dryRun) {
      return VerifyLibraryReport(
        objectsChecked: objectsChecked,
        originalsChecked: originalsChecked,
        thumbsChecked: thumbsChecked,
        renditionsChecked: renditionsChecked,
        orphansRemoved: 0,
        bytesReclaimed: 0,
        sessionsAborted: 0,
        repairsQueued: 0,
        totalBytes: totalBytes,
        reclaimableBytes: reclaimableBytes,
        waitingBytes: waitingBytes,
        deferred: !rules.deletesAllowed,
        sizesUnknown: sizesUnknown,
      );
    }

    // Reverse repair (spec 6.2): a stamp whose object is absent is stale -
    // clear it and queue a re-upload; the pipeline re-materializes local
    // bytes when they resolve and fails gracefully when they do not.
    var repairsQueued = 0;
    for (final row in await _mediaRepository.getRemoteStampedSummaries()) {
      var repaired = false;
      if (row.hasOriginal && !presentOriginals.contains(row.contentHash)) {
        await _mediaRepository.clearRemoteUploaded(row.id);
        repaired = true;
      }
      if (row.hasThumb && !presentThumbs.contains(row.contentHash)) {
        await _mediaRepository.clearRemoteThumbUploaded(row.id);
        repaired = true;
      }
      if (row.hasRendition && !presentRenditions.contains(row.contentHash)) {
        await _mediaRepository.clearRemoteCompressed(row.id);
        repaired = true;
      }
      if (repaired) {
        // Repair-specific enqueue: re-arms a terminally failed row, which
        // plain enqueueUpload deliberately refuses to resurrect.
        await _queue.enqueueRepairUpload(mediaId: row.id);
        repairsQueued++;
      }
    }

    // Best-effort like the per-object deletes: by now the deletions and
    // repairs above have already happened, and a listing failure here must
    // not fail the sweep (or block the fleet lastSweepAt stamp) - missed
    // sessions simply wait for the next run.
    var sessionsAborted = 0;
    try {
      sessionsAborted = await _store.reapStaleUploadSessions(
        olderThan: now.subtract(staleSessionAge),
      );
    } on Exception catch (e) {
      _log.warning('Stale upload-session reap failed', error: e);
    }

    return VerifyLibraryReport(
      objectsChecked: objectsChecked,
      originalsChecked: originalsChecked,
      thumbsChecked: thumbsChecked,
      renditionsChecked: renditionsChecked,
      orphansRemoved: orphansRemoved,
      bytesReclaimed: bytesReclaimed,
      sessionsAborted: sessionsAborted,
      repairsQueued: repairsQueued,
      totalBytes: totalBytes,
      reclaimableBytes: reclaimableBytes,
      waitingBytes: waitingBytes,
      deferred: !rules.deletesAllowed,
      sizesUnknown: sizesUnknown,
    );
  }

  static String _prefixFor(StoreNamespace ns) => switch (ns) {
    StoreNamespace.objects => _objectsPrefix,
    StoreNamespace.thumbs => _thumbsPrefix,
    StoreNamespace.renditions => _renditionsPrefix,
  };

  /// StoreKeys layout: a two-hex-char shard directory that must echo the
  /// hash's first two characters, a lowercase-hex hash, and a short
  /// alphanumeric extension. Anything else is treated as malformed and
  /// never deleted.
  static final _contentKeyShape = RegExp(
    r'^([0-9a-f]{2})/([0-9a-f]{4,64})\.([a-z0-9]{1,8})$',
  );

  /// `smv1/<tier>/<aa>/<hash>.<ext>` -> (hash, ext), or null when the key
  /// does not match the content-addressed shape (including a shard directory
  /// that does not match the hash, or a key outside [prefix]).
  ({String hash, String extension})? _parseKey(String key, String prefix) {
    if (!key.startsWith(prefix)) return null;
    final match = _contentKeyShape.firstMatch(key.substring(prefix.length));
    if (match == null) return null;
    final hash = match.group(2)!;
    if (!hash.startsWith(match.group(1)!)) return null;
    return (hash: hash, extension: match.group(3)!);
  }
}

/// One listed key and how many copies of it the listing returned.
class _Listed {
  const _Listed(this.info, this.copies);

  final StoreObjectInfo info;
  final int copies;
}
