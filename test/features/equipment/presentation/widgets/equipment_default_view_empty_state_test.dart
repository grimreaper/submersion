import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/constants/list_view_mode.dart';
import 'package:submersion/features/divers/presentation/providers/diver_providers.dart';
import 'package:submersion/features/equipment/domain/entities/equipment_item.dart';
import 'package:submersion/features/equipment/presentation/providers/equipment_providers.dart';
import 'package:submersion/features/equipment/presentation/widgets/equipment_list_content.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';

import '../../../../helpers/equipment_query_fakes.dart';
import '../../../../helpers/mock_providers.dart';
import '../../../../helpers/test_app.dart';

/// The default view is the diver's to choose (#2628), so it can hide every
/// item they own; the list must not then invite them to add their first.
Future<void> _pump(WidgetTester tester, List<EquipmentItem> owned) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    testApp(
      locale: const Locale('en'),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        settingsProvider.overrideWith((ref) => MockSettingsNotifier()),
        currentDiverIdProvider.overrideWith(
          (ref) => MockCurrentDiverIdNotifier(),
        ),
        // The fake reads the default view from the active list.
        activeEquipmentProvider.overrideWith(
          (ref) async => const <EquipmentItem>[],
        ),
        allEquipmentProvider.overrideWith((ref) async => owned),
        fakeEquipmentQueryIds(),
        equipmentListViewModeProvider.overrideWith(
          (ref) => ListViewMode.detailed,
        ),
      ],
      child: const EquipmentListContent(showAppBar: true),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const spareReg = EquipmentItem(
    id: 'reg',
    name: 'Spare Regulator',
    type: EquipmentType.regulator,
    status: EquipmentStatus.spare,
  );

  testWidgets('a default view hiding owned gear says so and offers it all', (
    tester,
  ) async {
    await _pump(tester, const [spareReg]);
    expect(find.text('No equipment in your default view'), findsOneWidget);
    expect(
      find.text('Your default view hides the rest of your gear.'),
      findsOneWidget,
    );
    expect(find.text('Add Your First Equipment'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('equipment_list_showAll')));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EquipmentListContent)),
    );
    expect(container.read(equipmentFilterProvider).allStatuses, isTrue);
    expect(find.text('Spare Regulator'), findsWidgets);
  });

  testWidgets('with no gear at all the add prompt stays', (tester) async {
    await _pump(tester, const []);
    expect(find.text('No equipment in your default view'), findsNothing);
    expect(find.text('Add Your First Equipment'), findsOneWidget);
  });
}
