// The Advanced section's copy actions say why they failed instead of
// leaving an unhandled error and a silent tap (issue #3482 review).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'photos_page_harness.dart';

void main() {
  late PhotosPageHarness h;

  setUp(() async => h = await PhotosPageHarness.create());

  Future<void> pumpAttached(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(h.app(statusHint: 'dive-media @ minio'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
  }

  Future<void> tapAndSettle(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
  }

  testWidgets('a failed upload-everything says why', (tester) async {
    h.backfill.failure = StateError('database is locked');
    await pumpAttached(tester);

    await tapAndSettle(tester, const Key('media-s3-backfill'));

    expect(h.backfill.calls, 1);
    expect(find.textContaining('database is locked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed stop-keeping says why', (tester) async {
    h.service.failure = StateError('keychain is locked');
    await pumpAttached(tester);

    await tester.ensureVisible(find.byKey(const Key('media-s3-disconnect')));
    await tester.tap(find.byKey(const Key('media-s3-disconnect')));
    await tester.pumpAndSettle();
    await tapAndSettle(tester, const Key('media-s3-disconnect-confirm'));

    expect(h.service.disconnectCalls, 1);
    expect(find.textContaining('keychain is locked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
