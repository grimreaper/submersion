import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';

const _columns = [
  'profile_color_depth',
  'profile_color_temperature',
  'profile_color_pressure',
  'profile_color_heart_rate',
  'profile_color_sac',
  'profile_color_max_depth',
  'profile_color_ceiling',
  'profile_color_ndl',
  'profile_color_tts',
  'profile_color_gtr',
  'profile_color_cns',
  'profile_color_otu',
  'profile_color_pp_o2',
  'profile_color_pp_n2',
  'profile_color_pp_he',
  'profile_color_mod',
  'profile_color_density',
  'profile_color_gf',
  'profile_color_surface_gf',
  'profile_color_mean_depth',
];

/// Schema v282: diver_settings.profile_color_* (issue #3012).
void main() {
  NativeDatabase setupDb() => NativeDatabase.memory(
    setup: (rawDb) {
      rawDb.execute('PRAGMA user_version = 281');
      rawDb.execute(
        'CREATE TABLE diver_settings (id TEXT NOT NULL PRIMARY KEY, '
        'diver_id TEXT NOT NULL)',
      );
      rawDb.execute(
        "INSERT INTO diver_settings (id, diver_id) VALUES ('s1', 'd1')",
      );
    },
  );

  test('v282 is in the ladder', () {
    expect(AppDatabase.currentSchemaVersion, greaterThanOrEqualTo(282));
    expect(AppDatabase.migrationVersions, contains(282));
    expect(
      AppDatabase.migrationStepCount(281),
      AppDatabase.migrationStepCount(282) + 1,
    );
  });

  test('this rung is additive and did not move the sync floor', () {
    expect(AppDatabase.minimumCompatibleSchemaVersion, lessThan(282));
  });

  test('upgrading from v281 adds 20 null colour columns', () async {
    final db = AppDatabase(setupDb());
    addTearDown(db.close);
    final row =
        (await db
                .customSelect(
                  'SELECT ${_columns.join(', ')} FROM diver_settings',
                )
                .get())
            .single;
    for (final column in _columns) {
      expect(row.read<int?>(column), isNull, reason: column);
    }
  });
}
