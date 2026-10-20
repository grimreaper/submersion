import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';

/// "Upload existing library" (design spec section 9 trigger 2). Enqueues
/// every eligible photo; enqueueUpload is idempotent per media id, so
/// re-running is safe.
class MediaBackfillService {
  MediaBackfillService({
    required MediaRepository mediaRepository,
    required MediaTransferQueueRepository queue,
    MediaStoreAttachState? attachState,
  }) : _mediaRepository = mediaRepository,
       _queue = queue,
       _attachState = attachState;

  final MediaRepository _mediaRepository;
  final MediaTransferQueueRepository _queue;

  /// Names the attached store, so rows stamped in another store upload to
  /// this one (issue #3482).
  final MediaStoreAttachState? _attachState;
  final _log = LoggerService.forClass(MediaBackfillService);

  Future<int> enqueueAll() async {
    final ids = await _mediaRepository.getBackfillCandidateIds(
      storeId: await _attachState?.attachedStoreId(),
    );
    for (final id in ids) {
      await _queue.enqueueUpload(mediaId: id);
    }
    _log.info('Backfill enqueued ${ids.length} items');
    return ids.length;
  }
}
