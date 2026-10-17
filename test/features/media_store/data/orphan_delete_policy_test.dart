import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/sync/peer_sync_snapshot.dart';
import 'package:submersion/features/media_store/data/orphan_delete_policy.dart';

void main() {
  final now = DateTime(2026, 10, 17, 12);
  final upload = now.subtract(const Duration(days: 2));

  PeerSyncSnapshot snapshot({
    DateTime? takenAt,
    bool caughtUp = true,
    List<Duration> peerPublishedAfterUpload = const [],
  }) => PeerSyncSnapshot(
    takenAt: takenAt ?? now.subtract(const Duration(minutes: 5)),
    caughtUp: caughtUp,
    peers: [
      for (final (i, d) in peerPublishedAfterUpload.indexed)
        PeerPublish(deviceId: 'p$i', publishedAt: upload.add(d)),
    ],
  );

  test('deletes after the grace window with sync off', () {
    final policy = OrphanDeletePolicy.unrestricted(now);
    expect(
      policy.verdictFor(now.subtract(const Duration(days: 8))),
      OrphanVerdict.delete,
    );
  });

  test('waits inside the grace window with sync off', () {
    final policy = OrphanDeletePolicy.unrestricted(now);
    expect(policy.deletesAllowed, isTrue);
    expect(policy.verdictFor(upload), OrphanVerdict.wait);
  });

  test('deletes early once every peer published after the upload', () {
    final policy = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(
        peerPublishedAfterUpload: const [Duration(hours: 3), Duration(days: 1)],
      ),
    );
    expect(policy.verdictFor(upload), OrphanVerdict.delete);
  });

  test('waits while one peer has not published since the upload', () {
    final policy = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(
        peerPublishedAfterUpload: const [
          Duration(hours: 3),
          Duration(hours: -1),
        ],
      ),
    );
    expect(policy.verdictFor(upload), OrphanVerdict.wait);
  });

  test('early delete respects the skew margin', () {
    final policy = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(
        peerPublishedAfterUpload: const [Duration(minutes: 30)],
      ),
    );
    expect(policy.verdictFor(upload), OrphanVerdict.wait);
  });

  test('deletes early with no peers once a pull followed the upload', () {
    final policy = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(),
    );
    expect(policy.verdictFor(upload), OrphanVerdict.delete);
    // An object uploaded after the last pull is not yet covered by it.
    expect(
      policy.verdictFor(now.subtract(const Duration(minutes: 1))),
      OrphanVerdict.wait,
    );
  });

  test('defers when sync is on and no snapshot exists', () {
    final policy = OrphanDeletePolicy(now: now, syncEnabled: true);
    expect(policy.deletesAllowed, isFalse);
    expect(
      policy.verdictFor(now.subtract(const Duration(days: 30))),
      OrphanVerdict.deferred,
    );
  });

  test('defers when the snapshot is not caught up', () {
    final policy = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(caughtUp: false),
    );
    expect(
      policy.verdictFor(now.subtract(const Duration(days: 30))),
      OrphanVerdict.deferred,
    );
  });

  test('policy defers every delete until a pull after the last restore', () {
    final restoredAt = now.subtract(const Duration(hours: 1));
    final before = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(
        takenAt: restoredAt.subtract(const Duration(hours: 1)),
      ),
      lastRestoreAt: restoredAt,
    );
    expect(
      before.verdictFor(now.subtract(const Duration(days: 30))),
      OrphanVerdict.deferred,
    );

    final after = OrphanDeletePolicy(
      now: now,
      syncEnabled: true,
      snapshot: snapshot(takenAt: restoredAt.add(const Duration(minutes: 5))),
      lastRestoreAt: restoredAt,
    );
    expect(
      after.verdictFor(now.subtract(const Duration(days: 30))),
      OrphanVerdict.delete,
    );
  });
}
