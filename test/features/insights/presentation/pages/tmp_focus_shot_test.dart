import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/theme/app_theme_registry.dart';
import 'package:submersion/features/insights/domain/focus/focus_factor_row.dart';
import 'package:submersion/features/insights/domain/focus/focus_metric.dart';
import 'package:submersion/features/insights/domain/focus/focus_selection.dart';
import 'package:submersion/features/insights/domain/trend_aggregation.dart';
import 'package:submersion/features/insights/presentation/pages/insights_focus_page.dart';
import 'package:submersion/features/insights/presentation/providers/insights_focus_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';
import '../../../../helpers/test_database.dart';

const _root = '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = await File(f).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  setUpAll(() async {
    final roboto = [
      '$_root/Roboto-Regular.ttf',
      '$_root/Roboto-Medium.ttf',
      '$_root/Roboto-Bold.ttf',
    ];
    await _font('Roboto', roboto);
    await _font('.SF Pro Text', roboto);
    await _font('MaterialIcons', ['$_root/MaterialIcons-Regular.otf']);
  });
  setUp(() async => setUpTestDatabase());
  tearDown(() async => tearDownTestDatabase());

  final r = Random(7);
  const sites = [
    'Blue Hole',
    'Casino Point',
    'Shaw\'s Cove',
    'Ginnie Springs',
    'Anacapa',
  ];
  const entries = ['shore', 'boat', 'backRoll'];
  final series = <TrendDataPoint>[];
  final rows = <FocusFactorRow>[];
  for (var i = 0; i < 64; i++) {
    final date = DateTime.utc(
      2022,
      1,
      1,
    ).add(Duration(days: i * 17 + r.nextInt(9)));
    final boat = r.nextBool();
    series.add(
      TrendDataPoint(
        date: date,
        value: 13 + r.nextDouble() * 9 + (boat ? -2 : 1),
        diveId: 'd$i',
      ),
    );
    rows.add(
      FocusFactorRow(
        diveId: 'd$i',
        dateTime: date.add(Duration(hours: 8 + r.nextInt(10))),
        maxDepth: 12 + r.nextDouble() * 20,
        avgDepth: 8 + r.nextDouble() * 10,
        durationMinutes: 35 + r.nextInt(30).toDouble(),
        waterTemp: 14 + r.nextDouble() * 12,
        currentStrength: ['none', 'light', 'moderate'][r.nextInt(3)],
        waterType: r.nextInt(5) == 0 ? 'fresh' : 'salt',
        entryMethod: boat ? 'boat' : entries[r.nextInt(3)],
        siteId: 's${i % 5}',
        siteName: sites[i % 5],
        gasClass: r.nextBool() ? 'nitrox' : 'air',
        firstTankVolume: r.nextBool() ? 11.1 : 12.0,
        weight: 4 + r.nextInt(6).toDouble(),
        suitKey: r.nextInt(3) == 0 ? 'drysuit' : 'wetsuit:7',
        buddyKey: r.nextInt(6) == 0 ? 'solo' : 'buddy',
      ),
    );
  }

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required double width,
    required Brightness brightness,
    FocusSelection selection = const FocusSelection(),
    double height = 3400,
  }) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = Size(width * 2, height * 2);
    addTearDown(tester.view.reset);
    final overrides = await getBaseOverrides();
    var theme = AppThemeRegistry.resolveTheme(
      AppThemeRegistry.presets.first,
      brightness,
    );
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('Dive focus')),
            body: const InsightsFocusPage(embedded: true),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          focusSelectionProvider.overrideWith((ref) => selection),
          for (final m in FocusMetric.values)
            focusMetricSeriesProvider(m).overrideWith(
              (ref) async => m == FocusMetric.rmv ? series : const [],
            ),
          focusFactorRowsProvider.overrideWith((ref) async => rows),
        ],
        child: MaterialApp.router(
          theme: theme,
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets(
    'phone light',
    (t) => shot(
      t,
      '01-focus-before-phone',
      width: 400,
      brightness: Brightness.light,
    ),
  );
  testWidgets(
    'desktop light',
    (t) => shot(
      t,
      '02-focus-before',
      width: 1100,
      brightness: Brightness.light,
      height: 2600,
    ),
  );
  testWidgets(
    'phone dark',
    (t) => shot(
      t,
      '03-focus-before-dark-phone',
      width: 400,
      brightness: Brightness.dark,
    ),
  );
  testWidgets(
    'threshold empty',
    (t) => shot(
      t,
      '04-focus-threshold-before-phone',
      width: 400,
      brightness: Brightness.light,
      height: 900,
      selection: const FocusSelection(mode: FocusMode.above),
    ),
  );
}
