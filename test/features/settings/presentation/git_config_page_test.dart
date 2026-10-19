import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:submersion/core/providers/account_providers.dart';
import 'package:submersion/core/providers/provider.dart';
import 'package:submersion/core/services/accounts/account_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/core/services/cloud_storage/git/git_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';
import 'package:submersion/core/services/cloud_storage/webdav/webdav_tls.dart';
import 'package:submersion/core/services/sync/library_epoch.dart';
import 'package:submersion/core/services/sync/sync_cleanup_outcome.dart';
import 'package:submersion/core/services/sync/sync_service.dart'
    show ConflictResolution;
import 'package:submersion/features/settings/presentation/pages/git_config_page.dart';
import 'package:submersion/features/settings/presentation/providers/git_providers.dart';
import 'package:submersion/features/settings/presentation/providers/settings_providers.dart';
import 'package:submersion/features/settings/presentation/providers/sync_providers.dart';
import 'package:submersion/features/settings/presentation/widgets/git_error_text.dart';
import 'package:submersion/l10n/arb/app_localizations.dart';
import 'package:submersion/l10n/arb/app_localizations_en.dart';

import '../../../support/fake_keychain_storage.dart';

/// A Git provider whose network side is scripted.
class _FakeGit extends GitStorageProvider {
  _FakeGit() : super(store: GitCredentialsStore(storage: InMemoryKeychain()));

  GitConnectionReport report = const GitConnectionReport(
    branchExists: false,
    willBecomeDefault: false,
    isPublic: false,
  );
  Object? failWith;

  /// Thrown by the next testConnection only.
  Object? failOnce;
  int tests = 0;
  int saves = 0;
  int signOuts = 0;
  GitConfig? saved;
  final tested = <GitConfig>[];

  @override
  Future<GitConnectionReport> testConnection(GitConfig config) async {
    tests++;
    tested.add(config);
    final once = failOnce;
    if (once != null) {
      failOnce = null;
      throw once;
    }
    final error = failWith;
    if (error != null) throw error;
    return report;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    saved = null;
  }

  /// Thrown by saveConfig, as a keychain failure would be.
  Object? saveFails;

  @override
  Future<void> saveConfig(GitConfig config) async {
    final fail = saveFails;
    if (fail != null) throw fail;
    saves++;
    saved = config;
  }

  @override
  Future<GitConfig?> loadConfig() async => saved;
}

/// Minimal [SyncNotifier] that never touches the database.
class _FakeSyncNotifier extends StateNotifier<SyncState>
    implements SyncNotifier {
  _FakeSyncNotifier(this._ref) : super(const SyncState());

  final Ref _ref;

  @override
  Future<void> refreshState() async {}

  @override
  Future<void> signOut() async {
    _ref.read(selectedCloudProviderTypeProvider.notifier).state = null;
  }

  @override
  Future<void> performSync({bool auto = false}) async {}

  @override
  Future<ReplacePreflight> replacePreflight() async =>
      const ReplacePreflight(localDiveCount: 0, peerFileCount: 0);

  @override
  Future<void> replaceCloudLibraryFromThisDevice() async {}

  @override
  Future<void> disableForDatabaseReset() async {}

  @override
  Future<FirstSyncMergeInfo?> firstSyncMergeInfo() async => null;

  @override
  Future<LibraryEpochMarker?> libraryReplaceInfo() async => null;

  @override
  Future<void> adoptReplacedLibrary() async {}

  @override
  Future<void> resetSyncState() async {}

  @override
  Future<void> repairSync() async {}

  @override
  Future<SyncCleanupOutcome> removeThisDeviceCloudFiles({
    SyncCleanupProgress? onProgress,
  }) async => const SyncCleanupOutcome();

  @override
  Future<SyncCleanupOutcome> wipeAllCloudSyncData({
    SyncCleanupProgress? onProgress,
  }) async => const SyncCleanupOutcome();

  @override
  Future<void> rebuildBackendFromThisDevice({
    SyncCleanupProgress? onProgress,
    void Function()? onPublishStarted,
  }) async {}

  @override
  Future<void> resolveConflict(
    String entityType,
    String recordId,
    ConflictResolution resolution,
  ) async {}

  @override
  Future<void> acknowledgeMoved() async {}

  @override
  Future<void> checkLibraryMoved() async {}

  @override
  Future<void> cleanupOldBackendData() async {}

  @override
  Future<void> dismissOldBackendCleanup() async {}

  @override
  Future<void> recordBackendDeparture({
    required CloudStorageProvider oldProvider,
    required String toProviderId,
    String? toProviderName,
  }) async {}
}

