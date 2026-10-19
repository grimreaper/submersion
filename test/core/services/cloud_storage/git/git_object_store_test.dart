import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_id.dart';
import 'package:submersion/core/services/cloud_storage/git/git_object_store.dart';

import '../../../../helpers/git_cli.dart';

GitStoredObject _blob(String text, {int pad = 0}) {
  final body = Uint8List.fromList(utf8.encode(text + ' ' * pad));
  return GitStoredObject(
    id: hashGitObject(GitObjectType.blob, body),
    type: GitObjectType.blob,
    body: body,
  );
}

void main() {
  group('MemoryGitObjectStore', () {
    test('returns what was put and reports presence', () async {
      final store = MemoryGitObjectStore();
      final a = _blob('a');
      expect(await store.has(a.id), isFalse);
      await store.put(a);
      expect(await store.has(a.id), isTrue);
      final back = (await store.get(a.id))!;
      expect(back.type, GitObjectType.blob);
      expect(back.body, a.body);
    });
  });

  group('FileGitObjectStore', () {
    test('survives a new instance on the same directory', () async {
      final dir = tempDirForTest('git_store_');
      final a = _blob('persisted');
      await FileGitObjectStore(dir).put(a);
      final back = await FileGitObjectStore(dir).get(a.id);
      expect(back?.body, a.body);
      expect(back?.type, GitObjectType.blob);
    });

    test('evicts the least recently read object once over maxBytes', () async {
      final dir = tempDirForTest('git_store_');
      // Each object is about 1 KB on disk; the cap holds two of them.
      final store = FileGitObjectStore(dir, maxBytes: 2100);
      final a = _blob('a', pad: 1000);
      final b = _blob('b', pad: 1000);
      final c = _blob('c', pad: 1000);
      await store.put(a);
      await store.put(b);
      await store.get(a.id); // a is now more recent than b
      await store.put(c);
      expect(await store.has(a.id), isTrue);
      expect(await store.has(b.id), isFalse);
      expect(await store.has(c.id), isTrue);
    });
  });
}
