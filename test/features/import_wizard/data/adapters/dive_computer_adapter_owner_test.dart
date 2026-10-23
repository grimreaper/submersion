import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:submersion/features/dive_computer/data/services/dive_import_service.dart';
import 'package:submersion/features/dive_computer/domain/entities/device_model.dart';
import 'package:submersion/features/dive_computer/domain/entities/downloaded_dive.dart';
import 'package:submersion/features/dive_log/domain/entities/dive_computer.dart';
import 'package:submersion/features/import_wizard/data/adapters/dive_computer_adapter.dart';
import 'package:submersion/features/import_wizard/domain/models/import_bundle.dart';
import 'package:submersion/features/import_wizard/domain/models/import_target_choice.dart';

import 'dive_computer_adapter_test.mocks.dart';

// Issue #2050: a download follows the dive computer's owner. Bill is the
// active profile; computer A belongs to Mitchell.

DiveComputer _computer({
  String id = 'A',
  String? diverId = 'mitchell',
  String serial = 'SN-1',
}) => DiveComputer(
  id: id,
  name: 'Perdix 2',
  diverId: diverId,
  manufacturer: 'Shearwater',
  model: 'Perdix 2',
  serialNumber: serial,
  createdAt: DateTime(2026, 3, 20),
  updatedAt: DateTime(2026, 3, 20),
);

DownloadedDive _dive() => DownloadedDive(
  startTime: DateTime(2026, 10, 20, 9, 10),
  durationSeconds: 45 * 60,
  maxDepth: 18,
  profile: const [],
);

final _device = DiscoveredDevice(
  id: 'AA',
  name: 'Perdix 2',
  connectionType: DeviceConnectionType.ble,
  address: 'AA',
  discoveredAt: DateTime(2026, 10, 20),
);

