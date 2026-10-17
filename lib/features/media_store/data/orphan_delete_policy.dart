import 'package:submersion/core/services/sync/peer_sync_snapshot.dart';

/// What the cleanup may do with one unreferenced media store object.
enum OrphanVerdict {
  /// Safe to delete now.
  delete,

  /// Inside the safety wait: a device that has not synced yet may still
  /// reference it.
  wait,

  /// This device is not caught up with its peers, so nothing may be deleted
  /// whatever its age.
  deferred,
}

/// Decides when an unreferenced media store object may be deleted (storage
/// GC design, safety rules).
///
/// An object nothing here references may still be referenced by a row this
/// device has not received yet. Two rules guard against deleting it:
///
/// - **Caught up.** With database sync on, no object is deleted unless the
///   last pull applied every live peer cleanly and came after the last
///   restore. After a Merge restore, rows for media added since the backup
///   come back from peers on that pull; deleting before it would remove
///   objects those rows still need.
/// - **Grace or early delete.** An object older than [grace] may go. One
///   uploaded before every peer last published (plus [skew] for clock
///   differences), and before this device's last pull, may go sooner: the
///   row that referenced it would have reached this device already.
///
/// With sync off this device knows of no peers, so only the grace window
/// applies.
class OrphanDeletePolicy {
  const OrphanDeletePolicy({
    required this.now,
    required this.syncEnabled,
    this.snapshot,
    this.lastRestoreAt,
    this.grace = const Duration(days: 7),
    this.skew = const Duration(hours: 1),
  });

  /// Sync off: the 7-day grace window is the only rule. Today's behaviour.
  const OrphanDeletePolicy.unrestricted(this.now)
    : syncEnabled = false,
      snapshot = null,
      lastRestoreAt = null,
      grace = const Duration(days: 7),
      skew = const Duration(hours: 1);

  final DateTime now;
  final bool syncEnabled;
  final PeerSyncSnapshot? snapshot;
  final DateTime? lastRestoreAt;
  final Duration grace;
  final Duration skew;

  /// False when this device is not caught up, so every verdict is
  /// [OrphanVerdict.deferred].
  bool get deletesAllowed {
    if (!syncEnabled) return true;
    final s = snapshot;
    if (s == null || !s.caughtUp) return false;
    final restored = lastRestoreAt;
    return restored == null || s.takenAt.isAfter(restored);
  }

  OrphanVerdict verdictFor(DateTime lastModified) {
    if (!deletesAllowed) return OrphanVerdict.deferred;
    if (lastModified.isBefore(now.subtract(grace))) return OrphanVerdict.delete;
    final s = snapshot;
    if (syncEnabled && s != null) {
      final covered = lastModified.add(skew);
      final everyoneSince =
          covered.isBefore(s.takenAt) &&
          s.peers.every((p) => covered.isBefore(p.publishedAt));
      if (everyoneSince) return OrphanVerdict.delete;
    }
    return OrphanVerdict.wait;
  }
}
