import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/services/sync/changeset_log/sync_manifest.dart';
import 'package:submersion/core/services/sync/peer_sync_snapshot.dart';

SyncManifest _manifest(String deviceId, int updatedAt) => SyncManifest(
  deviceId: deviceId,
  provider: 'test',
  headSeq: 1,
  updatedAt: updatedAt,
);

void main() {
  final now = DateTime(2026, 10, 17, 12);

  PeerSyncSnapshot build({
    List<SyncManifest>? manifests,
    Set<String> fenced = const {},
    Set<String> skipped = const {},
    Set<String> readFailed = const {},
    Set<String> newerSchema = const {},
    int recordsFailed = 0,
  }) => buildPeerSyncSnapshot(
    now: now,
    selfDeviceId: 'self',
    peerManifests: manifests ?? [_manifest('a', 1000)],
    fencedPeerIds: fenced,
    skippedPeerIds: skipped,
    readFailedPeerIds: readFailed,
    newerSchemaPeerIds: newerSchema,
    recordsFailed: recordsFailed,
  );

  test('excludes self, fenced and stale-epoch peers', () {
    final snapshot = build(
      manifests: [
        _manifest('self', 5),
        _manifest('a', 1000),
        _manifest('b', 2000),
        _manifest('c', 3000),
      ],
      fenced: {'b'},
      skipped: {'c'},
    );

    expect(snapshot.takenAt, now);
    expect(snapshot.peers.map((p) => p.deviceId), ['a']);
    expect(
      snapshot.peers.single.publishedAt,
      DateTime.fromMillisecondsSinceEpoch(1000),
    );
  });

  test('is caught up only after a clean pull', () {
    expect(build().caughtUp, isTrue);
    expect(build(recordsFailed: 1).caughtUp, isFalse);
    expect(build(readFailed: {'a'}).caughtUp, isFalse);
    expect(build(newerSchema: {'a'}).caughtUp, isFalse);
  });

  group('PeerSyncSnapshotStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips through the store', () async {
      final store = PeerSyncSnapshotStore(
        await SharedPreferences.getInstance(),
      );
      final snapshot = build();

      await store.write(snapshot);
      final read = store.read()!;

      expect(read.takenAt, snapshot.takenAt);
      expect(read.caughtUp, isTrue);
      expect(read.peers.single.deviceId, 'a');
      expect(read.peers.single.publishedAt, snapshot.peers.single.publishedAt);
    });

    test('read returns null when nothing was written', () async {
      final store = PeerSyncSnapshotStore(
        await SharedPreferences.getInstance(),
      );
      expect(store.read(), isNull);
    });

    test('read returns null for malformed json', () async {
      SharedPreferences.setMockInitialValues({PeerSyncSnapshotStore.key: '{'});
      final store = PeerSyncSnapshotStore(
        await SharedPreferences.getInstance(),
      );
      expect(store.read(), isNull);
    });
  });
}
