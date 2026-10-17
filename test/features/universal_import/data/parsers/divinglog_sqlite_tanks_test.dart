import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/parsers/divinglog_sqlite_parser.dart';

// Dive Log stores the primary cylinder on Logbook and additional cylinders
// in Tank. Use synthetic data so the regression needs no personal logbook.
Uint8List _logbook({
  String program = 'Dive Log',
  bool primaryInTankTable = false,
  bool includeMaterial = true,
}) {
  final dir = Directory.systemTemp.createTempSync('divinglog_tanks');
  try {
    final file = File(p.join(dir.path, 'logbook.sql'));
    final db = sqlite3.open(file.path);
    try {
      db.execute('CREATE TABLE DBInfo (PrgName TEXT)');
      db.execute('INSERT INTO DBInfo VALUES (?)', [program]);
      db.execute('''
CREATE TABLE Logbook (
  ID INTEGER PRIMARY KEY, Divedate TEXT, Tanksize REAL,
  PresS REAL, PresE REAL, PresW REAL, O2 REAL, He REAL, DblTank INTEGER,
  ProfileInt INTEGER, Profile TEXT, Profile2 TEXT
)''');
      db.execute('''
CREATE TABLE Tank (
  LogID INTEGER, TankID INTEGER, Tanksize REAL,
  PresS REAL, PresE REAL, PresW REAL, O2 REAL, He REAL, DblTank INTEGER
)''');
      db.execute('''
INSERT INTO Logbook VALUES (
  1, '2024-06-01', 12, 204, 107, 232, 21, 35, 1,
  30, '030000000000006000000000', '2002040000020018001000'
)''');
      // Deliberately insert out of order; identical gases are still distinct
      // cylinders. The primary's profile uses slot 0, then switches to slot 1.
      db.execute('INSERT INTO Tank VALUES (1, 2, 7, 210, 80, 232, 50, 0, 0)');
      db.execute('INSERT INTO Tank VALUES (1, 1, 11, 180, 90, 207, 50, 0, 0)');
      if (primaryInTankTable) {
        db.execute(
          'INSERT INTO Tank VALUES (1, 0, 12, 204, 107, 232, 21, 35, 1)',
        );
      }
      if (includeMaterial) {
        db.execute('ALTER TABLE Logbook ADD COLUMN Tanktype INTEGER');
        db.execute('ALTER TABLE Tank ADD COLUMN Tanktype INTEGER');
        db.execute('UPDATE Logbook SET Tanktype = 2');
        db.execute('UPDATE Tank SET Tanktype = TankID WHERE TankID < 2');
        db.execute('UPDATE Tank SET Tanktype = 2 WHERE TankID = 0');
        db.execute('UPDATE Tank SET Tanktype = 3 WHERE TankID = 2');
        // Single-cylinder dives exercise material on Logbook independently
        // of the additional-cylinder table, including unknown values.
        for (final (id, material) in [(2, 1), (3, 3), (4, 0), (5, 99)]) {
          db.execute(
            'INSERT INTO Logbook (ID, Divedate, Tanksize, Tanktype) '
            'VALUES (?, ?, ?, ?)',
            [id, '2024-06-02', 10, material],
          );
        }
      }
    } finally {
      db.close();
    }
    return file.readAsBytesSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'keeps the primary twinset, extra tanks and profile references',
    () async {
      final payload = await const DivingLogSqliteParser().parse(_logbook());
      final dive = payload.entitiesOf(ImportEntityType.dives).first;
      final tanks = dive['tanks'] as List<Map<String, dynamic>>;

      expect(tanks.map((t) => t['uddfTankId']), [
        'divinglog:0',
        'divinglog:1',
        'divinglog:2',
      ]);
      expect(tanks.map((t) => t['order']), [0, 1, 2]);
      expect(tanks.map((t) => t['volume']), [24.0, 11.0, 7.0]);
      expect(tanks.map((t) => t['startPressure']), [204.0, 180.0, 210.0]);
      expect(tanks.map((t) => t['endPressure']), [107.0, 90.0, 80.0]);
      expect(tanks.map((t) => t['workingPressure']), [232.0, 207.0, 232.0]);
      expect(tanks.map((t) => t['gasMix']), [
        const GasMix(o2: 21, he: 35),
        const GasMix(o2: 50),
        const GasMix(o2: 50),
      ]);
      expect(tanks.map((t) => t['material']), [
        'steel',
        'aluminum',
        'carbonFiber',
      ]);

      final profile = dive['profile'] as List<Map<String, dynamic>>;
      expect(profile[0]['allTankPressures'], [
        {'tankIndex': 0, 'pressure': 204.0},
      ]);
      expect(profile[1]['allTankPressures'], [
        {'tankIndex': 1, 'pressure': 180.0},
      ]);
      final switches = dive['gasSwitches'] as List<Map<String, dynamic>>;
      expect(switches.single['tankRef'], 'divinglog:1');
      expect(switches.single['timestamp'], 30);
    },
  );

  test('reads inline materials and leaves unknown codes unspecified', () async {
    final payload = await const DivingLogSqliteParser().parse(_logbook());
    final dives = payload.entitiesOf(ImportEntityType.dives);
    final materials = [
      for (final dive in dives.skip(1))
        (dive['tanks'] as List<Map<String, dynamic>>).single['material'],
    ];
    expect(materials, ['aluminum', 'carbonFiber', null, null]);
  });

  test('does not duplicate a primary already in the Tank table', () async {
    final payload = await const DivingLogSqliteParser().parse(
      _logbook(primaryInTankTable: true),
    );
    final tanks =
        payload.entitiesOf(ImportEntityType.dives).first['tanks']
            as List<Map<String, dynamic>>;
    expect(tanks.map((t) => t['uddfTankId']), [
      'divinglog:0',
      'divinglog:1',
      'divinglog:2',
    ]);
    expect(tanks.first['material'], 'steel');
  });

  test('accepts older files without Tanktype columns', () async {
    final payload = await const DivingLogSqliteParser().parse(
      _logbook(includeMaterial: false),
    );
    final tanks =
        payload.entitiesOf(ImportEntityType.dives).single['tanks']
            as List<Map<String, dynamic>>;
    expect(tanks, hasLength(3));
    expect(tanks.map((t) => t['material']), everyElement(isNull));
  });

  test('preserves DiveMate tanks and material code meanings', () async {
    final payload = await const DivingLogSqliteParser().parse(
      _logbook(program: 'DiveMate'),
    );
    final tanks =
        payload.entitiesOf(ImportEntityType.dives).first['tanks']
            as List<Map<String, dynamic>>;
    expect(tanks.map((t) => t['uddfTankId']), ['divinglog:1', 'divinglog:2']);
    expect(tanks.map((t) => t['material']), ['aluminum', null]);
  });
}
