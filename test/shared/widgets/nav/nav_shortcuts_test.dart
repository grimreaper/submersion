import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/router/shortcut_locations.dart';
import 'package:submersion/shared/widgets/nav/nav_destinations.dart';
import 'package:submersion/shared/widgets/nav/nav_shortcuts.dart';

void main() {
  test('catalog ids are unique and never collide with built-ins', () {
    final ids = kNavShortcuts.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(kNavShortcuts.length, 39);
    for (final id in kNavShortcutOrderIds) {
      expect(movableNavIds, isNot(contains(id)));
    }
  });

  test('every planning shortcut is gated, nothing else is', () {
    for (final s in kNavShortcuts) {
      expect(
        s.isPlanning,
        s.canonicalPath.startsWith('/planning'),
        reason: s.id,
      );
    }
  });

  test('every shortcut borrows the accent of a real nav destination', () {
    final builtIns = kNavDestinations.map((d) => d.id).toSet();
    for (final s in kNavShortcuts) {
      expect(builtIns, contains(s.accent), reason: s.id);
    }
  });

  test('order ids round-trip through the prefix', () {
    expect(navShortcutOrderId('gas-blender'), 'shortcut:gas-blender');
    expect(navShortcutForOrderId('shortcut:gas-blender')?.id, 'gas-blender');
    expect(navShortcutForOrderId('gas-blender'), isNull);
    expect(navShortcutForOrderId('shortcut:retired'), isNull);
  });

  test('a shortcut destination routes to its alias and owns its page', () {
    final d = navShortcutDestination(navShortcutById('gas-blender')!);
    expect(d.id, 'shortcut:gas-blender');
    expect(d.route, shortcutLocation('gas-blender'));
    expect(d.extraMatchPaths, ['/planning/gas-calculators/blender']);
    expect(d.selection?.queryKey, 'calc');
    expect(d.selection?.queryValue, 'blender');
    expect(d.accentId, 'planning');
  });

  test('resolveNavDestination finds built-ins and shortcuts', () {
    final byId = {for (final d in kNavDestinations) d.id: d};
    expect(resolveNavDestination('dives', byId)?.route, '/dives');
    expect(
      resolveNavDestination('shortcut:insights-gas', byId)?.route,
      '/shortcut/insights-gas',
    );
    expect(resolveNavDestination('shortcut:nope', byId), isNull);
  });
}
