import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/media_store/presentation/providers/photos_copies_provider.dart';
import 'package:submersion/features/media_store/presentation/widgets/photos_advanced_section.dart';
import 'package:submersion/features/media_store/presentation/widgets/photos_status_line.dart';
import 'package:submersion/features/media_store/presentation/widgets/photos_upload_settings.dart';
import 'package:submersion/features/media_store/presentation/widgets/photos_using_row.dart';
import 'package:submersion/features/settings/presentation/widgets/pending_setup_card.dart';
import 'package:submersion/features/settings/presentation/widgets/settings_pane_navigator.dart';
import 'package:submersion/features/settings/presentation/widgets/settings_section_helpers.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// Photos & videos (spec section 8.3): where copies are kept and what is
/// true of them, how uploads run, where photos come from, then Advanced.
/// It replaces the Photos & Media hub and the Media Storage page.
class PhotosVideosPage extends ConsumerWidget {
  const PhotosVideosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final attached = ref.watch(photosCopiesProvider).value?.attached ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_photosVideos_title),
        actions: [
          // Until the Set up this device card replaces it (phase 6).
          IconButton(
            tooltip: l10n.settings_photosMedia_guidedSetup,
            icon: const Icon(Icons.checklist_outlined),
            onPressed: () =>
                context.pushSettingsPage('/settings/photos-media/setup'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const PendingSetupCard(margin: EdgeInsets.fromLTRB(16, 16, 16, 0)),
          _header(context, l10n.settings_photos_cloudHeader),
          const PhotosUsingRow(),
          const PhotosStatusLine(),
          if (attached) const PhotosUploadSettings(),
          _header(context, l10n.settings_photos_sourcesHeader),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.settings_photos_library),
            subtitle: Text(l10n.settings_photosMedia_photoSources_subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushSettingsPage('/settings/media-sources'),
          ),
          PhotosAdvancedSection(attached: attached),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: buildSettingsSectionHeader(context, text),
  );
}
