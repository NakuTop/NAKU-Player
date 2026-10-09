import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';

const _source = CinemaSource(
  id: 'local-fixture',
  name: '本地测试目录',
  kind: CinemaSourceKind.maccms,
  url: 'https://catalogue.invalid/api.php/provide/vod',
);

class _Repository extends CinemaRepository {
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async => const CinemaPage(
    items: [],
    categories: [
      CinemaCategory(id: '1', name: '剧情片'),
      CinemaCategory(id: '2', name: '欧美剧'),
    ],
  );
}

class _Together extends CinemaWatchTogether {
  _Together(File file)
    : super(
        pairingFile: file,
        clientFactory: (_, _) => throw StateError(
          'An unpaired Home must never create a network client',
        ),
      );

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Together together;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-together-home-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    together = _Together(File('${directory.path}/pairing.json'));
    // Complete filesystem work before entering widget-test fake async.
    await store.load();
    await together.initialize();
  });

  tearDown(() async {
    together.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {double width = 1280}) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: CinemaHomePage(
          enableSearchDiscovery: false,
          store: store,
          repository: _Repository(),
          watchTogether: together,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTogether(WidgetTester tester) async {
    final entry = find.byKey(const ValueKey('watch-together-entry'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    // The coordinator's cached initialization future belongs to the real-I/O
    // zone from setUp; let its dialog continuation cross back into this test.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  void expectPairingForm() {
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Syncplay 服务器'), findsOneWidget);
    expect(find.text('房间名'), findsOneWidget);
    expect(find.text('昵称'), findsOneWidget);
    expect(find.text('创建 / 加入房间'), findsOneWidget);
    expect(find.byType(CinemaPlayerPage), findsNothing);
    expect(together.isPaired, isFalse);
    expect(together.session.connected, isFalse);
  }

  testWidgets('Home opens pairing without a player and keeps its coordinator', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('watch-together-entry')), findsOneWidget);
    expect(find.byType(CinemaPlayerPage), findsNothing);
    expect(together.onFollowRequested, isNotNull);

    await openTogether(tester);
    expectPairingForm();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    for (final section in ['剧集', '电影']) {
      final entry = find.widgetWithText(ListTile, section);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(together.wasDisposed, isFalse);
      expect(together.onFollowRequested, isNotNull);
    }
    await openTogether(tester);
    expectPairingForm();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // The Home route owns its subscription, not the app-wide room connection.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(together.wasDisposed, isFalse);
    expect(together.onFollowRequested, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Home drawer opens the pairing form without overflow', (
    tester,
  ) async {
    await mount(tester, width: 700);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await openTogether(tester);
    expectPairingForm();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(together.wasDisposed, isFalse);
    expect(together.onFollowRequested, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
