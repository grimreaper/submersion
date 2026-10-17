import 'package:flutter/material.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/theme/display_zoom.dart';
import 'package:submersion/features/settings/presentation/providers/display_zoom_provider.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// App-wide display zoom control.
///
/// No preview widget: zoom is applied at the app root, so this settings page
/// scales as the slider moves and is itself the live preview.
///
/// The title and the slider share one row once the tile is at least
/// [oneRowMinWidth] wide, scaled by the system text size, and stack on
/// narrower screens. The width is the tile's own, in logical pixels after
/// zoom, so zooming in on a wide pane can itself bring back the stacked
/// layout.
class DisplayZoomSettingsTile extends ConsumerWidget {
  const DisplayZoomSettingsTile({super.key});

  /// The narrowest tile that fits the title and the slider on one row at the
  /// default text size. Larger text needs proportionally more, or the Smaller
  /// and Larger labels squeeze the slider out of the row.
  static const double oneRowMinWidth = 560;

  /// The font size whose scaled size sets the text scale for the threshold.
  static const double _referenceFontSize = 14;

  /// The share of a one-row tile's width given to the slider, its labels and
  /// the reset action; the title takes the rest.
  static const double oneRowControlsWidthFraction = 0.6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(displayZoomNotifierProvider);
    final notifier = ref.read(displayZoomNotifierProvider.notifier);
    final l10n = context.l10n;
    final percent = (zoom * 100).round();
    final label = l10n.settings_appearance_displaySize_value(percent);

    final reset = zoom == DisplayZoom.defaultValue
        ? null
        : IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: l10n.settings_appearance_displaySize_reset,
            onPressed: notifier.reset,
          );
    final slider = _ZoomSlider(zoom: zoom, label: label, notifier: notifier);
    final textScale =
        MediaQuery.textScalerOf(context).scale(_referenceFontSize) /
        _referenceFontSize;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= oneRowMinWidth * textScale) {
          return ListTile(
            leading: const Icon(Icons.format_size),
            title: Text(l10n.settings_appearance_displaySize),
            subtitle: Text(label),
            trailing: SizedBox(
              width: constraints.maxWidth * oneRowControlsWidthFraction,
              child: Row(
                children: [
                  Expanded(child: slider),
                  // Reserve the reset slot even while it is hidden, so the
                  // track does not shrink under the pointer when a drag moves
                  // off 100%.
                  SizedBox(width: kMinInteractiveDimension, child: reset),
                ],
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.format_size),
              title: Text(l10n.settings_appearance_displaySize),
              subtitle: Text(label),
              trailing: reset,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: slider,
            ),
          ],
        );
      },
    );
  }
}

/// The slider between its Smaller and Larger labels.
class _ZoomSlider extends StatelessWidget {
  const _ZoomSlider({
    required this.zoom,
    required this.label,
    required this.notifier,
  });

  final double zoom;
  final String label;
  final DisplayZoomNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    return Row(
      children: [
        Text(l10n.settings_appearance_displaySize_smaller, style: labelStyle),
        Expanded(
          child: Slider(
            value: zoom,
            min: DisplayZoom.min,
            max: DisplayZoom.max,
            divisions: DisplayZoom.divisions,
            label: label,
            // Rescale live on every notch, but only write to storage once the
            // drag ends.
            onChanged: notifier.previewZoom,
            onChangeEnd: notifier.setZoom,
          ),
        ),
        Text(l10n.settings_appearance_displaySize_larger, style: labelStyle),
      ],
    );
  }
}
