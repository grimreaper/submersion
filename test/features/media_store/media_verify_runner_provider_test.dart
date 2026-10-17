import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/resolvers/media_store_resolver.dart';
import 'package:submersion/features/media/presentation/providers/media_providers.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';
import 'package:submersion/features/media_store/data/media_stores_repository.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/data/orphan_delete_policy.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../helpers/fake_path_provider.dart';
import '../../helpers/in_memory_media_object_store.dart';
import '../../helpers/test_database.dart';

void main() {
  late LocalCacheDatabase cacheDb;
  late Directory root;
  late InMemoryMediaObjectStore store;
  late SharedPreferences prefs;

  void writeMarker(String storeId) {
    store.objects['smv1/store.json'] = utf8.encode(
      jsonEncode({'storeId': storeId, 'formatVersion': 1, 'createdAt': ''}),
    );
  }

  setUp(() async {
    // Attached to store-1, whose marker the store carries: the preflight
    // every sweep runs passes.
    SharedPreferences.setMockInitialValues({
      MediaStoreAttachState.storeIdKey: 'store-1',
    });
    prefs = await SharedPreferences.getInstance();
    await setUpTestDatabase();
    cacheDb = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    root = await Directory.systemTemp.createTemp('verify_runner');
    useFakePathProvider(_TempPathProvider(root.path));
    store = InMemoryMediaObjectStore();
    writeMarker('store-1');
  });

  tearDown(() async {
    await cacheDb.close();
    await root.delete(recursive: true);
    await tearDownTestDatabase();
  });

  ProviderContainer container({
    bool attached = true,
    OrphanDeletePolicy Function()? policy,
  }) {
    final cache = MediaCacheStore(database: cacheDb, root: root);
    final c = ProviderContainer(
      overrides: [
        // The delete policy reads the sync snapshot and restore time here.
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (policy != null)
          orphanDeletePolicyFactoryProvider.overrideWithValue(policy),
        mediaRepositoryProvider.overrideWithValue(MediaRepository()),
        mediaTransferQueueRepositoryProvider.overrideWithValue(
          MediaTransferQueueRepository(database: cacheDb),
        ),
        mediaStoreRuntimeProvider.overrideWith(
          (ref) async => attached
              ? MediaStoreRuntime(
                  storeId: 'store-1',
                  store: store,
                  cache: cache,
                  resolver: MediaStoreResolver(store: store, cache: cache),
                )
              : null,
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'runner sweeps the attached store and stamps the fleet timestamp',
    () async {
      final storesRepository = MediaStoresRepository();
      await storesRepository.upsertActive(
        storeId: 'store-1',
        providerType: 's3',
        displayHint: 'test',
      );
      store.staleSessionCount = 1;

      final report = await container().read(mediaVerifyRunnerProvider)();

      expect(report.objectsChecked, 0);
      expect(report.sessionsAborted, 1);
      expect((await storesRepository.getActive())!.lastSweepAt, isNotNull);
    },
  );

  test('a deferred run does not stamp the fleet timestamp', () async {
    // Stamping a run that deleted nothing would hold every device's
    // cleanup off for a week.
    final storesRepository = MediaStoresRepository();
    await storesRepository.upsertActive(
      storeId: 'store-1',
      providerType: 's3',
      displayHint: 'test',
    );

    final report = await container(
      policy: () => OrphanDeletePolicy(now: DateTime.now(), syncEnabled: true),
    ).read(mediaVerifyRunnerProvider)();

    expect(report.deferred, isTrue);
    expect((await storesRepository.getActive())!.lastSweepAt, isNull);
  });

  test('runner without an active descriptor still returns a report', () async {
    final report = await container().read(mediaVerifyRunnerProvider)();
    expect(report.orphansRemoved, 0);
  });

  test('runner throws StateError when no store is attached', () async {
    await expectLater(
      container(attached: false).read(mediaVerifyRunnerProvider)(),
      throwsStateError,
    );
  });

  test('a store that fails its marker check is not swept', () async {
    // Repointed or wiped: its objects are not this library's to judge.
    writeMarker('another-library');

    await expectLater(
      container().read(mediaVerifyRunnerProvider)(),
      throwsStateError,
    );
  });
}

/// Points the temporary directory at the test's own folder: the store
/// marker read goes through it.
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.path);

  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}
