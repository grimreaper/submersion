import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';

/// "{copied} of {total} copied" for the Photos page (issue #3482), counted
/// with the backfill's own rule. Re-counts when media change and as the
/// transfer queue moves, so uploads landing tick the count up.
final mediaUploadProgressProvider =
    FutureProvider.autoDispose<({int copied, int total})>((ref) async {
      final repository = ref.watch(mediaRepositoryProvider);
      ref.invalidateSelfWhen(repository.watchMediaChanges());
      ref.watch(mediaTransferSummaryProvider.select((s) => s.value?.total));
      return repository.countUploadProgress();
    }, retry: (_, _) => null);
