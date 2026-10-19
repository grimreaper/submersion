// Issue #3482 phase 3: the backup copy goes to the account the diver chose,
// built the way sync builds its provider, or follows sync when none is chosen.

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/providers/account_providers.dart';
import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/accounts/account_provider_adapter.dart';
import 'package:submersion/core/services/accounts/account_provider_registry.dart';
import 'package:submersion/core/services/accounts/account_usage_service.dart';
import 'package:submersion/core/services/accounts/connected_account.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/encrypting_cloud_storage_provider.dart';
import 'package:submersion/core/services/sync/crypto/encryption_key_store.dart';
import 'package:submersion/features/backup/presentation/providers/backup_copy_providers.dart';
import 'package:submersion/features/settings/presentation/providers/account_group_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';

final _t = DateTime.utc(2026);

ConnectedAccount _row(String id, AccountKind kind) => ConnectedAccount(
  id: id,
  kind: kind,
  label: id,
  createdAt: _t,
  updatedAt: _t,
);

/// The sync account ('acct-sync', iCloud) and another ('acct-b', S3).
List<AccountGroup> _groups() => groupAccounts(
  rows: [_row('acct-sync', AccountKind.icloud), _row('acct-b', AccountKind.s3)],
  statusById: const {
    'acct-sync': AccountStatus.signedIn,
    'acct-b': AccountStatus.signedIn,
  },
  localLocationById: const {},
  usagesOf: (a) => a.id == 'acct-sync'
      ? const [AccountUsage(AccountUsageKind.databaseSync)]
      : const [],
);

class _Provider extends Fake implements CloudStorageProvider {
  _Provider(this.name);
  final String name;

  @override
  String get providerName => name;
}

/// An S3 adapter that records which row it was asked to build.
class _RecordingSyncAdapter extends AccountProviderAdapter
    implements SyncCapable {
  final built = <String>[];

  @override
  AccountKind get kind => AccountKind.s3;

  @override
  Future<AccountStatus> status(ConnectedAccount account) async =>
      AccountStatus.signedIn;

  @override
  Future<void> disconnect(ConnectedAccount account) async {}

  @override
  CloudStorageProvider syncProvider(ConnectedAccount account) {
    built.add(account.id);
    return _Provider('copy:${account.id}');
  }
}

class _SeededKeyNotifier extends EncryptionKeyNotifier {
  _SeededKeyNotifier(
    super.keyStore,
    super.preferences,
    EncryptionSessionState s,
  ) {
    state = s;
  }
}

void main() {
  late _RecordingSyncAdapter adapter;
  final syncProvider = _Provider('sync');

  Future<ProviderContainer> container(
    Map<String, Object> prefs, {
    bool unlocked = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final shared = await SharedPreferences.getInstance();
    adapter = _RecordingSyncAdapter();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(shared),
        accountGroupsProvider.overrideWith((ref) async => _groups()),
        accountProviderRegistryProvider.overrideWithValue(
          AccountProviderRegistry([adapter]),
        ),
        cloudStorageProviderProvider.overrideWithValue(syncProvider),
        if (unlocked)
          encryptionKeyNotifierProvider.overrideWith(
            (ref) => _SeededKeyNotifier(
              ref.watch(encryptionKeyStoreProvider),
              ref.watch(syncPreferencesProvider),
              EncryptionSessionState(
                key: UnlockedKey(
                  libraryKeyId: 'k',
                  mlk: SecretKey(List<int>.filled(32, 1)),
                ),
                dataKey: SecretKey(List<int>.filled(32, 2)),
              ),
            ),
          ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  const pinned = {
    'backup_cloud_enabled': true,
    'backup_copy_account_id': 'acct-b',
    'backup_copy_account_kind': 's3',
  };

  group('backupCopyTargetProvider', () {
    test('the copy off reads as no copy', () async {
      final c = await container({});
      expect(await c.read(backupCopyTargetProvider.future), isA<NoCopy>());
    });

    test('on with no account chosen follows the sync account', () async {
      final c = await container({'backup_cloud_enabled': true});
      final target = await c.read(backupCopyTargetProvider.future);
      expect(target, isA<CopyFollowsSync>());
      expect((target as CopyFollowsSync).group?.rows.single.id, 'acct-sync');
    });

    test('a chosen account names its group and row', () async {
      final c = await container(pinned);
      final target = await c.read(backupCopyTargetProvider.future);
      expect(target, isA<CopyToAccount>());
      expect((target as CopyToAccount).row.id, 'acct-b');
      expect(target.group.rows.single.id, 'acct-b');
    });

    test('a chosen account no longer on the roster reads as gone', () async {
      final c = await container({
        ...pinned,
        'backup_copy_account_id': 'acct-gone',
      });
      final target = await c.read(backupCopyTargetProvider.future);
      expect(target, isA<CopyAccountGone>());
      expect((target as CopyAccountGone).accountId, 'acct-gone');
    });
  });

  group('backupCopyProviderProvider', () {
    test('following sync uses the sync provider', () async {
      final c = await container({'backup_cloud_enabled': true});
      expect(c.read(backupCopyProviderProvider), same(syncProvider));
      expect(adapter.built, isEmpty);
    });

    test('a chosen account builds from that row, not the sync one', () async {
      final c = await container(pinned);
      final provider = c.read(backupCopyProviderProvider);
      expect(adapter.built, ['acct-b']);
      expect(provider?.providerName, 'copy:acct-b');
    });

    test(
      'with sync encryption unlocked the chosen provider is sealed',
      () async {
        final c = await container(pinned, unlocked: true);
        expect(
          c.read(backupCopyProviderProvider),
          isA<EncryptingCloudStorageProvider>(),
        );
      },
    );

    test('the copy off still lists the sync folder, as before', () async {
      final c = await container({
        'backup_copy_account_id': 'acct-b',
        'backup_copy_account_kind': 's3',
      });
      expect(c.read(backupCopyProviderProvider), same(syncProvider));
    });
  });
}
