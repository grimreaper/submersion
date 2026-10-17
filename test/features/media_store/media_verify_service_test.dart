import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/store_keys.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/data/media_verify_service.dart';
import 'package:submersion/features/media_store/data/orphan_delete_policy.dart';
import 'package:submersion/core/services/media_store/network_status_service.dart';
import 'package:submersion/core/database/local_cache_database.dart';

import '../../helpers/in_memory_media_object_store.dart';
import '../../helpers/test_database.dart';

/// Lists a key once per stored copy, as Google Drive does when two devices
/// uploaded one key at the same moment; each delete removes one copy.
class _DuplicatingStore extends InMemoryMediaObjectStore
    implements DuplicateKeyStore {
  final copies = <String, int>{};

  @override
  Future<int> deleteExtraCopies(String key) async {
    final extra = (copies[key] ?? 1) - 1;
    if (extra > 0) copies[key] = 1;
    return extra;
  }

  @override
  Stream<StoreObjectInfo> list(String keyPrefix) async* {
    await for (final info in super.list(keyPrefix)) {
      for (var i = 0; i < (copies[info.key] ?? 1); i++) {
        yield info;
      }
    }
  }

  @override
  Future<void> delete(String key) async {
    final n = copies[key] ?? 1;
    if (n > 1) {
      copies[key] = n - 1;
      return;
    }
    copies.remove(key);
    await super.delete(key);
  }
}

/// Repeats every listed key, as a paged listing might, while holding one
/// object per key.
class _RepeatingStore extends InMemoryMediaObjectStore {
  @override
  Stream<StoreObjectInfo> list(String keyPrefix) async* {
    await for (final info in super.list(keyPrefix)) {
      yield info;
      yield info;
    }
  }
}

class _ReapThrowingStore extends InMemoryMediaObjectStore {
  @override
  Future<int> reapStaleUploadSessions({required DateTime olderThan}) async {
    throw Exception('list-uploads unavailable');
  }
}

