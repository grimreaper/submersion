import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/accounts/account_group_service.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/accounts/account_provider_adapter.dart';
import 'package:submersion/core/services/accounts/account_provider_registry.dart';
import 'package:submersion/core/services/accounts/connected_account.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/features/media_store/data/media_store_service.dart';

/// Sets up photo copies in an account the diver chose from the account
/// sheet (spec sections 7.4 and 8.3).
///
/// The account's photos-folder row is reached first: an own server gets
/// one made with the account's keys (`submersion-media/` or the WebDAV
/// media folder) when it has none, and the other kinds use their one row.
/// Its store is built through the same adapter the runtime uses, so the
/// copies never read keys the attachment does not name.
class MediaStoreAccountAttach {
  MediaStoreAccountAttach({
    required MediaStoreService service,
    required AccountGroupService accounts,
    required AccountProviderRegistry registry,
  }) : _service = service,
       _accounts = accounts,
       _registry = registry;

  final MediaStoreService _service;
  final AccountGroupService _accounts;
  final AccountProviderRegistry _registry;

  /// Attaches this device's copies to [group]. [storeAccountId] is the row
  /// the library's announced store records: when [group] holds it, that row
  /// is used, so a second device joins the copies in their own folder.
  /// Throws `MediaStoreException(kind: auth)` when the account holds no
  /// usable keys here.
  Future<MediaStoreConnectResult> attach(
    AccountGroup group, {
    String? storeAccountId,
  }) async {
    final (row, store) = await _resolve(group, storeAccountId);
    return _service.attachToAccountRow(row, store);
  }

  /// Moves this device's copies to [group]. [group]'s store is reached
  /// before anything changes, so an account with no keys here is refused
  /// with the current copies still attached. The current store is then
  /// detached (nothing in it is deleted) and [group]'s attached; when that
  /// attach fails the device stays detached and the error propagates, and
  /// the old store is never reattached behind the diver's back.
  Future<MediaStoreConnectResult> switchTo(AccountGroup group) async {
    final (row, store) = await _resolve(group, null);
    // A null store is refused by attachToAccountRow before it touches any
    // state, so only a reachable account detaches the current copies.
    if (store != null) await _service.disconnect();
    return _service.attachToAccountRow(row, store);
  }

  Future<(ConnectedAccount, MediaObjectStore?)> _resolve(
    AccountGroup group,
    String? storeAccountId,
  ) async {
    final ConnectedAccount row;
    try {
      row = await _mediaRowOf(group, storeAccountId);
    } on StateError {
      throw MediaStoreException(
        '${group.label} is not signed in on this device',
        kind: MediaStoreErrorKind.auth,
      );
    }
    final store = await _registry
        .capabilityFor<MediaStoreCapable>(row.kind)
        ?.mediaObjectStore(row);
    return (row, store);
  }

  Future<ConnectedAccount> _mediaRowOf(
    AccountGroup group,
    String? storeAccountId,
  ) async {
    final recorded = group.rows
        .where((r) => r.id == storeAccountId)
        .firstOrNull;
    if (recorded != null) {
      await _giveServerKeys(group, recorded);
      return recorded;
    }
    if (group.kind == AccountKind.s3 || group.kind == AccountKind.webdav) {
      return _accounts.ensureRole(group, AccountRole.media);
    }
    return group.rowFor(AccountRole.media) ?? group.rows.first;
  }

  /// Writes the server keys this device holds for [group] to [row] when it
  /// has none, through the same path an edit of the server takes (rows
  /// holding other keys keep them). A row that still has none afterwards is
  /// refused by the attach.
  Future<void> _giveServerKeys(AccountGroup group, ConnectedAccount row) async {
    switch (row.kind) {
      case AccountKind.s3:
        if (await _accounts.storedS3ForRow(row.id) != null) return;
        final held = await _accounts.storedS3For(group);
        if (held == null) return;
        await _accounts.storeServerConfig(group, s3: held, previousS3: held);
      case AccountKind.webdav:
        if (await _accounts.storedWebDavForRow(row.id) != null) return;
        final held = await _accounts.storedWebDavFor(group);
        if (held == null) return;
        await _accounts.storeServerConfig(
          group,
          webdav: held,
          previousWebDav: held,
        );
      default:
        return;
    }
  }
}
