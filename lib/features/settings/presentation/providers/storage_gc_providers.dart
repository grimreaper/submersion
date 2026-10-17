import 'dart:async';

import 'package:path_provider/path_provider.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/core/services/local_cache_database_service.dart';
import 'package:submersion/core/services/media_store/network_status_service.dart';
import 'package:submersion/core/services/shared_library/shared_library_transport.dart';
import 'package:submersion/core/services/storage/gc/cloud_usage_measure.dart';
import 'package:submersion/core/services/storage/gc/storage_gc_coordinator.dart';
import 'package:submersion/core/services/storage/gc/storage_gc_store.dart';
import 'package:submersion/core/services/storage/local_cache_sweep.dart';
import 'package:submersion/core/services/storage/restore_temp_sweep.dart';
import 'package:submersion/core/services/storage/scratch_sweep.dart';
import 'package:submersion/core/services/sync/sync_coordinator.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media_store/data/media_verify_service.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';
import 'package:submersion/features/shared_library/presentation/providers/shared_library_providers.dart';

/// Device-local cleanup state.
final storageGcStoreProvider = Provider<StorageGcStore>(
  (ref) => StorageGcStore(ref.watch(sharedPreferencesProvider)),
);

/// The connection the cleanup checks before cloud work: unmetered, metered
/// or offline. A seam so tests can choose one without the platform plugin.
final storageGcNetworkProvider = Provider<Future<NetworkKind> Function()>(
  (ref) => NetworkStatusService().current,
);

/// The storage cleanup coordinator, wired to the live services. Also runs it
/// every six hours, since a desktop app can stay open for days without a
/// launch or a resume.
// no-tick: the value is a SERVICE. Every repository read happens inside its
// closures at run time via ref.read, so there is no cached row to go stale.
final storageGcCoordinatorProvider = Provider<StorageGcCoordinator>((ref) {
  final store = ref.watch(storageGcStoreProvider);
  final coordinator = StorageGcCoordinator(
    store: store,
    deviceSweeps: [
      ({required now, required dryRun}) => StorageScratchSweep(
        temporaryDirectory: getTemporaryDirectory,
        supportDirectory: getApplicationSupportDirectory,
      ).run(now: now, dryRun: dryRun),
      ({required now, required dryRun}) => RestoreTempSweep(
        temporaryDirectory: getTemporaryDirectory,
      ).run(now: now, dryRun: dryRun),
    ],
    localCacheSweep: (now) => _localCacheSweepIfDue(ref, now),
    network: () => ref.read(storageGcNetworkProvider)(),
    isSyncBusy: () => SyncCoordinator.busy,
    hasTransferringUploads: () =>
        ref.read(mediaTransferQueueRepositoryProvider).hasTransferringUploads(),
    mediaSweep: ({required dryRun}) => _mediaSweep(ref, dryRun: dryRun),
    fleetSweepDue: (now) async {
      final active = await ref.read(mediaStoresRepositoryProvider).getActive();
      return isCadenceDue(
        active?.lastSweepAt ?? store.localFleetSweep,
        now,
        const Duration(days: 7),
      );
    },
    stampFleetSweep: (now) async {
      final stores = ref.read(mediaStoresRepositoryProvider);
      final active = await stores.getActive();
      if (active != null) {
        await stores.stampLastSweep(active.id, now);
      } else {
        // No descriptor (a restore from before the store was attached):
        // keep the cadence on this device until a peer syncs the row back.
        await store.setLocalFleetSweep(now);
      }
    },
    measureSync: () async {
      final provider = ref.read(cloudStorageProviderProvider);
      return provider == null ? null : measureSyncFolderBytes(provider);
    },
    measureLibraries: () => _measureLibraries(ref),
  );
  final timer = Timer.periodic(
    const Duration(hours: 6),
    (_) => unawaited(coordinator.run(StorageGcTrigger.timer)),
  );
  ref.onDispose(() {
    timer.cancel();
    coordinator.dispose();
  });
  return coordinator;
});

/// What the Storage usage page shows from the cleanup, re-read whenever a
/// run starts or ends.
class StorageGcView {
  const StorageGcView({
    required this.running,
    this.cloudUsage,
    this.lastDeviceResult,
    this.lastCloudResult,
  });