void main() {
  late AppDatabase db;
  late LocalCacheDatabase cacheDb;
  late MediaTransferQueueRepository queue;
  late MediaRepository repo;
  late InMemoryMediaObjectStore store;
  late MediaVerifyService service;

  final now = DateTime.utc(2026, 7, 23);
  final old = now.subtract(const Duration(days: 30));

  setUp(() async {
    db = await setUpTestDatabase();
    cacheDb = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    queue = MediaTransferQueueRepository(database: cacheDb);
    repo = MediaRepository();
    store = InMemoryMediaObjectStore();
    service = MediaVerifyService(
      store: store,
      mediaRepository: repo,
      queue: queue,
      now: () => now,
    );
  });

  tearDown(() async {
    await cacheDb.close();
    await tearDownTestDatabase();
  });

  Future<void> insertDive(String id) async {
    final epoch = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: Value(id),
            diveDateTime: Value(epoch),
            createdAt: Value(epoch),
            updatedAt: Value(epoch),
          ),
        );
  }

  Future<MediaItem> photo(
    String name, {
    required String hash,
    DateTime? uploadedAt,
    DateTime? thumbAt,
    DateTime? compressedAt,
  }) async {
    final created = await repo.createMedia(
      MediaItem(
        id: '',
        mediaType: MediaType.photo,
        sourceType: MediaSourceType.platformGallery,
        filePath: '/tmp/$name',
        localPath: '/tmp/$name',
        originalFilename: name,
        diveId: 'd1',
        contentHash: hash,
        takenAt: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ),
    );
    if (uploadedAt != null) {
      await repo.stampRemoteUploaded(created.id, uploadedAt: uploadedAt);
    }
    if (thumbAt != null) {
      await repo.stampRemoteThumbUploaded(created.id, uploadedAt: thumbAt);
    }
    if (compressedAt != null) {
      await repo.stampRemoteCompressedUploaded(
        created.id,
        uploadedAt: compressedAt,
        level: 'balanced',
        sizeBytes: 10,
      );
    }
    return created;
  }

  void seedObject(String key, {required DateTime modified, int size = 3}) {
    store.objects[key] = List.filled(size, 7);
    store.modified[key] = modified;
  }

  test('deletes old unreferenced objects across all three namespaces, '
      'sparing referenced, young, and marker objects', () async {
    await insertDive('d1');
    await photo('kept.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));

    // Referenced (survives), old orphan in each namespace (dies), young
    // orphan (grace window), and the store marker (never touched).
    final keptKey = StoreKeys.objectKey('aabb', extension: 'jpg');
    seedObject(keptKey, modified: old);
    seedObject(StoreKeys.objectKey('dead', extension: 'jpg'), modified: old);
    seedObject(StoreKeys.thumbKey('dead'), modified: old, size: 5);
    seedObject(StoreKeys.renditionKey('dead', ext: 'jpg'), modified: old);
    seedObject(
      StoreKeys.objectKey('f00d', extension: 'jpg'),
      modified: now.subtract(const Duration(hours: 1)),
    );
    seedObject(StoreKeys.markerKey, modified: old);
    // Old and unreferenced, but not content-addressed shaped: never deleted.
    seedObject('smv1/objects/zz/not-a-hash.jpg', modified: old);

    final report = await service.run();

    expect(store.objects.keys, contains(keptKey));
    expect(store.objects.keys, contains(StoreKeys.markerKey));
    expect(
      store.objects.keys,
      contains(StoreKeys.objectKey('f00d', extension: 'jpg')),
      reason: 'young orphan is protected by the grace window',
    );
    expect(
      store.objects.keys,
      contains('smv1/objects/zz/not-a-hash.jpg'),
      reason: 'malformed keys are never deleted',
    );
    expect(
      store.objects.keys,
      isNot(contains(StoreKeys.objectKey('dead', extension: 'jpg'))),
    );
    expect(store.objects.keys, isNot(contains(StoreKeys.thumbKey('dead'))));
    expect(report.orphansRemoved, 3);
    expect(report.bytesReclaimed, 11); // 3 + 5 + 3
    expect(report.objectsChecked, 6); // marker is outside the namespaces
    // The total counts every stored object, so a library of N photos reads
    // as 2N or 3N; the breakdown is what makes that number explainable.
    expect(report.originalsChecked, 4);
    expect(report.thumbsChecked, 1);
    expect(report.renditionsChecked, 1);
    expect(report.repairsQueued, 0);
  });

  test(
    'reverse repair clears the stale stamp and queues a re-upload',
    () async {
      await insertDive('d1');
      final missingOriginal = await photo(
        'missing.jpg',
        hash: 'cc11',
        uploadedAt: DateTime(2026, 2),
        thumbAt: DateTime(2026, 2),
      );
      // Thumb object exists; original object is absent from the store.
      seedObject(StoreKeys.thumbKey('cc11'), modified: old);

      final report = await service.run();

      final got = await repo.getMediaById(missingOriginal.id);
      expect(got!.remoteUploadedAt, isNull, reason: 'stale stamp cleared');
      expect(got.remoteThumbUploadedAt, isNotNull, reason: 'thumb is present');
      expect(report.repairsQueued, 1);
      final entry = (await queue.allForTesting()).single;
      expect(entry.direction, 'upload');
      expect(entry.mediaId, missingOriginal.id);
    },
  );

  test('a failing object delete is best-effort within the sweep', () async {
    await insertDive('d1');
    seedObject(StoreKeys.objectKey('dead', extension: 'jpg'), modified: old);
    store.failDeleteWith = Exception('delete refused');
    final report = await service.run();
    expect(report.orphansRemoved, 0);
    expect(
      store.objects.keys,
      contains(StoreKeys.objectKey('dead', extension: 'jpg')),
    );
  });

  test(
    'reverse repair clears thumb and rendition stamps independently',
    () async {
      await insertDive('d1');
      final item = await photo(
        'tiers.jpg',
        hash: 'ee33',
        thumbAt: DateTime(2026, 2),
        compressedAt: DateTime(2026, 2),
      );
      // Neither the thumb nor the rendition object exists in the store.
      final report = await service.run();
      final got = await repo.getMediaById(item.id);
      expect(got!.remoteThumbUploadedAt, isNull);
      expect(got.remoteCompressedUploadedAt, isNull);
      expect(report.repairsQueued, 1);
    },
  );

  test('reverse repair re-arms a terminally failed upload row', () async {
    await insertDive('d1');
    final item = await photo(
      'stuck.jpg',
      hash: 'dd22',
      uploadedAt: DateTime(2026, 2),
    );
    final rowId = await queue.enqueueUpload(mediaId: item.id);
    for (var i = 0; i < 5; i++) {
      await queue.markFailed(rowId, 'boom');
    }
    expect((await queue.allForTesting()).single.state, 'failed');

    final report = await service.run(); // original object absent -> repair

    expect(report.repairsQueued, 1);
    final row = (await queue.allForTesting()).single;
    expect(row.id, rowId);
    expect(row.state, 'pending', reason: 'repair re-arms the failed row');
  });

  test(
    'a failing session reap is best-effort: the sweep still succeeds',
    () async {
      await insertDive('d1');
      seedObject(StoreKeys.objectKey('dead', extension: 'jpg'), modified: old);
      final throwingStore = _ReapThrowingStore()
        ..objects.addAll(store.objects)
        ..modified.addAll(store.modified);
      final failing = MediaVerifyService(
        store: throwingStore,
        mediaRepository: repo,
        queue: queue,
        now: () => now,
      );
      final report = await failing.run();
      expect(report.orphansRemoved, 1, reason: 'earlier cleanup still counts');
      expect(report.sessionsAborted, 0);
    },
  );

  test('sessionsAborted passes through the store reap', () async {
    store.staleSessionCount = 2;
    final report = await service.run();
    expect(report.sessionsAborted, 2);
  });

  group('shouldAutoVerify', () {
    final now = DateTime.utc(2026, 7, 23);

    test('never swept + unmetered runs', () {
      expect(
        shouldAutoVerify(
          lastSweepAt: null,
          network: NetworkKind.unmetered,
          now: now,
        ),
        isTrue,
      );
    });

    test('stale sweep + unmetered runs', () {
      expect(
        shouldAutoVerify(
          lastSweepAt: now.subtract(const Duration(days: 31)),
          network: NetworkKind.unmetered,
          now: now,
        ),
        isTrue,
      );
    });

    test('fresh sweep skips', () {
      expect(
        shouldAutoVerify(
          lastSweepAt: now.subtract(const Duration(days: 5)),
          network: NetworkKind.unmetered,
          now: now,
        ),
        isFalse,
      );
    });

    test('a slightly-future stamp reads as freshly swept and skips', () {
      expect(
        shouldAutoVerify(
          lastSweepAt: now.add(const Duration(hours: 2)),
          network: NetworkKind.unmetered,
          now: now,
        ),
        isFalse,
      );
    });

    test('a far-future stamp is bogus clock skew and does not suppress', () {
      expect(
        shouldAutoVerify(
          lastSweepAt: now.add(const Duration(days: 90)),
          network: NetworkKind.unmetered,
          now: now,
        ),
        isTrue,
      );
    });

    test('cellular and offline never run', () {
      for (final kind in [NetworkKind.cellular, NetworkKind.offline]) {
        expect(
          shouldAutoVerify(lastSweepAt: null, network: kind, now: now),
          isFalse,
        );
      }
    });
  });

  test('onProgress reports monotonically increasing counts', () async {
    await insertDive('d1');
    seedObject(StoreKeys.objectKey('x1', extension: 'jpg'), modified: old);
    seedObject(StoreKeys.thumbKey('x2'), modified: old);
    final seen = <int>[];
    await service.run(onProgress: seen.add);
    expect(seen, isNotEmpty);
    expect(seen.last, 2);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });

  group('storage GC', () {
    test('dry run deletes nothing and reports reclaimable bytes', () async {
      await insertDive('d1');
      seedObject(StoreKeys.objectKey('dead', extension: 'jpg'), modified: old);
      store.staleSessionCount = 2;

      final report = await service.run(dryRun: true);

      expect(
        store.objects.keys,
        contains(StoreKeys.objectKey('dead', extension: 'jpg')),
      );
      expect(report.orphansRemoved, 0);
      expect(report.bytesReclaimed, 0);
      expect(report.reclaimableBytes, 3);
      expect(report.sessionsAborted, 0, reason: 'a dry run reaps nothing');
    });

    test('deferred policy deletes nothing and reports waiting bytes', () async {
      await insertDive('d1');
      seedObject(StoreKeys.objectKey('dead', extension: 'jpg'), modified: old);

      final report = await service.run(
        policy: OrphanDeletePolicy(now: now, syncEnabled: true),
      );

      expect(report.deferred, isTrue);
      expect(report.orphansRemoved, 0);
      expect(report.reclaimableBytes, 0);
      expect(report.waitingBytes, 3);
    });

    test(
      'deletes an unreferenced extension sibling past the grace window',
      () async {
        await insertDive('d1');
        await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
        final kept = StoreKeys.objectKey('aabb', extension: 'jpg');
        final sibling = StoreKeys.objectKey('aabb', extension: 'jpeg');
        final staleRendition = StoreKeys.renditionKey('aabb', ext: 'jpg');
        seedObject(kept, modified: old);
        seedObject(sibling, modified: old);
        seedObject(staleRendition, modified: old);

        final report = await service.run();

        expect(store.objects.keys, contains(kept));
        expect(store.objects.keys, isNot(contains(sibling)));
        expect(store.objects.keys, isNot(contains(staleRendition)));
        expect(report.orphansRemoved, 2);
      },
    );

    test('keeps a sibling a pending row still needs', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      // Same bytes under another name, upload not finished: no stamp yet.
      await photo('b.jpeg', hash: 'aabb');
      final sibling = StoreKeys.objectKey('aabb', extension: 'jpeg');
      seedObject(StoreKeys.objectKey('aabb', extension: 'jpg'), modified: old);
      seedObject(sibling, modified: old);

      final report = await service.run();

      expect(store.objects.keys, contains(sibling));
      expect(report.orphansRemoved, 0);
    });

    test('keeps a sibling when it is the only copy of the photo', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      // The row's own key is missing; the resolver can still fall back to
      // this variant, so it must not be deleted.
      final onlyCopy = StoreKeys.objectKey('aabb', extension: 'jpeg');
      seedObject(onlyCopy, modified: old);

      final report = await service.run();

      expect(store.objects.keys, contains(onlyCopy));
      expect(report.orphansRemoved, 0);
    });

    test('deletes extra copies of a duplicated key and keeps one', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      final dup = _DuplicatingStore();
      final key = StoreKeys.objectKey('aabb', extension: 'jpg');
      dup.objects[key] = List.filled(3, 7);
      dup.modified[key] = old;
      dup.copies[key] = 3;
      final sweep = MediaVerifyService(
        store: dup,
        mediaRepository: repo,
        queue: queue,
        now: () => now,
      );

      final report = await sweep.run();

      expect(dup.objects.keys, contains(key));
      expect(dup.copies[key], 1, reason: 'one copy left');
      expect(report.orphansRemoved, 2);
      expect(report.totalBytes, 9);
    });

    test('a store that cannot hold duplicates is never asked to', () async {
      // A listing that repeats a key on S3 is a listing artefact, not two
      // objects: deleting "the extra copy" would delete the only one.
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      final repeating = _RepeatingStore();
      final key = StoreKeys.objectKey('aabb', extension: 'jpg');
      repeating.objects[key] = List.filled(3, 7);
      repeating.modified[key] = old;
      final sweep = MediaVerifyService(
        store: repeating,
        mediaRepository: repo,
        queue: queue,
        now: () => now,
      );

      final report = await sweep.run();

      expect(repeating.objects.keys, contains(key));
      expect(report.orphansRemoved, 0);
    });

    test('a repeated orphan on a plain store is counted once', () async {
      await insertDive('d1');
      final repeating = _RepeatingStore();
      final key = StoreKeys.objectKey('dead', extension: 'jpg');
      repeating.objects[key] = List.filled(3, 7);
      repeating.modified[key] = old;
      final sweep = MediaVerifyService(
        store: repeating,
        mediaRepository: repo,
        queue: queue,
        now: () => now,
      );

      final report = await sweep.run();

      expect(repeating.objects.keys, isNot(contains(key)));
      expect(report.orphansRemoved, 1);
      expect(report.bytesReclaimed, 3);
    });

    test('duplicates wait while deletes are deferred', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      final dup = _DuplicatingStore();
      final key = StoreKeys.objectKey('aabb', extension: 'jpg');
      dup.objects[key] = List.filled(3, 7);
      dup.modified[key] = old;
      dup.copies[key] = 2;
      final sweep = MediaVerifyService(
        store: dup,
        mediaRepository: repo,
        queue: queue,
        now: () => now,
      );

      await sweep.run(policy: OrphanDeletePolicy(now: now, syncEnabled: true));

      expect(dup.copies[key], 2);
    });

    test('a key listed once is never deleted as a duplicate', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      final key = StoreKeys.objectKey('aabb', extension: 'jpg');
      seedObject(key, modified: old);

      final report = await service.run();

      expect(store.objects.keys, contains(key));
      expect(report.orphansRemoved, 0);
    });

    test('totalBytes sums every listed object', () async {
      await insertDive('d1');
      await photo('a.jpg', hash: 'aabb', uploadedAt: DateTime(2026, 2));
      seedObject(StoreKeys.objectKey('aabb', extension: 'jpg'), modified: old);
      seedObject(StoreKeys.thumbKey('aabb'), modified: old, size: 5);
      seedObject(
        StoreKeys.objectKey('f00d', extension: 'jpg'),
        modified: now.subtract(const Duration(hours: 1)),
        size: 7,
      );

      final report = await service.run();

      expect(report.totalBytes, 15);
      expect(report.waitingBytes, 7);
    });
  });
}
