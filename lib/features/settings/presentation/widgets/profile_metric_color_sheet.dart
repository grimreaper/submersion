import 'package:flutter/material.dart';

import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric_label.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric_palette.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric_swatches.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/swatch_name.dart';
import 'package:submersion/features/dive_log/presentation/widgets/profile_metric_colors.dart';
import 'package:submersion/l10n/l10n_extension.dart';

/// The colour choice for one profile metric (issue #3012): Default (or
/// Auto), then every palette swatch. A swatch another metric shows names it,
/// since picking it swaps the two.
Future<void> showProfileMetricColorSheet(
  BuildContext context, {
  required ProfileMetric metric,
  required ProfileMetricPalette palette,
  required ValueChanged<Color?> onPicked,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: _SheetBody(
          metric: metric,
          palette: palette,
          onPicked: (color) {
            Navigator.of(sheetContext).pop();
            onPicked(color);
          },
        ),
      ),
    ),
  );
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.metric,
    required this.palette,
    required this.onPicked,
  });

  final ProfileMetric metric;
  final ProfileMetricPalette palette;
  final ValueChanged<Color?> onPicked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = palette.overrides.effectiveArgb(metric);
    final onDefault = palette.overrides.argbOf(metric) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settings_metricColors_sheetTitle(
            profileMetricLabel(l10n, metric),
          ),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            _Swatch(
              // The colour Default/Auto gives, not the current choice.
              color:
                  metric.defaultColor ??
                  (metric == ProfileMetric.temperature
                      ? palette.temperatureAuto
                      : ProfileMetricColors.pressure),
              selected: onDefault,
              caption: metric.isAuto
                  ? l10n.settings_metricColors_auto
                  : l10n.settings_metricColors_default,
              semanticsLabel: metric.isAuto
                  ? l10n.settings_metricColors_auto
                  : l10n.settings_metricColors_default,
              onTap: () => onPicked(null),
            ),
            for (final swatch in profileMetricSwatches)
              _buildSwatch(context, swatch, current),
          ],
        ),
      ],
    );
  }

  Widget _buildSwatch(BuildContext context, Color swatch, int? current) {
    final l10n = context.l10n;
    final argb = swatch.toARGB32();
    final holder = palette.overrides.holderOf(argb, except: metric);
    final holderLabel = holder == null
        ? null
        : profileMetricLabel(l10n, holder);
    final name = swatchName(l10n, swatch);
    return _Swatch(
      color: swatch,
      selected: argb == current && palette.overrides.argbOf(metric) != null,
      caption: holderLabel,
      semanticsLabel: holderLabel == null
          ? name
          : '$name, ${l10n.settings_metricColors_swapsWith(holderLabel)}',
      onTap: () => onPicked(swatch),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.semanticsLabel,
    required this.onTap,
    this.caption,
  });

  final Color color;
  final bool selected;
  final String semanticsLabel;
  final String? caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: SizedBox(
          // Wide enough for a two-line caption such as "Heart Rate".
          width: 76,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? scheme.onSurface
                            : scheme.outlineVariant,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 32,
                child: caption == null
                    ? null
                    : Text(
                        caption!,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
