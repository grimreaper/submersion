import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:submersion/core/constants/list_view_mode.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/features/dive_sites/domain/entities/dive_site.dart';
import 'package:submersion/features/dive_sites/presentation/pages/site_detail_page.dart';
import 'package:submersion/features/dive_sites/presentation/providers/site_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/mock_providers.dart';

/// The detail page's Duplicate action (issue #3575) opens the new-site form
/// filled from this site, from the phone page and the desktop pane alike.
void main() {
  const site = DiveSite(id: 'site-1', name: 'Salt Pier');

  Future<void> pumpDetail(WidgetTester tester, {required bool embedded}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = embedded
        ? const Size(1400, 900)
        : const Size(400, 900);
    addTearDown(tester.view.reset);

    final overrides = await getBaseOverrides();
    final router = GoRouter(
      initialLocation: '/other',
      routes: [
        GoRoute(
          path: '/other',
          builder: (context, state) => Scaffold(
            body: ElevatedButton(
              onPressed: () => context.push('/sites/site-1'),
              child: const Text('GO'),
            ),
          ),
        ),
        GoRoute(
          path: '/sites/new',
          builder: (context, state) => Scaffold(
            body: Text('new from ${state.uri.queryParameters['duplicateOf']}'),
          ),
        ),
        GoRoute(
          path: '/sites/site-1',
          builder: (context, state) => embedded
              ? const Scaffold(
                  body: SiteDetailPage(siteId: 'site-1', embedded: true),
                )
              : const SiteDetailPage(siteId: 'site-1'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          siteListViewModeProvider.overrideWith((ref) => ListViewMode.detailed),
          siteProvider(site.id).overrideWith((ref) async => site),
          siteDiveCountProvider(site.id).overrideWith((ref) async => 0),
        ].cast<Override>(),
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Pushed, so the phone page does not redirect into the list.
    await tester.tap(find.text('GO'));
    await tester.pumpAndSettle();
  }

  for (final embedded in [false, true]) {
    final where = embedded ? 'the desktop pane' : 'the phone page';

    testWidgets('Duplicate on $where opens the new-site form from this site', (
      tester,
    ) async {
      await pumpDetail(tester, embedded: embedded);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy), findsOneWidget);
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();

      expect(find.text('new from site-1'), findsOneWidget);
    });
  }
}
