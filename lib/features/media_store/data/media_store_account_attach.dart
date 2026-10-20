import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/accounts/account_group_service.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/accounts/account_provider_adapter.dart';
import 'package:submersion/core/services/accounts/account_provider_registry.dart';
import 'package:submersion/core/services/accounts/connected_account.dart';
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

  /// Attaches this device's copies to [group]. Throws
  /// `MediaStoreException(kind: auth)` when the account holds no usable keys
  /// here.
  Future<MediaStoreConnectResult> attach(AccountGroup group) async {
    final row = await _mediaRowOf(group);
    final store = await _registry
        .capabilityFor<MediaStoreCapable>(row.kind)
        ?.mediaObjectStore(row);
    return _service.attachToAccountRow(row, store);
  }

  /// Moves this device's copies to [group]: the current store is detached
  /// first (nothing in it is deleted), then [group]'s is attached. When the
  /// attach fails the device stays detached and the error propagates; the
  /// old store is never reattached behind the diver's back.
  Future<MediaStoreConnectResult> switchTo(AccountGroup group) async {
    await _service.disconnect();
    return attach(group);
  }

  Future<ConnectedAccount> _mediaRowOf(AccountGroup group) async {
    if (group.kind == AccountKind.s3 || group.kind == AccountKind.webdav) {
      return _accounts.ensureRole(group, AccountRole.media);
    }
    return group.rowFor(AccountRole.media) ?? group.rows.first;
  }
}
