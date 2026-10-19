import 'dart:io';
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
  Future<void> put(GitStoredObject object);
  Future<bool> has(GitObjectId id);
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
}

/// A size-bounded on-disk store: one file per object at
/// `<root>/<first two hex digits>/<other 38>`, holding a 1-byte pack type
/// code followed by the body. Above [maxBytes] the least recently used
/// objects are deleted. Recency lives in memory, seeded from file
/// modification times the first time the store is used.
final class FileGitObjectStore implements GitObjectStore {
  FileGitObjectStore(this.root, {this.maxBytes = 256 * 1024 * 1024});

  final Directory root;
  final int maxBytes;

  /// path -> (size, recency); larger recency is more recently used.
  Map<String, ({int size, int recency})>? _index;
  int _clock = 0;
  int _total = 0;

  File _fileFor(GitObjectId id) {
    final hex = id.hex;
    return File(p.join(root.path, hex.substring(0, 2), hex.substring(2)));
  }

  Future<Map<String, ({int size, int recency})>> _ensureIndex() async {
    final existing = _index;
    if (existing != null) return existing;
    final found = <({String path, int size, DateTime modified})>[];
    if (await root.exists()) {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
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
    return _index = index;
  }

  @override
  Future<GitStoredObject?> get(GitObjectId id) async {
    final index = await _ensureIndex();
    final file = _fileFor(id);
    final entry = index[file.path];
    if (entry == null) return null;
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      index.remove(file.path);
      _total -= entry.size;
      return null;
    }
    if (bytes.isEmpty) return null;
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
    if (index.containsKey(file.path)) return;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes([object.type.packCode, ...object.body], flush: true);
    await tmp.rename(file.path);
    final size = object.body.length + 1;
    index[file.path] = (size: size, recency: ++_clock);
    _total += size;
    await _evict(keep: file.path);
  }

  Future<void> _evict({required String keep}) async {
    final index = _index!;
    if (_total <= maxBytes) return;
    final byAge = index.entries.where((e) => e.key != keep).toList()
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
