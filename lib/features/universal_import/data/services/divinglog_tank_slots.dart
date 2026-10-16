import 'package:submersion/features/universal_import/data/services/divinglog_raw_types.dart';

/// Resolves Diving Log's packed profile tank ids to cylinders.
class DivingLogTankSlots {
  /// A pressure step at a gas switch larger than this, in bar, is read as
  /// the series moving to another cylinder when that cylinder has no
  /// pressure to compare against. Breathing one cylinder between two
  /// consecutive samples drops it by a bar or two at most; switching
  /// transmitters jumps it by tens of bar.
  static const _jumpBar = 10.0;

  const DivingLogTankSlots._();

  /// The position in [tanks] that a profile tank id refers to, or null when
  /// it refers to no cylinder we have.
  ///
  /// The two numbering schemes are not the same. `uddfTankId` carries the
  /// source `Tank.TankID`, which the reference logbook writes as 1, while
  /// the id packed into the profile is the computer's own 0-based slot.
  /// Position therefore wins: on a logbook whose cylinders are TankID 1 and
  /// 2, profile slot 1 means the second cylinder, and matching the number
  /// against TankID would resolve it to the first. Where a logbook numbers
  /// its cylinders from zero the two agree anyway, so this stays correct
  /// for both shapes, and id matching is kept only for an id that is out of
  /// range as a position.
  static int? position(int tankId, List<Map<String, dynamic>> tanks) {
    if (tankId >= 0 && tankId < tanks.length) return tankId;
    final byId = tanks.indexWhere(
      (t) => t['uddfTankId'] == 'divinglog:$tankId',
    );
    return byId >= 0 ? byId : null;
  }

  /// The cylinder position that owns each sample's `Profile2` pressure, one
  /// entry per sample in [samples].
  ///
  /// `Profile2` packs a single pressure beside the tank id, and that tank id
  /// is the gas in use, not necessarily the cylinder the pressure was read
  /// from. A computer with one transmitter keeps reporting the back-gas
  /// cylinder after a switch to a stage that has no sensor (#3339), so a
  /// change of tank id alone does not move the series. It moves only when
  /// the first reading after the switch fits the new cylinder better than
  /// it continues the current one: closer to the new cylinder's last
  /// reading, or to its recorded start pressure before it has any, or, with
  /// neither known, a jump larger than [_jumpBar].
  static List<int> pressureOwners(
    List<DivingLogRawSample> samples,
    List<Map<String, dynamic>> tanks,
  ) {
    final lastReading = <int, double>{};
    final owners = <int>[];
    int? owner;
    int? activeTankId;
    int? candidate;
    for (final s in samples) {
      final tankId = s.tankId;
      if (tankId != null && tankId != activeTankId) {
        final slot = position(tankId, tanks);
        if (owner == null) {
          owner = slot;
        } else {
          // An id with no cylinder cancels any switch still pending, so a
          // reading after it cannot be decided against stale state.
          candidate = slot;
        }
        activeTankId = tankId;
      }
      final current = owner ?? 0;
      final pressure = s.pressureBar;
      var next = current;
      if (pressure != null) {
        if (candidate != null && candidate != current) {
          if (_moves(
            pressure,
            lastReading[current],
            candidate,
            lastReading,
            tanks,
          )) {
            next = candidate;
          }
        }
        candidate = null;
        lastReading[next] = pressure;
      }
      owner = next;
      owners.add(next);
    }
    return owners;
  }

  static bool _moves(
    double pressure,
    double? previous,
    int candidate,
    Map<int, double> lastReading,
    List<Map<String, dynamic>> tanks,
  ) {
    if (previous == null) return true;
    final expected =
        lastReading[candidate] ??
        (tanks[candidate]['startPressure'] as num?)?.toDouble();
    final step = (pressure - previous).abs();
    if (expected == null) return step > _jumpBar;
    return (pressure - expected).abs() < step;
  }
}
