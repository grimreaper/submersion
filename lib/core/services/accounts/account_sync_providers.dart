import 'package:submersion/core/data/repositories/sync_repository.dart'
    show CloudProviderType;
import 'package:submersion/core/services/accounts/account_credentials_store.dart';
import 'package:submersion/core/services/accounts/account_kind.dart';
import 'package:submersion/core/services/cloud_storage/cloud_provider_instances.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/dropbox/dropbox_auth_manager.dart';
import 'package:submersion/core/services/cloud_storage/dropbox/dropbox_auth_store.dart';
import 'package:submersion/core/services/cloud_storage/dropbox_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/s3/s3_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/s3_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/webdav/webdav_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/webdav_storage_provider.dart';

/// The S3 provider for the roster row [accountId], reading its per-account
/// keychain key. The S3 adapter builds through here too, so the foreground
/// and the scheduled backup cannot reach the row differently.
S3StorageProvider s3SyncProviderFor(String accountId) => S3StorageProvider(
  store: S3CredentialsStore(
    storageKey: AccountCredentialsStore.keyFor(accountId),
  ),
);

/// The WebDAV provider for the roster row [accountId]; see
/// [s3SyncProviderFor].
WebDavStorageProvider webdavSyncProviderFor(String accountId) =>
    WebDavStorageProvider(
      store: WebDavCredentialsStore(
        storageKey: AccountCredentialsStore.keyFor(accountId),
      ),
    );

/// A sync-capable provider for the roster row [accountId] of [kind], built
/// with no database or Riverpod container (the scheduled backup's isolate).
///
/// Session-managed kinds (Google Drive, iCloud) are the per-type instances,
/// as everywhere else. Dropbox gets a fresh auth manager over the row's key:
/// the isolate runs one backup, so there is no refresh to share. Lightroom
/// cannot hold files and yields null.
CloudStorageProvider? accountSyncProvider(
  AccountKind kind,
  String accountId, {
  CloudStorageProvider Function(CloudProviderType type)? instanceFor,
}) => switch (kind) {
  AccountKind.s3 => s3SyncProviderFor(accountId),
  AccountKind.webdav => webdavSyncProviderFor(accountId),
  AccountKind.dropbox => DropboxStorageProvider(
    authManager: DropboxAuthManager(
      store: DropboxAuthStore(
        storageKey: AccountCredentialsStore.keyFor(accountId),
      ),
    ),
  ),
  AccountKind.googledrive || AccountKind.icloud =>
    (instanceFor ?? cloudProviderInstanceFor)(kind.cloudProviderType!),
  AccountKind.adobeLightroom => null,
};
