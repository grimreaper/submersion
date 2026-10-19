import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/features/settings/presentation/providers/git_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/git_provider_tile.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester,
    GitConfig? config, {
    bool selected = false,
  }) async {
    final calls = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [gitConfigProvider.overrideWith((ref) async => config)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GitProviderTile(
              isSelected: selected,
              onSelect: () => calls.add('select'),
              onEdit: () => calls.add('edit'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('unconfigured: generic subtitle, tap opens the editor', (
    tester,
  ) async {
    final calls = await pump(tester, null);
    expect(find.text('Any Git host'), findsOneWidget);
    await tester.tap(find.text('Git'));
    expect(calls, ['edit']);
  });

  testWidgets('configured: repository and branch, tap selects', (tester) async {
    final calls = await pump(
      tester,
      GitConfig(
        repoUrl: 'https://github.com/you/dive-log',
        username: 'you',
        token: 'ghp_secret',
      ),
    );
    expect(
      find.text('you/dive-log @ github.com, submersion-sync'),
      findsOneWidget,
    );
    await tester.tap(find.text('Git'));
    expect(calls, ['select']);
  });

  testWidgets('the gear always edits, and a selected tile shows connected', (
    tester,
  ) async {
    final calls = await pump(
      tester,
      GitConfig(
        repoUrl: 'https://gitlab.com/group/r',
        username: 'you',
        token: 't',
      ),
      selected: true,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.byTooltip('Edit Git configuration'));
    expect(calls, ['edit']);
  });
}
