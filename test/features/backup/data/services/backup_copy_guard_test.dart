import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/features/backup/data/services/backup_copy_guard.dart';
import 'package:submersion/features/backup/domain/entities/backup_record.dart';

BackupRecord _record({String? cloudFileId, String? cloudAccountId}) =>
    BackupRecord(
      id: 'r',
      filename: 'submersion_backup_x.db',
      timestamp: DateTime(2026, 10, 19),
      sizeBytes: 1,
      location: BackupLocation.both,
      cloudFileId: cloudFileId,
      cloudAccountId: cloudAccountId,
    );

void main() {
  group('cloudCopyReachable', () {
    test('a record from before accounts were noted is reachable', () {
      expect(
        cloudCopyReachable(_record(cloudFileId: 'f'), copyAccountId: 'acct-b'),
        isTrue,
      );
    });

    test('a copy in the account the copy goes to now is reachable', () {
      expect(
        cloudCopyReachable(
          _record(cloudFileId: 'f', cloudAccountId: 'acct-b'),
          copyAccountId: 'acct-b',
        ),
        isTrue,
      );
    });

    test('a copy in another account is not', () {
      expect(
        cloudCopyReachable(
          _record(cloudFileId: 'f', cloudAccountId: 'acct-a'),
          copyAccountId: 'acct-b',
        ),
        isFalse,
      );
    });

    test('a copy in an account, with no account known now, is not', () {
      expect(
        cloudCopyReachable(
          _record(cloudFileId: 'f', cloudAccountId: 'acct-a'),
          copyAccountId: null,
        ),
        isFalse,
      );
    });

    test('a record with no cloud file is not', () {
      expect(cloudCopyReachable(_record(), copyAccountId: 'acct-b'), isFalse);
    });
  });

  test('a record round-trips its cloud account through JSON', () {
    final r = _record(cloudFileId: 'f', cloudAccountId: 'acct-a');
    expect(BackupRecord.fromJson(r.toJson()).cloudAccountId, 'acct-a');
    final legacy = r.toJson()..remove('cloudAccountId');
    expect(BackupRecord.fromJson(legacy).cloudAccountId, isNull);
  });
}
