// Issue #3482 phase 5: once a replace and join commits, every queued
// transfer names the replaced library's media, so the whole queue goes.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';

void main() {
  late LocalCacheDatabase db;
  late MediaTransferQueueRepository repo;

  setUp(() {
    db = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    repo = MediaTransferQueueRepository(database: db);
  });

  tearDown(() => db.close());

  test('clears rows in every state and direction', () async {
    await repo.enqueueUpload(mediaId: 'pending');
    final transferring = await repo.enqueueUpload(mediaId: 'moving');
    await repo.markTransferring(transferring);
    final failed = await repo.enqueueUpload(mediaId: 'failed');
    for (var i = 0; i < 5; i++) {
      await repo.markFailed(failed, 'boom');
    }
    final done = await repo.enqueueDelete(
      mediaId: 'gone',
      contentHash: 'h1',
      originalExt: 'jpg',
      renditionExt: 'jpg',
    );
    await repo.markDone(done);

    expect(await repo.clearAll(), 4);
    expect(await repo.allForTesting(), isEmpty);
  });

  test('an empty queue clears nothing', () async {
    expect(await repo.clearAll(), 0);
  });
}
