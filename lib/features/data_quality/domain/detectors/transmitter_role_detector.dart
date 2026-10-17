import 'package:submersion/core/constants/enums.dart';
import 'package:submersion/core/profile/surfacing_pressure.dart';
import 'package:submersion/features/data_quality/domain/detectors/quality_detector.dart';
import 'package:submersion/features/data_quality/domain/entities/dive_quality_context.dart';
import 'package:submersion/features/data_quality/domain/entities/quality_finding.dart';
import 'package:submersion/features/dive_log/domain/services/ccr_bailout_timeline.dart';

/// A CCR transmitter whose role was read off its name drained like a
/// bailout: flat on the loop, fast after the switch to open circuit (issue
/// #3307). A Shearwater turns a bailout named "OC" into the O2 supply; the
/// repair makes it the bailout. A role the diver set is never judged.
class TransmitterRoleDetector extends QualityDetector {
  const TransmitterRoleDetector();

  @override
  String get id => 'transmitter_role';
  @override
  int get version => 1;
  @override
  QualityCategory get category => QualityCategory.tank;

  @override
  List<QualityFinding> detect(DiveQualityContext ctx) {
    if (ctx.dive.diveMode != DiveMode.ccr) return const [];
    final candidates = [
      for (final t in ctx.tanks)
        if (t.roleSource == TankRoleSource.transmitterName &&
            (ctx.pressuresByTankId[t.id]?.length ?? 0) >= 2)
          t,
    ];
    if (candidates.isEmpty) return const [];

    final roleById = {for (final t in ctx.tanks) t.id: t.role};
    final evidence = bailoutEvidence<String>(
      switches: [
        for (final sw in ctx.gasSwitches) (t: sw.timestamp, tankKey: sw.tankId),
      ],
      isLoopTank: (id) =>
          roleById[id] == TankRole.diluent ||
          roleById[id] == TankRole.oxygenSupply,
      pressures: {
        for (final t in candidates)
          t.id: [
            for (final s in ctx.pressuresByTankId[t.id]!) (t: s.t, bar: s.bar),
          ],
      },
      candidates: candidates.map((t) => t.id),
      inWaterEndSeconds: lastTimeBelowSurfaceThreshold(
        ctx.primarySamples.map((s) => (t: s.t, depth: s.depth)),
      ),
    );
    if (evidence == null) return const [];

    final byId = {for (final t in candidates) t.id: t};
    return [
      for (final e in evidence)
        make(
          ctx,
          discriminator: e.tankKey,
          computerId: byId[e.tankKey]!.computerId,
          severity: QualitySeverity.warning,
          params: {
            'tankId': e.tankKey,
            'tankOrder': byId[e.tankKey]!.order,
            'ocTankId': e.ocTankKey,
            'ocDropBar': e.ocDropBar,
            'loopRate': e.loopRate,
            'ocRate': e.ocRate,
            'role': byId[e.tankKey]!.role.name,
          },
        ),
    ];
  }
}
