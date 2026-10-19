import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/git/git_branch_files.dart';
import 'package:submersion/core/services/cloud_storage/git/git_config.dart';
import 'package:submersion/core/services/cloud_storage/git/git_credentials_store.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';

import '../../../helpers/git_cli.dart';
import '../../../helpers/git_http_backend_server.dart';
import '../../../support/fake_keychain_storage.dart';

const _deviceId = '1234abcd-0000-4000-8000-000000000001';

Future<GitStorageProvider> _provider(
  Uri repoUrl, {
  bool encrypted = false,
  Future<bool> Function()? encryption,
  String token = 'tok',
  Duration deleteQuietPeriod = const Duration(minutes: 10),
  Duration uploadBudget = const Duration(seconds: 45),
  int? resetThresholdBytes,
}) async {
  final store = GitCredentialsStore(storage: InMemoryKeychain());
  await store.save(
    GitConfig(repoUrl: repoUrl.toString(), username: 'diver', token: token),
  );
  final provider = GitStorageProvider(
    store: store,
    storeFactory: (_) async => MemoryGitObjectStore(),
    device: () async => (deviceId: _deviceId, deviceName: "Eric's iPhone"),
    encryptionEnabled: encryption ?? () async => encrypted,
    deleteQuietPeriod: deleteQuietPeriod,
    minPushSpacing: Duration.zero,
    uploadBudget: uploadBudget,
    resetThresholdBytes: resetThresholdBytes ?? kGitHistoryResetThresholdBytes,
  );
  addTearDown(provider.dispose);
  return provider;
}

