import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/core/services/storage/scratch_sweep.dart';

/// Reclaims backup files a restore left in the app temp folder.
///
/// Restoring from a cloud backup or a SAF document copies the whole database
/// to `<temp>/<backup filename>` first. Restores now delete that copy when
/// they finish, but copies made before that change, or by a restore that was
/// killed part way, stay there forever (storage GC design, leak 1).
///
/// Deliberately narrow, like [StorageScratchSweep]: only regular files
/// directly in the temp folder whose names are this app's backup names, and
/// only once they are a day old. The age guard matters because the share
/// sheet's export writes the same names into the same folder.
class RestoreTempSweep {
  RestoreTempSweep({required Future<Directory> Function() temporaryDirectory})
    : _temporaryDirectory = temporaryDirectory;

  final Future<Directory> Function() _temporaryDirectory;
  final _log = LoggerService.forClass(RestoreTempSweep);

  static const Duration minAge = Duration(hours: 24);

  static final _backupName = RegExp(r'^submersion_backup_.+\.(db|sbe)$');

  /// A [dryRun] counts what the pass would reclaim and deletes nothing.
  Future<ScratchSweepReport> run({DateTime? now, bool dryRun = false}) async {
    final cutoff = (now ?? DateTime.now()).subtract(minAge);
    final temp = await _temporaryDirectory();
    if (!await temp.exists()) return ScratchSweepReport.empty;

    var files = 0;
    var bytes = 0;
    await for (final entity in temp.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_backupName.hasMatch(name)) continue;
      try {
        final stat = await entity.stat();
        if (!stat.modified.isBefore(cutoff)) continue;
        if (!dryRun) await entity.delete();
        files++;
        bytes += stat.size;
      } on FileSystemException {
        // Vanished or unreadable: leave it for the next pass.
        continue;
      }
    }
    if (files > 0 && !dryRun) {
      _log.info('Restore temp sweep reclaimed $bytes bytes in $files files');
    }
    return ScratchSweepReport(filesDeleted: files, bytesReclaimed: bytes);
  }
}