void main() {
  late MockDiveImportService importService;
  late MockDiveComputerRepository computers;
  late MockDiveRepository dives;
  late MockDiveConsolidationService consolidation;

  setUp(() {
    importService = MockDiveImportService();
    when(importService.unmatchedTransmitterSerials).thenReturn(const []);
    computers = MockDiveComputerRepository();
    dives = MockDiveRepository();
    consolidation = MockDiveConsolidationService();
    when(
      dives.getSourceKeysByDiveId(diverId: anyNamed('diverId')),
    ).thenAnswer((_) async => {});
  });

  DiveComputerAdapter adapter({
    DiveComputer? known,
    String active = 'bill',
    bool follow = true,
    Map<String, String> names = const {'bill': 'Bill', 'mitchell': 'Mitchell'},
  }) => DiveComputerAdapter(
    importService: importService,
    computerRepository: computers,
    diveRepository: dives,
    consolidationService: consolidation,
    diverId: active,
    knownComputer: known,
    followComputerOwner: follow,
    diverName: (id) async => names[id],
  );

  Future<ImportBundle> bundleFor(DiveComputerAdapter a) async {
    a.setDownloadedDives([_dive()]);
    return a.buildBundle();
  }

  group('lookup across profiles', () {
    test(
      "resolveKnownComputer finds another profile's computer by address",
      () async {
        when(
          computers.findByBluetoothAddress('AA', diverId: 'bill'),
        ).thenAnswer((_) async => null);
        when(
          computers.findByBluetoothAddress('AA', diverId: null),
        ).thenAnswer((_) async => _computer());
        final a = adapter();

        await a.resolveKnownComputer(_device);

        expect(a.computer?.id, 'A');
      },
    );

    test(
      "ensureComputer reuses another profile's computer by serial",
      () async {
        when(
          computers.findByHardwareIdentity(
            manufacturer: anyNamed('manufacturer'),
            model: anyNamed('model'),
            serialNumber: anyNamed('serialNumber'),
            diverId: argThat(equals('bill'), named: 'diverId'),
          ),
        ).thenAnswer((_) async => null);
        when(
          computers.findByHardwareIdentity(
            manufacturer: anyNamed('manufacturer'),
            model: anyNamed('model'),
            serialNumber: anyNamed('serialNumber'),
            diverId: argThat(isNull, named: 'diverId'),
          ),
        ).thenAnswer((_) async => _computer());
        final a = adapter();

        await a.ensureComputer(device: _device, serialNumber: 'SN-1');

        expect(a.computer?.id, 'A');
        expect(a.computer?.diverId, 'mitchell');
        verifyNever(computers.createComputer(any));
      },
    );

    test("the active profile's duplicate record wins", () async {
      when(
        computers.findByHardwareIdentity(
          manufacturer: anyNamed('manufacturer'),
          model: anyNamed('model'),
          serialNumber: anyNamed('serialNumber'),
          diverId: argThat(equals('bill'), named: 'diverId'),
        ),
      ).thenAnswer((_) async => _computer(id: 'A2', diverId: 'bill'));
      final a = adapter();

      await a.ensureComputer(device: _device, serialNumber: 'SN-1');
      final bundle = await bundleFor(a);

      expect(a.computer?.id, 'A2');
      expect(bundle.targetChoice, isNull);
      expect(a.targetDiverId, 'bill');
    });

    test('a computer seen for the first time is created for the active '
        'profile', () async {
      when(computers.createComputer(any)).thenAnswer(
        (inv) async => inv.positionalArguments.first as DiveComputer,
      );
      final a = adapter();

      await a.ensureComputer(device: _device, serialNumber: 'SN-NEW');

      expect(a.computer?.diverId, 'bill');
      expect((await bundleFor(a)).targetChoice, isNull);
    });
  });

  group('the target diver', () {
    test('the bundle names the owner and defaults to them', () async {
      final a = adapter(known: _computer());

      final bundle = await bundleFor(a);

      expect(
        bundle.targetChoice,
        const ImportTargetChoice(
          ownerDiverId: 'mitchell',
          chosenDiverId: 'mitchell',
        ),
      );
      expect(a.targetDiverId, 'mitchell');
      expect(a.activeDiverId, 'bill');
    });

    test('with the switch off it defaults to the active profile', () async {
      final a = adapter(known: _computer(), follow: false);

      final bundle = await bundleFor(a);

      expect(bundle.targetChoice?.chosenDiverId, 'bill');
      expect(a.targetDiverId, 'bill');
    });

    test('a deleted owner shows no choice', () async {
      final a = adapter(known: _computer(), names: const {'bill': 'Bill'});

      final bundle = await bundleFor(a);

      expect(bundle.targetChoice, isNull);
      expect(a.targetDiverId, 'bill');
    });

    test('a computer with no owner shows no choice', () async {
      final a = adapter(known: _computer(diverId: null));

      expect((await bundleFor(a)).targetChoice, isNull);
      expect(a.targetDiverId, 'bill');
    });

    test('an unscoped library shows no choice', () async {
      final a = adapter(known: _computer(), active: '');

      expect((await bundleFor(a)).targetChoice, isNull);
      expect(a.targetDiverId, '');
    });

    test(
      'a choice survives a rebuilt bundle and is cleared by reset',
      () async {
        final a = adapter(known: _computer());
        await bundleFor(a);

        await a.setTargetDiver('bill');
        final rebuilt = await a.buildBundle();

        expect(rebuilt.targetChoice?.chosenDiverId, 'bill');
        a.resetState();
        expect(a.targetDiverId, 'bill');
        expect((await a.buildBundle()).targetChoice?.chosenDiverId, 'mitchell');
      },
    );

    test('provisionalTargetDiverId follows the known owner when on', () {
      expect(adapter(known: _computer()).provisionalTargetDiverId, 'mitchell');
      expect(
        adapter(known: _computer(), follow: false).provisionalTargetDiverId,
        'bill',
      );
      expect(adapter().provisionalTargetDiverId, 'bill');
    });
  });

  group('importing', () {
    test('writes to the chosen diver and leaves the owner alone', () async {
      final dive = _dive();
      final a = adapter(known: _computer());
      a.setDownloadedDives([dive]);
      await a.buildBundle();
      await a.setTargetDiver('bill');
      final bundle = await a.buildBundle();
      when(
        importService.importSingleDiveAsNew(
          dive,
          computerId: 'A',
          diverId: 'bill',
        ),
      ).thenAnswer((_) async => 'new-1');

      await a.performImport(bundle, {
        ImportEntityType.dives: {0},
      }, {});

      verify(
        importService.importSingleDiveAsNew(
          dive,
          computerId: 'A',
          diverId: 'bill',
        ),
      ).called(1);
      // The fingerprint and count bookkeeping touch the computer; nothing
      // rewrites the record, so its owner stays Mitchell.
      verifyNever(computers.updateComputer(any));
    });

    test('checks duplicates against the chosen diver', () async {
      when(
        importService.detectDuplicate(
          any,
          diverId: anyNamed('diverId'),
          computerId: anyNamed('computerId'),
          sourceKeysCache: anyNamed('sourceKeysCache'),
        ),
      ).thenAnswer((_) async => DuplicateResult.noMatch());
      final a = adapter(known: _computer());
      final bundle = await bundleFor(a);

      await a.checkDuplicates(bundle);

      verify(dives.getSourceKeysByDiveId(diverId: 'mitchell')).called(1);
      verify(dives.getPlannedDives(diverId: 'mitchell')).called(1);
    });
  });
}
