import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/features/dive_import/domain/services/dive_matcher.dart';
import 'package:submersion/features/import_wizard/domain/adapters/import_source_adapter.dart';
import 'package:submersion/features/import_wizard/domain/models/duplicate_action.dart';
import 'package:submersion/features/import_wizard/domain/models/import_bundle.dart';
import 'package:submersion/features/import_wizard/domain/models/import_cancellation_token.dart';
import 'package:submersion/features/import_wizard/domain/models/import_phase.dart';
import 'package:submersion/features/import_wizard/domain/models/import_target_choice.dart';
import 'package:submersion/features/import_wizard/domain/models/tag_selection.dart';
import 'package:submersion/features/import_wizard/domain/models/unified_import_result.dart';
import 'package:submersion/features/import_wizard/presentation/providers/import_wizard_providers.dart';
import 'package:submersion/shared/widgets/wizard/wizard_step_def.dart';

// Issue #2050: choosing another profile on the review step re-checks the
// download against that profile's dives. Dive 0 duplicates one of
// Mitchell's dives and none of Bill's.

class _RetargetableAdapter
    implements ImportSourceAdapter, RetargetableImportAdapter {
  String target = 'mitchell';
  final targets = <String>[];
  bool failDuplicateCheck = false;

  @override
  Future<void> setTargetDiver(String diverId) async {
    targets.add(diverId);
    target = diverId;
  }

  @override
  Future<ImportBundle> buildBundle() async => ImportBundle(
    source: const ImportSourceInfo(
      type: ImportSourceType.diveComputer,
      displayName: 'Perdix 2',
    ),
    groups: {
      ImportEntityType.dives: const EntityGroup(
        items: [
          EntityItem(title: 'Dive 1', subtitle: ''),
          EntityItem(title: 'Dive 2', subtitle: ''),
        ],
      ),
    },
    targetChoice: ImportTargetChoice(
      ownerDiverId: 'mitchell',
      chosenDiverId: target,
    ),
  );

  @override
  Future<ImportBundle> checkDuplicates(ImportBundle bundle) async {
    if (failDuplicateCheck) throw StateError('database is locked');
    if (target != 'mitchell') return bundle;
    final dives = bundle.groups[ImportEntityType.dives]!;
    return ImportBundle(
      source: bundle.source,
      groups: {
        ImportEntityType.dives: EntityGroup(
          items: dives.items,
          duplicateIndices: const {0},
          matchResults: {
            0: const DiveMatchResult(
              diveId: 'mitchell-dive',
              score: 0.95,
              timeDifferenceMs: 0,
              matchedExistingSource: true,
            ),
          },
        ),
      },
      targetChoice: bundle.targetChoice,
    );
  }

  @override
  void resetState() {}
  @override
  ImportSourceType get sourceType => ImportSourceType.diveComputer;
  @override
  String get displayName => 'Perdix 2';
  @override
  String get defaultTagName => 'Perdix Import';
  @override
  List<WizardStepDef> get acquisitionSteps => const [];
  @override
  Set<DuplicateAction> get supportedDuplicateActions => const {
    DuplicateAction.skip,
    DuplicateAction.importAsNew,
  };
  @override
  Set<DuplicateAction> duplicateActionsFor(ImportEntityType type) =>
      supportedDuplicateActions;
  @override
  Future<UnifiedImportResult> performImport(
    ImportBundle bundle,
    Map<ImportEntityType, Set<int>> selections,
    Map<ImportEntityType, Map<int, DuplicateAction>> duplicateActions, {
    bool retainSourceDiveNumbers = false,
    ImportProgressCallback? onProgress,
    ImportCancellationToken? cancelToken,
  }) => throw UnimplementedError();
}

void main() {
  late _RetargetableAdapter adapter;
  late ImportWizardNotifier notifier;

  setUp(() async {
    adapter = _RetargetableAdapter();
    notifier = ImportWizardNotifier(adapter);
    notifier.setBundle(
      await adapter.checkDuplicates(await adapter.buildBundle()),
    );
    notifier.addImportTag(const TagSelection(name: 'Perdix Import'));
  });

  tearDown(() => notifier.dispose());

  test('starts with the owner and their duplicate skipped', () {
    expect(notifier.state.bundle?.targetChoice?.chosenDiverId, 'mitchell');
    expect(notifier.state.selections[ImportEntityType.dives], {1});
  });

  test('another profile re-checks the download against that profile', () async {
    await notifier.changeTargetDiver('bill');

    expect(adapter.targets, ['bill']);
    expect(notifier.state.bundle?.targetChoice?.chosenDiverId, 'bill');
    expect(notifier.state.selections[ImportEntityType.dives], {0, 1});
    expect(notifier.state.duplicateActions[ImportEntityType.dives], isNull);
    expect(notifier.state.importTags, const [
      TagSelection(name: 'Perdix Import'),
    ]);
  });

  test('a failed re-check keeps the rebuilt bundle unchecked', () async {
    adapter.failDuplicateCheck = true;

    await notifier.changeTargetDiver('bill');

    expect(notifier.state.bundle?.targetChoice?.chosenDiverId, 'bill');
    expect(notifier.state.selections[ImportEntityType.dives], {0, 1});
  });

  test('does nothing for a bundle with no choice', () async {
    notifier.setBundle(
      const ImportBundle(
        source: ImportSourceInfo(
          type: ImportSourceType.diveComputer,
          displayName: 'Perdix 2',
        ),
        groups: {},
      ),
    );

    await notifier.changeTargetDiver('bill');

    expect(adapter.targets, isEmpty);
  });
}
