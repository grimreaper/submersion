import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/data/repositories/sync_repository.dart'
    show CloudProviderType;
import 'package:submersion/core/services/cloud_storage/s3/s3_config.dart';
import 'package:submersion/core/services/media_store/media_object_store.dart';
import 'package:submersion/core/services/media_store/media_store_attach_state.dart';
import 'package:submersion/core/services/media_store/media_store_credentials_store.dart';
import 'package:submersion/core/services/media_store/media_upload_quality_policy.dart';
import 'package:submersion/features/media_store/domain/media_upload_quality.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/data/services/media_health_report.dart';
import 'package:submersion/features/media/data/services/media_health_reporter.dart';
import 'package:submersion/features/media/presentation/providers/media_health_providers.dart';
import 'package:submersion/features/media_store/data/media_backfill_service.dart';
import 'package:submersion/features/media_store/data/media_store_service.dart';
import 'package:submersion/features/media_store/data/media_verify_service.dart';
import 'package:submersion/features/media_store/data/media_stores_repository.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';
import 'package:submersion/features/media_store/domain/media_transfer_summary.dart';
import 'package:submersion/features/media_store/presentation/pages/photos_videos_page.dart';
import 'package:submersion/features/media_store/presentation/providers/media_upload_progress_provider.dart';
import 'package:submersion/features/media_store/presentation/providers/photos_copies_provider.dart';
import 'package:submersion/features/settings/presentation/widgets/pending_setup_card.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart'
    show sharedPreferencesProvider;
import 'package:submersion/features/media_store/presentation/providers/media_store_providers.dart';
import 'package:submersion/features/media_store/presentation/providers/media_sweep_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';

import '../../../../helpers/fake_cloud_storage_provider.dart';
import '../../../../helpers/in_memory_media_object_store.dart';
import '../../../../support/fake_app_settings_repository.dart';
import '../../../../support/fake_keychain_storage.dart';

class _RecordingService extends MediaStoreService {
  _RecordingService()
    : super(
        credentials: MediaStoreCredentialsStore(storage: InMemoryKeychain()),
        attachState: MediaStoreAttachState(),
        storesRepository: MediaStoresRepository(),
        storeFactory: (_) => InMemoryMediaObjectStore(),
      );

  int connectCalls = 0;
  int testCalls = 0;
  int dropboxCalls = 0;
  int gdriveCalls = 0;
  int icloudCalls = 0;
  int disconnectCalls = 0;

  /// When set, connectS3/testConnection/connectDropbox throw it.
  Object? throwOnConnect;
  Object? throwOnTest;
  Object? throwOnDropbox;

  /// Appended to on every connectGoogleDrive() call, so a test can assert
  /// ordering against another recorder (e.g. the auth provider) instead of
  /// just an eventual end state.
  List<String>? callOrder;

  static const _result = MediaStoreConnectResult(
    storeId: 'store-x',
    createdNewStore: true,
  );

  @override
  Future<MediaStoreConnectResult> connectS3(
    S3Config config, {
    String? accountId,
  }) async {
    connectCalls++;
    if (throwOnConnect != null) throw throwOnConnect!;
    return _result;
  }

  @override
  Future<MediaStoreConnectResult> connectDropbox() async {
    dropboxCalls++;
    if (throwOnDropbox != null) throw throwOnDropbox!;
    return _result;
  }

  @override
  Future<MediaStoreConnectResult> connectGoogleDrive() async {
    gdriveCalls++;
    callOrder?.add('connect');
    return _result;
  }

  @override
  Future<MediaStoreConnectResult> connectICloud() async {
    icloudCalls++;
    return _result;
  }

  @override
  Future<void> testConnection(S3Config config) async {
    testCalls++;
    if (throwOnTest != null) throw throwOnTest!;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }
}

/// Backfill double: returns a fixed count without touching a database.
class _FakeBackfillService extends MediaBackfillService {
  _FakeBackfillService()
    : super(
        mediaRepository: MediaRepository(),
        queue: MediaTransferQueueRepository(),
      );

  int calls = 0;

