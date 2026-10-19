import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';

GitException _corrupt(String what) => GitException(
  'The server sent a corrupt pack ($what).',
  code: GitErrorCode.unexpected,
);

/// Inflates the zlib stream that starts at [offset] in [buf].
///
/// Returns the inflated bytes and [consumed], the exact length of the zlib
/// stream: its 2-byte header, the deflate data, and the 4-byte Adler-32
/// trailer. A packfile stores objects back to back with no lengths, so this
/// count is the only way to find where the next object starts.
///
/// The deflate decoder buffers bits ahead of what it has used, so the input
/// position it stops at can sit a few bytes past the real end of the data.
/// The trailer pins the end exactly: it is the big-endian Adler-32 of the
/// inflated bytes, found in a small window around where decoding stopped.
({Uint8List data, int consumed}) inflateAt(
  Uint8List buf,
  int offset, {
  int? expectedSize,
}) {
  if (offset + 2 > buf.length) throw _corrupt('truncated zlib header');
  final cmf = buf[offset];
  final flg = buf[offset + 1];
  if ((cmf & 0x0f) != 8 || ((cmf << 8) | flg) % 31 != 0 || (flg & 0x20) != 0) {
    throw _corrupt('bad zlib header');
  }
  final input = InputMemoryStream(buf, offset: offset + 2);
  final Uint8List data;
  try {
    data = Inflate.stream(input, uncompressedSize: expectedSize).getBytes();
  } catch (e) {
    throw _corrupt('deflate error: $e');
  }
  if (expectedSize != null && data.length != expectedSize) {
    throw _corrupt('size ${data.length}, expected $expectedSize');
  }
  final adler = getAdler32(data);
  final stoppedAt = offset + 2 + input.position;
  final from = (stoppedAt - 8) < offset + 2 ? offset + 2 : stoppedAt - 8;
  for (var p = from; p <= stoppedAt + 4 && p + 4 <= buf.length; p++) {
    final trailer =
        (buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3];
    if (trailer == adler) {
      return (data: data, consumed: p + 4 - offset);
    }
  }
  throw _corrupt('Adler-32 trailer not found');
}
