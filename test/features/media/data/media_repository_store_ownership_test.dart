// Issue #3482 phase 4: upload stamps name the store they refer to, so a
// device that switches stores counts and uploads to the new one from zero.
// A stamp with no store predates the column and counts for the attached
// store until a switch claims it for the store it was made in.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';

import '../../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late MediaRepository repo;
  final at = DateTime.utc(2026, 10, 20);

  setUp(() async {
    db = await setUpTestDatabase();
    repo = MediaRepository();
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: const Value('dive-1'),
            diveDateTime: Value(DateTime(2026).millisecondsSinceEpoch),
            createdAt: Value(DateTime(2026).millisecondsSinceEpoch),
            updatedAt: Value(DateTime(2026).millisecondsSinceEpoch),
          ),
        );
  });
  tearDown(tearDownTestDatabase);

  Future<String> add(
    String name, {
    bool original = false,
    bool compressed = false,
    bool thumb = false,
    String? store,
  }) async {
    final created = await repo.createMedia(
      MediaItem(
        id: '',
        mediaType: MediaType.photo,
        sourceType: MediaSourceType.platformGallery,
        filePath: '/tmp/$name',
        localPath: '/tmp/$name',
        originalFilename: name,
        diveId: 'dive-1',
        takenAt: DateTime(2026),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    await (db.update(db.media)..where((m) => m.id.equals(created.id))).write(
      MediaCompanion(
        remoteUploadedAt: Value(original ? 1 : null),
        remoteCompressedUploadedAt: Value(compressed ? 1 : null),
        compressedLevel: Value(compressed ? 'high' : null),
        compressedSizeBytes: Value(compressed ? 10 : null),
        remoteThumbUploadedAt: Value(thumb ? 1 : null),
        remoteStoreId: Value(store),
      ),
    );
    return created.id;
  }

  Future<MediaData> row(String id) =>
      (db.select(db.media)..where((m) => m.id.equals(id))).getSingle();

  group('counting and backfill for a store', () {
    test('stamps made in another store are not copies here', () async {
      await add('old-store.jpg', original: true, store: 'store-a');
      await add('this-store.jpg', original: true, store: 'store-b');
      await add('unclaimed.jpg', original: true);
      await add('waiting.jpg');

      final progress = await repo.countUploadProgress(storeId: 'store-b');

      expect(progress.total, 4);
      expect(progress.copied, 2, reason: 'this store and the unclaimed one');
    });

    test('the backfill uploads what another store holds', () async {
      final old = await add('old-store.jpg', original: true, store: 'store-a');
      await add('this-store.jpg', original: true, store: 'store-b');
      final waiting = await add('waiting.jpg');

      final ids = await repo.getBackfillCandidateIds(storeId: 'store-b');

      expect(ids.toSet(), {old, waiting});
    });

    test('with no store named, any stamp counts', () async {
      await add('old-store.jpg', original: true, store: 'store-a');
      expect((await repo.countUploadProgress()).copied, 1);
      expect(await repo.getBackfillCandidateIds(), isEmpty);
    });
  });

  group('stamping for a store', () {
    test('records the store with the stamp', () async {
      final id = await add('new.jpg');

      await repo.stampRemoteUploaded(id, uploadedAt: at, storeId: 'store-b');

      expect((await row(id)).remoteStoreId, 'store-b');
    });

    test('a stamp for a new store clears the old store\'s stamps', () async {
      final id = await add(
        'moved.jpg',
        compressed: true,
        thumb: true,
        store: 'store-a',
      );

      await repo.stampRemoteThumbUploaded(
        id,
        uploadedAt: at,
        storeId: 'store-b',
      );

      final r = await row(id);
      expect(r.remoteStoreId, 'store-b');
      expect(r.remoteThumbUploadedAt, at.millisecondsSinceEpoch);
      expect(r.remoteCompressedUploadedAt, isNull);
      expect(r.compressedLevel, isNull);
      expect(r.compressedSizeBytes, isNull);
    });

    test('an unclaimed row keeps its stamps and takes the store', () async {
      final id = await add('legacy.jpg', thumb: true);

      await repo.stampRemoteCompressedUploaded(
        id,
        uploadedAt: at,
        level: 'high',
        sizeBytes: 5,
        storeId: 'store-b',
      );

      final r = await row(id);
      expect(r.remoteStoreId, 'store-b');
      expect(r.remoteThumbUploadedAt, 1);
    });
  });

  group('claiming unclaimed stamps', () {
    test('names the store on stamped rows that have none', () async {
      final legacy = await add('legacy.jpg', original: true);
      final thumbOnly = await add('thumb.jpg', thumb: true);
      final other = await add('other.jpg', original: true, store: 'store-c');
      final none = await add('waiting.jpg');

      final claimed = await repo.claimUnownedStamps('store-a');

      expect(claimed, 2);
      expect((await row(legacy)).remoteStoreId, 'store-a');
      expect((await row(thumbOnly)).remoteStoreId, 'store-a');
      expect((await row(other)).remoteStoreId, 'store-c');
      expect((await row(none)).remoteStoreId, isNull);
    });

    test('a claimed row syncs under a new upload clock', () async {
      final legacy = await add('legacy.jpg', original: true);
      final before = (await row(legacy)).uploadFactsHlc;

      await repo.claimUnownedStamps('store-a');

      final after = (await row(legacy)).uploadFactsHlc;
      expect(after, isNotNull);
      expect(after, isNot(before));
    });

    test('after a claim the new store counts from zero', () async {
      await add('legacy.jpg', original: true);
      await repo.claimUnownedStamps('store-a');

      final progress = await repo.countUploadProgress(storeId: 'store-b');
      expect(progress.copied, 0);
      expect(progress.total, 1);
    });
  });
}
