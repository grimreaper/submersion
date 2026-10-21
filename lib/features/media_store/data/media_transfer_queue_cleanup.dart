part of 'media_transfer_queue_repository.dart';

/// Whole-queue reads and removals, split out of the repository to keep it
/// under the file size limit.
extension MediaTransferQueueCleanup on MediaTransferQueueRepository {
  /// Removes every queue entry, in any state or direction, and returns how
  /// many. For a replaced library (issue #3482), whose rows all name media
  /// that is gone: the caller has detached the store first, so no row is
  /// transferring.
  Future<int> clearAll() => _db.delete(_db.mediaTransferQueue).go();

  Future<int> deleteDone() => (_db.delete(
    _db.mediaTransferQueue,
  )..where((t) => t.state.equals('done'))).go();

  /// Whether an upload is transferring right now. The storage cleanup holds
  /// its cloud deletes while one is (storage GC design, safety rules); a
  /// pending row is not counted, since its hash already protects its objects
  /// and a row stuck pending must not block the cleanup forever.
  Future<bool> hasTransferringUploads() async {
    final row =
        await (_db.select(_db.mediaTransferQueue)
              ..where(
                (t) =>
                    t.direction.equals('upload') &
                    t.state.equals('transferring'),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }
}
