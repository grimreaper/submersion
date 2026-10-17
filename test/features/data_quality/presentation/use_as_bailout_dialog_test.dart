import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/data_quality/presentation/widgets/use_as_bailout_dialog.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

/// Issue #3307: the confirmation for making a name-derived transmitter tank
/// the bailout names every change, and offers to register the transmitter.
void main() {
  const tx = DiveTank(
    id: 'tx',
    order: 1,
    role: TankRole.oxygenSupply,
    roleSource: TankRoleSource.transmitterName,
    gasMix: GasMix(o2: 100, he: 0),
    transmitterSerial: '180777',
    sourceTankIndex: 1,
  );
  const oc = DiveTank(
    id: 'oc',
    order: 3,
    role: TankRole.bailout,
    gasMix: GasMix(o2: 18, he: 45),
    sourceTankIndex: 3,
  );

  UseAsBailoutChoice? choice;
  var closed = false;
  setUp(() {
    choice = null;
    closed = false;
  });

  Future<void> show(
    WidgetTester tester, {
    DiveTank tank = tx,
    DiveTank? ocTank = oc,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              choice = await showUseAsBailoutDialog(
                context,
                tank: tank,
                tankNumber: 2,
                ocTank: ocTank,
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('names the role, the mix and the merge', (tester) async {
    await show(tester);
    expect(
      find.text("Role: O₂ Supply, read from the transmitter's name → Bailout"),
      findsOneWidget,
    );
    expect(find.text('Gas mix: O2 → Tx 18/45'), findsOneWidget);
    expect(
      find.text(
        'Removes the duplicate Bailout cylinder (switches move to Tank 2)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('no merge line when the OC cylinder was edited', (tester) async {
    await show(tester, ocTank: oc.copyWith(volume: 11.1));
    expect(find.textContaining('Removes the duplicate'), findsNothing);
  });

  testWidgets('offers to register the transmitter, ticked', (tester) async {
    await show(tester);
    final box = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(box.value, isTrue);
    expect(
      find.text('Also register this transmitter as a Bailout'),
      findsOneWidget,
    );
    await tester.tap(find.text('Use as bailout'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(choice, isNotNull);
    expect(choice!.register, isTrue);
  });

  testWidgets('without a serial there is nothing to register', (tester) async {
    await show(
      tester,
      tank: const DiveTank(
        id: 'tx',
        order: 1,
        role: TankRole.oxygenSupply,
        roleSource: TankRoleSource.transmitterName,
        gasMix: GasMix(o2: 100, he: 0),
        sourceTankIndex: 1,
      ),
    );
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.text('Use as bailout'));
    await tester.pumpAndSettle();
    expect(choice!.register, isFalse);
  });

  testWidgets('cancel returns null', (tester) async {
    await show(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(choice, isNull);
  });
}
