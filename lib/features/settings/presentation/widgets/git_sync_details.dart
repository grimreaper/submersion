import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/settings/presentation/providers/git_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// What sync on a Git repository adds under "Using": when the branch history
/// was last reset, and, when the host refused a reset as a protected branch,
/// how to allow it. Nothing when neither is known.
class GitSyncDetails extends ConsumerWidget {
  const GitSyncDetails({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(gitConfigProvider).valueOrNull;
    if (config == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final reset = GitStorageProvider.lastKnownResetFor(config);
    final refused = GitStorageProvider.resetRefusedFor(config);
    return Column(
      key: const Key('git-sync-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reset != null)
          Text(
            l10n.settings_cloudSync_provider_git_lastReset(
              // The diver's date preference, not the ambient locale.
              UnitFormatter(
                ref.watch(settingsProvider),
              ).formatDate(reset.toLocal()),
            ),
          ),
        if (refused)
          Text(
            l10n.settings_gitConfig_error_protectedBranch(config.branch),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
