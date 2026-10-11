import 'package:drift/drift.dart';

import 'package:submersion/core/database/database.dart';

/// How a fill group decides whether a row holds a value.
enum _Holds {
  /// Any listed column is non-null.
  any,

  /// Every listed column is non-null (a GPS fix is a latitude AND a
  /// longitude; half of one is no fix).
  all,

  /// Non-blank text, for a non-null text column defaulting to ''.
  text,

  /// True, for a non-null flag defaulting to false. A secondary can only
  /// raise the flag, never clear it.
  flag,
}

/// Columns a consolidation copies together, from a single secondary.
class _FillGroup {
  const _FillGroup(
    this.columns, {
    this.holds = _Holds.any,
    this.alsoHeldBy = const [],
  });

  final List<String> columns;
  final _Holds holds;

  /// Columns that count toward the target already holding this group but
  /// are never copied themselves.
  final List<String> alsoHeldBy;
}

/// Every dives column a consolidation fills, as the units it fills them in.
///
/// Each group is copied whole from the first secondary (in the order given)
/// that holds it, and only when the target holds none of it. Taking a block
/// whole means two computers never meet inside one reading: weather fetched
/// for one source is not stamped with another's wind, and a visibility
/// range is not paired with another source's measurement (#3226).
const List<_FillGroup> _groups = [
  // GPS fixes (#542).
  _FillGroup(['entry_latitude', 'entry_longitude'], holds: _Holds.all),
  _FillGroup(['exit_latitude', 'exit_longitude'], holds: _Holds.all),
  // Site and runtime (#1809).
  _FillGroup(['site_id']),
  _FillGroup(['runtime']),
  // Measurements. The target's own computer wins; a secondary's reading
  // only stands in for one it never took.
  _FillGroup(['bottom_time']),
  _FillGroup(['max_depth']),
  _FillGroup(['avg_depth']),
  _FillGroup(['water_temp']),
  _FillGroup(['cns_end']),
  _FillGroup(['otu']),
  // The dive itself.
  _FillGroup(['name']),
  _FillGroup(['dive_number']),
  _FillGroup(['surface_interval_seconds']),
  _FillGroup(['rating']),
  _FillGroup(['notes'], holds: _Holds.text),
  // Conditions.
  _FillGroup(['air_temp']),
  _FillGroup(
    ['visibility_meters', 'visibility_min_meters', 'visibility_max_meters'],
    alsoHeldBy: ['visibility'],
  ),
  _FillGroup(['current_direction']),
  _FillGroup(['current_strength']),
  _FillGroup(['swell_height']),
  _FillGroup(['surface_conditions']),
  _FillGroup(['water_type']),
  _FillGroup(['altitude']),
  _FillGroup(['surface_pressure']),
  _FillGroup(['entry_method']),
  _FillGroup(['exit_method']),
  _FillGroup([
    'wind_speed',
    'wind_direction',
    'cloud_cover',
    'precipitation',
    'humidity',
    'weather_description',
    'weather_source',
    'weather_fetched_at',
    'weather_code',
  ]),
  // Logistics and people.
  _FillGroup(['dive_center_id']),
  _FillGroup(['trip_id']),
  _FillGroup(['course_id']),
  _FillGroup(['buddy']),
  _FillGroup(['dive_master']),
  _FillGroup(['dive_operator']),
  _FillGroup(['boat_name']),
  _FillGroup(['boat_captain']),
  // Weighting.
  _FillGroup(['weight_amount']),
  _FillGroup(['weight_type']),
  _FillGroup(['weighting_feedback', 'weighting_feedback_kg']),
  // Rebreather rig. Set on the rig rather than on one computer, so a backup
  // computer's record of it describes the same loop.
  _FillGroup([
    'setpoint_low',
    'setpoint_high',
    'setpoint_deco',
    'scr_type',
    'scr_injection_rate',
    'scr_addition_ratio',
    'scr_orifice_size',
    'assumed_vo2',
    'diluent_o2',
    'diluent_he',
    'loop_o2_min',
    'loop_o2_max',
    'loop_o2_avg',
    'loop_volume',
    'scrubber_type',
    'scrubber_duration_minutes',
    'scrubber_remaining_minutes',
  ]),
  // Statistics exclusions: one on any source survives, since silently
  // re-admitting a dive the diver took out of their statistics is the
  // harder error to notice (the sequential merge's rule).
  _FillGroup(['excluded_from_stats'], holds: _Holds.flag),
  _FillGroup(['excluded_from_gas_stats'], holds: _Holds.flag),
];