Future<int> _commits(Directory repo) async => int.parse(
  await runGit(repo, ['rev-list', '--count', 'refs/heads/$kDefaultGitBranch']),
);

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  final skip = skipUnlessGit();

  group('gitCommitIdentityFor', () {
    test('uses the device name when sync is not encrypted', () {
      final id = gitCommitIdentityFor(
        deviceId: _deviceId,
        deviceName: "Eric's iPhone",
        encrypted: false,
      );
      expect(id.name, "Eric's iPhone");
      expect(id.messageLabel, "Eric's iPhone");
    });

    test('keeps the device name out of the repository under encryption', () {
      final id = gitCommitIdentityFor(
        deviceId: _deviceId,
        deviceName: "Eric's iPhone",
        encrypted: true,
      );
      expect(id.name, 'Submersion 1234abcd');
      expect(id.messageLabel, 'Submersion 1234abcd');
    });

    test('falls back to the short device id when there is no name', () {
      final id = gitCommitIdentityFor(
        deviceId: _deviceId,
        deviceName: null,
        encrypted: false,
      );
      expect(id.name, 'Submersion 1234abcd');
    });
  });

  group('against git http-backend', () {
    test(
      'an uploaded file is listed by another device with size and time',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        await server.createBareRepo('sync');
        final writer = await _provider(server.repoUrl('sync'));
        final folder = await writer.getOrCreateSyncFolder();
        expect(folder, 'Submersion Sync');
        final before = DateTime.now().toUtc();
        final result = await writer.uploadFile(
          _bytes('{"x":1}'),
          'ssv1.a.cs.1.json',
          folderId: folder,
        );
        expect(result.fileId, 'Submersion Sync/ssv1.a.cs.1.json');

        final reader = await _provider(server.repoUrl('sync'));
        final files = await reader.listFiles(
          folderId: await reader.getOrCreateSyncFolder(),
        );
        final file = files.single;
        expect(file.name, 'ssv1.a.cs.1.json');
        expect(file.sizeBytes, 7);
        expect(
          file.modifiedTime.isAfter(
            before.subtract(const Duration(seconds: 1)),
          ),
          isTrue,
        );
        expect(
          String.fromCharCodes(await reader.downloadFile(file.id)),
          '{"x":1}',
        );
        expect(
          await reader.listFiles(folderId: folder, namePattern: 'nope'),
          isEmpty,
        );
      },
      skip: skip,
    );

    test(
      'deleteFile pushes nothing, hides the file at once, and flush pushes one commit',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        final repo = await server.createBareRepo('sync');
        final p = await _provider(server.repoUrl('sync'));
        final folder = await p.getOrCreateSyncFolder();
        final ids = <String>[];
        for (var i = 0; i < 10; i++) {
          ids.add(
            (await p.uploadFile(
              _bytes('$i'),
              'f$i.json',
              folderId: folder,
            )).fileId,
          );
        }
        await p.listFiles(folderId: folder);
        final count = await _commits(repo);
        for (final id in ids) {
          await p.deleteFile(id);
        }
        expect(await _commits(repo), count);
        expect(await p.fileExists(ids.first), isFalse);
        expect(await p.listFiles(folderId: folder), isEmpty);
        await p.flush();
        expect(await _commits(repo), count + 1);
        final files = await runGit(repo, [
          'ls-tree',
          '-r',
          '--name-only',
          'refs/heads/$kDefaultGitBranch',
        ]);
        expect(files, isNot(contains('Submersion Sync/')));
      },
      skip: skip,
    );

    test('pending deletes ride along in the next upload\'s commit', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      final p = await _provider(server.repoUrl('sync'));
      final folder = await p.getOrCreateSyncFolder();
      final old = await p.uploadFile(
        _bytes('old'),
        'old.json',
        folderId: folder,
      );
      await p.listFiles(folderId: folder);
      final count = await _commits(repo);
      await p.deleteFile(old.fileId);
      await p.uploadFile(_bytes('new'), 'new.json', folderId: folder);
      expect(await _commits(repo), count + 1);
      final names = (await p.listFiles(folderId: folder)).map((f) => f.name);
      expect(names, ['new.json']);
    }, skip: skip);

    test('the quiet period flushes deletes on its own', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      final p = await _provider(
        server.repoUrl('sync'),
        deleteQuietPeriod: const Duration(milliseconds: 50),
      );
      final folder = await p.getOrCreateSyncFolder();
      final f = await p.uploadFile(_bytes('x'), 'x.json', folderId: folder);
      await p.listFiles(folderId: folder);
      final count = await _commits(repo);
      await p.deleteFile(f.fileId);
      for (var i = 0; i < 100 && await _commits(repo) == count; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await _commits(repo), count + 1);
    }, skip: skip);

    test('a backup streams from disk and is committed as a backup', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      final p = await _provider(server.repoUrl('sync'));
      final dir = tempDirForTest('git_backup_');
      final r = Random(1);
      final file = File(joinPath(dir, 'submersion_backup_1.db'))
        ..writeAsBytesSync(
          List.generate(3 * 1024 * 1024, (_) => r.nextInt(256)),
        );
      final backups = await p.createFolder('Submersion Backups');
      expect(backups, 'Submersion Backups');
      final up = await p.uploadFileFromPath(
        file.path,
        'submersion_backup_1.db',
        folderId: backups,
      );
      expect(up.fileId, 'Submersion Backups/submersion_backup_1.db');
      final subject = await runGit(repo, [
        'log',
        '-1',
        '--format=%s',
        'refs/heads/$kDefaultGitBranch',
      ]);
      expect(subject, startsWith('Backup from '));
      final listed = await p.listFiles(folderId: backups);
      expect(listed.single.sizeBytes, 3 * 1024 * 1024);
      final out = File(joinPath(dir, 'restored.db'));
      await p.downloadToFile(up.fileId, out.path);
      expect(out.lengthSync(), 3 * 1024 * 1024);
    }, skip: skip);

    test('a public repository refuses unencrypted writes', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
        anonymousRead: true,
      );
      final repo = await server.createBareRepo('open');
      final plain = await _provider(server.repoUrl('open'));
      await expectLater(
        plain.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync'),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.publicRepoUnencrypted,
          ),
        ),
      );
      // Turning encryption on must still be possible: the keyslot file holds
      // only a wrapped key, so it may land while sync is unencrypted.
      await plain.uploadFile(
        _bytes('{"slots":[]}'),
        'submersion_keyslots.json',
        folderId: 'Submersion Sync',
      );
      final files = await runGit(repo, [
        'ls-tree',
        '-r',
        '--name-only',
        'refs/heads/$kDefaultGitBranch',
      ]);
      expect(files, contains('Submersion Sync/submersion_keyslots.json'));
      expect(files, isNot(contains('Submersion Sync/x.json')));
      final sealed = await _provider(server.repoUrl('open'), encrypted: true);
      await sealed.uploadFile(
        _bytes('x'),
        'x.json',
        folderId: 'Submersion Sync',
      );
      expect(await _commits(repo), greaterThanOrEqualTo(2));
      expect(await sealed.isPubliclyReadable(), isTrue);
    }, skip: skip);

    test(
      'a history reset is known to every provider for that repository',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        await server.createBareRepo('reset');
        final p = await _provider(server.repoUrl('reset'));
        await p.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync');
        final config = (await p.loadConfig())!;
        expect(GitStorageProvider.lastKnownResetFor(config), isNull);
        await p.resetHistoryNow();
        // The tile reads this, and the active sync provider is a different
        // instance (one per account) from the settings singleton.
        expect(GitStorageProvider.lastKnownResetFor(config), isNotNull);
        expect(
          p.lastKnownResetAt,
          GitStorageProvider.lastKnownResetFor(config),
        );
      },
      skip: skip,
    );

    test('commits under encryption carry no device name', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      final p = await _provider(server.repoUrl('sync'), encrypted: true);
      await p.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync');
      final log = await runGit(repo, [
        'log',
        '--format=%an|%s',
        'refs/heads/$kDefaultGitBranch',
      ]);
      expect(log, isNot(contains('Eric')));
      expect(
        log,
        contains('Submersion 1234abcd|Sync from Submersion 1234abcd'),
      );
    }, skip: skip);
  });

  group('testConnection', () {
    test(
      'an empty repository: the branch will be created and become default',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        await server.createBareRepo('empty');
        final p = await _provider(server.repoUrl('empty'));
        final report = await p.testConnection(
          GitConfig(
            repoUrl: server.repoUrl('empty').toString(),
            username: 'diver',
            token: 'tok',
          ),
        );
        expect(report.branchExists, isFalse);
        expect(report.willBecomeDefault, isTrue);
        expect(report.isPublic, isFalse);
      },
      skip: skip,
    );

    test(
      'a branch with other content is refused and nothing is written',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        final repo = await server.createBareRepo('mine', withMainCommit: true);
        final p = await _provider(server.repoUrl('mine'));
        await expectLater(
          p.testConnection(
            GitConfig(
              repoUrl: server.repoUrl('mine').toString(),
              username: 'diver',
              token: 'tok',
              branch: 'main',
            ),
          ),
          throwsA(
            isA<GitException>().having(
              (e) => e.code,
              'code',
              GitErrorCode.branchHasOtherContent,
            ),
          ),
        );
        expect(
          await runGit(repo, ['rev-list', '--count', 'refs/heads/main']),
          '1',
        );
      },
      skip: skip,
    );

    test('a wrong token is unauthorized', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'right',
      );
      await server.createBareRepo('private');
      final p = await _provider(server.repoUrl('private'));
      await expectLater(
        p.testConnection(
          GitConfig(
            repoUrl: server.repoUrl('private').toString(),
            username: 'diver',
            token: 'wrong',
          ),
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.unauthorized,
          ),
        ),
      );
    }, skip: skip);

    test('an invalid config is refused before any request', () async {
      final p = GitStorageProvider(
        store: GitCredentialsStore(storage: InMemoryKeychain()),
      );
      addTearDown(p.dispose);
      await expectLater(
        p.testConnection(
          GitConfig(
            repoUrl: 'http://github.com/a/b',
            username: 'diver',
            token: 'tok',
          ),
        ),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.invalidConfig,
          ),
        ),
      );
    });
  });

  test('without a saved config the provider is not authenticated', () async {
    final p = GitStorageProvider(
      store: GitCredentialsStore(storage: InMemoryKeychain()),
    );
    addTearDown(p.dispose);
    expect(await p.isAuthenticated(), isFalse);
    await expectLater(
      p.authenticate(),
      throwsA(
        isA<GitException>().having(
          (e) => e.code,
          'code',
          GitErrorCode.invalidConfig,
        ),
      ),
    );
    expect(p.providerId, 'git');
    expect(p.providerName, 'Git');
  });

  group('review fixes', () {
    test('an upload replaces a pending delete of the same path', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      await server.createBareRepo('sync');
      final p = await _provider(server.repoUrl('sync'));
      final up = await p.uploadFile(
        _bytes('one'),
        'epoch.json',
        folderId: 'Submersion Sync',
      );
      await p.listFiles(folderId: 'Submersion Sync');
      await p.deleteFile(up.fileId);
      await p.uploadFile(
        _bytes('two'),
        'epoch.json',
        folderId: 'Submersion Sync',
      );
      final reader = await _provider(server.repoUrl('sync'));
      expect(String.fromCharCodes(await reader.downloadFile(up.fileId)), 'two');
    }, skip: skip);

    test(
      'a refused history reset neither fails the flush nor goes unseen',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
        );
        final repo = await server.createBareRepo('sync');
        final p = await _provider(
          server.repoUrl('sync'),
          resetThresholdBytes: 1,
        );
        final up = await p.uploadFile(
          _bytes('x' * 100),
          'x.json',
          folderId: 'Submersion Sync',
        );
        await p.listFiles(folderId: 'Submersion Sync');
        await runGit(repo, ['config', 'receive.denyNonFastForwards', 'true']);
        await p.deleteFile(up.fileId);
        await p.flush();
        final config = (await p.loadConfig())!;
        expect(GitStorageProvider.resetRefusedFor(config), isTrue);
        final files = await runGit(repo, [
          'ls-tree',
          '-r',
          '--name-only',
          'refs/heads/$kDefaultGitBranch',
        ]);
        expect(files, isNot(contains('Submersion Sync/x.json')));
      },
      skip: skip,
    );

    test(
      'turning encryption off later is noticed over a public repository',
      () async {
        final server = await startGitTestServer(
          requireUser: 'diver',
          requirePassword: 'tok',
          anonymousRead: true,
        );
        await server.createBareRepo('open');
        var encrypted = true;
        final p = await _provider(
          server.repoUrl('open'),
          encryption: () async => encrypted,
        );
        await p.uploadFile(
          _bytes('sealed'),
          'a.json',
          folderId: 'Submersion Sync',
        );
        encrypted = false;
        await expectLater(
          p.uploadFile(_bytes('plain'), 'b.json', folderId: 'Submersion Sync'),
          throwsA(
            isA<GitException>().having(
              (e) => e.code,
              'code',
              GitErrorCode.publicRepoUnencrypted,
            ),
          ),
        );
      },
      skip: skip,
    );

    test('a backup is not cut off by the sync upload budget', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      await server.createBareRepo('sync');
      final p = await _provider(
        server.repoUrl('sync'),
        uploadBudget: const Duration(microseconds: 1),
      );
      await expectLater(
        p.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync'),
        throwsA(isA<GitException>()),
      );
      final up = await p.uploadFile(
        _bytes('backup'),
        'submersion_backup_1.db',
        folderId: 'Submersion Backups',
      );
      expect(up.fileId, 'Submersion Backups/submersion_backup_1.db');
    }, skip: skip);
  });
}
