part of 'shared_library_transport.dart';

/// How much a library's folder holds, for the Storage usage page (storage GC
/// design). Kept apart from the transport's read and write paths, which it
/// only lists.
extension SharedLibraryTransportMeasure on SharedLibraryTransport {
  /// Bytes this library holds: the files directly in its root and in its
  /// members, sites, suggestions and backups folders. Files of a library
  /// nested below this one are not counted (the same [_directlyIn] guard as
  /// [_listKind]). [partial] is set when a folder could not be listed or a
  /// file reported no size. Measurement only; nothing is deleted.
  Future<({int bytes, bool partial})> measureBytes() async {
    var bytes = 0;
    var partial = false;
    final seen = <String>{};
    for (final (folder, mayBeAbsent) in <(Future<String> Function(), bool)>[
      (_rootId, false),
      (_membersId, false),
      (_sitesId, false),
      (_suggestionsId, true),
      (_backupsId, true),
    ]) {
      final String folderId;
      try {
        folderId = await folder();
      } on Exception {
        // A library that has never had a suggestion or a backup has no
        // folder for them, and a reader may not create one: nothing to
        // count, and no reason to call the figure partial.
        if (!mayBeAbsent) partial = true;
        continue;
      }
      try {
        for (final f in await _provider.listFiles(folderId: folderId)) {
          final ours = SharedLibraryTransport._directlyIn(folderId, f);
          if (!ours || !seen.add(f.id)) continue;
          final size = f.sizeBytes;
          if (size == null) {
            partial = true;
          } else {
            bytes += size;
          }
        }
      } on Exception {
        partial = true;
      }
    }
    return (bytes: bytes, partial: partial);
  }
}
