import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/sync/replace_and_join_service.dart';
import 'package:submersion/core/services/sync/sync_service.dart';
import 'package:submersion/features/backup/presentation/providers/backup_providers.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';

/// Replace and join's steps on the app's own services (issue #3482). Its
/// own file: sync providers may not import the backup providers.
class ProductionReplaceJoinSteps implements ReplaceJoinSteps {
  ProductionReplaceJoinSteps(this._ref);

  final Ref _ref;

  SyncService get _sync => _ref.read(syncServiceProvider);

  @override
  Future<({ReplaceJoinPrepared? prepared, ReplaceJoinResult? refused})>
  prepare() => _sync.prepareReplaceJoin();

  @override
  Future<void> takePinnedBackup(String note) async {
    final backups = _ref.read(backupServiceProvider);
    final record = await backups.performBackup(note: note);
    await backups.pinBackup(record.id);
  }

  @override
  Future<ReplaceJoinResult> apply(ReplaceJoinPrepared prepared) =>
      _sync.applyReplaceJoin(prepared);

  @override
  Future<void> discardPhotoQueue() async {
    await _ref.read(mediaTransferQueueRepositoryProvider).clearAll();
  }

  @override
  Future<void> forgetPhotoStore() =>
      _ref.read(mediaStoreServiceProvider).disconnect();

  @override
  Future<void> settleSyncState() async {
    final provider = _ref.read(cloudStorageProviderProvider);
    if (provider != null) {
      await _ref
          .read(establishedProviderStoreProvider)
          .add(provider.providerId);
    }
    await _ref.read(postRestoreSyncStoreProvider).clear();
  }

  @override
  Future<void> realignActiveDiver() =>
      realignActiveDiverAfterDataReplace(_ref.read(sharedPreferencesProvider));
}

/// Replace and join, ready to run. Phase 6 calls it from step 2 of Set up
/// this device, after the typed-word confirm, then reloads the app.
final replaceAndJoinServiceProvider = Provider<ReplaceAndJoinService>(
  (ref) => ReplaceAndJoinService(
    steps: ProductionReplaceJoinSteps(ref),
    attachState: ref.watch(mediaStoreAttachStateProvider),
  ),
);
