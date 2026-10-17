import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/media_store/network_status_service.dart';
import 'package:submersion/core/services/media_store/store_keys.dart';
import 'package:submersion/core/services/shared_library/shared_library_models.dart';
import 'package:submersion/core/services/shared_library/shared_library_store.dart';
import 'package:submersion/core/services/shared_library/shared_library_transport.dart';
import 'package:submersion/core/services/storage/gc/storage_gc_coordinator.dart';
import 'package:submersion/core/services/storage/local_cache_sweep.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/resolvers/media_store_resolver.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';
import 'package:submersion/features/media_store/data/media_stores_repository.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/settings/presentation/providers/storage_gc_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';
import 'package:submersion/features/shared_library/presentation/providers/shared_library_providers.dart';

import '../../../../helpers/fake_cloud_storage_provider.dart';
import '../../../../helpers/in_memory_media_object_store.dart';
import '../../../../helpers/test_database.dart';

/// The coordinator's wiring to the live services: the media store runtime,
/// the fleet cadence on the media_stores row, the sync folder and the shared
/// library transports. The schedule itself is covered by the coordinator's
/// own tests; this pins that the providers hand it the right things.
void main() {
  late LocalCacheDatabase cacheDb;
  late Directory root;
  late InMemoryMediaObjectStore store;
  late SharedPreferences prefs;
  late FakeCloudStorageProvider syncCloud;
  late FakeCloudStorageProvider libraryCloud;
  final old = DateTime.now().subtract(const Duration(days: 30));

  setUp(() async {
    // A fresh local cache sweep stamp keeps the weekly pass (which needs
    // the live database services) out of these tests.
    SharedPreferences.setMockInitialValues({
      kLocalCacheSweepStampKey: DateTime.now().millisecondsSinceEpoch,
    });
    prefs = await SharedPreferences.getInstance();
    await setUpTestDatabase();
    cacheDb = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    root = await Directory.systemTemp.createTemp('storage_gc_providers');
    store = InMemoryMediaObjectStore();
    syncCloud = FakeCloudStorageProvider();
    libraryCloud = FakeCloudStorageProvider();
  });

  tearDown(() async {
    await cacheDb.close();
    await root.delete(recursive: true);
    await tearDownTestDatabase();
  });

  ProviderContainer container({
    List<SharedLibrary> libraries = const [],
    bool syncOn = true,
  }) {
    final cache = MediaCacheStore(database: cacheDb, root: root);
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        storageGcNetworkProvider.overrideWithValue(
          () async => NetworkKind.unmetered,
        ),
        mediaRepositoryProvider.overrideWithValue(MediaRepository()),
        mediaTransferQueueRepositoryProvider.overrideWithValue(
          MediaTransferQueueRepository(database: cacheDb),
        ),
        mediaStoreRuntimeProvider.overrideWith(
          (ref) async => MediaStoreRuntime(
            storeId: 'store-1',
            store: store,
            cache: cache,
            resolver: MediaStoreResolver(store: store, cache: cache),
          ),
        ),
        cloudStorageProviderProvider.overrideWithValue(
          syncOn ? syncCloud : null,
        ),
        // The store, not the libraries stream: an unlistened stream provider
        // is paused in Riverpod 3, and the cleanup runs with nothing
        // listening to it.
        sharedLibraryStoreProvider.overrideWithValue(
          _FakeLibraryStore(libraries),
        ),
        sharedLibraryTransportFactoryProvider.overrideWithValue(
          (library) async =>
              SharedLibraryTransport(libraryCloud, prefix: library.prefix),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('rescan measures the media store, sync folder and libraries', () async {
    store.objects[StoreKeys.objectKey('aabb', extension: 'jpg')] = [1, 2, 3];
    store.modified[StoreKeys.objectKey('aabb', extension: 'jpg')] = old;
    await syncCloud.uploadFile(Uint8List(20), 'ssv1.dev1.manifest.json');
    await libraryCloud.uploadFile(Uint8List(7), 'keyslots.json');
    final c = container(
      libraries: const [
        SharedLibrary(
          id: 'L1',
          name: 'Reef Survey',
          connectedAccountId: 'acct',
          prefix: 'site-sync',
        ),
      ],
    );

    await c.read(storageGcCoordinatorProvider).run(StorageGcTrigger.rescan);

    final usage = c.read(storageGcStoreProvider).cloudUsage!;
    expect(usage.mediaBytes, 3);
    // The sync row is set up but no snapshot exists yet, so the orphan
    // waits rather than counting as reclaimable.
    expect(usage.mediaReclaimableBytes, 0);
    expect(usage.mediaWaitingBytes, 3);
    expect(usage.syncBytes, 20);
    expect(usage.librariesBytes, 7);
    expect(
      store.objects,
      isNotEmpty,
      reason: 'a rescan never deletes anything',
    );
  });

  test('no libraries leaves the library figure out', () async {
    final c = container();

    await c.read(storageGcCoordinatorProvider).run(StorageGcTrigger.rescan);

    expect(c.read(storageGcStoreProvider).cloudUsage!.librariesBytes, isNull);
  });

  test(
    'with no media_stores row the fleet cadence is kept on this device',
    () async {
      final c = container();

      await c.read(storageGcCoordinatorProvider).run(StorageGcTrigger.manual);

      expect(
        c.read(storageGcStoreProvider).localFleetSweep,
        isNull,
        reason: 'sync on and no snapshot: the sweep was deferred',
      );
    },
  );

  test('a manual run that may delete stamps the active descriptor', () async {
    final stores = MediaStoresRepository();
    await stores.upsertActive(
      storeId: 'store-1',
      providerType: 's3',
      displayHint: 'test',
    );
    store.objects[StoreKeys.objectKey('dead', extension: 'jpg')] = [1, 2, 3];
    store.modified[StoreKeys.objectKey('dead', extension: 'jpg')] = old;
    // Sync off: the 7-day grace window is the only rule, so the old orphan
    // may go.
    final c = container(syncOn: false);

    await c.read(storageGcCoordinatorProvider).run(StorageGcTrigger.manual);

    expect(store.objects, isEmpty);
    expect((await stores.getActive())!.lastSweepAt, isNotNull);
    final usage = c.read(storageGcStoreProvider).cloudUsage!;
    expect(usage.syncBytes, isNull, reason: 'no sync backend set up');
    expect(c.read(storageGcStoreProvider).lastCloudResult!.bytes, 3);
  });
}

class _FakeLibraryStore extends SharedLibraryStore {
  _FakeLibraryStore(this.libraries);

  final List<SharedLibrary> libraries;

  @override
  Future<List<SharedLibrary>> getLibraries() async => libraries;
}