  final bool running;
  final CloudUsage? cloudUsage;
  final AreaResult? lastDeviceResult;
  final AreaResult? lastCloudResult;

  /// The more recent of the two "last reclaimed" results.
  AreaResult? get lastReclaimed {
    final d = lastDeviceResult;
    final c = lastCloudResult;
    if (d == null) return c;
    if (c == null) return d;
    return c.at.isAfter(d.at) ? c : d;
  }
}

// no-tick: reads SharedPreferences, not a table; the coordinator's change
// stream is what re-emits it after every run.
final storageGcStateProvider = StreamProvider<StorageGcView>((ref) async* {
  final coordinator = ref.watch(storageGcCoordinatorProvider);
  StorageGcView view() => StorageGcView(
    running: coordinator.isRunning,
    cloudUsage: coordinator.store.cloudUsage,
    lastDeviceResult: coordinator.store.lastDeviceResult,
    lastCloudResult: coordinator.store.lastCloudResult,
  );
  yield view();
  await for (final _ in coordinator.changes) {
    yield view();
  }
});

/// Bytes the device sweeps could reclaim right now, from a dry run.
// no-tick: a filesystem walk, not a table read. It is recomputed after a
// cleanup pass reclaims on the device (its watch on storageGcStateProvider),
// and the page's Recalculate action invalidates it.
final deviceReclaimableBytesProvider = FutureProvider.autoDispose<int>((ref) {
  // Recomputed only when a device pass recorded a result: a run that
  // reclaimed nothing on the device left the figure as it was.
  ref.watch(
    storageGcStateProvider.select((s) => s.value?.lastDeviceResult?.at),
  );
  return ref.read(storageGcCoordinatorProvider).deviceReclaimableBytes();
});

/// The weekly local cache database sweep, on its own stamp as before.
Future<void> _localCacheSweepIfDue(Ref ref, DateTime now) async {
  final prefs = ref.read(sharedPreferencesProvider);
  final stampMs = prefs.getInt(kLocalCacheSweepStampKey);
  final last = stampMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(stampMs);
  if (!shouldSweepLocalCache(lastSweptAt: last, now: now)) return;
  await LocalCacheSweep(
    localCache: LocalCacheDatabaseService.instance.database,
    library: DatabaseService.instance.database,
  ).run(now: now);
  // Stamped after the pass, so a sweep that throws part way retries.
  await prefs.setInt(kLocalCacheSweepStampKey, now.millisecondsSinceEpoch);
}

Future<VerifyLibraryReport?> _mediaSweep(
  Ref ref, {
  required bool dryRun,
}) async {
  final runtime = await ref.read(mediaStoreRuntimeProvider.future);
  if (runtime == null) return null;
  final report =
      await MediaVerifyService(
        store: runtime.store,
        mediaRepository: ref.read(mediaRepositoryProvider),
        queue: ref.read(mediaTransferQueueRepositoryProvider),
      ).run(
        policy: ref.read(orphanDeletePolicyFactoryProvider)(),
        dryRun: dryRun,
        deleteGuard: SyncCoordinator.quietGuard(),
      );
  // Repairs the sweep queued drain now rather than on the next trigger.
  if (!dryRun) unawaited(runtime.worker?.drain());
  return report;
}

Future<({int bytes, bool partial})?> _measureLibraries(Ref ref) async {
  // Straight from the store, never `sharedLibrariesProvider.future`: Riverpod
  // pauses a stream provider nobody listens to, and the cleanup usually runs
  // with no library page open, so that future would never complete and the
  // whole run (and every run that joins it) would hang.
  final libraries = await ref.read(sharedLibraryStoreProvider).getLibraries();
  if (libraries.isEmpty) return null;
  final transportFor = ref.read(sharedLibraryTransportFactoryProvider);
  var bytes = 0;
  var partial = false;
  for (final library in libraries) {
    try {
      final measured = await (await transportFor(library)).measureBytes();
      bytes += measured.bytes;
      partial = partial || measured.partial;
    } catch (_) {
      // A library this device cannot reach right now: count what was
      // reachable and say the total is partial.
      partial = true;
    }
  }
  return (bytes: bytes, partial: partial);
}
