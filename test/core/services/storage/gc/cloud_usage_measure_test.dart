import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/shared_library/shared_library_transport.dart';
import 'package:submersion/core/services/storage/gc/cloud_usage_measure.dart';

import '../../../../helpers/fake_cloud_storage_provider.dart';

/// Keys folders by path and lists like S3: a folder's listing holds every
/// object below it, nested libraries included.
class _PathProvider extends FakeCloudStorageProvider {
  final files = <String, int?>{};

  @override
  Future<String> createFolder(
    String folderName, {
    String? parentFolderId,
  }) async => (parentFolderId == null || parentFolderId.isEmpty)
      ? folderName
      : '$parentFolderId/$folderName';

  @override
  Future<List<CloudFileInfo>> listFiles({
    String? folderId,
    String? namePattern,
  }) async => [
    for (final e in files.entries)
      if (folderId == null || e.key.startsWith('$folderId/'))
        CloudFileInfo(
          id: e.key,
          name: e.key.split('/').last,
          modifiedTime: DateTime(2026),
          sizeBytes: e.value,
        ),
  ];
}

void main() {
  test('sums only sync files', () async {
    final cloud = FakeCloudStorageProvider();
    await cloud.uploadFile(Uint8List(10), 'ssv1.dev1.manifest.json');
    await cloud.uploadFile(Uint8List(20), 'ssv1.dev1.cs.000000000001.json');
    await cloud.uploadFile(Uint8List(99), 'submersion_backup_x.db');
    await cloud.uploadFile(Uint8List(7), 'ssv1.bogus');

    expect(await measureSyncFolderBytes(cloud), 30);
  });

  test('library measure ignores nested library folders', () async {
    final cloud = _PathProvider();
    const root = 'submersion-sites/site-sync';
    cloud.files.addAll({
      '$root/submersion-shared-library.json': 5,
      '$root/keyslots.json': 6,
      '$root/sites/site-a.json': 10,
      '$root/members/member-m1.json': 3,
      '$root/suggestions/suggestion-g1.json': 2,
      '$root/backups/index.json': 4,
      '$root/backups/backup-1.zip': 100,
      // A library nested under this one: not ours to count.
      '$root/nested/submersion-shared-library.json': 50,
      '$root/nested/sites/site-z.json': 50,
    });

    final measured = await SharedLibraryTransport(
      cloud,
      prefix: 'site-sync',
    ).measureBytes();

    expect(measured.bytes, 5 + 6 + 10 + 3 + 2 + 4 + 100);
    expect(measured.partial, isFalse);
  });

  test('a file without a size marks the library partial', () async {
    final cloud = _PathProvider();
    cloud.files['submersion-sites/site-sync/sites/site-a.json'] = null;
    cloud.files['submersion-sites/site-sync/keyslots.json'] = 6;

    final measured = await SharedLibraryTransport(
      cloud,
      prefix: 'site-sync',
    ).measureBytes();

    expect(measured.bytes, 6);
    expect(measured.partial, isTrue);
  });

  test('CloudUsage round-trips through json', () {
    final usage = CloudUsage(
      mediaBytes: 100,
      mediaReclaimableBytes: 10,
      mediaWaitingBytes: 5,
      syncBytes: 30,
      librariesBytes: null,
      partial: true,
      scannedAt: DateTime(2026, 10, 17, 12),
    );

    final back = CloudUsage.fromJson(usage.toJson());

    expect(back.mediaBytes, 100);
    expect(back.mediaReclaimableBytes, 10);
    expect(back.mediaWaitingBytes, 5);
    expect(back.syncBytes, 30);
    expect(back.librariesBytes, isNull);
    expect(back.partial, isTrue);
    expect(back.scannedAt, usage.scannedAt);
  });
}
