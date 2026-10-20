import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/accounts/account_group.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/features/media_store/presentation/media_store_error_message.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/media_store/presentation/providers/photos_copies_provider.dart';
import 'package:submersion/features/settings/presentation/providers/account_group_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/accounts/account_group_tile.dart';
import 'package:submersion/features/settings/presentation/widgets/accounts/account_sheet.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/widgets/tile_subtitle_action.dart';

/// "Copies in {account}" with Change, or "Not set up" with Set up (spec
/// section 8.3). Choosing an account attaches this device's copies there:
/// today's marker check joins the store already in that account or starts
/// one. Choosing another account says what that does first.
class PhotosUsingRow extends ConsumerStatefulWidget {
  const PhotosUsingRow({super.key});

  @override
  ConsumerState<PhotosUsingRow> createState() => _PhotosUsingRowState();
}

class _PhotosUsingRowState extends ConsumerState<PhotosUsingRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(photosCopiesProvider);
    final copies = async.value;
    if (copies == null) {
      return ListTile(
        leading: const Icon(Icons.cloud_outlined),
        title: Text(
          async.hasError
              ? l10n.settings_connectedAccounts_loadError
              : l10n.settings_data_status_checking,
        ),
      );
    }
    final label = copies.label;
    final hasCopies =
        label != null && (copies.attached || copies.store != null);
    final group = copies.group;
    return ListTile(
      key: const Key('photos-using'),
      leading: _busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              group != null
                  ? accountKindIcon(group.kind)
                  : hasCopies
                  ? Icons.cloud_outlined
                  : Icons.cloud_off_outlined,
            ),
      title: Text(
        hasCopies
            ? l10n.settings_photos_copiesIn(label)
            : l10n.settings_sync_notSetUp,
      ),
      subtitle: TileSubtitleAction(
        actionKey: const Key('photos-using-change'),
        // Attached here: Change. Not attached (nothing, or a store this
        // device has not joined): Set up.
        label: copies.attached
            ? l10n.settings_sync_change
            : l10n.settings_data_setUp,
        semanticsLabel: copies.attached
            ? null
            : l10n.settings_data_setUpFeature(l10n.settings_photosVideos_title),
        onPressed: _busy ? null : () => _choose(copies),
      ),
    );
  }

  Future<void> _choose(PhotosCopies copies) async {
    final l10n = context.l10n;
    final currentLabel = copies.attached ? copies.label : null;
    final choice = await showAccountSheet(
      context,
      allowedKinds: photoAccountKinds,
      currentKey: copies.group?.key,
      consequenceOf: (AccountGroup c) =>
          currentLabel != null && c.key != copies.group?.key
          ? l10n.settings_photos_switchConsequence(currentLabel, c.label)
          : null,
    );
    if (choice == null || !mounted) return;
    // The account the copies already use: nothing to do.
    if (copies.attached && choice.key == copies.group?.key) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final attach = container.read(mediaStoreAccountAttachProvider);
      if (copies.attached) {
        await attach.switchTo(choice);
      } else {
        await attach.attach(choice);
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.settings_photos_attached(choice.label))),
      );
    } on MediaStoreException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(mediaStoreErrorMessage(l10n, e))),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      // A failed switch leaves this device detached; either way every
      // reader of the attachment and the accounts' uses re-reads.
      invalidateMediaStoreAttachmentWith(container.invalidate);
      container.invalidate(photosCopiesProvider);
      refreshAccountState(container.invalidate);
      if (mounted) setState(() => _busy = false);
    }
  }
}
