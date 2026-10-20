// Issue #3482 phase 4: photo copies are set up by choosing an account. The
// account's photos-folder row is reached (created for an own server), its
// store is built the way the runtime builds it, and today's marker checks
// decide whether this joins an existing store or starts one.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:submersion/core/data/repositories/connected_accounts_repository.dart';
import 'package:submersion/core/services/accounts/account_credentials_store.dart';
import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/accounts/account_group_service.dart';
import 'package:submersion/core/services/accounts/account_identity.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/accounts/account_location.dart';
import 'package:submersion/core/services/accounts/account_provider_adapter.dart';
import 'package:submersion/core/services/accounts/account_provider_registry.dart';
import 'package:submersion/core/services/accounts/adapters/s3_account_adapter.dart';
import 'package:submersion/core/services/accounts/connected_account.dart';
import 'package:submersion/core/services/cloud_storage/s3/s3_config.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/core/services/media_store/media_store_credentials_store.dart';
import 'package:submersion/features/media_store/data/media_store_account_attach.dart';
import 'package:submersion/features/media_store/data/media_store_service.dart';
import 'package:submersion/features/media_store/data/media_stores_repository.dart';

import '../../../helpers/in_memory_media_object_store.dart';
import '../../../helpers/test_database.dart';
import '../../../support/fake_keychain_storage.dart';

final _t = DateTime.utc(2026);

ConnectedAccount _row(String id, AccountKind kind, String label) =>
    ConnectedAccount(
      id: id,
      kind: kind,
      label: label,
      createdAt: _t,
      updatedAt: _t,
    );

AccountGroup _group(ConnectedAccount row) => groupAccounts(
  rows: [row],
  statusById: {row.id: AccountStatus.signedIn},
  localLocationById: const {},
  usagesOf: (_) => const [],
).single;

/// Hands out the store each row id maps to, as the runtime's adapters do;
/// a row with no store has no usable keys here.
class _MediaAdapter extends AccountProviderAdapter
    implements MediaStoreCapable {
  _MediaAdapter(this.kind, this.stores);

  @override
  final AccountKind kind;
  final Map<String, MediaObjectStore> stores;

  @override
  Future<AccountStatus> status(ConnectedAccount account) async =>
      AccountStatus.signedIn;

  @override
  Future<void> disconnect(ConnectedAccount account) async {}

  @override
  Future<MediaObjectStore?> mediaObjectStore(ConnectedAccount account) async =>
      stores[account.id];
}

/// Creates the photos-folder row on a server, as ensureRole does.
class _Accounts extends Fake implements AccountGroupService {
  _Accounts(this.mediaRow);
  final ConnectedAccount mediaRow;
  final ensured = <(String, AccountRole)>[];

  @override
  Future<ConnectedAccount> ensureRole(
    AccountGroup group,
    AccountRole role, {
    String? libraryFolder,
  }) async {
    ensured.add((group.key, role));
    return mediaRow;
  }
}

/// A server account no row of which holds keys here.
class _NoKeys extends Fake implements AccountGroupService {
  @override
  Future<ConnectedAccount> ensureRole(
    AccountGroup group,
    AccountRole role, {
    String? libraryFolder,
  }) async => throw StateError('not signed in');
}

/// Hands out [store] for any row that holds keys on this device, as the S3
/// adapter does, without reaching a network.
class _KeyedAdapter extends AccountProviderAdapter
    implements MediaStoreCapable {
  _KeyedAdapter(this.credentials, this.store);
  final AccountCredentialsStore credentials;
  final MediaObjectStore store;

  @override
  AccountKind get kind => AccountKind.s3;

  @override
  Future<AccountStatus> status(ConnectedAccount account) async =>
      AccountStatus.signedIn;

  @override
  Future<void> disconnect(ConnectedAccount account) async {}

  @override
  Future<MediaObjectStore?> mediaObjectStore(ConnectedAccount account) async =>
      await credentials.read(account.id) == null ? null : store;
}

