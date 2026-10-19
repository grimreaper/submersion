import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/services/cloud_storage/cloud_provider_instances.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';

/// The Git provider singleton, for the settings page (load, save, test).
final gitStorageProviderInstanceProvider = Provider<GitStorageProvider>(
  (ref) => gitProviderInstance,
);

/// The stored Git sync configuration, or null when unset. Invalidate after
/// saving or removing it.
final gitConfigProvider = FutureProvider<GitConfig?>((ref) async {
  return ref.watch(gitStorageProviderInstanceProvider).loadConfig();
});
