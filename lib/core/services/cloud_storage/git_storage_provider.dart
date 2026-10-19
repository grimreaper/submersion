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
import 'package:submersion/core/services/cloud_storage/git/git_branch_session.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/core/services/cloud_storage/git/git_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_http_transport.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';
import 'package:submersion/core/services/logger_service.dart';
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

  GitConfig? _cachedConfig;
  GitBranchSession? _session;
  int _generation = 0;
  bool _publicChecked = false;
  DateTime? _lastPushStart;
  Timer? _deleteTimer;
  Future<void> _lock = Future.value();

  /// path -> blob id seen when the delete was asked for.
  final Map<String, GitObjectId> _pendingDeletes = {};

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

  /// When history was last reset, from the latest snapshot; no network.
  DateTime? get lastKnownResetAt {
    final ms = _session?.current?.meta.lastResetAtMs;
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
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

  /// The session with its branch open. The public-repository check runs
  /// first, because opening creates the branch when it is missing, and that
  /// is already a write.
  Future<GitBranchSession> _opened() async {
    final session = await _requireSession();
    if (session.current == null) {
      await _ensurePublicSafe(session);
      await session.open();
    }
    return session;
  }

  void _invalidate() {
    _generation++;
    _session?.transport.close();
    _session = null;
    _cachedConfig = null;
    _publicChecked = false;
    _pendingDeletes.clear();
  }

  /// Runs [action] after every write started before it, one at a time.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Refuses writes to a public repository while sync is unencrypted. The
  /// check runs once per session; a failed check is not cached, so turning
  /// encryption on takes effect on the next write.
  Future<void> _ensurePublicSafe(GitBranchSession session) async {
    if (_publicChecked) return;
    final public = await session.transport.isPubliclyReadable();
    if (public == true && !await _encryptionEnabled()) {
      throw GitException(
        'The repository is public. Turn on encrypted sync or make the '
        'repository private.',
        code: GitErrorCode.publicRepoUnencrypted,
      );
    }
    _publicChecked = true;
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
    await _ensurePublicSafe(session);
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
    return _serial(() async {
      final session = await _opened();
      await _ensurePublicSafe(session);
      final deletes = Map<String, GitObjectId>.of(_pendingDeletes);
      await _pace();
      await session.commit(
        GitChange(puts: {path: put}, deletes: deletes),
        messagePrefix: messagePrefix,
      );
      for (final MapEntry(:key, :value) in deletes.entries) {
        if (_pendingDeletes[key] == value) _pendingDeletes.remove(key);
      }
      return UploadResult(fileId: path, uploadTime: DateTime.now().toUtc());
    }).timeout(
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
    final blob = _session?.current?.index.entries[fileId]?.blobId;
    if (blob == null) return;
    _pendingDeletes[fileId] = blob;
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
    final session = _session;
    if (session == null) return;
    if (_pendingDeletes.isNotEmpty) {
      await _ensurePublicSafe(session);
      final deletes = Map<String, GitObjectId>.of(_pendingDeletes);
      await _pace();
      await session.commit(GitChange(deletes: deletes), messagePrefix: 'Sync');
      for (final MapEntry(:key, :value) in deletes.entries) {
        if (_pendingDeletes[key] == value) _pendingDeletes.remove(key);
      }
    }
    if (session.current != null) {
      try {
        await session.resetHistoryIfDue();
      } on GitException catch (e) {
        if (e.code != GitErrorCode.protectedBranch) rethrow;
        _log.warning(
          'History reset refused: the branch is protected',
          error: e,
        );
      }
    }
  });

  @override
  Future<void> resetHistoryNow() async {
    await flush();
    await _serial(() async {
      final session = await _opened();
      await session.resetHistoryIfDue(force: true);
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
