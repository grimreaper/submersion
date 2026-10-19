import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';

/// A Git object's id, type and raw body (no loose-object header).
final class GitStoredObject {
  const GitStoredObject({
    required this.id,
    required this.type,
    required this.body,
  });

  final GitObjectId id;
  final GitObjectType type;
  final Uint8List body;
}

/// Where fetched and created objects live. Objects are immutable and
/// addressed by content, so a store never needs invalidating, only bounding.
abstract interface class GitObjectStore {
  Future<GitStoredObject?> get(GitObjectId id);

  /// Stores [object]. Never evicts anything, so a caller can read back what
  /// it just fetched; [trim] does that.
  Future<void> put(GitStoredObject object);
  Future<bool> has(GitObjectId id);

  /// Deletes the least recently used objects until the store is within its
  /// bound, never one [keep] returns; [keep] is asked only when something
  /// must go. A no-op for an unbounded store.
  Future<void> trim({Future<Set<GitObjectId>> Function()? keep});
}

/// An unbounded in-memory store, for tests and short-lived sessions.
final class MemoryGitObjectStore implements GitObjectStore {
  final Map<GitObjectId, GitStoredObject> _objects = {};

  @override
  Future<GitStoredObject?> get(GitObjectId id) async => _objects[id];

  @override
  Future<void> put(GitStoredObject object) async =>
      _objects[object.id] = object;

  @override
  Future<bool> has(GitObjectId id) async => _objects.containsKey(id);

  @override
  Future<void> trim({Future<Set<GitObjectId>> Function()? keep}) async {}
}

/// A size-bounded on-disk store: one file per object at
/// `<root>/<first two hex digits>/<other 38>`, holding a 1-byte pack type
/// code followed by the body. [trim] deletes the least recently used
/// objects above [maxBytes]. Recency lives in memory, seeded from file
/// modification times the first time the store is used.
final class FileGitObjectStore implements GitObjectStore {
  FileGitObjectStore(this.root, {this.maxBytes = 256 * 1024 * 1024});

  static const String _tmpSuffix = '.tmp';
  static const Duration _staleTmpAge = Duration(hours: 1);
  static final Random _random = Random();

  final Directory root;
  final int maxBytes;

  /// path -> (size, recency); larger recency is more recently used.
  Future<Map<String, ({int size, int recency})>>? _index;
  int _clock = 0;
  int _total = 0;

  File _fileFor(GitObjectId id) {
    final hex = id.hex;
    return File(p.join(root.path, hex.substring(0, 2), hex.substring(2)));
  }

  /// Scans the directory once, however many callers arrive first.
  Future<Map<String, ({int size, int recency})>> _ensureIndex() =>
      _index ??= _scan();

  Future<Map<String, ({int size, int recency})>> _scan() async {
    final found = <({String path, int size, DateTime modified})>[];
    if (await root.exists()) {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (entity.path.endsWith(_tmpSuffix)) {
          // An old one is a write cut short by a crash (the object is
          // fetched again); a recent one may be another store's on this
          // directory, still being written.
          final age = DateTime.now().difference(stat.modified);
          if (age > _staleTmpAge) {
            await entity.delete().catchError((_) => entity);
          }
          continue;
        }
        found.add((
          path: entity.path,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    }
    found.sort((a, b) => a.modified.compareTo(b.modified));
    final index = <String, ({int size, int recency})>{};
    for (final f in found) {
      index[f.path] = (size: f.size, recency: ++_clock);
      _total += f.size;
    }
    return index;
  }

  @override
  Future<GitStoredObject?> get(GitObjectId id) async {
    final index = await _ensureIndex();
    final file = _fileFor(id);
    final entry = index[file.path];
    if (entry == null) return null;
    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      bytes = null;
    }
    // Gone, or emptied by a crash: forgotten, so the next read fetches it.
    if (bytes == null || bytes.isEmpty) {
      index.remove(file.path);
      _total -= entry.size;
      return null;
    }
    index[file.path] = (size: entry.size, recency: ++_clock);
    return GitStoredObject(
      id: id,
      type: GitObjectType.fromPackCode(bytes[0]),
      body: Uint8List.sublistView(bytes, 1),
    );
  }

  @override
  Future<void> put(GitStoredObject object) async {
    final index = await _ensureIndex();
    final file = _fileFor(object.id);
    // Another store on the same directory may have deleted it since.
    if (index.containsKey(file.path) && await file.exists()) return;
    await file.parent.create(recursive: true);
    // A name of its own: two puts of one object may run at once.
    final tmp = File(
      '${file.path}.${_random.nextInt(1 << 32).toRadixString(16)}$_tmpSuffix',
    );
    // Header byte and body as one buffer: a List<int> spread would cost
    // about eight bytes per body byte.
    final bytes = Uint8List(object.body.length + 1)
      ..[0] = object.type.packCode
      ..setRange(1, object.body.length + 1, object.body);
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    // A concurrent put of the same object has counted it already.
    if (index.containsKey(file.path)) return;
    final size = object.body.length + 1;
    index[file.path] = (size: size, recency: ++_clock);
    _total += size;
  }

  @override
  Future<void> trim({Future<Set<GitObjectId>> Function()? keep}) async {
    final index = await _ensureIndex();
    if (_total <= maxBytes) return;
    final kept = {
      for (final id in await keep?.call() ?? const <GitObjectId>{})
        _fileFor(id).path,
    };
    final byAge = index.entries.where((e) => !kept.contains(e.key)).toList()
      ..sort((a, b) => a.value.recency.compareTo(b.value.recency));
    for (final victim in byAge) {
      if (_total <= maxBytes) break;
      try {
        await File(victim.key).delete();
      } on FileSystemException {
        // Already gone; only the bookkeeping is left to drop.
      }
      index.remove(victim.key);
      _total -= victim.value.size;
    }
  }

  @override
  Future<bool> has(GitObjectId id) async =>
      (await _ensureIndex()).containsKey(_fileFor(id).path);
}
