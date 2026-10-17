import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:submersion/features/universal_import/data/models/import_enums.dart';
import 'package:submersion/features/universal_import/data/models/import_payload.dart';
import 'package:submersion/features/universal_import/data/models/import_warning.dart';
import 'package:submersion/features/universal_import/data/parsers/divinglog_sqlite_parser.dart';

Future<ImportPayload> _parse(List<String> statements) async {
  final dir = Directory.systemTemp.createTempSync('divinglog_details');
  try {
    final file = File(p.join(dir.path, 'logbook.sql'));
    final db = sqlite3.open(file.path);
    try {
      db.execute('''
CREATE TABLE Logbook (
  ID INTEGER PRIMARY KEY, Divedate TEXT, Entrytime TEXT, Comments TEXT,
  Water INTEGER, Rating INTEGER, Entry INTEGER, Weather TEXT,
  UWCurrent TEXT, Surface TEXT, Surfint TEXT, VisHor TEXT, Visibility INTEGER,
  Boat TEXT, Gas TEXT, Altitude TEXT, SupplyType TEXT, TripID INTEGER,
  PlaceID INTEGER
)''');
      db.execute("INSERT INTO Logbook (ID, Divedate) VALUES (1, '2024-06-01')");
      for (final statement in statements) {
        db.execute(statement);
      }
    } finally {
      db.close();
    }
    return await const DivingLogSqliteParser().parse(file.readAsBytesSync());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('imports recorded conditions alongside the original notes', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Comments='Original note', Water=2, Rating=4, "
          "Entry=1, Weather='Regen', UWCurrent='Mittlere Strömung', "
          "Surface='Kleine Wellen', Surfint='01:54', VisHor='5 m', "
          "Visibility=2, Boat='Example boat'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['waterType'], 'fresh');
    expect(dive['rating'], 4);
    expect(dive['entryMethod'], 'shore');
    expect(dive['weatherDescription'], 'Regen');
    expect(dive['currentStrength'], 'moderate');
    expect(dive['surfaceConditions'], 'Kleine Wellen');
    expect(dive['surfaceInterval'], const Duration(hours: 1, minutes: 54));
    expect(dive['visibilityMeters'], 5.0);
    expect(dive['visibility'], 'moderate');
    expect(dive['boatName'], 'Example boat');
    expect(dive['notes'], 'Original note');
  });

  for (final rating in [1, 5]) {
    test('imports rating $rating without adding a note', () async {
      final payload = await _parse([
        "UPDATE Logbook SET Rating=$rating, Comments='Original note'",
      ]);
      final dive = payload.entitiesOf(ImportEntityType.dives).single;
      expect(dive['rating'], rating);
      expect(dive['notes'], 'Original note');
    });
  }

  for (final rating in [null, 0]) {
    test('leaves rating $rating unrated without adding a note', () async {
      final payload = await _parse([
        "UPDATE Logbook SET Rating=${rating ?? 'NULL'}, Comments='Original note'",
      ]);
      final dive = payload.entitiesOf(ImportEntityType.dives).single;
      expect(dive['rating'], isNull);
      expect(dive['notes'], 'Original note');
    });
  }

  for (final rating in [-1, 9]) {
    test(
      'preserves unsupported rating $rating alongside original notes',
      () async {
        final payload = await _parse([
          "UPDATE Logbook SET Rating=$rating, Comments='Original note'",
        ]);
        final dive = payload.entitiesOf(ImportEntityType.dives).single;
        expect(dive['rating'], isNull);
        expect(dive['notes'], 'Original note\n\nRating (Dive Log): $rating');
      },
    );
  }

  test('imports a textual visibility level', () async {
    final payload = await _parse([
      "UPDATE Logbook SET VisHor='Good', Comments='Original note'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['visibility'], 'good');
    expect(dive['visibilityMeters'], isNull);
    expect(dive['notes'], 'Original note');
  });

  test('imports altitude in metres without treating it as pressure', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Altitude='500 m', Comments='Original note'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['altitude'], 500.0);
    expect(dive['surfacePressure'], isNull);
    expect(dive['notes'], 'Original note');
  });

  test('imports jetty entry', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Entry=5, Comments='Original note'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['entryMethod'], 'jetty');
    expect(dive['notes'], 'Original note');
  });

  test('preserves pool entry in notes', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Entry=3, Comments='Original note'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['entryMethod'], isNull);
    expect(dive['notes'], 'Original note\n\nEntry type: Pool');
  });

  test('does not add notes or tags for an unset supply type', () async {
    final payload = await _parse([
      "UPDATE Logbook SET SupplyType='5', Comments='Original note'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['notes'], 'Original note');
    expect(dive['tagRefs'], isNull);
    expect(payload.entitiesOf(ImportEntityType.tags), isEmpty);
  });

  test('imports algorithm, gradient factors and pressure in bar', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Gas='ZHL-16C GF: 20/85', Altitude='1014 mbar', "
          "SupplyType='0'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['decoAlgorithm'], 'ZHL-16C');
    expect(dive['gradientFactorLow'], 20);
    expect(dive['gradientFactorHigh'], 85);
    expect(dive['surfacePressure'], closeTo(1.014, 1e-9));
    expect(dive['altitude'], isNull);
    expect(dive['tagRefs'], isNull);
    expect(payload.entitiesOf(ImportEntityType.tags), isEmpty);
  });

  test('imports gauge mode and preserves unknown values', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Gas='Gauge', Water=99, Entry=99, SupplyType='99', "
          "VisHor='variable', UWCurrent='changing'",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['diveMode'], 'gauge');
    expect(dive['waterType'], isNull);
    expect(dive['entryMethod'], isNull);
    expect(dive['tagRefs'], isNull);
    expect(dive['notes'], contains('Water type (Dive Log): 99'));
    expect(dive['notes'], contains('Entry type (Dive Log): 99'));
    expect(dive['notes'], contains('Supply type (Dive Log): 99'));
    expect(dive['notes'], contains('Visibility: variable'));
    expect(dive['notes'], contains('Current: changing'));
  });

  test('does not invent measurements from malformed values', () async {
    final payload = await _parse([
      "UPDATE Logbook SET Gas='ZHL-16C GF: 120/85', Altitude='-5 mbar', "
          "Surfint='00:99', Rating=9",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['gradientFactorLow'], isNull);
    expect(dive['surfacePressure'], isNull);
    expect(dive['surfaceInterval'], isNull);
    expect(dive['rating'], isNull);
    expect(dive['notes'], contains('Rating (Dive Log): 9'));
    expect(dive['notes'], contains('ZHL-16C GF: 120/85'));
  });

  test('keeps chlorinated water as notes without relabeling it', () async {
    final payload = await _parse([
      'UPDATE Logbook SET Water=4, PlaceID=10',
      'CREATE TABLE Place (ID INTEGER, Place TEXT, Water INTEGER)',
      "INSERT INTO Place VALUES (10, 'Example pool', 4)",
    ]);
    final dive = payload.entitiesOf(ImportEntityType.dives).single;
    expect(dive['waterType'], isNull);
    expect(dive['notes'], contains('Water type: Chlorinated'));
    final site = payload.entitiesOf(ImportEntityType.sites).single;
    expect(site['waterType'], isNull);
    expect(site['description'], contains('Water type: Chlorinated'));
  });

  test('reports embedded images that the importer cannot attach', () async {
    final payload = await _parse([
      'CREATE TABLE Equipment (ID INTEGER, Object TEXT, Photo BLOB)',
      "INSERT INTO Equipment VALUES (1, 'Example regulator', X'010203')",
      "INSERT INTO Equipment VALUES (2, 'Example fins', X'')",
    ]);
    final notices = payload.warnings.where(
      (w) => w.code == ImportWarningCode.logbookImagesNotImported,
    );
    // One notice for the file, counting only the non-empty blob.
    expect(notices, hasLength(1));
    expect(notices.single.count, 1);
    expect(notices.single.message, contains('1 equipment photos'));
  });

  test('raises no picture notice when no blob is filled', () async {
    final payload = await _parse([
      'CREATE TABLE Equipment (ID INTEGER, Object TEXT, Photo BLOB)',
      "INSERT INTO Equipment VALUES (1, 'Example fins', X'')",
    ]);
    expect(
      payload.warnings.where(
        (w) => w.code == ImportWarningCode.logbookImagesNotImported,
      ),
      isEmpty,
    );
  });

  test('reports an undated trip without dives', () async {
    final payload = await _parse([
      'CREATE TABLE Trip (ID INTEGER, TripName TEXT)',
      "INSERT INTO Trip VALUES (7, 'Undated trip')",
    ]);
    expect(payload.entitiesOf(ImportEntityType.trips), isEmpty);
    final notice = payload.warnings.singleWhere(
      (w) => w.code == ImportWarningCode.tripsNotImported,
    );
    expect(notice.names, ['Undated trip']);
    expect(notice.severity, ImportWarningSeverity.warning);
  });

  test('imports unused sites and German difficulty labels', () async {
    final payload = await _parse([
      'CREATE TABLE Place (ID INTEGER, Place TEXT, Difficulty TEXT)',
      "INSERT INTO Place VALUES (10, 'Example site', 'Fortgeschritten')",
      "INSERT INTO Place VALUES (11, 'Unvisited site', 'Leicht')",
      'UPDATE Logbook SET PlaceID=10',
    ]);
    final sites = payload.entitiesOf(ImportEntityType.sites);
    expect(sites, hasLength(2));
    expect(sites.first['difficulty'], 'advanced');
    expect(sites.last['difficulty'], 'beginner');
    expect(sites.last['name'], 'Unvisited site');
  });

  test('derives missing trip dates from its dives', () async {
    final payload = await _parse([
      'CREATE TABLE Trip (ID INTEGER, TripName TEXT)',
      "INSERT INTO Trip VALUES (7, 'Example trip')",
      'UPDATE Logbook SET TripID=7',
      "INSERT INTO Logbook (ID, Divedate, TripID) VALUES (2, '2024-06-04', 7)",
    ]);
    final trip = payload.entitiesOf(ImportEntityType.trips).single;
    expect(trip['startDate'], DateTime.utc(2024, 6, 1));
    expect(trip['endDate'], DateTime.utc(2024, 6, 4));
  });

  test('reads gear service dates and purchase shop', () async {
    final payload = await _parse([
      'CREATE TABLE Equipment (ID INTEGER, Object TEXT, DateR TEXT, '
          'DateRN TEXT, Shop TEXT, Price REAL)',
      "INSERT INTO Equipment VALUES (1, 'Example regulator', '2024-01-01', "
          "'2025-01-01', 'Example shop', 200)",
      "INSERT INTO Equipment VALUES (2, 'Example tank', NULL, "
          "'2025-06-01', NULL, NULL)",
    ]);
    final gear = payload.entitiesOf(ImportEntityType.equipment);
    expect(gear.first['lastServiceDate'], DateTime.utc(2024, 1, 1));
    expect(gear.first['serviceIntervalDays'], 366);
    expect(
      gear.first['attributes'],
      contains(equals({'key': 'retailer', 'valueText': 'Example shop'})),
    );
    // The service record carries the first item's next date; the second
    // has no service record, so its notes are the only place it survives.
    expect(gear.first['notes'], isNot(contains('Next service')));
    expect(gear.last['notes'], contains('Next service: 2025-06-01'));
    final records = payload.entitiesOf(ImportEntityType.serviceRecords);
    expect(records.single['serviceDate'], DateTime.utc(2024, 1, 1));
    expect(records.single['nextServiceDue'], DateTime.utc(2025, 1, 1));
    expect(records.single['equipmentRef'], gear.first['uddfId']);
  });

  test('preserves card scans, instructor number and buddy photo', () async {
    final payload = await _parse([
      'CREATE TABLE Brevets (ID INTEGER, Brevet TEXT, InstructorNo TEXT, '
          'Scan1 BLOB, Scan2 BLOB)',
      "INSERT INTO Brevets VALUES (1, 'Example certification', 'TEST-123', "
          "X'010203', X'040506')",
      'CREATE TABLE Buddy (ID INTEGER, FirstName TEXT, Photo BLOB)',
      "INSERT INTO Buddy VALUES (1, 'Example buddy', X'070809')",
    ]);
    final cert = payload.entitiesOf(ImportEntityType.certifications).single;
    expect(cert['instructorNumber'], 'TEST-123');
    expect(cert['photoFront'], Uint8List.fromList([1, 2, 3]));
    expect(cert['photoBack'], Uint8List.fromList([4, 5, 6]));
    final buddy = payload.entitiesOf(ImportEntityType.buddies).single;
    expect(buddy['photo'], Uint8List.fromList([7, 8, 9]));
  });
}
