// Issue #3482 phase 5: the steps replace and join takes once the library
// has been swapped, on the app's own stores.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/providers/replace_and_join_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';

import '../../../../support/fake_cloud_storage_provider.dart';

void main() {
  late SharedPreferences prefs;
  late LocalCacheDatabase cacheDb;
  late MediaTransferQueueRepository queue;
  late FakeCloudStorageProvider cloud;
  late ProductionReplaceJoinSteps steps;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    cacheDb = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    queue = MediaTransferQueueRepository(database: cacheDb);
    cloud = FakeCloudStorageProvider();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        mediaTransferQueueRepositoryProvider.overrideWithValue(queue),
        cloudStorageProviderProvider.overrideWithValue(cloud),
      ],
    );
    addTearDown(container.dispose);
    steps = container.read(
      Provider<ProductionReplaceJoinSteps>(ProductionReplaceJoinSteps.new),
    );
  });

  tearDown(() => cacheDb.close());

  test('the photo queue is emptied', () async {
    await queue.enqueueUpload(mediaId: 'old-1');
    await queue.enqueueUpload(mediaId: 'old-2');

    await steps.discardPhotoQueue();

    expect(await queue.allForTesting(), isEmpty);
  });

  test(
    'the account counts as established and no restore sync is left',
    () async {
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await container.read(postRestoreSyncStoreProvider).setPending();

      await steps.settleSyncState();

      expect(
        container
            .read(establishedProviderStoreProvider)
            .contains(cloud.providerId),
        isTrue,
      );
      expect(container.read(postRestoreSyncStoreProvider).pending, isFalse);
    },
  );
}
