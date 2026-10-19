import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_http_transport.dart';

import '../../../helpers/git_cli.dart';
import '../../../helpers/git_http_backend_server.dart';
import '../../../helpers/git_test_provider.dart';

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  final skip = skipUnlessGit();

  test(
    'a delete whose push failed is listed again, and a retry removes it',
    () async {
      final server = await startGitTestServer(
        requireUser: 'diver',
        requirePassword: 'tok',
      );
      final repo = await server.createBareRepo('sync');
      final p = await gitTestProvider(server.repoUrl('sync'));
      final up = await p.uploadFile(
        _bytes('x'),
        'x.json',
        folderId: 'Submersion Sync',
      );
      await p.listFiles(folderId: 'Submersion Sync');
      var pushesFail = true;
      server.beforeServe = (request) =>
          !pushesFail ||
          request.method != 'POST' ||
          !request.uri.path.endsWith('/git-receive-pack');

      await p.deleteFile(up.fileId);
      await expectLater(p.flush(), throwsA(isA<GitException>()));
      // Still on the branch, so a caller that retries must find it.
      final listed = await p.listFiles(folderId: 'Submersion Sync');
      expect(listed.map((f) => f.id), [up.fileId]);
      expect(await p.fileExists(up.fileId), isTrue);

      pushesFail = false;
      await p.deleteFile(up.fileId);
      await p.flush();
      expect(
        await syncBranchFiles(repo),
        isNot(contains('Submersion Sync/x.json')),
      );
    },
    skip: skip,
  );

  test('concurrent first calls share one session', () async {
    final server = await startGitTestServer(
      requireUser: 'diver',
      requirePassword: 'tok',
    );
    await server.createBareRepo('sync');
    var transports = 0;
    final p = await gitTestProvider(
      server.repoUrl('sync'),
      transportFactory: (config) {
        transports++;
        return GitHttpTransport(config.toRemote());
      },
    );
    await Future.wait([
      p.listFiles(folderId: 'Submersion Sync'),
      p.listFiles(folderId: 'Submersion Sync'),
    ]);
    expect(transports, 1);
  }, skip: skip);
}
