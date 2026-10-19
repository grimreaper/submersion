import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';
import 'package:submersion/core/services/cloud_storage/git/pack_inflater.dart';

GitException _corrupt(String what) => GitException(
  'The server sent a corrupt pack ($what).',
  code: GitErrorCode.unexpected,
);

const int _ofsDelta = 6;
const int _refDelta = 7;

/// One pack entry before delta resolution.
final class _Entry {
  _Entry(this.offset, this.typeCode, this.data, {this.baseOffset, this.baseId});

  final int offset;
  final int typeCode;
  final Uint8List data;
  final int? baseOffset;
  final GitObjectId? baseId;
}

/// Parses a version 2 pack, resolves OFS_DELTA and REF_DELTA entries, and
/// stores every object in [store]. A REF_DELTA base may be in the pack or
/// already in [store] (a thin pack). Returns the ids in pack order.
///
/// Throws [GitException] with [GitErrorCode.unexpected] on any malformed
/// input: a bad header or trailer checksum, a corrupt stream, or a delta
/// that does not fit its base; [GitDeltaBaseMissingException] for a delta
/// whose base is neither in the pack nor in [store].
Future<List<GitObjectId>> readPack(Uint8List pack, GitObjectStore store) async {
  if (pack.length < 32 ||
      pack[0] != 0x50 ||
      pack[1] != 0x41 ||
      pack[2] != 0x43 ||
      pack[3] != 0x4b) {
    throw _corrupt('missing PACK signature');
  }
  final header = ByteData.sublistView(pack, 4, 12);
  if (header.getUint32(0) != 2) throw _corrupt('unsupported pack version');
  final count = header.getUint32(4);
  final body = Uint8List.sublistView(pack, 0, pack.length - 20);
  final trailer = Uint8List.sublistView(pack, pack.length - 20);
  final digest = sha1.convert(body).bytes;
  for (var i = 0; i < 20; i++) {
    if (digest[i] != trailer[i]) throw _corrupt('checksum mismatch');
  }

  final entries = <_Entry>[];
  var pos = 12;
  for (var n = 0; n < count; n++) {
    final start = pos;
    if (pos >= body.length) throw _corrupt('truncated entry header');
    var byte = body[pos++];
    final typeCode = (byte >> 4) & 0x07;
    var size = byte & 0x0f;
    var shift = 4;
    while (byte & 0x80 != 0) {
      if (pos >= body.length) throw _corrupt('truncated entry size');
      byte = body[pos++];
      size |= (byte & 0x7f) << shift;
      shift += 7;
    }
    int? baseOffset;
    GitObjectId? baseId;
    if (typeCode == _ofsDelta) {
      if (pos >= body.length) throw _corrupt('truncated delta offset');
      var c = body[pos++];
      var off = c & 0x7f;
      while (c & 0x80 != 0) {
        if (pos >= body.length) throw _corrupt('truncated delta offset');
        c = body[pos++];
        off = ((off + 1) << 7) | (c & 0x7f);
      }
      baseOffset = start - off;
      if (baseOffset < 12) throw _corrupt('delta offset out of range');
    } else if (typeCode == _refDelta) {
      if (pos + 20 > body.length) throw _corrupt('truncated delta base id');
      baseId = GitObjectId(Uint8List.sublistView(body, pos, pos + 20));
      pos += 20;
    } else if (typeCode < 1 || typeCode > 4) {
      throw _corrupt('object type $typeCode');
    }
    final inflated = inflateAt(body, pos, expectedSize: size);
    pos += inflated.consumed;
    entries.add(
      _Entry(
        start,
        typeCode,
        inflated.data,
        baseOffset: baseOffset,
        baseId: baseId,
      ),
    );
  }
  if (pos != body.length) throw _corrupt('trailing bytes after objects');

  final byOffset = {for (final e in entries) e.offset: e};
  final resolvedByOffset = <int, GitStoredObject>{};
  final resolvedById = <GitObjectId, GitStoredObject>{};

  Future<GitStoredObject> resolve(_Entry e, int depth) async {
    final done = resolvedByOffset[e.offset];
    if (done != null) return done;
    if (depth > 1000) throw _corrupt('delta chain too deep');
    final GitStoredObject object;
    if (e.typeCode != _ofsDelta && e.typeCode != _refDelta) {
      final type = GitObjectType.fromPackCode(e.typeCode);
      object = GitStoredObject(
        id: hashGitObject(type, e.data),
        type: type,
        body: e.data,
      );
    } else {
      GitStoredObject? base;
      if (e.baseOffset != null) {
        final baseEntry = byOffset[e.baseOffset!];
        if (baseEntry == null) throw _corrupt('delta base not in pack');
        base = await resolve(baseEntry, depth + 1);
      } else {
        // Every whole object in the pack is already resolved (see below).
        base = resolvedById[e.baseId!] ?? await store.get(e.baseId!);
        if (base == null) throw GitDeltaBaseMissingException(e.baseId!);
      }
      final result = applyGitDelta(base.body, e.data);
      object = GitStoredObject(
        id: hashGitObject(base.type, result),
        type: base.type,
        body: result,
      );
    }
    resolvedByOffset[e.offset] = object;
    resolvedById[object.id] = object;
    return object;
  }

  final ids = <GitObjectId>[];
  // Resolve non-deltas first so a REF_DELTA against an in-pack base finds it
  // by id without a scan, then everything in pack order.
  for (final e in entries.where((e) => e.typeCode < _ofsDelta)) {
    await resolve(e, 0);
  }
  for (final e in entries) {
    final object = await resolve(e, 0);
    await store.put(object);
    ids.add(object.id);
  }
  return ids;
}

/// Applies a Git delta to [base]. Throws [GitException] when the delta does
/// not match its base or its declared result size.
Uint8List applyGitDelta(Uint8List base, Uint8List delta) {
  var pos = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= delta.length) throw _corrupt('truncated delta size');
      final b = delta[pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  final sourceSize = varint();
  final targetSize = varint();
  if (sourceSize != base.length) throw _corrupt('delta base size mismatch');
  final out = Uint8List(targetSize);
  var written = 0;
  while (pos < delta.length) {
    final cmd = delta[pos++];
    if (cmd & 0x80 != 0) {
      var offset = 0;
      var size = 0;
      for (var i = 0; i < 4; i++) {
        if (cmd & (1 << i) != 0) {
          if (pos >= delta.length) throw _corrupt('truncated copy');
          offset |= delta[pos++] << (8 * i);
        }
      }
      for (var i = 0; i < 3; i++) {
        if (cmd & (0x10 << i) != 0) {
          if (pos >= delta.length) throw _corrupt('truncated copy');
          size |= delta[pos++] << (8 * i);
        }
      }
      if (size == 0) size = 0x10000;
      if (offset + size > base.length || written + size > targetSize) {
        throw _corrupt('copy out of range');
      }
      out.setRange(written, written + size, base, offset);
      written += size;
    } else if (cmd != 0) {
      if (pos + cmd > delta.length || written + cmd > targetSize) {
        throw _corrupt('insert out of range');
      }
      out.setRange(written, written + cmd, delta, pos);
      pos += cmd;
      written += cmd;
    } else {
      throw _corrupt('reserved delta opcode');
    }
  }
  if (written != targetSize) throw _corrupt('delta result size mismatch');
  return out;
}
