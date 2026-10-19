import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/git/git_branch_files.dart';
import 'package:submersion/core/services/cloud_storage/git/git_branch_session.dart';
import 'package:submersion/core/services/cloud_storage/git/git_errors.dart';
import 'package:submersion/core/services/cloud_storage/git/git_http_transport.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';
import 'package:submersion/core/services/cloud_storage/git/git_remote.dart';

import '../../../../helpers/git_cli.dart';
import '../../../../helpers/git_http_backend_server.dart';

const _branch = 'submersion-sync';

/// A push that reaches the server and then loses its reply.
class _LostReplyTransport extends GitHttpTransport {
  _LostReplyTransport(super.remote);

  bool loseNextReply = false;

  @override
  Future<void> push({
    required String branch,
    required GitObjectId? oldTip,
    required GitObjectId newTip,
    required Stream<List<int>> pack,
  }) async {
    await super.push(
      branch: branch,
      oldTip: oldTip,
      newTip: newTip,
      pack: pack,
    );
    if (loseNextReply) {
      loseNextReply = false;
      throw GitException(
        'Could not reach 127.0.0.1.',
        code: GitErrorCode.unreachable,
        host: '127.0.0.1',
      );
    }
  }
}

GitBranchSession _session(
  Uri url, {
  String branch = _branch,
  GitHttpTransport? transport,
  int resetThresholdBytes = kGitHistoryResetThresholdBytes,
  DateTime Function()? clock,
}) {
  final t =
      transport ??
      GitHttpTransport(GitRemote(cloneUrl: url, username: 'u', token: 't'));
  addTearDown(t.close);
  return GitBranchSession(
    transport: t,
    store: MemoryGitObjectStore(),
    branch: branch,
    identity: () async => const GitCommitIdentity(
      name: 'Submersion 1234abcd',
      messageLabel: 'Submersion 1234abcd',
    ),
    clock: clock ?? () => DateTime.utc(2026, 10, 18, 12),
    retryDelay: (_) => Duration.zero,
    resetThresholdBytes: resetThresholdBytes,
  );
}

GitPut _text(String s) => GitPut.bytes(Uint8List.fromList(utf8.encode(s)));