  @override
  Future<int> enqueueAll() async {
    calls++;
    return 7;
  }
}

/// Answers a fixed library report and counts the asks.
class _FakeLibraryReporter implements MediaHealthReporter {
  _FakeLibraryReporter(this.report);
  final MediaHealthReport report;
  int libraryCalls = 0;

  @override
  Future<MediaHealthReport> forLibrary({bool probeStore = false}) async {
    libraryCalls++;
    return report;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

void main() {
  late _RecordingService service;
  late _FakeBackfillService backfill;
  late FakeCloudStorageProvider gdriveProvider;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = _RecordingService();
    backfill = _FakeBackfillService();
    // Authenticated by default: the connect button's happy path (existing
    // tests) never needs the interactive flow.
    gdriveProvider = FakeCloudStorageProvider();
  });

  Widget app({
    bool apple = true,
    // Pinned, not inherited: googleDriveAvailableProvider resolves to
    // GoogleDriveClientConfig.isSupportedOnThisPlatform, which is false on a
    // Windows/Linux HOST with no Desktop client secret compiled in. Reading it
    // ambiently made these expectations pass on macOS and fail on the Linux
    // CI runners.
    bool googleDriveAvailable = true,
    String? statusHint,
    MediaTransferSummary summary = const MediaTransferSummary(),
    // Overrides the default (pre-authenticated) fake for tests exercising
    // the interactive-auth branch. A separate parameter, not extraOverrides:
    // both would override cloudStorageProviderForProvider in the same
    // container, which Riverpod refuses.
    FakeCloudStorageProvider? gdriveProviderOverride,
    // Riverpod 3 does not export the Override type; mirror the
    // weight_planner_page_test precedent.
    List<dynamic> extraOverrides = const [],
  }) => ProviderScope(
    overrides: [
      mediaStoreRuntimeProvider.overrideWith((ref) async => null),
      mediaStoreCredentialsStoreProvider.overrideWithValue(
        MediaStoreCredentialsStore(storage: InMemoryKeychain()),
      ),
      mediaStoreServiceProvider.overrideWithValue(service),
      mediaBackfillServiceProvider.overrideWithValue(backfill),
      mediaStoreStatusHintProvider.overrideWith((ref) async => statusHint),
      // The Photos page reads where the copies are from here; a status hint
      // stands for "attached here, under that name".
      photosCopiesProvider.overrideWith(
        (ref) async => (
          attached: statusHint != null,
          store: null,
          group: null,
          label: statusHint,
        ),
      ),
      photosStoreReachableProvider.overrideWithValue(true),
      mediaUploadProgressProvider.overrideWith(
        (ref) async => (copied: 0, total: 0),
      ),
      pendingSetupItemsProvider.overrideWith((ref) async => const []),
      sharedPreferencesProvider.overrideWithValue(prefs),
      mediaTransferSummaryProvider.overrideWith((ref) => Stream.value(summary)),
      isApplePlatformProvider.overrideWithValue(apple),
      googleDriveAvailableProvider.overrideWith(
        (ref) async => googleDriveAvailable,
      ),
      cloudStorageProviderForProvider(
        CloudProviderType.googledrive,
      ).overrideWithValue(gdriveProviderOverride ?? gdriveProvider),
      // Last, so callers can genuinely override any of the defaults above.
      // (Plain spread: dynamic elements implicitly cast, and Riverpod 3
      // does not export the Override type to name in a cast<T>().)
      ...extraOverrides,
    ],
    child: const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PhotosVideosPage(),
    ),
  );

  testWidgets('the connected state shows policies, transfers, backfill and '
      'disconnect', (tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          summary: const MediaTransferSummary(transferring: 3),
        ),
      );
      // Pump until the active-count stream has propagated.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.textContaining('3 uploading').evaluate().isNotEmpty) break;
      }
    });

    // The S3 form is gone; the connected controls are present.
    expect(find.byKey(const Key('media-s3-endpoint')), findsNothing);
    expect(find.byKey(const Key('media-provider-chooser')), findsNothing);
    expect(
      find.byKey(const Key('media-s3-policy-auto-upload')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('media-s3-policy-photos-cellular')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('media-s3-backfill')), findsOneWidget);
    expect(find.byKey(const Key('media-s3-transfers')), findsOneWidget);
    expect(find.byKey(const Key('media-s3-disconnect')), findsOneWidget);
    // The status line says how many are moving.
    expect(find.textContaining('3 uploading'), findsOneWidget);
  });

  testWidgets('toggling the policy switches writes through to policies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(app(statusHint: 'dive-media @ minio'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(
      find.byKey(const Key('media-s3-policy-auto-upload')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-s3-policy-auto-upload')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    });
    await tester.ensureVisible(
      find.byKey(const Key('media-s3-policy-photos-cellular')),
    );
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const Key('media-s3-policy-photos-cellular')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    });

    // Defaults are on; both toggles flip to off and persist.
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('media_store_auto_upload'),
      isFalse,
      reason: 'auto-upload persisted off',
    );
  });

  testWidgets('the quality section renders the synced levels', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policy = MediaUploadQualityPolicy(
      settings: FakeAppSettingsRepository(),
    );
    await policy.setPhotoUploadQuality(MediaUploadQuality.small);
    await policy.setVideoUploadQuality(MediaUploadQuality.high);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(find.byKey(const Key('media-quality-photos')), findsOneWidget);
    expect(find.byKey(const Key('media-quality-video')), findsOneWidget);

    final photo = tester.widget<DropdownButton<MediaUploadQuality>>(
      find.byKey(const Key('media-quality-photos')),
    );
    final video = tester.widget<DropdownButton<MediaUploadQuality>>(
      find.byKey(const Key('media-quality-video')),
    );
    expect(photo.value, MediaUploadQuality.small);
    expect(video.value, MediaUploadQuality.high);
  });

  testWidgets('changing the photo quality writes to the synced setting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeAppSettingsRepository();
    final policy = MediaUploadQualityPolicy(settings: settings);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    final dropdown = find.byKey(const Key('media-quality-photos'));
    await tester.ensureVisible(dropdown);
    await tester.runAsync(() async {
      await tester.tap(dropdown);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Small').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(settings.values[MediaUploadQualityPolicy.photoQualityKey], 'small');
  });

  // Popping the page mid-save must not crash: `ref` throws once the
  // ConsumerState is disposed, so _saveQuality captures the app-level
  // container before the first await. The write and the invalidate both still
  // have to land, otherwise the next visit shows a stale level.
  testWidgets('a save that outlives the page neither throws nor is lost', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeAppSettingsRepository();
    final policy = MediaUploadQualityPolicy(settings: settings);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    // Hold the write open so the page can be disposed while it is in flight.
    final gate = Completer<void>();
    settings.gateWrite = gate;

    final dropdown = find.byKey(const Key('media-quality-photos'));
    await tester.ensureVisible(dropdown);
    await tester.runAsync(() async {
      await tester.tap(dropdown);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Small').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    // Navigate away: the page is disposed while the write is still
    // awaiting the gate.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(find.byType(PhotosVideosPage), findsNothing);

    await tester.runAsync(() async {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      settings.values[MediaUploadQualityPolicy.photoQualityKey],
      'small',
      reason: 'the write must still land after the page is gone',
    );
  });

  // Writes rethrow by design so a failed save is visible; the previous
  // handlers awaited the write and swallowed the error entirely.
  testWidgets('a failed quality write surfaces a snackbar', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final settings = FakeAppSettingsRepository();
    final policy = MediaUploadQualityPolicy(settings: settings);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    settings.throwOnWrite = StateError('disk full');

    final dropdown = find.byKey(const Key('media-quality-photos'));
    await tester.ensureVisible(dropdown);
    await tester.runAsync(() async {
      await tester.tap(dropdown);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Small').last);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    await tester.pump();

    expect(
      find.text('Could not save the upload quality. Try again.'),
      findsOneWidget,
    );
    expect(
      settings.values[MediaUploadQualityPolicy.photoQualityKey],
      isNull,
      reason: 'the failed write must not appear to have landed',
    );
  });

  testWidgets('backfill enqueues and reports the count', (tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(app(statusHint: 'dive-media @ minio'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-s3-backfill')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-s3-backfill')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(backfill.calls, 1);
    expect(find.textContaining('7'), findsWidgets);
  });

  testWidgets('export media report builds the library report and hands it '
      'to the exporter', (tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final exported = <(String content, String fileName, String mimeType)>[];
    final reporter = _FakeLibraryReporter(
      MediaHealthReport(
        generatedAt: DateTime.utc(2026, 7, 1),
        deviceId: 'dev-a',
        deviceName: 'Device A',
        attachedStoreId: 'store-1',
        markerStoreId: 'store-1',
        rows: const [],
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaHealthReporterProvider.overrideWithValue(reporter),
            textFileExporterProvider.overrideWithValue((
              content,
              fileName,
              mimeType, {
              Rect? sharePositionOrigin,
            }) async {
              exported.add((content, fileName, mimeType));
              return fileName;
            }),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(
      find.textContaining('The report lists file paths and device names'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('media-export-report')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-export-report')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(reporter.libraryCalls, 1);
    final (content, fileName, mimeType) = exported.single;
    expect(fileName, 'submersion-media-report.txt');
    expect(mimeType, 'text/plain');
    expect(content, startsWith('Submersion media health report'));
    expect(content, contains('device: dev-a (Device A)'));
    expect(find.text('Media report exported'), findsOneWidget);
  });

  testWidgets('export media report is offered with no store attached', (
    tester,
  ) async {
    // The report describes local file and gallery rows too, which is the
    // whole library a user with no store has. Gating it on a connection
    // hid the media diagnostic from exactly the people diagnosing media.
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final exported = <(String content, String fileName, String mimeType)>[];
    final reporter = _FakeLibraryReporter(
      MediaHealthReport(
        generatedAt: DateTime.utc(2026, 7, 1),
        deviceId: 'dev-a',
        deviceName: 'Device A',
        attachedStoreId: null,
        markerStoreId: null,
        rows: const [],
      ),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          extraOverrides: [
            mediaHealthReporterProvider.overrideWithValue(reporter),
            textFileExporterProvider.overrideWithValue((
              content,
              fileName,
              mimeType, {
              Rect? sharePositionOrigin,
            }) async {
              exported.add((content, fileName, mimeType));
              return fileName;
            }),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-export-report')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-export-report')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(reporter.libraryCalls, 1);
    expect(exported.single.$2, 'submersion-media-report.txt');
  });

  testWidgets('verify library runs the sweep and reports the summary', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var runs = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaVerifyRunnerProvider.overrideWithValue(() async {
              runs++;
              return const VerifyLibraryReport(
                objectsChecked: 12,
                originalsChecked: 7,
                thumbsChecked: 4,
                renditionsChecked: 1,
                orphansRemoved: 3,
                bytesReclaimed: 999,
                sessionsAborted: 1,
                repairsQueued: 2,
              );
            }),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-verify-library')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-verify-library')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(runs, 1);
    // A photo is stored as an original plus a thumbnail (plus a rendition
    // when compressed), so the object count exceeds the photo count; the
    // summary says so rather than leaving the reader to count twice.
    expect(
      find.textContaining(
        'Checked 12 cloud objects (7 originals, 4 thumbnails, 1 compressed version)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a deferred verify says nothing was deleted yet', (tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var runs = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaVerifyRunnerProvider.overrideWithValue(() async {
              runs++;
              return const VerifyLibraryReport(
                objectsChecked: 12,
                originalsChecked: 7,
                thumbsChecked: 4,
                renditionsChecked: 1,
                orphansRemoved: 0,
                bytesReclaimed: 0,
                sessionsAborted: 1,
                repairsQueued: 0,
                deferred: true,
              );
            }),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-verify-library')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-verify-library')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(runs, 1);
    // Removed 0 alone reads as "nothing to remove"; the deletes were held
    // back until this device catches up with sync.
    expect(
      find.textContaining(
        'Nothing was deleted: deletes wait until this device has finished '
        'syncing.',
      ),
      findsOneWidget,
    );
  });

  Widget throwingVerifyApp(Object error) => app(
    statusHint: 'dive-media @ minio',
    extraOverrides: [
      mediaVerifyRunnerProvider.overrideWithValue(() async => throw error),
    ],
  );

  Future<void> pumpAndTapVerify(WidgetTester tester, Widget widget) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    await tester.ensureVisible(find.byKey(const Key('media-verify-library')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-verify-library')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
  }

  testWidgets('verify surfaces MediaStoreException via the error snack', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpAndTapVerify(
      tester,
      throwingVerifyApp(
        const MediaStoreException(
          'bucket unreachable',
          kind: MediaStoreErrorKind.transient,
        ),
      ),
    );
    expect(find.text('bucket unreachable'), findsOneWidget);
  });

  testWidgets('verify surfaces generic failures via the error snack', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpAndTapVerify(
      tester,
      throwingVerifyApp(StateError('no media store attached')),
    );
    expect(find.textContaining('no media store attached'), findsOneWidget);
  });
  testWidgets('disconnect confirms via dialog then calls the service', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(app(statusHint: 'dive-media @ minio'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-s3-disconnect')));
    await tester.tap(find.byKey(const Key('media-s3-disconnect')));
    await tester.pumpAndSettle();

    // Confirm in the dialog.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('media-s3-disconnect-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(service.disconnectCalls, 1);
  });

  testWidgets('cancelling the disconnect dialog does not disconnect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(app(statusHint: 'dive-media @ minio'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(find.byKey(const Key('media-s3-disconnect')));
    await tester.tap(find.byKey(const Key('media-s3-disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(service.disconnectCalls, 0);
  });

  testWidgets('Linux hint shows when video level set and ffmpeg missing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policy = MediaUploadQualityPolicy(
      settings: FakeAppSettingsRepository(),
    );
    await policy.setVideoUploadQuality(MediaUploadQuality.small);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          apple: false,
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
            isLinuxPlatformProvider.overrideWithValue(true),
            videoTranscodeAvailableProvider.overrideWith((ref) async => false),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump(); // policy load applies; video level becomes 'small'
      // The availability provider is only watched once _videoQuality is set
      // (the if-condition short-circuits before it), so a second cycle lets
      // that provider resolve and the hint render.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    await tester.ensureVisible(
      find.byKey(const Key('media-quality-transcoder-hint')),
    );
    expect(
      find.byKey(const Key('media-quality-transcoder-hint')),
      findsOneWidget,
    );
  });

  // The Linux gate was only correct while quality was per-device: a user could
  // then only pick a level their own machine could not honour. A library-wide
  // setting lets a Mac choose a level for a Windows box with no engine.
  testWidgets('a non-Linux device without an engine shows the generic hint', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policy = MediaUploadQualityPolicy(
      settings: FakeAppSettingsRepository(),
    );
    await policy.setVideoUploadQuality(MediaUploadQuality.small);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
            isLinuxPlatformProvider.overrideWithValue(false),
            videoTranscodeAvailableProvider.overrideWith((ref) async => false),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    await tester.ensureVisible(
      find.byKey(const Key('media-quality-transcoder-hint')),
    );
    expect(
      find.byKey(const Key('media-quality-transcoder-hint')),
      findsOneWidget,
    );
    expect(
      find.text(
        'This device cannot compress video. Originals are uploaded '
        'from it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a device with a working engine shows no hint', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final policy = MediaUploadQualityPolicy(
      settings: FakeAppSettingsRepository(),
    );
    await policy.setVideoUploadQuality(MediaUploadQuality.small);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        app(
          statusHint: 'dive-media @ minio',
          extraOverrides: [
            mediaUploadQualityPolicyProvider.overrideWithValue(policy),
            isLinuxPlatformProvider.overrideWithValue(false),
            videoTranscodeAvailableProvider.overrideWith((ref) async => true),
          ],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(
      find.byKey(const Key('media-quality-transcoder-hint')),
      findsNothing,
    );
  });
}
