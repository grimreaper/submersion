/// SQL for "the regulators on a dive tank" (issue #3375): the first in
/// `dive_tanks.regulator_equipment_id`, the rest as a JSON array in
/// `dive_tanks.extra_regulator_ids`. Every raw-SQL reader that asks which
/// regulators a tank or dive has goes through here, so the counts, the gear
/// filters and the service clocks cannot disagree.
///
/// Arguments are SQL expressions (a table alias, `?1`, `{from}.id`), never
/// user input.
library;

/// The tank's extras as JSON `json_each` can read, or NULL when the stored
/// text is not valid JSON: `json_each` fails the whole statement on
/// malformed JSON, and one bad row from a peer must not break every
/// equipment page.
String tankExtraRegulatorsJson(String tank) =>
    'CASE WHEN json_valid($tank.extra_regulator_ids) '
    'THEN $tank.extra_regulator_ids END';

/// True when [tank] names [id] as its first regulator or an extra.
String tankNamesRegulatorSql(String tank, String id) =>
    '($tank.regulator_equipment_id = $id OR EXISTS (SELECT 1 FROM '
    'json_each(${tankExtraRegulatorsJson(tank)}) WHERE value = $id))';

/// True when [tank] names any id in [inList] (the inside of an `IN (...)`).
/// The list appears twice, so anonymous `?` markers in it are bound twice.
String tankNamesAnyRegulatorSql(String tank, String inList) =>
    '($tank.regulator_equipment_id IN ($inList) OR EXISTS (SELECT 1 FROM '
    'json_each(${tankExtraRegulatorsJson(tank)}) WHERE value IN ($inList)))';

/// A `SELECT dive_id` of every dive with a tank naming [id]. Two branches,
/// so the first regulator reads its index and the extras the partial index
/// over tanks that have any; safe to correlate per item.
String tankRegulatorDiveIdsSql(String id) =>
    'SELECT rt.dive_id FROM dive_tanks rt '
    'WHERE rt.regulator_equipment_id = $id '
    'UNION ALL SELECT dive_id FROM ($tankExtraRegulatorRowsSql) '
    'WHERE regulator_id = $id';

/// A `SELECT` of every regulator id on the tanks of dive [diveId].
String tankRegulatorIdsOfDiveSql(String diveId) =>
    'SELECT rt.regulator_equipment_id FROM dive_tanks rt '
    'WHERE rt.dive_id = $diveId AND rt.regulator_equipment_id IS NOT NULL '
    'UNION SELECT rj.value FROM dive_tanks rt, '
    'json_each(${tankExtraRegulatorsJson('rt')}) rj '
    'WHERE rt.dive_id = $diveId';

/// One row per extra regulator on a tank: `dive_id`, `o2_percent` and
/// `regulator_id`. For queries that look up many regulators at once: read
/// once (a MATERIALIZED CTE) and joined, the JSON is parsed once per tank
/// rather than once per tank per regulator, and the first regulator keeps
/// its index on `regulator_equipment_id`.
final String tankExtraRegulatorRowsSql =
    'SELECT xt.dive_id, xt.o2_percent, xj.value AS regulator_id '
    'FROM dive_tanks xt, json_each(${tankExtraRegulatorsJson('xt')}) xj '
    'WHERE xt.extra_regulator_ids IS NOT NULL';