void main() {
  final skip = skipUnlessGit();

  test(
    'open() on an empty repository creates the branch and its root files',
    () async {
      final server = await startGitTestServer();
      final repo = await server.createBareRepo('empty');
      final snap = await _session(server.repoUrl('empty')).open();
      expect(snap.isDefaultBranch, isTrue);
      expect(snap.index.entries, isEmpty);
      final files = await runGit(repo, [
        'ls-tree',
        '-r',
        '--name-only',
        'refs/heads/$_branch',
      ]);
      expect(
        files.split('\n'),
        unorderedEquals([kGitReadmePath, kGitMetaPath, kGitIndexPath]),
      );
      // Another device adopts the branch rather than creating a second one.
      final again = await _session(server.repoUrl('empty')).open();
      expect(again.tip, snap.tip);
    },
    skip: skip,
  );

  test(
    'open() refuses a branch with other content and leaves it untouched',
    () async {
      final server = await startGitTestServer();
      final repo = await server.createBareRepo('mine', withMainCommit: true);
      final before = await runGit(repo, ['rev-parse', 'refs/heads/main']);
      await expectLater(
        _session(server.repoUrl('mine'), branch: 'main').open(),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.branchHasOtherContent,
          ),
        ),
      );
      expect(await runGit(repo, ['rev-parse', 'refs/heads/main']), before);
      expect(
        await runGit(repo, ['rev-list', '--count', 'refs/heads/main']),
        '1',
      );
    },
    skip: skip,
  );

  test(
    'a committed file is listed by a fresh session with size and time',
    () async {
      final server = await startGitTestServer();
      await server.createBareRepo('sync');
      final writer = _session(
        server.repoUrl('sync'),
        clock: () => DateTime.utc(2026, 10, 18, 9, 30),
      );
      await writer.open();
      await writer.commit(
        GitChange(puts: {'Submersion Sync/ssv1.a.cs.1.json': _text('{"x":1}')}),
        messagePrefix: 'Sync',
      );
      final reader = _session(server.repoUrl('sync'));
      final snap = await reader.open();
      final entry = snap.index.entries['Submersion Sync/ssv1.a.cs.1.json']!;
      expect(entry.size, 7);
      expect(
        entry.modifiedMs,
        DateTime.utc(2026, 10, 18, 9, 30).millisecondsSinceEpoch,
      );
      expect(
        utf8.decode(await reader.readFile('Submersion Sync/ssv1.a.cs.1.json')),
        '{"x":1}',
      );
    },
    skip: skip,
  );

  test('two devices committing at once both land', () async {
    final server = await startGitTestServer();
    final repo = await server.createBareRepo('sync');
    final a = _session(server.repoUrl('sync'));
    await a.open();
    final b = _session(server.repoUrl('sync'));
    await b.open();
    await a.commit(
      GitChange(puts: {'Submersion Sync/a.json': _text('a')}),
      messagePrefix: 'Sync',
    );
    // b still believes the old tip; its push is stale and must be rebuilt.
    await b.commit(
      GitChange(puts: {'Submersion Sync/b.json': _text('b')}),
      messagePrefix: 'Sync',
    );
    final files = await runGit(repo, [
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/$_branch',
    ]);
    expect(files, contains('Submersion Sync/a.json'));
    expect(files, contains('Submersion Sync/b.json'));
  }, skip: skip);

  test(
    'a delete is dropped when a peer rewrote the file since it was listed',
    () async {
      final server = await startGitTestServer();
      await server.createBareRepo('sync');
      const path = 'Submersion Sync/submersion_library_epoch.json';
      final a = _session(server.repoUrl('sync'));
      await a.open();
      await a.commit(
        GitChange(puts: {path: _text('epoch 1')}),
        messagePrefix: 'Sync',
      );
      final b = _session(server.repoUrl('sync'));
      final seen = (await b.open()).index.entries[path]!.blobId;
      await a.commit(
        GitChange(puts: {path: _text('epoch 2')}),
        messagePrefix: 'Sync',
      );
      await b.commit(GitChange(deletes: {path: seen}), messagePrefix: 'Sync');
      final fresh = _session(server.repoUrl('sync'));
      await fresh.open();
      expect(utf8.decode(await fresh.readFile(path)), 'epoch 2');
    },
    skip: skip,
  );

  test(
    'a push whose reply is lost is recognised as landed, not repeated',
    () async {
      final server = await startGitTestServer();
      final repo = await server.createBareRepo('sync');
      final transport = _LostReplyTransport(
        GitRemote(cloneUrl: server.repoUrl('sync'), username: 'u', token: 't'),
      );
      final s = _session(server.repoUrl('sync'), transport: transport);
      await s.open();
      final before = int.parse(
        await runGit(repo, ['rev-list', '--count', 'refs/heads/$_branch']),
      );
      transport.loseNextReply = true;
      await s.commit(
        GitChange(puts: {'Submersion Sync/x.json': _text('x')}),
        messagePrefix: 'Sync',
      );
      final after = int.parse(
        await runGit(repo, ['rev-list', '--count', 'refs/heads/$_branch']),
      );
      expect(after, before + 1);
    },
    skip: skip,
  );

  test('a due history reset leaves one commit with the same files', () async {
    final server = await startGitTestServer();
    final repo = await server.createBareRepo('sync');
    final s = _session(server.repoUrl('sync'), resetThresholdBytes: 1024);
    await s.open();
    final big = 'x' * 2000;
    await s.commit(
      GitChange(puts: {'Submersion Sync/old.json': _text(big)}),
      messagePrefix: 'Sync',
    );
    final oldId = s.current!.index.entries['Submersion Sync/old.json']!.blobId;
    await s.commit(
      GitChange(
        puts: {'Submersion Sync/keep.json': _text('keep')},
        deletes: {'Submersion Sync/old.json': oldId},
      ),
      messagePrefix: 'Sync',
    );
    expect(s.current!.meta.deletedBytesSinceReset, greaterThanOrEqualTo(2000));
    final filesBefore = await runGit(repo, [
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/$_branch',
    ]);
    expect(await s.resetHistoryIfDue(), isTrue);
    expect(
      await runGit(repo, ['rev-list', '--count', 'refs/heads/$_branch']),
      '1',
    );
    expect(
      await runGit(repo, [
        'ls-tree',
        '-r',
        '--name-only',
        'refs/heads/$_branch',
      ]),
      filesBefore,
    );
    expect(s.current!.meta.deletedBytesSinceReset, 0);
    expect(s.current!.meta.lastResetAtMs, isNotNull);
    expect(await s.resetHistoryIfDue(), isFalse);
  }, skip: skip);

  test('a reset that races a peer commit gives up and loses nothing', () async {
    final server = await startGitTestServer();
    final repo = await server.createBareRepo('sync');
    final a = _session(server.repoUrl('sync'));
    await a.open();
    final b = _session(server.repoUrl('sync'));
    await b.open();
    await b.commit(
      GitChange(puts: {'Submersion Sync/peer.json': _text('p')}),
      messagePrefix: 'Sync',
    );
    expect(await a.resetHistoryIfDue(force: true), isFalse);
    final files = await runGit(repo, [
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/$_branch',
    ]);
    expect(files, contains('Submersion Sync/peer.json'));
  }, skip: skip);

  test('a change that alters nothing makes no commit', () async {
    final server = await startGitTestServer();
    final repo = await server.createBareRepo('sync');
    final s = _session(server.repoUrl('sync'));
    await s.open();
    await s.commit(
      GitChange(puts: {'Submersion Sync/x.json': _text('x')}),
      messagePrefix: 'Sync',
    );
    final count = await runGit(repo, [
      'rev-list',
      '--count',
      'refs/heads/$_branch',
    ]);
    await s.commit(
      GitChange(puts: {'Submersion Sync/x.json': _text('x')}),
      messagePrefix: 'Sync',
    );
    expect(
      await runGit(repo, ['rev-list', '--count', 'refs/heads/$_branch']),
      count,
    );
  }, skip: skip);

  test('a put and a delete of the same path keep the new file', () async {
    final server = await startGitTestServer();
    await server.createBareRepo('sync');
    const path = 'Submersion Sync/submersion_library_epoch.json';
    final s = _session(server.repoUrl('sync'));
    await s.open();
    await s.commit(
      GitChange(puts: {path: _text('epoch 1')}),
      messagePrefix: 'Sync',
    );
    final old = s.current!.index.entries[path]!.blobId;
    await s.commit(
      GitChange(puts: {path: _text('epoch 2')}, deletes: {path: old}),
      messagePrefix: 'Sync',
    );
    final fresh = _session(server.repoUrl('sync'));
    await fresh.open();
    expect(utf8.decode(await fresh.readFile(path)), 'epoch 2');
  }, skip: skip);

  test(
    'a reset the host refuses as a non-fast-forward is protectedBranch',
    () async {
      final server = await startGitTestServer();
      final repo = await server.createBareRepo('sync');
      final s = _session(server.repoUrl('sync'));
      await s.open();
      await runGit(repo, ['config', 'receive.denyNonFastForwards', 'true']);
      await expectLater(
        s.resetHistoryIfDue(force: true),
        throwsA(
          isA<GitException>().having(
            (e) => e.code,
            'code',
            GitErrorCode.protectedBranch,
          ),
        ),
      );
    },
    skip: skip,
  );

  test('a too-large refusal names the size of the file', () async {
    final server = await startGitTestServer();
    final repo = await server.createBareRepo('sync');
    final s = _session(server.repoUrl('sync'));
    await s.open();
    await server.refusePushes(repo, 'GH001: Large files detected.');
    await expectLater(
      s.commit(
        GitChange(puts: {'Submersion Backups/b.db': _text('x' * 5000)}),
        messagePrefix: 'Backup',
      ),
      throwsA(
        isA<GitException>()
            .having((e) => e.code, 'code', GitErrorCode.tooLarge)
            .having((e) => e.sizeBytes, 'sizeBytes', 5000),
      ),
    );
  }, skip: skip);

  test(
    'a host without filter still follows a peer, commit after commit',
    () async {
      final server = await startGitTestServer(allowFilter: false);
      await server.createBareRepo('sync');
      final a = _session(server.repoUrl('sync'));
      await a.open();
      final b = _session(server.repoUrl('sync'));
      await b.open();
      for (var i = 0; i < 3; i++) {
        await a.commit(
          GitChange(
            puts: {'Submersion Sync/f$i.json': _text('v$i ${'x' * 3000}')},
          ),
          messagePrefix: 'Sync',
        );
        await b.refresh();
        expect(
          utf8.decode(await b.readFile('Submersion Sync/f$i.json')),
          startsWith('v$i '),
        );
      }
    },
    skip: skip,
  );

  test('a host without filter sends only what a peer changed', () async {
    final server = await startGitTestServer(allowFilter: false);
    await server.createBareRepo('sync');
    final a = _session(server.repoUrl('sync'));
    await a.open();
    final r = Random(7);
    final big = List.generate(
      200000,
      (_) => r.nextInt(16).toRadixString(16),
    ).join();
    await a.commit(
      GitChange(puts: {'Submersion Backups/b.db': _text(big)}),
      messagePrefix: 'Backup',
    );
    final b = _session(server.repoUrl('sync'));
    await b.open();
    server.fetchResponseBytes.clear();
    await a.commit(
      GitChange(puts: {'Submersion Sync/small.json': _text('{"x":1}')}),
      messagePrefix: 'Sync',
    );
    await b.refresh();
    final fetched = server.fetchResponseBytes.fold<int>(0, (a, b) => a + b);
    // The unchanged 200 KB backup must not travel again.
    expect(fetched, lessThan(20000));
    expect(
      utf8.decode(await b.readFile('Submersion Sync/small.json')),
      '{"x":1}',
    );
  }, skip: skip);
}
