import 'package:submersion/core/providers/account_providers.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/accounts/account_provider_adapter.dart';
import 'package:submersion/core/services/accounts/connected_account.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/features/backup/presentation/providers/backup_providers.dart';
import 'package:submersion/features/settings/presentation/providers/account_group_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';

/// Where the backup copy goes on this device (spec section 8.2).
sealed class BackupCopyTarget {
  const BackupCopyTarget();
}

/// The copy goes to whichever account sync uses; [group] is null when sync
/// has no account here.
final class CopyFollowsSync extends BackupCopyTarget {
  const CopyFollowsSync(this.group);
  final AccountGroup? group;
}

/// The copy goes to [row], the sync-role row of [group].
final class CopyToAccount extends BackupCopyTarget {
  const CopyToAccount(this.group, this.row);
  final AccountGroup group;
  final ConnectedAccount row;
}

/// The copy was pinned to a row the roster no longer has. The preference is
/// kept: switching the copy elsewhere is the diver's choice to make.
final class CopyAccountGone extends BackupCopyTarget {
  const CopyAccountGone(this.accountId);
  final String accountId;
}

/// No copy off this device.
final class NoCopy extends BackupCopyTarget {
  const NoCopy();
}

/// Reads the account groups, which probe every account, so only the
/// Backups page watches it.
final backupCopyTargetProvider = FutureProvider.autoDispose<BackupCopyTarget>((
  ref,
) async {
  final (enabled, accountId) = ref.watch(
    backupSettingsProvider.select(
      (s) => (s.cloudBackupEnabled, s.copyAccountId),
    ),
  );
  if (!enabled) return const NoCopy();
  final groups = await ref.watch(accountGroupsProvider.future);
  if (accountId == null) return CopyFollowsSync(groups.syncing);
  final group = groups.holding(accountId);
  final row = group?.rows.where((r) => r.id == accountId).firstOrNull;
  if (group == null || row == null) return CopyAccountGone(accountId);
  return CopyToAccount(group, row);
}, retry: (_, _) => null);

/// The provider the backup service copies through, lists and restores from.
///
/// Following sync (or with the copy off, so history still lists the sync
/// folder's backups as it always has) it is sync's own provider. Pinned to a
/// row, it is built the way sync builds one, through the row's
/// [SyncCapable] adapter, from the stored id and kind alone: waiting for the
/// roster here would copy through the wrong account while it loads. A row
/// since removed still resolves to its own credentials, which are gone, so
/// the upload fails and the backup stays on this device; it never falls back
/// to the sync account.
final backupCopyProviderProvider = Provider<CloudStorageProvider?>((ref) {
  final (enabled, accountId, kind) = ref.watch(
    backupSettingsProvider.select(
      (s) => (s.cloudBackupEnabled, s.copyAccountId, s.copyAccountKind),
    ),
  );
  if (!enabled || accountId == null || kind == null) {
    return ref.watch(cloudStorageProviderProvider);
  }
  final raw = ref
      .watch(accountProviderRegistryProvider)
      .capabilityFor<SyncCapable>(kind)
      ?.syncProvider(copyRowReference(accountId, kind));
  if (raw == null) return null;
  return wrapForLibrary(raw, ref.watch(encryptionKeyNotifierProvider));
});

/// A roster row named by id and kind only. Every [SyncCapable.syncProvider]
/// reads nothing else from the row: credentials live in the keychain under
/// the id.
ConnectedAccount copyRowReference(String id, AccountKind kind) =>
    ConnectedAccount(
      id: id,
      kind: kind,
      label: '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
