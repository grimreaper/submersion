import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart' show AppDatabase;
import 'package:submersion/features/dive_centers/data/repositories/dive_center_repository.dart';

import '../../../../helpers/test_database.dart';

/// Issue #3491: an import that knows a dive center only by name reuses the
/// diver's own center of that name, or an unowned one, before creating one.
void main() {
  late AppDatabase db;
  late DiveCenterRepository repo;

  setUp(() async {
    db = await setUpTestDatabase();
    await db.customStatement(
      "INSERT INTO divers (id, name, created_at, updated_at) "
      "VALUES ('diver-1', 'Me', 1000, 1000), ('diver-2', 'You', 1000, 1000)",
    );
    repo = DiveCenterRepository();
  });

  tearDown(() async {
    await tearDownTestDatabase();
  });

  Future<void> insertCenter(
    String id,
    String? diverId,
    String name,
  ) => db.customStatement(
    'INSERT INTO dive_centers (id, diver_id, name, created_at, '
    "updated_at) VALUES ('$id', ${diverId == null ? 'NULL' : "'$diverId'"}, "
    "'$name', 1000, 1000)",
  );

  Future<int> centerCount() async =>
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM dive_centers')
              .getSingle())
          .read<int>('n');

  test('reuses the diver\'s center of that name, ignoring case', () async {
    await insertCenter('c-own', 'diver-1', 'TKL');

    final center = await repo.findOrCreateByName('tkl', diverId: 'diver-1');

    expect(center.id, 'c-own');
    expect(await centerCount(), 1);
  });

  test('prefers the diver\'s own center over an unowned namesake', () async {
    await insertCenter('c-unowned', null, 'TKL');
    await insertCenter('c-own', 'diver-1', 'TKL');

    final center = await repo.findOrCreateByName('TKL', diverId: 'diver-1');

    expect(center.id, 'c-own');
  });

  test('matches a stored name with stray spaces', () async {
    await insertCenter('c-own', 'diver-1', ' TKL ');

    final center = await repo.findOrCreateByName('TKL', diverId: 'diver-1');

    expect(center.id, 'c-own');
    expect(await centerCount(), 1);
  });

  test('claims an unowned center for the diver', () async {
    await insertCenter('c-unowned', null, 'TKL');

    final center = await repo.findOrCreateByName('TKL', diverId: 'diver-1');

    expect(center.id, 'c-unowned');
    expect((await repo.getDiveCenterById('c-unowned'))!.diverId, 'diver-1');
  });

  test('never takes another diver\'s center', () async {
    await insertCenter('c-theirs', 'diver-2', 'TKL');

    final center = await repo.findOrCreateByName(' TKL ', diverId: 'diver-1');

    expect(center.id, isNot('c-theirs'));
    expect(center.diverId, 'diver-1');
    expect(center.name, 'TKL');
    expect(await centerCount(), 2);
  });
}
