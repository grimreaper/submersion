import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/settings/presentation/providers/git_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The Git row in Cloud Sync's provider list. Tapping selects Git once it is
/// configured, otherwise opens its settings; the gear always edits. Shows
/// the repository, the branch, and when its history was last reset.
class GitProviderTile extends ConsumerWidget {
  const GitProviderTile({
    super.key,
    required this.isSelected,
    required this.onSelect,
    required this.onEdit,
  });

  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final config = ref.watch(gitConfigProvider).valueOrNull;
    final reset = config == null
        ? null
        : GitStorageProvider.lastKnownResetFor(config);
    final resetRefused =
        config != null && GitStorageProvider.resetRefusedFor(config);
    return Semantics(
      selected: isSelected,
      child: ListTile(
        key: const Key('git-provider-tile'),
        leading: const Icon(Icons.commit),
        title: Text(l10n.settings_cloudSync_provider_git_title),
        subtitle: config == null
            ? Text(l10n.settings_cloudSync_provider_git_subtitle)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${config.displayLabel}, ${config.branch}'),
                  if (reset != null)
                    Text(
                      l10n.settings_cloudSync_provider_git_lastReset(
                        // The diver's date preference, not the ambient locale.
                        UnitFormatter(
                          ref.watch(settingsProvider),
                        ).formatDate(reset.toLocal()),
                      ),
                    ),
                  if (resetRefused)
                    Text(
                      l10n.settings_gitConfig_error_protectedBranch(
                        config.branch,
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Colors.green,
                semanticLabel: l10n.settings_cloudSync_provider_connected,
              ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: l10n.settings_cloudSync_provider_git_edit,
              onPressed: onEdit,
            ),
          ],
        ),
        onTap: config != null ? onSelect : onEdit,
      ),
    );
  }
}
