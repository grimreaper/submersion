import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/features/data_quality/domain/detectors/transmitter_role_detector.dart';
import 'package:submersion/features/data_quality/domain/entities/dive_quality_context.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart'
    as domain;
import 'package:submersion/features/dive_log/domain/entities/gas_switch.dart';

import '../../helpers/quality_test_helpers.dart';

/// Issue #3307: a Shearwater reads a CCR transmitter's role off its name, so
/// a bailout named "OC" arrives as the O2 supply. When it only drained after
/// the diver switched to open circuit, it was the bailout.
void main() {
  const detector = TransmitterRoleDetector();

  domain.DiveTank tank(
    String id,
    int order,
    TankRole role, {
    TankRoleSource? roleSource,
  }) =>
      domain.DiveTank(id: id, order: order, role: role, roleSource: roleSource);

  final tx = tank(
    'tx',
    1,
    TankRole.oxygenSupply,
    roleSource: TankRoleSource.transmitterName,
  );
  final dil = tank('dil', 0, TankRole.diluent);
  final oc = tank('oc', 2, TankRole.bailout);

  List<QualityPressureSample> series(
    int from,
    int to,
    double start,
    double r,
  ) => [
    for (var t = from; t <= to; t += 10)
      QualityPressureSample(t: t, bar: start - r * (t - from) / 60),
  ];

  final bailoutShape = [
    ...series(0, 2390, 200, 0),
    ...series(2400, 3000, 200, 6),
  ];
  final switchToOc = GasSwitch(
    id: 's1',
    diveId: 'd1',
    timestamp: 2400,
    tankId: 'oc',
    createdAt: DateTime.utc(2026, 7, 1),
  );

  DiveQualityContext ctx({
    DiveMode mode = DiveMode.ccr,
    List<domain.DiveTank>? tanks,
    Map<String, List<QualityPressureSample>>? pressures,
  }) => makeContext(
    dive: makeTestDive(
      diveMode: mode,
      tanks: tanks ?? [dil, tx, oc],
      runtime: const Duration(minutes: 60),
    ),
    samples: flatProfile(durationSeconds: 3600),
    pressures: pressures ?? {'tx': bailoutShape},
    gasSwitches: [switchToOc],
  );

  test('flags an O-named tank breathed only on open circuit', () {
    final findings = detector.detect(ctx());
    expect(findings, hasLength(1));
    final p = findings.single.params;
    expect(p['tankId'], 'tx');
    expect(p['tankOrder'], 1);
    expect(p['ocTankId'], 'oc');
    expect((p['ocDropBar']! as num).toDouble(), closeTo(60, 0.001));
    expect(p['role'], 'oxygenSupply');
  });

  test('ignores a role the diver set', () {
    final mine = tank('tx', 1, TankRole.oxygenSupply);
    expect(detector.detect(ctx(tanks: [dil, mine, oc])), isEmpty);
  });

  test('ignores OC and SCR dives', () {
    expect(detector.detect(ctx(mode: DiveMode.oc)), isEmpty);
    expect(detector.detect(ctx(mode: DiveMode.scr)), isEmpty);
  });

  test('ignores a tank with no pressure series', () {
    expect(detector.detect(ctx(pressures: const {})), isEmpty);
  });

  test('finding ids are stable across scans', () {
    expect(detector.detect(ctx()).single.id, detector.detect(ctx()).single.id);
  });
}