void main() {
  late MediaStoreAttachState attachState;
  late MediaStoresRepository stores;
  late MediaStoreService service;
  late InMemoryMediaObjectStore bucket;

  setUp(() async {
    await setUpTestDatabase();
    SharedPreferences.setMockInitialValues({});
    attachState = MediaStoreAttachState(
      prefs: await SharedPreferences.getInstance(),
    );
    stores = MediaStoresRepository();
    service = MediaStoreService(
      credentials: MediaStoreCredentialsStore(storage: InMemoryKeychain()),
      attachState: attachState,
      storesRepository: stores,
      markerRetryBackoff: const [],
    );
    bucket = InMemoryMediaObjectStore();
  });

  tearDown(tearDownTestDatabase);

  MediaStoreAccountAttach attacher(
    AccountKind kind,
    Map<String, MediaObjectStore> byRow, {
    ConnectedAccount? mediaRow,
    _Accounts? accounts,
  }) => MediaStoreAccountAttach(
    service: service,
    accounts:
        accounts ??
        _Accounts(mediaRow ?? _row('unused', AccountKind.s3, 'unused')),
    registry: AccountProviderRegistry([_MediaAdapter(kind, byRow)]),
  );

  test('an own server attaches through its photos-folder row', () async {
    final syncRow = _row('s3-sync', AccountKind.s3, 'dives @ minio');
    final mediaRow = _row('s3-media', AccountKind.s3, 'dives @ minio');
    final accounts = _Accounts(mediaRow);

    await attacher(AccountKind.s3, {
      's3-media': bucket,
    }, accounts: accounts).attach(_group(syncRow));

    expect(accounts.ensured.single.$2, AccountRole.media);
    expect(await attachState.attachedAccountId(), 's3-media');
    final active = (await stores.getActive())!;
    expect(active.accountId, 's3-media');
    expect(active.providerType, 's3');
  });

  test('a WebDAV server does the same', () async {
    final mediaRow = _row('dav-media', AccountKind.webdav, 'eric @ nas');
    await attacher(
      AccountKind.webdav,
      {'dav-media': bucket},
      mediaRow: mediaRow,
    ).attach(_group(_row('dav-sync', AccountKind.webdav, 'eric @ nas')));

    expect(await attachState.attachedAccountId(), 'dav-media');
    expect((await stores.getActive())!.providerType, 'webdav');
  });

  test('Dropbox attaches through its own row', () async {
    final row = _row('db-row', AccountKind.dropbox, 'Dropbox');
    await attacher(AccountKind.dropbox, {'db-row': bucket}).attach(_group(row));

    expect(await attachState.attachedAccountId(), 'db-row');
    expect(
      await attachState.attachedProviderType(),
      AccountKind.dropbox.cloudProviderType,
    );
    expect((await stores.getActive())!.accountId, 'db-row');
  });

  // Review Focus 1: a second device holding the account joins the store
  // the library already uses, with nothing to type.
  test('the account a store already lives in joins that store', () async {
    final row = _row('db-row', AccountKind.dropbox, 'Dropbox');
    final first = await attacher(AccountKind.dropbox, {
      'db-row': bucket,
    }).attach(_group(row));
    await service.disconnect();

    final second = await attacher(AccountKind.dropbox, {
      'db-row': bucket,
    }).attach(_group(row));

    expect(second.createdNewStore, isFalse);
    expect(second.storeId, first.storeId);
  });

  test('an account with no keys here is refused, attaching nothing', () async {
    final row = _row('db-row', AccountKind.dropbox, 'Dropbox');
    await expectLater(
      attacher(AccountKind.dropbox, const {}).attach(_group(row)),
      throwsA(
        isA<MediaStoreException>().having(
          (e) => e.kind,
          'kind',
          MediaStoreErrorKind.auth,
        ),
      ),
    );
    expect(await attachState.attachedStoreId(), isNull);
  });

  // Review Focus 3: never a silent mix of two stores, and never a detach
  // for an account that could not have been attached anyway.
  test('switching to an account with no keys here keeps the current '
      'copies', () async {
    final a = _row('a-row', AccountKind.dropbox, 'Dropbox');
    final b = _row('b-row', AccountKind.dropbox, 'Dropbox 2');
    final attach = attacher(AccountKind.dropbox, {'a-row': bucket});
    final first = await attach.attach(_group(a));

    await expectLater(
      attach.switchTo(_group(b)),
      throwsA(
        isA<MediaStoreException>().having(
          (e) => e.kind,
          'kind',
          MediaStoreErrorKind.auth,
        ),
      ),
    );

    expect(await attachState.attachedStoreId(), first.storeId);
    expect(await attachState.attachedAccountId(), 'a-row');
  });

  test('switching to a server this device holds no keys for keeps the '
      'current copies', () async {
    final a = _row('a-row', AccountKind.dropbox, 'Dropbox');
    final attach = MediaStoreAccountAttach(
      service: service,
      accounts: _NoKeys(),
      registry: AccountProviderRegistry([
        _MediaAdapter(AccountKind.dropbox, {'a-row': bucket}),
      ]),
    );
    final first = await attach.attach(_group(a));

    await expectLater(
      attach.switchTo(_group(_row('s3-row', AccountKind.s3, 'dives @ minio'))),
      throwsA(
        isA<MediaStoreException>().having(
          (e) => e.kind,
          'kind',
          MediaStoreErrorKind.auth,
        ),
      ),
    );

    expect(await attachState.attachedStoreId(), first.storeId);
  });

  test('a switch whose marker check fails stays detached', () async {
    final a = _row('a-row', AccountKind.dropbox, 'Dropbox');
    final b = _row('b-row', AccountKind.dropbox, 'Dropbox 2');
    final refusing = InMemoryMediaObjectStore();
    final attach = attacher(AccountKind.dropbox, {
      'a-row': bucket,
      'b-row': refusing,
    });
    await attach.attach(_group(a));
    refusing.failNextWith = const MediaStoreException(
      'denied',
      kind: MediaStoreErrorKind.auth,
    );

    await expectLater(
      attach.switchTo(_group(b)),
      throwsA(isA<MediaStoreException>()),
    );

    expect(await attachState.attachedStoreId(), isNull);
  });

  test('switching attaches the new account\'s store', () async {
    final a = _row('a-row', AccountKind.dropbox, 'Dropbox');
    final b = _row('b-row', AccountKind.dropbox, 'Dropbox 2');
    final other = InMemoryMediaObjectStore();
    final attach = attacher(AccountKind.dropbox, {
      'a-row': bucket,
      'b-row': other,
    });
    final first = await attach.attach(_group(a));

    final second = await attach.switchTo(_group(b));

    expect(second.storeId, isNot(first.storeId));
    expect(await attachState.attachedAccountId(), 'b-row');
  });

  // Final review: a second device holding the server joins the copies in
  // the folder the library records, not a new `submersion-media/` folder.
  group('the account the copies live in', () {
    late ConnectedAccountsRepository roster;
    late AccountCredentialsStore keys;
    late AccountGroupService accounts;

    S3Config s3(String prefix) => S3Config(
      endpoint: 'https://minio.home:9000',
      bucket: 'dives',
      prefix: prefix,
      accessKeyId: 'AKIA1',
      secretAccessKey: 'shh',
    );

    setUp(() {
      roster = ConnectedAccountsRepository();
      keys = AccountCredentialsStore(storage: InMemoryKeychain());
      accounts = AccountGroupService(
        accounts: roster,
        credentials: keys,
        registry: AccountProviderRegistry([
          S3AccountAdapter(credentials: keys),
        ]),
      );
    });

    /// The server as this device sees it: keys for the sync folder, and the
    /// photos row another device made (a custom folder) with none.
    Future<(AccountGroup, ConnectedAccount)> server() async {
      final sync = await accounts.saveOwnServer(s3: s3('submersion-sync/'));
      final photos = s3('dive-photos/');
      final media = await roster.ensure(
        kind: AccountKind.s3,
        naturalKey: s3NaturalKey(photos),
        label: 'dives @ minio.home',
        location: S3AccountLocation.fromConfig(photos),
      );
      final rows = [
        (await roster.getById(sync.id))!,
        (await roster.getById(media.id))!,
      ];
      final group = groupAccounts(
        rows: rows,
        statusById: {for (final r in rows) r.id: AccountStatus.signedIn},
        localLocationById: const {},
        usagesOf: (_) => const [],
      ).single;
      return (group, media);
    }

    MediaStoreAccountAttach real() => MediaStoreAccountAttach(
      service: service,
      accounts: accounts,
      registry: AccountProviderRegistry([_KeyedAdapter(keys, bucket)]),
    );

    test(
      'attaches through the recorded row, giving it the server keys',
      () async {
        final (group, media) = await server();

        await real().attach(group, storeAccountId: media.id);

        expect(await attachState.attachedAccountId(), media.id);
        final written = await accounts.storedS3ForRow(media.id);
        expect(written?.prefix, 'dive-photos/');
        expect(written?.accessKeyId, 'AKIA1');
      },
    );

    test('a recorded row on another account is ignored', () async {
      final (group, _) = await server();

      await real().attach(group, storeAccountId: 'elsewhere');

      final attachedRow = await attachState.attachedAccountId();
      expect(
        (await accounts.storedS3ForRow(attachedRow!))?.prefix,
        'submersion-media/',
      );
    });
  });
}
