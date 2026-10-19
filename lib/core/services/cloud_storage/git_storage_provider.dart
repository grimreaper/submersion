import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/data/repositories/sync_repository.dart';
import 'package:submersion/core/services/accounts/account_identity.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/deferred_write_provider.dart';
import 'package:submersion/core/services/cloud_storage/git/git_branch_files.dart';
import 'package:submersion/core/services/cloud_storage/git/git_branch_session.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/core/services/cloud_storage/git/git_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_http_transport.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/sync/crypto/keyslots.dart';
import 'package:submersion/core/services/sync/sync_device_metadata.dart';
import 'package:submersion/core/services/sync/sync_preferences.dart';

typedef GitTransportFactory = GitHttpTransport Function(GitConfig config);
typedef GitStoreFactory = Future<GitObjectStore> Function(GitConfig config);
typedef GitDeviceSource =
    Future<({String deviceId, String? deviceName})> Function();

/// Who commits say they are from. Commit metadata is never encrypted, so
/// under encrypted sync the device's display name stays out of it.
GitCommitIdentity gitCommitIdentityFor({
  required String deviceId,
  required String? deviceName,
  required bool encrypted,
}) {
  final short = deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId;
  final neutral = 'Submersion $short';
  final name = encrypted || deviceName == null || deviceName.trim().isEmpty
      ? neutral
      : deviceName.trim();
  return GitCommitIdentity(name: name, messageLabel: name);
}

/// What Test connection found, for the setup screen.
final class GitConnectionReport {
  const GitConnectionReport({
    required this.branchExists,
    required this.willBecomeDefault,
    required this.isPublic,
  });

  final bool branchExists;

  /// Creating the branch will make it the repository's default (the
  /// repository is empty).
  final bool willBecomeDefault;

  /// Anyone can read the repository without signing in.
  final bool isPublic;
}

