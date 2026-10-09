import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_library_actions.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

const _first = CinemaTitle(
  id: '1',
  sourceId: 'one',
  title: '第一部电影',
  year: '2020',
  category: '剧情片',
  doubanId: '111',
);
const _variant = CinemaTitle(
  id: '10',
  sourceId: 'two',
  title: '第一部电影',
  year: '2020',
  category: '剧情片',
  doubanId: '111',
);
const _second = CinemaTitle(
  id: '2',
  sourceId: 'one',
  title: '另一部电影',
  year: '2021',
  category: '剧情片',
  doubanId: '222',
);

Map<String, dynamic> _history(CinemaTitle title, int day, int position) =>
    CinemaHistory(
      title: title,
      routeIndex: 2,
      episodeIndex: 3,
      positionSeconds: position,
      durationSeconds: 6000,
      updatedAt: DateTime.utc(2026, 1, day),
    ).toJson();

void main() {
  late Directory directory;
  late File file;
  late CinemaStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-library-actions-');
    file = File('${directory.path}/library.json');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'sources': [],
        'favorites': [
          {..._first.toJson(), 'privateNote': 'keep'},
          {..._variant.toJson(), 'customVariant': true},
          _second.toJson(),
        ],
        'history': [
          {..._history(_first, 3, 321), 'customResume': 'first'},
          {..._history(_variant, 2, 120), 'customResume': 'variant'},
          _history(_second, 1, 95),
        ],
      }),
    );
    store = CinemaStore(file: file, defaults: const []);
    await store.load();
  });
  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<Map<String, dynamic>> saved() async =>
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;

  test('undo preserves exact merged documents, progress and time', () async {
    final before = await saved();
    final favoriteUndo = await store.removeFavorite(_variant);
    final historyUndo = await store.removeHistory(_variant);
    expect(store.favorites.single.key, _second.key);
    expect(store.history.single.title.key, _second.key);
    expect(await favoriteUndo!.restore(), isTrue);
    expect(await historyUndo!.restore(), isTrue);
    final after = await saved();
    expect(after['favorites'], before['favorites']);
    expect(after['history'], before['history']);
    expect(await historyUndo.restore(), isFalse);
    expect(store.history, hasLength(2));
    final reopened = CinemaStore(file: file, defaults: const []);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.historyForWork(_variant)?.positionSeconds, 321);
    expect(
      reopened.historyForWork(_variant)?.updatedAt,
      DateTime.utc(2026, 1, 3),
    );
    expect(reopened.isFavorite(_variant), isTrue);
  });

  test('undo cannot replace a newer source progress or favorite', () async {
    final historyUndo = await store.removeHistory(_first);
    final favoriteUndo = await store.removeFavorite(_first);
    await store.recordProgress(
      title: _variant,
      routeIndex: 0,
      episodeIndex: 1,
      positionSeconds: 456,
    );
    await store.toggleFavorite(_variant);
    final latest = await saved();
    expect(await historyUndo!.restore(), isFalse);
    expect(await favoriteUndo!.restore(), isFalse);
    expect(await saved(), latest);
    expect(store.historyForWork(_first)?.title.key, _variant.key);
    expect(store.historyForWork(_first)?.positionSeconds, 456);
  });

  test(
    'undo restores only its work without reviving unrelated deletions',
    () async {
      final historyUndo = await store.removeHistory(_first);
      final favoriteUndo = await store.removeFavorite(_first);
      await store.removeHistory(_second);
      await store.removeFavorite(_second);
      expect(await historyUndo!.restore(), isTrue);
      expect(await favoriteUndo!.restore(), isTrue);
      expect(store.history.single.title.key, _first.key);
      expect(store.favorites.single.key, _first.key);
      expect(await store.removeFavorite(_second), isNull);
      expect(await store.removeHistory(_second), isNull);
    },
  );

  test('failed atomic deletion leaves the original record available', () async {
    final before = await file.readAsString();
    await Directory('${file.path}.tmp').create();
    await expectLater(
      store.removeHistory(_first),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.historyForWork(_variant)?.positionSeconds, 321);
    expect(store.history, hasLength(2));
    expect(await file.readAsString(), before);
  });

  var opened = 0;
  Future<void> mount(WidgetTester tester, {bool history = false}) async {
    opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: store,
            builder: (context, _) {
              final titles = history
                  ? store.history.map((h) => h.title).toList()
                  : store.favorites;
              return ListView(
                children: [
                  for (final title in titles)
                    CinemaLibraryActions(
                      key: ValueKey(title.key),
                      store: store,
                      title: title,
                      history: history,
                      child: ListTile(
                        key: ValueKey('open:${title.key}'),
                        title: Text(title.title),
                        onTap: () => opened++,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> flush(WidgetTester tester) async {
    // Storage uses real atomic file IO rather than a mocked deletion method.
    await tester.pumpAndSettle();
    var completed = false;
    store.flush().then((_) => completed = true);
    for (var i = 0; i < 100 && !completed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(completed, isTrue, reason: 'Atomic library write must finish.');
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'favorite right click deletes and undo restores without opening',
    (tester) async {
      await mount(tester);
      await rightClick(tester, find.text(_first.title));
      expect(find.text('取消收藏'), findsOneWidget);
      expect(opened, 0);
      await tester.tap(find.text('取消收藏'));
      await flush(tester);
      expect(find.text(_first.title), findsNothing);
      expect(find.text(_second.title), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await flush(tester);
      expect(find.text(_first.title), findsOneWidget);
      expect(store.isFavorite(_variant), isTrue);
      expect(opened, 0);
    },
  );

  testWidgets('history right click deletes only the chosen work', (
    tester,
  ) async {
    await mount(tester, history: true);
    await rightClick(tester, find.text(_first.title));
    await tester.tap(find.widgetWithText(PopupMenuItem<bool>, '删除记录'));
    await flush(tester);
    expect(store.history.single.title.key, _second.key);
    expect(store.favorites, hasLength(2));
    expect(opened, 0);
  });

  testWidgets(
    'touch long press exposes favorite removal and ordinary tap still opens',
    (tester) async {
      await mount(tester);
      await tester.longPress(find.text(_first.title));
      await tester.pumpAndSettle();
      expect(find.text('取消收藏'), findsOneWidget);
      expect(opened, 0);
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_first.title));
      expect(opened, 1);
      expect(store.favorites, hasLength(2));
    },
  );

  testWidgets('history swipe deletes and undo keeps its original progress', (
    tester,
  ) async {
    await mount(tester, history: true);
    await tester.drag(
      find.byKey(ValueKey('open:${_first.key}')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    await flush(tester);
    expect(store.history.single.title.key, _second.key);
    expect(opened, 0);
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await flush(tester);
    expect(store.historyForWork(_variant)?.positionSeconds, 321);
    expect(store.historyForWork(_variant)?.routeIndex, 2);
    expect(store.historyForWork(_variant)?.episodeIndex, 3);
    expect(opened, 0);
  });

  testWidgets('short swipe cancels without deleting or opening a title', (
    tester,
  ) async {
    await mount(tester, history: true);
    await tester.timedDrag(
      find.byKey(ValueKey('open:${_first.key}')),
      const Offset(-60, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(store.history, hasLength(2));
    expect(opened, 0);
    expect(find.text('撤销'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed swipe write restores an interactive row without dismissal errors',
    (tester) async {
      final before = await tester.runAsync(file.readAsString);
      await tester.runAsync(() => Directory('${file.path}.tmp').create());
      await mount(tester, history: true);
      await tester.drag(
        find.byKey(ValueKey('open:${_first.key}')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      final failure = find.text('未能保存删除操作，记录已保留');
      for (var i = 0; i < 100 && failure.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(failure, findsOneWidget);
      expect(find.text(_first.title), findsOneWidget);
      expect(store.historyForWork(_variant)?.positionSeconds, 321);
      expect(await tester.runAsync(file.readAsString), before);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(_first.title));
      expect(opened, 1);

      // Clearing the storage fault allows the same restored row to be swiped.
      await tester.runAsync(() => Directory('${file.path}.tmp').delete());
      await tester.drag(
        find.byKey(ValueKey('open:${_first.key}')),
        const Offset(-600, 0),
      );
      await flush(tester);
      expect(store.history.single.title.key, _second.key);
      expect(tester.takeException(), isNull);
    },
  );
}
