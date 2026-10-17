import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/services/sync/changeset_log/sync_manifest.dart';

/// One live peer's most recent publish, as its manifest reported it.
class PeerPublish {
  const PeerPublish({required this.deviceId, required this.publishedAt});

  final String deviceId;

  /// The peer's own wall clock at its last publish (manifest `updatedAt`).
  final DateTime publishedAt;
}

/// What this device knew about its sync peers at the end of its last pull.
///
/// Peer manifests are downloaded on every pull and then discarded; the
/// storage cleanup needs two facts from them long after the pull is over:
/// whether this device applied everything its peers had published (so a row
/// a peer still holds cannot be missing here), and when each peer last
/// published (so an object uploaded before that publish is one the peer has
/// already told us about). See the storage GC design, safety rules.
class PeerSyncSnapshot {
  const PeerSyncSnapshot({
    required this.takenAt,
    required this.caughtUp,
    required this.peers,
  });

  /// When the pull finished, on this device's clock.
  final DateTime takenAt;

  /// True when the pull applied every live peer cleanly: no failed records,
  /// no peer that failed to read, and no peer held for a newer schema.
  final bool caughtUp;

  /// Live peers in the current library epoch, excluding this device.
  final List<PeerPublish> peers;

  Map<String, Object?> toJson() => {
    'takenAt': takenAt.millisecondsSinceEpoch,
    'caughtUp': caughtUp,
    'peers': [
      for (final p in peers)
        {'id': p.deviceId, 'at': p.publishedAt.millisecondsSinceEpoch},
    ],
  };

  factory PeerSyncSnapshot.fromJson(Map<String, Object?> json) {
    final peers = json['peers']! as List<Object?>;
    return PeerSyncSnapshot(
      takenAt: DateTime.fromMillisecondsSinceEpoch(json['takenAt']! as int),
      caughtUp: json['caughtUp']! as bool,
      peers: [
        for (final raw in peers.cast<Map<String, Object?>>())
          PeerPublish(
            deviceId: raw['id']! as String,
            publishedAt: DateTime.fromMillisecondsSinceEpoch(raw['at']! as int),
          ),
      ],
    );
  }
}

/// Builds the snapshot for one finished pull.
///
/// Fenced (retired) peers and stale-epoch peers are left out: neither can
/// publish anything this library will apply. A stale-epoch peer does not
/// spoil [PeerSyncSnapshot.caughtUp] either, since it never will be applied;
/// a peer that failed to read or is held for a newer schema does.
PeerSyncSnapshot buildPeerSyncSnapshot({
  required DateTime now,
  required String selfDeviceId,
  required List<SyncManifest> peerManifests,
  required Set<String> fencedPeerIds,
  required Set<String> skippedPeerIds,
  required Set<String> readFailedPeerIds,
  required Set<String> newerSchemaPeerIds,
  required int recordsFailed,
}) {
  return PeerSyncSnapshot(
    takenAt: now,
    caughtUp:
        recordsFailed == 0 &&
        readFailedPeerIds.isEmpty &&
        newerSchemaPeerIds.isEmpty,
    peers: [
      for (final m in peerManifests)
        if (m.deviceId != selfDeviceId &&
            !fencedPeerIds.contains(m.deviceId) &&
            !skippedPeerIds.contains(m.deviceId))
          PeerPublish(
            deviceId: m.deviceId,
            publishedAt: DateTime.fromMillisecondsSinceEpoch(m.updatedAt),
          ),
    ],
  );
}

/// Device-local persistence for the last [PeerSyncSnapshot].
class PeerSyncSnapshotStore {
  PeerSyncSnapshotStore(this._prefs);

  static const key = 'sync_peer_snapshot_v1';

  final SharedPreferences _prefs;

  /// The last snapshot, or null when none was written or it cannot be read.
  PeerSyncSnapshot? read() {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return PeerSyncSnapshot.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      // A malformed value reads as "no snapshot", which the cleanup treats
      // as not caught up: the safe direction.
      return null;
    }
  }

  Future<void> write(PeerSyncSnapshot snapshot) =>
      _prefs.setString(key, jsonEncode(snapshot.toJson()));
}
