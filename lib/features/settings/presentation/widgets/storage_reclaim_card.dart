import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/storage/gc/storage_gc_coordinator.dart';
import 'package:submersion/core/utils/byte_format.dart';
import 'package:submersion/core/utils/unit_formatter.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/settings/presentation/providers/storage_gc_providers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The top of the Storage usage page: how much the cleanup could give back
/// now, what it gave back last time, and a button to run it (issue #3396).
///
/// The cleanup also runs on its own schedule, so the button is for a diver
/// who wants it now. It follows the same safety rules as the automatic runs:
/// cloud objects inside the safety wait stay, and the card says how much is
/// waiting rather than counting it as reclaimable.
class StorageReclaimCard extends ConsumerStatefulWidget {
  const StorageReclaimCard({super.key});

  @override
  ConsumerState<StorageReclaimCard> createState() => _StorageReclaimCardState();
}

class _StorageReclaimCardState extends ConsumerState<StorageReclaimCard> {
  bool _running = false;

  Future<void> _reclaim() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    final coordinator = ref.read(storageGcCoordinatorProvider);
    final startedAt = DateTime.now();
    setState(() => _running = true);
    try {
      await coordinator.run(StorageGcTrigger.manual);
    } finally {
      if (mounted) setState(() => _running = false);
    }
    // What this run reclaimed: the results it recorded, which carry a time
    // no earlier than its start.
    var bytes = 0;
    for (final result in [
      coordinator.store.lastDeviceResult,
      coordinator.store.lastCloudResult,
    ]) {
      if (result != null && !result.at.isBefore(startedAt)) {
        bytes += result.bytes;
      }
    }
    if (!mounted) return;
    ref.invalidate(deviceReclaimableBytesProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.settings_storageUsage_reclaimDone(formatBytes(bytes)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final view = ref.watch(storageGcStateProvider).value;
    final device = ref.watch(deviceReclaimableBytesProvider).value ?? 0;
    final cloud = view?.cloudUsage;
    final reclaimable = device + (cloud?.mediaReclaimableBytes ?? 0);
    final waiting = cloud?.mediaWaitingBytes ?? 0;
    final last = view?.lastReclaimed;
    final running = _running || (view?.running ?? false);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reclaimable > 0
                  ? l10n.settings_storageUsage_reclaimTitle(
                      formatBytes(reclaimable),
                    )
                  : l10n.settings_storageUsage_reclaimNothing,
              style: theme.textTheme.titleMedium,
            ),
            if (last != null) ...[
              const SizedBox(height: 4),
              Text(
                l10n.settings_storageUsage_reclaimLast(
                  formatBytes(last.bytes),
                  UnitFormatter(
                    ref.watch(settingsProvider),
                  ).formatDateTime(last.at, l10n: l10n),
                ),
                style: muted,
              ),
            ],
            if (waiting > 0) ...[
              const SizedBox(height: 4),
              Text(
                l10n.settings_storageUsage_reclaimWaiting(formatBytes(waiting)),
                style: muted,
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: running ? null : _reclaim,
              icon: running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cleaning_services_outlined),
              label: Text(l10n.settings_storageUsage_reclaimAction),
            ),
          ],
        ),
      ),
    );
  }
}
