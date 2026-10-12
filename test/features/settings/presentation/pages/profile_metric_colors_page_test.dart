import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric.dart';
import 'package:submersion/features/dive_log/presentation/profile_colors/profile_metric_color_overrides.dart';
import 'package:submersion/features/dive_log/presentation/widgets/profile_metric_colors.dart';
import 'package:submersion/features/settings/presentation/pages/profile_metric_colors_page.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Issue #3012: Settings > Appearance > Dives > Metric Colors.
class _StubSettingsNotifier extends StateNotifier<AppSettings>
    implements SettingsNotifier {
  _StubSettingsNotifier([AppSettings? s]) : super(s ?? const AppSettings());

  @override
  Future<void> setProfileMetricColor(
    ProfileMetric metric,
    Color? color,
  ) async => state = state.copyWith(
    profileMetricColors: state.profileMetricColors.withColor(metric, color),
  );

  @override
  Future<void> resetProfileMetricColors() async => state = state.copyWith(
    profileMetricColors: ProfileMetricColorOverrides.none,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _page(_StubSettingsNotifier n) => ProviderScope(
  overrides: [settingsProvider.overrideWith((ref) => n)],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale('en'),
    home: ProfileMetricColorsPage(),
  ),
);

Future<void> _pumpTall(WidgetTester tester, _StubSettingsNotifier n) async {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_page(n));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists all 20 metrics under the chart dialog\'s sections', (
    tester,
  ) async {
    await _pumpTall(tester, _StubSettingsNotifier());
    for (final metric in ProfileMetric.values) {
      expect(
        find.byKey(ValueKey('metricColorRow-${metric.name}')),
        findsOneWidget,
        reason: metric.name,
      );
    }
    for (final header in [
      'Overlays',
      'Markers',
      'Decompression',
      'Gas Analysis',
      'Other',
    ]) {
      expect(find.text(header), findsOneWidget, reason: header);
    }
  });

  testWidgets('Auto metrics say so in their subtitle', (tester) async {
    await _pumpTall(tester, _StubSettingsNotifier());
    expect(find.text('Auto: follows the theme'), findsOneWidget);
    expect(find.text('Auto: each gas has its own color'), findsOneWidget);
  });

  testWidgets('a custom pressure colour says it is for single-tank dives', (
    tester,
  ) async {
    await _pumpTall(
      tester,
      _StubSettingsNotifier(
        AppSettings(
          profileMetricColors: ProfileMetricColorOverrides.none.withColor(
            ProfileMetric.pressure,
            const Color(0xFF00E676),
          ),
        ),
      ),
    );
    expect(find.text('Used on single-tank dives'), findsOneWidget);
  });

  testWidgets('the sheet names a held swatch and tapping it swaps', (
    tester,
  ) async {
    final n = _StubSettingsNotifier();
    await _pumpTall(tester, n);
    await tester.tap(find.text('ppO2'));
    await tester.pumpAndSettle();

    expect(find.text('ppO2 color'), findsOneWidget);
    final held = find.bySemanticsLabel(RegExp(r'Swaps with TTS$'));
    expect(held, findsOneWidget);
    await tester.tap(held);
    await tester.pumpAndSettle();

    expect(find.text('ppO2 color'), findsNothing, reason: 'sheet closes');
    expect(
      n.state.profileMetricColors.effectiveArgb(ProfileMetric.tts),
      ProfileMetricColors.ppO2.toARGB32(),
    );
    expect(
      n.state.profileMetricColors.effectiveArgb(ProfileMetric.ppO2),
      ProfileMetricColors.tts.toARGB32(),
    );
  });

  testWidgets('Default returns a metric to its own colour', (tester) async {
    final n = _StubSettingsNotifier(
      AppSettings(
        profileMetricColors: ProfileMetricColorOverrides.none.withColor(
          ProfileMetric.ppO2,
          const Color(0xFFE040FB),
        ),
      ),
    );
    await _pumpTall(tester, n);
    await tester.tap(find.text('ppO2'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Default'));
    await tester.pumpAndSettle();
    expect(n.state.profileMetricColors, ProfileMetricColorOverrides.none);
  });

  testWidgets('Reset all is disabled with nothing customised', (tester) async {
    await _pumpTall(tester, _StubSettingsNotifier());
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.restart_alt),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Reset all clears every colour after confirming', (tester) async {
    final n = _StubSettingsNotifier(
      AppSettings(
        profileMetricColors: ProfileMetricColorOverrides.none.withColor(
          ProfileMetric.ppO2,
          const Color(0xFFE040FB),
        ),
      ),
    );
    await _pumpTall(tester, n);
    await tester.tap(find.byTooltip('Reset all'));
    await tester.pumpAndSettle();
    expect(find.text('Reset metric colors?'), findsOneWidget);
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(n.state.profileMetricColors, ProfileMetricColorOverrides.none);
  });
}