/// Every dives column a consolidation leaves as the target has it, and why.
///
/// Together with [consolidationFilledColumns] this covers the whole table,
/// which a test enforces, so a new column has to be classified before it
/// ships.
const Map<String, String> consolidationUnfilledColumns = {
  'id': 'identity of the target row',
  'diver_id': 'every source belongs to the same diver',
  'dive_date_time': "the target's timeline; secondaries are re-based onto it",
  'entry_time': "the target's timeline; secondaries are re-based onto it",
  'exit_time': "the target's timeline; secondaries are re-based onto it",
  'created_at': 'row bookkeeping',
  'updated_at': 'row bookkeeping, stamped by the fold itself',
  'hlc': 'row bookkeeping',
  'visibility': 'legacy pre-v144 bucket, which new code must not write',
  'dive_type': 'legacy column; dive types are unioned through their table',
  'diver_role': 'roles are unioned through the role links',
  'dive_mode': "non-null, so the target computer's mode always stands",
  'cns_start': 'non-null with a 0 default, so an unset value is invisible',
  'is_favorite': 'a secondary does not make the dive a favorite',
  'is_planned': 'a consolidated dive was logged, whatever its sources say',
  'gradient_factor_low': 'how the target computer computed its deco',
  'gradient_factor_high': 'how the target computer computed its deco',
  'deco_algorithm': 'how the target computer computed its deco',
  'deco_conservatism': 'how the target computer computed its deco',
  'computer_tissue_json': "the target computer's own tissue state",
  'computer_id': 'identifies the computer that logged the target',
  'dive_computer_model': 'identifies the computer that logged the target',
  'dive_computer_serial': 'identifies the computer that logged the target',
  'dive_computer_firmware': 'identifies the computer that logged the target',
  'import_source': 'import provenance of the target row',
  'import_id': 'import provenance of the target row',
  'import_version': 'import provenance of the target row',
  'outing_id': "the target's own mirror group",
  'site_suggestion_dismissed_at':
      "the diver's answer to the target's own "
      'site suggestion',
};

/// Every dives column a consolidation can fill.
final Set<String> consolidationFilledColumns = {
  for (final group in _groups) ...group.columns,
};

/// The values to write onto [target] so that columns it leaves empty adopt
/// what [secondaries] recorded, before the secondaries are tombstoned and
/// their rows are gone.
///
/// Never overwrites a value the target holds. Keyed by SQL column name, for
/// a `RawValuesInsertable`; empty when there is nothing to fill.
Map<String, Expression> consolidationFieldFill(
  Dive target,
  List<Dive> secondaries,
) {
  final targetValues = target.toColumns(false);
  final secondaryValues = [for (final s in secondaries) s.toColumns(false)];
  final fill = <String, Expression>{};
  for (final group in _groups) {
    if (_held(group, targetValues, includeAlsoHeldBy: true)) continue;
    for (final values in secondaryValues) {
      if (!_held(group, values, includeAlsoHeldBy: false)) continue;
      for (final column in group.columns) {
        fill[column] = values[column]!;
      }
      break;
    }
  }
  return fill;
}

bool _held(
  _FillGroup group,
  Map<String, Expression> values, {
  required bool includeAlsoHeldBy,
}) {
  Object? valueOf(String column) => (values[column]! as Variable).value;
  final columns = group.columns.map(valueOf);
  final alsoHeld =
      includeAlsoHeldBy && group.alsoHeldBy.map(valueOf).any((v) => v != null);
  return switch (group.holds) {
    _Holds.any => alsoHeld || columns.any((v) => v != null),
    _Holds.all => alsoHeld || columns.every((v) => v != null),
    _Holds.text => columns.any((v) => (v as String).trim().isNotEmpty),
    _Holds.flag => columns.any((v) => v == true),
  };
}
