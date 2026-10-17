import 'dart:typed_data';

import 'package:submersion/core/services/images/profile_photo_codec.dart';

/// An image carried in an import payload, re-encoded the way the app stores
/// every image a diver picks.
///
/// Source files hold pictures at any size and in any format, and a stored
/// blob rides in every sync changeset, so an imported picture is bounded by
/// [spec] exactly like a picked one. Null when [value] is not image bytes or
/// cannot be decoded: the record then imports without a picture rather than
/// holding one that never renders.
Future<Uint8List?> importedImage(Object? value, ImageEncodeSpec spec) async {
  if (value is! Uint8List || value.isEmpty) return null;
  final encoded = await encodeStoredImage(
    ImageEncodeRequest.fromBytes(bytes: value, spec: spec),
  );
  return encoded.outcome == ImageEncodeOutcome.encoded ? encoded.bytes : null;
}
