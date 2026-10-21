// Issue #3569: a device on a store the library no longer announces does not
// re-upload rows stamped in another store, so it never erases the announced
// store's record and the two devices never trade the row back and forth.

import 'dart:io';
import 'dart:ui' show Size;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/core/database/app_sql_functions.dart';
import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/media_source_resolver_registry.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media/domain/services/media_source_resolver.dart';
import 'package:submersion/features/media/domain/value_objects/media_source_data.dart';
import 'package:submersion/features/media/domain/value_objects/verify_result.dart';
import 'package:submersion/features/media_store/data/media_cache_store.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/data/media_upload_pipeline.dart';

import '../../helpers/in_memory_media_object_store.dart';
import '../../helpers/test_database.dart';

/// Serves one local file for every row.
class _FileResolver implements MediaSourceResolver {
  _FileResolver(this.file);
  final File file;

  @override
  MediaSourceType get sourceType => MediaSourceType.localFile;

  @override
  bool canResolveOnThisDevice(MediaItem item) => true;

  @override
  Future<MediaSourceData> resolve(MediaItem item) async => FileData(file: file);

  @override
  Future<MediaSourceData> resolveThumbnail(
    MediaItem item, {
    required Size target,
  }) async => FileData(file: file);

  @override
  Future<VerifyResult> verify(MediaItem item) async => VerifyResult.available;
}

void main() {
  late AppDatabase db;
  late MediaRepository repo;
  late LocalCacheDatabase cacheDb;
  late Directory root;
  late MediaTransferQueueRepository queue;

  setUp(() async {
    db = await setUpTestDatabase();
    repo = MediaRepository();
    cacheDb = LocalCacheDatabase(
      NativeDatabase.memory(setup: registerAppSqlFunctions),
    );
    root = await Directory.systemTemp.createTemp('pipeline_takeover');
    queue = MediaTransferQueueRepository(database: cacheDb);
    final epoch = DateTime(2026).millisecondsSinceEpoch;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion(
            id: const Value('d1'),
            diveDateTime: Value(epoch),
            createdAt: Value(epoch),
            updatedAt: Value(epoch),
          ),
        );
  });

  tearDown(() async {
    await cacheDb.close();
    if (root.existsSync()) await root.delete(recursive: true);
    await tearDownTestDatabase();
  });

  test('a device on a store that is not announced skips a row stamped '
      'elsewhere', () async {
    final created = await repo.createMedia(
      MediaItem(
        id: '',
        mediaType: MediaType.photo,
        sourceType: MediaSourceType.localFile,
        filePath: 'moved.jpg',
        localPath: 'moved.jpg',
        originalFilename: 'moved.jpg',
        diveId: 'd1',
        contentHash: 'h1',
        takenAt: DateTime(2026),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    await repo.stampRemoteUploaded(
      created.id,
      uploadedAt: DateTime.utc(2026),
      storeId: 'store-b',
    );
    await queue.enqueueUpload(mediaId: created.id);
    final store = InMemoryMediaObjectStore();

    final outcome = await MediaUploadPipeline(
      mediaRepository: repo,
      queue: queue,
      store: store,
      registry: MediaSourceResolverRegistry(const {}),
      cache: MediaCacheStore(database: cacheDb, root: root),
      storeId: 'store-a',
      takesOver: () async => false,
    ).process((await queue.nextPending(DateTime.now()))!);

    expect(outcome, UploadOutcome.deduplicated);
    expect(store.objects, isEmpty);
    final after = (await repo.getMediaById(created.id))!;
    expect(after.remoteStoreId, 'store-b');
    expect(after.remoteUploadedAt, isNotNull);
  });

  // Issue #3569 review: the library can move to another store while this
  // upload stages and transfers; the stamp it ends with must not undo that.
  test('a takeover that lands mid-upload keeps the announced store\'s '
      'stamps', () async {
    final file = File(p.join(root.path, 'fresh.jpg'))
      ..writeAsBytesSync([1, 2, 3, 4]);
    final created = await repo.createMedia(
      MediaItem(
        id: '',
        mediaType: MediaType.photo,
        sourceType: MediaSourceType.localFile,
        filePath: file.path,
        localPath: file.path,
        originalFilename: 'fresh.jpg',
        diveId: 'd1',
        takenAt: DateTime(2026),
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    await queue.enqueueUpload(mediaId: created.id);
    final takenOverAt = DateTime.utc(2026, 5, 5);
    var asked = 0;

    await MediaUploadPipeline(
      mediaRepository: repo,
      queue: queue,
      store: InMemoryMediaObjectStore(),
      registry: MediaSourceResolverRegistry({
        MediaSourceType.localFile: _FileResolver(file),
      }),
      cache: MediaCacheStore(database: cacheDb, root: root),
      storeId: 'store-a',
      // The first ask is just before a stamp: by then another device has
      // moved the library to store-b and its stamp has synced in.
      takesOver: () async {
        if (asked++ == 0) {
          await repo.stampRemoteUploaded(
            created.id,
            uploadedAt: takenOverAt,
            storeId: 'store-b',
          );
        }
        return false;
      },
    ).process((await queue.nextPending(DateTime.now()))!);

    final after = (await repo.getMediaById(created.id))!;
    expect(asked, greaterThan(0), reason: 'asked again before stamping');
    expect(after.remoteStoreId, 'store-b');
    expect(
      after.remoteUploadedAt?.millisecondsSinceEpoch,
      takenOverAt.millisecondsSinceEpoch,
    );
  });
}
