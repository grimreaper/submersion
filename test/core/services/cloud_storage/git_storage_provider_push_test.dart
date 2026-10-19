import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/git_storage_provider.dart';

import '../../../helpers/git_cli.dart';
import '../../../helpers/git_http_backend_server.dart';
import '../../../helpers/git_test_provider.dart';

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  final skip = skipUnlessGit();

  group('the sync upload budget', () {
    test('grows with the payload', () {
      const base = Duration(seconds: 45);
      expect(GitStorageProvider.uploadBudgetFor(base, 1024), base);
      expect(
        GitStorageProvider.uploadBudgetFor(base, 8 * 1024 * 1024),
        const Duration(seconds: 64),
      );
    });

    test('does not count the wait for push pacing', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      await server.createBareRepo('sync');
      final p = await gitTestProvider(
        server.repoUrl('sync'),
        minPushSpacing: const Duration(seconds: 3),
        maxPacingWait: const Duration(seconds: 3),
        uploadBudget: const Duration(seconds: 2),
      );
      await p.uploadFile(_bytes('a'), 'a.json', folderId: 'Submersion Sync');
      // Paced for about three seconds, then pushed well inside two.
      await p.uploadFile(_bytes('b'), 'b.json', folderId: 'Submersion Sync');
      final names = (await p.listFiles(
        folderId: 'Submersion Sync',
      )).map((f) => f.name).toSet();
      expect(names, {'a.json', 'b.json'});
    }, skip: skip);

    test('runs out as a timeout, since the push may still land', () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      await server.createBareRepo('sync');
      final p = await gitTestProvider(
        server.repoUrl('sync'),
        uploadBudget: const Duration(microseconds: 1),
      );
      await expectLater(
        p.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync'),
        throwsA(isA<TimeoutException>()),
      );
    }, skip: skip);
  });

  test(
    'a device name with brackets or a line break still makes valid commits',
    () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      // Hosts check every pushed object, as GitHub does.
      await runGit(repo, ['config', 'receive.fsckObjects', 'true']);
      final p = await gitTestProvider(
        server.repoUrl('sync'),
        deviceName: 'Eric <work>\nphone',
      );
      await p.uploadFile(_bytes('x'), 'x.json', folderId: 'Submersion Sync');
      final author = await runGit(repo, [
        'log',
        '-1',
        '--format=%an <%ae>',
        'refs/heads/submersion-sync',
      ]);
      expect(author, 'Eric work phone <sync@submersion.invalid>');
    },
    skip: skip,
  );
}