/// Git implementation of [CloudStorageProvider], for any smart-HTTP host.
///
/// - A fileId is a path on the sync branch (`Submersion Sync/x.json`); a
///   folderId is a top-level directory name.
/// - Uploads are committed and pushed before they return. Deletes are
///   deferred and batched into one commit ([flush]), since the sync engine
///   tolerates a file that outlives its delete for a while.
/// - A public repository is refused for writes unless sync is encrypted.
class GitStorageProvider
    with CloudStorageProviderMixin
    implements CloudStorageProvider, DeferredWriteProvider, HistoryResettable {
  GitStorageProvider({
    GitCredentialsStore? store,
    GitTransportFactory? transportFactory,
    GitStoreFactory? storeFactory,
    GitDeviceSource? device,
    Future<bool> Function()? encryptionEnabled,
    this.deleteQuietPeriod = const Duration(seconds: 5),
    this.maxPacingWait = const Duration(seconds: 10),
    this.minPushSpacing = const Duration(seconds: 10),
    this.uploadBudget = const Duration(seconds: 45),
    this.resetThresholdBytes = kGitHistoryResetThresholdBytes,
  }) : _store = store ?? GitCredentialsStore(),
       _transportFactory =
           transportFactory ?? ((c) => GitHttpTransport(c.toRemote())),
       _storeFactory = storeFactory ?? _defaultStore,
       _device = device ?? _defaultDevice,
       _encryptionEnabled = encryptionEnabled ?? _defaultEncryptionEnabled;

  static final _log = LoggerService.forClass(GitStorageProvider);

  static const String backupFolderName = 'Submersion Backups';

  final GitCredentialsStore _store;
  final GitTransportFactory _transportFactory;
  final GitStoreFactory _storeFactory;
  final GitDeviceSource _device;
  final Future<bool> Function() _encryptionEnabled;
  final Duration deleteQuietPeriod;
  final Duration maxPacingWait;
  final Duration minPushSpacing;
  final Duration uploadBudget;

  /// Deleted bytes after which the branch history is reset.
  final int resetThresholdBytes;

  GitConfig? _cachedConfig;
  GitBranchSession? _session;
  int _generation = 0;
  bool? _knownPublic;
  DateTime? _lastPushStart;
  Timer? _deleteTimer;
  Future<void> _lock = Future.value();

  /// path -> blob id seen when the delete was asked for, or null when this
  /// instance had not seen the path (deleted whatever it holds).
  final Map<String, GitObjectId?> _pendingDeletes = {};

  static Future<GitObjectStore> _defaultStore(GitConfig config) async {
    final support = await getApplicationSupportDirectory();
    final key = sha1.convert(utf8.encode(gitNaturalKey(config))).toString();
    return FileGitObjectStore(
      Directory(p.join(support.path, 'git_objects', key)),
    );
  }

  static Future<({String deviceId, String? deviceName})>
  _defaultDevice() async {
    final repo = SyncRepository();
    final id = await repo.getDeviceId();
    final name = (await SyncDeviceMetadata(repo).resolve()).name;
    return (deviceId: id, deviceName: name);
  }

  static Future<bool> _defaultEncryptionEnabled() async => SyncPreferences(
    await SharedPreferences.getInstance(),
  ).syncEncryptionEnabled;

  @override
  String get providerName => 'Git';

  @override
  String get providerId => 'git';

  @override
  Future<bool> isAvailable() async => true;

  /// Presence only, no network (UI rebuild paths call this).
  @override
  Future<bool> isAuthenticated() async => (await _loadConfig()) != null;

  Future<GitConfig?> loadConfig() => _loadConfig();

  Future<void> saveConfig(GitConfig config) async {
    await _store.save(config);
    _invalidate();
  }

  /// Drops the cached config and session, for when the stored config was
  /// changed or removed by someone other than this provider.
  void forgetCachedConfig() => _invalidate();

  @override
  Future<void> signOut() async {
    await _store.clear();
    _invalidate();
  }

  @override
  Future<String?> getUserEmail() async => (await _loadConfig())?.displayLabel;

  /// When each repository and branch last had its history reset, as seen
  /// by any provider in this process. Process-wide because the active sync
  /// provider is built per account, apart from the settings singleton that
  /// the Cloud sync page reads.
  static final Map<String, DateTime> _lastResetByEndpoint = {};

  /// Repositories and branches whose host refused a history reset.
  static final Set<String> _resetRefusedEndpoints = {};

  /// Whether the host refused the last history reset of [config]'s branch
  /// (branch protection); the Cloud sync page says how to allow it.
  static bool resetRefusedFor(GitConfig config) =>
      _resetRefusedEndpoints.contains(gitNaturalKey(config));

  /// When [config]'s branch was last reset, as far as this process has
  /// seen; no network.
  static DateTime? lastKnownResetFor(GitConfig config) =>
      _lastResetByEndpoint[gitNaturalKey(config)];

  /// When this provider's branch was last reset; no network.
  DateTime? get lastKnownResetAt {
    final config = _cachedConfig;
    return config == null ? null : lastKnownResetFor(config);
  }

  void _noteSnapshot(GitBranchSession session) {
    final ms = session.current?.meta.lastResetAtMs;
    final config = _cachedConfig;
    if (ms == null || config == null) return;
    _lastResetByEndpoint[gitNaturalKey(config)] =
        DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  void dispose() {
    _deleteTimer?.cancel();
    _invalidate();
  }

  // ---- Session --------------------------------------------------------------

  Future<GitConfig?> _loadConfig() async {
    final cached = _cachedConfig;
    if (cached != null) return cached;
    final generation = _generation;
    final loaded = await _store.load();
    if (generation != _generation) return _cachedConfig;
    return _cachedConfig = loaded;
  }

  Future<GitConfig> _requireConfig() async {
    final config = await _loadConfig();
    if (config == null) {
      throw GitException(
        'Git is not configured. Open the Git settings and enter your repository.',
        code: GitErrorCode.invalidConfig,
      );
    }
    return config;
  }

  Future<GitBranchSession> _requireSession() async {
    while (true) {
      final generation = _generation;
      final config = await _requireConfig();
      final existing = _session;
      if (existing != null) return existing;
      final store = await _storeFactory(config);
      if (generation != _generation) continue;
      return _session = GitBranchSession(
        transport: _transportFactory(config),
        store: store,
        branch: config.branch,
        identity: _identity,
        resetThresholdBytes: resetThresholdBytes,
      );
    }
  }

  Future<GitCommitIdentity> _identity() async {
    final device = await _device();
    return gitCommitIdentityFor(
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      encrypted: await _encryptionEnabled(),
    );
  }

  /// The session with its branch open. Opening may create the branch, but a
  /// new branch holds only the README and Submersion's own marker files, so
  /// it needs no public-repository check; data uploads do.
  Future<GitBranchSession> _opened() async {
    final session = await _requireSession();
    if (session.current == null) await session.open();
    return session;
  }

  void _invalidate() {
    _generation++;
    _session?.transport.close();
    _session = null;
    _cachedConfig = null;
    _knownPublic = null;
    _pendingDeletes.clear();
  }

  /// Runs [action] after every write started before it, one at a time.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Refuses data uploads to a public repository while sync is unencrypted.
  /// Whether the repository is public is asked once per session (an unclear
  /// answer is asked again next time); whether sync is encrypted is checked
  /// on every upload, so turning encryption off later is still caught.
  Future<void> _ensurePublicSafe(GitBranchSession session) async {
    final public = _knownPublic ??= await session.transport
        .isPubliclyReadable();
    if (public == true && !await _encryptionEnabled()) {
      throw GitException(
        'The repository is public. Turn on encrypted sync or make the '
        'repository private.',
        code: GitErrorCode.publicRepoUnencrypted,
      );
    }
  }

  Future<void> _pace() async {
    final last = _lastPushStart;
    if (last != null) {
      var wait = minPushSpacing - DateTime.now().difference(last);
      if (wait > maxPacingWait) wait = maxPacingWait;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastPushStart = DateTime.now();
  }

  @override
  Future<void> authenticate() async {
    final session = await _requireSession();
    await session.open();
    _log.info('Git branch ${session.branch} opened');
  }

  /// Validates unsaved [config] against the host without writing anything.
  Future<GitConnectionReport> testConnection(GitConfig config) async {
    final error = config.validate();
    if (error != null) {
      throw GitException(error, code: GitErrorCode.invalidConfig);
    }
    final transport = _transportFactory(config);
    try {
      await transport.checkPushAccess();
      final session = GitBranchSession(
        transport: transport,
        store: MemoryGitObjectStore(),
        branch: config.branch,
        identity: _identity,
      );
      final found = await session.inspect();
      final public = await transport.isPubliclyReadable();
      return GitConnectionReport(
        branchExists: found.exists,
        willBecomeDefault: found.willBecomeDefault,
        isPublic: public == true,
      );
    } finally {
      transport.close();
    }
  }

  /// Whether the saved repository can be read without signing in; null when
  /// there is no config or the host's answer is unclear.
  Future<bool?> isPubliclyReadable() async {
    final config = await _loadConfig();
    if (config == null) return null;
    final transport = _transportFactory(config);
    try {
      return await transport.isPubliclyReadable();
    } finally {
      transport.close();
    }
  }

  // ---- Writes ---------------------------------------------------------------

  Future<UploadResult> _write(
    String path,
    GitPut put, {
    required String messagePrefix,
  }) {
    final run = _serial(() async {
      final session = await _opened();
      // The keyslot file holds only a wrapped key, so it may land in a
      // public repository: without it, encryption could never be turned on.
      if (p.posix.basename(path) != KeyslotFile.cloudFileName) {
        await _ensurePublicSafe(session);
      }
      // Uploading a path replaces it: an older delete of it is void.
      _pendingDeletes.remove(path);
      final deletes = Map<String, GitObjectId?>.of(_pendingDeletes);
      await _pace();
      await session.commit(
        GitChange(puts: {path: put}, deletes: deletes),
        messagePrefix: messagePrefix,
      );
      _noteSnapshot(session);
      for (final MapEntry(:key, :value) in deletes.entries) {
        if (_pendingDeletes[key] == value) _pendingDeletes.remove(key);
      }
      return UploadResult(fileId: path, uploadTime: DateTime.now().toUtc());
    });
    // Sync files are small and the engine's callers wrap them in their own
    // short timeouts, so they get a budget. Backups are large; a budget
    // would give up on a slow link while the push still lands, leaving a
    // copy the backup history never tracks.
    if (path.startsWith('$backupFolderName/')) return run;
    return run.timeout(
      uploadBudget,
      onTimeout: () => throw GitException(
        'The upload to the Git host took too long.',
        code: GitErrorCode.unreachable,
        host: _cachedConfig?.host,
      ),
    );
  }

  String _pathIn(String? folderId, String filename) =>
      '${folderId ?? CloudStorageProviderMixin.syncFolderName}/$filename';

  String _prefixFor(String path) =>
      path.startsWith('$backupFolderName/') ? 'Backup' : 'Sync';

  @override
  Future<UploadResult> uploadFile(
    Uint8List data,
    String filename, {
    String? folderId,
  }) {
    final path = _pathIn(folderId, filename);
    return _write(path, GitPut.bytes(data), messagePrefix: _prefixFor(path));
  }

  @override
  Future<UploadResult> uploadFileFromPath(
    String sourcePath,
    String filename, {
    String? folderId,
  }) {
    final path = _pathIn(folderId, filename);
    return _write(
      path,
      GitPut.file(File(sourcePath)),
      messagePrefix: _prefixFor(path),
    );
  }

  /// Records the delete; no network. The file disappears from listings at
  /// once and from the branch on the next commit or [flush].
  @override
  Future<void> deleteFile(String fileId) async {
    // A caller may delete by id without listing first (backup pruning on a
    // provider built for this account): record it unconditionally then.
    _pendingDeletes[fileId] = _session?.current?.index.entries[fileId]?.blobId;
    _deleteTimer?.cancel();
    _deleteTimer = Timer(deleteQuietPeriod, () {
      unawaited(
        flush().catchError((Object e) {
          _log.warning(
            'Deferred Git delete failed; a later sweep retries',
            error: e,
          );
        }),
      );
    });
  }

  @override
  Future<void> flush() => _serial(() async {
    _deleteTimer?.cancel();
    // Deletes recorded without a loaded branch still have to reach it.
    final session = _pendingDeletes.isNotEmpty ? await _opened() : _session;
    if (session == null) return;
    if (_pendingDeletes.isNotEmpty) {
      final deletes = Map<String, GitObjectId?>.of(_pendingDeletes);
      await _pace();
      await session.commit(GitChange(deletes: deletes), messagePrefix: 'Sync');
      for (final MapEntry(:key, :value) in deletes.entries) {
        if (_pendingDeletes[key] == value) _pendingDeletes.remove(key);
      }
    }
    if (session.current != null) {
      // Best effort: the deletes above already landed, so a reset that
      // fails must not make the caller report them as failed. A due reset
      // is tried again on the next flush.
      try {
        await _resetIfDue(session, force: false);
      } on GitException catch (e) {
        _log.warning('History reset not done; retried later', error: e);
      }
    }
  });

  /// Resets [session]'s history when due (or always, with [force]) and
  /// records the outcome for the Cloud sync page: a reset the host refuses
  /// as a protected branch is shown there, since it otherwise only logs.
  Future<void> _resetIfDue(
    GitBranchSession session, {
    required bool force,
  }) async {
    final config = _cachedConfig;
    final key = config == null ? null : gitNaturalKey(config);
    try {
      final reset = await session.resetHistoryIfDue(force: force);
      if (reset && key != null) _resetRefusedEndpoints.remove(key);
      _noteSnapshot(session);
    } on GitException catch (e) {
      if (e.code == GitErrorCode.protectedBranch && key != null) {
        _resetRefusedEndpoints.add(key);
      }
      rethrow;
    }
  }

  @override
  Future<void> resetHistoryNow() async {
    await flush();
    await _serial(() async {
      await _resetIfDue(await _opened(), force: true);
    });
  }

  // ---- Reads ----------------------------------------------------------------

  @override
  Future<String> getOrCreateSyncFolder() async {
    await _opened();
    return CloudStorageProviderMixin.syncFolderName;
  }

  /// Folders exist implicitly on Git: a path is enough.
  @override
  Future<String> createFolder(
    String folderName, {
    String? parentFolderId,
  }) async =>
      parentFolderId == null ? folderName : '$parentFolderId/$folderName';

  @override
  Future<List<CloudFileInfo>> listFiles({
    String? folderId,
    String? namePattern,
  }) async {
    final session = await _opened();
    final snap = await session.refresh();
    _noteSnapshot(session);
    final prefix = '${folderId ?? CloudStorageProviderMixin.syncFolderName}/';
    final out = <CloudFileInfo>[];
    for (final MapEntry(:key, :value) in snap.index.entries.entries) {
      if (!key.startsWith(prefix)) continue;
      final name = key.substring(prefix.length);
      if (name.contains('/')) continue;
      if (_pendingDeletes.containsKey(key)) continue;
      if (namePattern != null && !name.contains(namePattern)) continue;
      out.add(_info(key, name, value.size, value.modifiedMs));
    }
    return out;
  }

  CloudFileInfo _info(String path, String name, int size, int modifiedMs) =>
      CloudFileInfo(
        id: path,
        name: name,
        modifiedTime: DateTime.fromMillisecondsSinceEpoch(
          modifiedMs,
          isUtc: true,
        ),
        sizeBytes: size,
      );

  @override
  Future<CloudFileInfo?> getFileInfo(String fileId) async {
    if (_pendingDeletes.containsKey(fileId)) return null;
    final session = await _opened();
    final snap = await session.refresh();
    final entry = snap.index.entries[fileId];
    if (entry == null) return null;
    return _info(
      fileId,
      p.posix.basename(fileId),
      entry.size,
      entry.modifiedMs,
    );
  }

  @override
  Future<bool> fileExists(String fileId) async =>
      (await getFileInfo(fileId)) != null;

  Future<GitBranchSession> _sessionHolding(String fileId) async {
    if (_pendingDeletes.containsKey(fileId)) {
      throw GitException('$fileId was deleted.', code: GitErrorCode.notFound);
    }
    final session = await _opened();
    if (session.current?.index.entries.containsKey(fileId) != true) {
      await session.refresh();
    }
    return session;
  }

  @override
  Future<Uint8List> downloadFile(String fileId) async =>
      (await _sessionHolding(fileId)).readFile(fileId);

  @override
  Future<void> downloadToFile(String fileId, String destinationPath) async =>
      (await _sessionHolding(fileId)).readFileTo(fileId, File(destinationPath));
}