void main() {
  late _FakeGit git;

  setUp(() => git = _FakeGit());

  Future<void> pumpPage(WidgetTester tester, {bool encrypted = false}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({
      'sync_encryption_enabled': encrypted,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          accountCredentialsStoreProvider.overrideWithValue(
            AccountCredentialsStore(storage: InMemoryKeychain()),
          ),
          gitCredentialsStoreProvider.overrideWithValue(
            GitCredentialsStore(storage: InMemoryKeychain()),
          ),
          gitStorageProviderInstanceProvider.overrideWithValue(git),
          syncStateProvider.overrideWith((ref) => _FakeSyncNotifier(ref)),
          selectedCloudProviderTypeProvider.overrideWith((ref) => null),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GitConfigPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fillValidForm(
    WidgetTester tester, {
    String url = 'https://github.com/you/dive-log',
    String token = 'ghp_secret',
  }) async {
    await tester.enterText(find.byKey(const Key('git-repo-url')), url);
    await tester.enterText(find.byKey(const Key('git-username')), 'you');
    await tester.enterText(find.byKey(const Key('git-token')), token);
    await tester.pump();
  }

  testWidgets('shows the four fields with the branch defaulted', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('Repository address'), findsOneWidget);
    expect(find.text('The HTTPS address you would clone from'), findsOneWidget);
    expect(find.text('Access token'), findsOneWidget);
    expect(find.text(kDefaultGitBranch), findsOneWidget);
    expect(
      find.textContaining('Your other branches are never touched'),
      findsOneWidget,
    );
  });

  testWidgets('the token help follows the host in the address', (tester) async {
    await pumpPage(tester);
    await tester.enterText(
      find.byKey(const Key('git-repo-url')),
      'https://github.com/you/r',
    );
    await tester.pump();
    expect(find.textContaining('fine-grained token'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('git-repo-url')),
      'https://gitlab.example.org/group/r',
    );
    await tester.pump();
    expect(find.textContaining('write_repository'), findsOneWidget);
    expect(find.textContaining('fine-grained token'), findsNothing);
  });

  testWidgets('an empty token is refused before any request', (tester) async {
    await pumpPage(tester);
    await fillValidForm(tester, token: '');
    await tester.tap(find.byKey(const Key('git-save')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the access token'), findsOneWidget);
    expect(git.tests, 0);
    expect(git.saves, 0);
  });

  testWidgets('an invalid branch name is refused before any request', (
    tester,
  ) async {
    await pumpPage(tester);
    await fillValidForm(tester);
    await tester.enterText(find.byKey(const Key('git-branch')), 'sync dev');
    await tester.tap(find.byKey(const Key('git-test')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid branch name'), findsOneWidget);
    expect(git.tests, 0);
  });

  testWidgets('a failure outside Git and the keychain is not blamed on '
      'secure storage', (tester) async {
    await pumpPage(tester);
    await fillValidForm(tester);
    git.failWith = StateError('boom');
    await tester.tap(find.byKey(const Key('git-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Something went wrong'), findsOneWidget);
    expect(find.textContaining('secure storage'), findsNothing);
  });

  testWidgets('a keychain failure on save says so', (tester) async {
    await pumpPage(tester);
    await fillValidForm(tester);
    git.saveFails = StateError('keychain locked');
    await tester.tap(find.byKey(const Key('git-save')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not access secure storage'),
      findsOneWidget,
    );
  });

  testWidgets('every failure shows its own localized text', (tester) async {
    await pumpPage(tester);
    await fillValidForm(tester);
    final l10n = AppLocalizationsEn();
    for (final code in GitErrorCode.values) {
      final error = GitException(
        'x',
        code: code,
        host: 'git.example.net',
        sizeBytes: 120 * 1024 * 1024,
      );
      git.failWith = error;
      await tester.tap(find.byKey(const Key('git-test')));
      await tester.pumpAndSettle();
      expect(
        find.text(gitErrorText(l10n, error, branch: kDefaultGitBranch)),
        findsOneWidget,
        reason: code.name,
      );
      ScaffoldMessenger.of(
        tester.element(find.byType(GitConfigPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('an empty repository warns that the branch becomes the default', (
    tester,
  ) async {
    git.report = const GitConnectionReport(
      branchExists: false,
      willBecomeDefault: true,
      isPublic: false,
    );
    await pumpPage(tester);
    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('git-test')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('will become its default branch'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a public repository with encryption off is not saved on cancel',
    (tester) async {
      git.report = const GitConnectionReport(
        branchExists: false,
        willBecomeDefault: false,
        isPublic: true,
      );
      await pumpPage(tester);
      await fillValidForm(tester);
      await tester.tap(find.byKey(const Key('git-save')));
      await tester.pumpAndSettle();
      expect(find.text('This repository is public'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(git.saves, 0);
    },
  );

  testWidgets('choosing to turn on encryption saves the public repository', (
    tester,
  ) async {
    git.report = const GitConnectionReport(
      branchExists: true,
      willBecomeDefault: false,
      isPublic: true,
    );
    await pumpPage(tester);
    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('git-save')));
    await tester.pumpAndSettle();
    // The dialog only saves; encryption is turned on from Cloud sync.
    await tester.tap(find.byKey(const Key('git-public-save')));
    await tester.pumpAndSettle();
    expect(git.saves, 1);
    expect(
      git.saved!.cloneUrl.toString(),
      'https://github.com/you/dive-log.git',
    );
  });

  testWidgets('a public repository saves straight away when encryption is on', (
    tester,
  ) async {
    git.report = const GitConnectionReport(
      branchExists: true,
      willBecomeDefault: false,
      isPublic: true,
    );
    await pumpPage(tester, encrypted: true);
    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('git-save')));
    await tester.pumpAndSettle();
    expect(find.text('This repository is public'), findsNothing);
    expect(git.saves, 1);
  });

  testWidgets('a saved config fills the form and can be removed', (
    tester,
  ) async {
    git.saved = GitConfig(
      repoUrl: 'https://gitlab.com/group/r',
      username: 'you',
      token: 'glpat_x',
      branch: 'dive-sync',
    );
    await pumpPage(tester);
    expect(find.text('https://gitlab.com/group/r.git'), findsOneWidget);
    expect(find.text('dive-sync'), findsOneWidget);
    expect(find.textContaining('write_repository'), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Git configuration?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-remove-confirm')));
    await tester.pumpAndSettle();
    expect(git.signOuts, 1);
  });

  testWidgets('removal can be cancelled', (tester) async {
    git.saved = GitConfig(
      repoUrl: 'https://github.com/you/r',
      username: 'you',
      token: 't',
    );
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('git-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(git.signOuts, 0);
  });

  testWidgets('an existing Submersion branch is reported as found', (
    tester,
  ) async {
    git.report = const GitConnectionReport(
      branchExists: true,
      willBecomeDefault: false,
      isPublic: false,
    );
    await pumpPage(tester);
    await fillValidForm(tester);
    await tester.tap(find.byKey(const Key('git-test')));
    await tester.pumpAndSettle();
    expect(
      find.text('Connected to the Submersion branch submersion-sync.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a trusted self-signed certificate is pinned and the test retried',
    (tester) async {
      git.failOnce = GitUntrustedCertificateException(
        WebDavCertificateDetails(
          host: 'git.example.net',
          port: 443,
          sha256: 'ab' * 32,
          subject: 'CN=git.example.net',
          issuer: 'CN=git.example.net',
          startValidity: DateTime.utc(2026),
          endValidity: DateTime.utc(2027),
        ),
      );
      await pumpPage(tester);
      await fillValidForm(tester, url: 'https://git.example.net/you/r');
      await tester.tap(find.byKey(const Key('git-test')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trust this certificate'));
      await tester.pumpAndSettle();
      expect(git.tests, 2);
      expect(git.tested.first.pinnedCertSha256, isNull);
      expect(git.tested.last.pinnedCertSha256, 'ab' * 32);
      expect(find.textContaining('Connected.'), findsOneWidget);
    },
  );
}
