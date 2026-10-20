import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/utils/log_failure.dart';
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/settings_pane_navigator.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// "Upload new photos automatically", "Use cellular data" and Uploads, for a
/// device that keeps copies (spec section 8.3).
class PhotosUploadSettings extends ConsumerStatefulWidget {
  const PhotosUploadSettings({super.key});

  @override
  ConsumerState<PhotosUploadSettings> createState() =>
      _PhotosUploadSettingsState();
}

class _PhotosUploadSettingsState extends ConsumerState<PhotosUploadSettings> {
  // Null until loaded; the switches render only once values are known.
  bool? _autoUpload;
  bool? _photosOnCellular;

  @override
  void initState() {
    super.initState();
    logFailure(_load(), _PhotosUploadSettingsState, 'load policies');
  }

  Future<void> _load() async {
    final policies = ref.read(mediaStorePoliciesProvider);
    final autoUpload = await policies.autoUpload();
    final photosOnCellular = await policies.photosOnCellular();
    if (!mounted) return;
    setState(() {
      _autoUpload = autoUpload;
      _photosOnCellular = photosOnCellular;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_autoUpload case final autoUpload?)
          SwitchListTile(
            key: const Key('media-s3-policy-auto-upload'),
            secondary: const Icon(Icons.cloud_upload_outlined),
            title: Text(l10n.settings_photos_autoUpload),
            value: autoUpload,
            onChanged: (value) async {
              setState(() => _autoUpload = value);
              await ref.read(mediaStorePoliciesProvider).setAutoUpload(value);
            },
          ),
        if (_photosOnCellular case final onCellular?)
          SwitchListTile(
            key: const Key('media-s3-policy-photos-cellular'),
            secondary: const Icon(Icons.signal_cellular_alt),
            title: Text(l10n.settings_photos_cellular),
            value: onCellular,
            onChanged: (value) async {
              setState(() => _photosOnCellular = value);
              await ref
                  .read(mediaStorePoliciesProvider)
                  .setPhotosOnCellular(value);
            },
          ),
        ListTile(
          key: const Key('media-s3-transfers'),
          leading: const Icon(Icons.swap_vert),
          title: Text(l10n.settings_photos_uploads),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              context.pushSettingsPage('/settings/photos-media/uploads'),
        ),
      ],
    );
  }
}
