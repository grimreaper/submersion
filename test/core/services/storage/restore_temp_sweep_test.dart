import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/core/services/storage/restore_temp_sweep.dart';

void main() {
  late Directory temp;
  final now = DateTime(2026, 10, 17, 12);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('restore_temp_sweep_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  RestoreTempSweep build() =>
      RestoreTempSweep(temporaryDirectory: () async => temp);

  Future<File> write(String relative, int bytes, Duration age) async {
    final file = File(p.join(temp.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(bytes, 0));
    await file.setLastModified(now.subtract(age));
    return file;
  }

  test('deletes an old downloaded backup left in temp', () async {
    final db = await write(
      'submersion_backup_2026-10-01_101500.db',
      300,
      const Duration(days: 3),
    );
    final sbe = await write(
      'submersion_backup_2026-10-01_101500__d0a1b2c3d.sbe',
      200,
      const Duration(days: 3),
    );

    final report = await build().run(now: now);

    expect(db.existsSync(), isFalse);
    expect(sbe.existsSync(), isFalse);
    expect(report.filesDeleted, 2);
    expect(report.bytesReclaimed, 500);
  });

  test('keeps a backup-named file younger than 24 hours', () async {
    // The share sheet exports under the same name into the same folder.
    final fresh = await write(
      'submersion_backup_2026-10-17_110000.db',
      300,
      const Duration(hours: 2),
    );

    final report = await build().run(now: now);

    expect(fresh.existsSync(), isTrue);
    expect(report.filesDeleted, 0);
  });

  test('ignores files in subfolders and names that do not match', () async {
    final others = [
      await write('notes.db', 10, const Duration(days: 9)),
      await write(
        p.join('picked', 'submersion_backup_x.db'),
        10,
        const Duration(days: 9),
      ),
      await write('submersion_backup_x.txt', 10, const Duration(days: 9)),
      await write('ssv1_base.db', 10, const Duration(days: 9)),
    ];

    final report = await build().run(now: now);

    for (final f in others) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
    expect(report.filesDeleted, 0);
  });

  test('dry run counts without deleting', () async {
    final db = await write(
      'submersion_backup_2026-10-01_101500.db',
      300,
      const Duration(days: 3),
    );

    final report = await build().run(now: now, dryRun: true);

    expect(report.bytesReclaimed, 300);
    expect(db.existsSync(), isTrue);
  });

  test('a missing temp folder reclaims nothing', () async {
    await temp.delete(recursive: true);
    expect((await build().run(now: now)).filesDeleted, 0);
  });
}
