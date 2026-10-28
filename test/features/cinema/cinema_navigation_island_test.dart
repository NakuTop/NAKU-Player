import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_navigation_island.dart';

void main() {
  const entries = [
    (0, Icons.movie_outlined, '电影'),
    (1, Icons.tv, '剧集'),
    (2, Icons.animation, '动漫'),
    (3, Icons.bookmark_outline, '收藏'),
    (4, Icons.history, '继续观看'),
    (5, Icons.settings_outlined, '设置'),
  ];
  var current = 0;
  var visibleEntries = entries;
  late StateSetter update;
  final committed = <int>[];

  Future<void> mount(
    WidgetTester tester, {
    int initial = 0,
    ValueNotifier<double>? progress,
    bool reduceMotion = false,
  }) async {
    current = initial;
    visibleEntries = entries;
    committed.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(800, 600),
            disableAnimations: reduceMotion,
          ),
          child: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return CinemaNavigationIsland<int>(
                    value: current,
                    destinations: visibleEntries,
                    keyFor: (value) => ValueKey('destination-$value'),
                    swipeProgress: progress,
                    onChanged: (value) => setState(() {
                      current = value;
                      committed.add(value);
                    }),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Offset center(WidgetTester tester, int index) =>
      tester.getCenter(find.byKey(ValueKey('destination-$index')));

  double thumbX(WidgetTester tester) => tester
      .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
      .dx;

  testWidgets('dragging an inactive cell acquires the thumb at the pointer', (
    tester,
  ) async {
    await mount(tester);
    final start = center(tester, 3);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(28, 0));
    await tester.pump();
    expect(thumbX(tester), closeTo(start.dx + 28, 1));
    expect(current, 0);
    expect(committed, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(current, 3);
    expect(committed, [3]);
  });

  testWidgets('trackpad follows the thumb and selects once at gesture end', (
    tester,
  ) async {
    await mount(tester, initial: 1);
    final start = center(tester, 1);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(start, timeStamp: const Duration(seconds: 1));
    await gesture.panZoomUpdate(
      start,
      pan: const Offset(65, 1),
      timeStamp: const Duration(milliseconds: 1040),
    );
    await tester.pump();
    expect(thumbX(tester), greaterThan(start.dx + 50));
    expect(current, 1);
    expect(committed, isEmpty);
    await gesture.panZoomUpdate(
      start,
      pan: const Offset(600, 1),
      timeStamp: const Duration(milliseconds: 1080),
    );
    await gesture.panZoomEnd(timeStamp: const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(current, 2);
    expect(committed, [2]);
    expect(thumbX(tester), closeTo(center(tester, 2).dx, 1));
  });

  testWidgets('horizontal wheel commits once and rejects its momentum tail', (
    tester,
  ) async {
    await mount(tester, initial: 1);
    final start = center(tester, 1);
    Future<void> wheel(int milliseconds, Offset delta) =>
        tester.sendEventToBinding(
          PointerScrollEvent(
            device: 71,
            timeStamp: Duration(milliseconds: milliseconds),
            position: start,
            scrollDelta: delta,
          ),
        );
    await wheel(1000, const Offset(-65, 0));
    await tester.pump();
    expect(thumbX(tester), greaterThan(start.dx + 50));
    expect(committed, isEmpty);
    await tester.pump(const Duration(milliseconds: 140));
    expect(current, 2);
    expect(committed, [2]);
    await wheel(1150, const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 150));
    await wheel(1300, const Offset(-70, 0));
    await tester.pumpAndSettle();
    expect(current, 2);
    expect(committed, [2]);
    await wheel(2000, const Offset(-65, 0));
    await tester.pump(const Duration(milliseconds: 140));
    await tester.pumpAndSettle();
    expect(current, 3);
    expect(committed, [2, 3]);
  });

  testWidgets(
    'a fresh native trackpad gesture can immediately reverse direction',
    (tester) async {
      await mount(tester, initial: 2);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      final first = center(tester, 2);
      await gesture.panZoomStart(
        first,
        timeStamp: const Duration(milliseconds: 1000),
      );
      await gesture.panZoomUpdate(
        first,
        pan: const Offset(70, 0),
        timeStamp: const Duration(milliseconds: 1040),
      );
      await gesture.panZoomEnd(timeStamp: const Duration(milliseconds: 1050));
      await tester.pump();
      expect(current, 3);
      expect(committed, [3]);

      final second = center(tester, 3);
      await gesture.panZoomStart(
        second,
        timeStamp: const Duration(milliseconds: 1100),
      );
      await gesture.panZoomUpdate(
        second,
        pan: const Offset(-70, 0),
        timeStamp: const Duration(milliseconds: 1140),
      );
      await gesture.panZoomEnd(timeStamp: const Duration(milliseconds: 1150));
      await tester.pumpAndSettle();
      expect(current, 2);
      expect(committed, [3, 2]);
      expect(thumbX(tester), closeTo(center(tester, 2).dx, 1));
    },
  );

  for (final direction in [-1, 1]) {
    testWidgets('trackpad physical direction $direction scrubs the thumb', (
      tester,
    ) async {
      await mount(tester, initial: 2);
      final start = center(tester, 2);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(start);
      await gesture.panZoomUpdate(start, pan: Offset(direction * 70.0, 0));
      await tester.pump();
      expect((thumbX(tester) - start.dx).sign, direction.toDouble());
      expect(current, 2);
      expect(committed, isEmpty);
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(current, 2 + direction);
      expect(committed, [2 + direction]);
      expect(thumbX(tester), closeTo(center(tester, 2 + direction).dx, 1));
    });

    testWidgets(
      'wheel scroll direction $direction normalizes physical scrubbing',
      (tester) async {
        await mount(tester, initial: 2);
        final start = center(tester, 2);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: start,
            scrollDelta: Offset(direction * 70.0, 0),
          ),
        );
        await tester.pump();
        expect((thumbX(tester) - start.dx).sign, -direction.toDouble());
        expect(current, 2);
        expect(committed, isEmpty);
        await tester.pump(const Duration(milliseconds: 140));
        await tester.pumpAndSettle();
        expect(current, 2 - direction);
        expect(committed, [2 - direction]);
        expect(thumbX(tester), closeTo(center(tester, 2 - direction).dx, 1));
      },
    );
  }

  testWidgets(
    'vertical wheel locks its stream and short horizontal pan returns',
    (tester) async {
      await mount(tester, initial: 2);
      final start = center(tester, 2);
      for (final delta in [const Offset(1, 60), const Offset(90, 0)]) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: start, scrollDelta: delta),
        );
      }
      await tester.pumpAndSettle();
      expect(current, 2);
      expect(committed, isEmpty);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(start);
      await gesture.panZoomUpdate(start, pan: const Offset(-25, 0));
      await tester.pump();
      expect(thumbX(tester), lessThan(start.dx));
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(current, 2);
      expect(committed, isEmpty);
      expect(thumbX(tester), closeTo(start.dx, 1));
    },
  );

  for (final pinch in [true, false]) {
    testWidgets('trackpad ${pinch ? 'pinch' : 'rotation'} cancels navigation', (
      tester,
    ) async {
      await mount(tester, initial: 2);
      final start = center(tester, 2);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(start);
      await gesture.panZoomUpdate(start, pan: const Offset(-65, 0));
      await gesture.panZoomUpdate(
        start,
        pan: const Offset(-80, 0),
        scale: pinch ? 1.2 : 1,
        rotation: pinch ? 0 : .2,
      );
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(current, 2);
      expect(committed, isEmpty);
      expect(thumbX(tester), closeTo(start.dx, 1));
    });
  }

  testWidgets('pointer cancellation restores the committed destination', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      center(tester, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(center(tester, 4));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(current, 0);
    expect(committed, isEmpty);
    expect(thumbX(tester), closeTo(center(tester, 0).dx, 1));
  });

  testWidgets(
    'trackpad vertical intent stays locked through its horizontal tail',
    (tester) async {
      await mount(tester, initial: 2);
      final start = center(tester, 2);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(start);
      await gesture.panZoomUpdate(start, pan: const Offset(1, -50));
      await gesture.panZoomUpdate(start, pan: const Offset(-150, -50));
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(current, 2);
      expect(committed, isEmpty);
      expect(thumbX(tester), closeTo(start.dx, 1));
    },
  );

  testWidgets('empty destinations have no thumb or invalid layout', (
    tester,
  ) async {
    await mount(tester);
    update(() => visibleEntries = []);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cinema-navigation-thumb')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(committed, isEmpty);
  });

  testWidgets('selection change during a trackpad stream cancels its release', (
    tester,
  ) async {
    await mount(tester, initial: 1);
    final start = center(tester, 1);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(start);
    await gesture.panZoomUpdate(start, pan: const Offset(-65, 0));
    await tester.pump();
    update(() => current = 4);
    await tester.pump();
    await gesture.panZoomUpdate(start, pan: const Offset(-150, 0));
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(current, 4);
    expect(committed, isEmpty);
    expect(thumbX(tester), closeTo(center(tester, 4).dx, 1));
  });

  testWidgets(
    'page swipe previews the same thumb and cancels without selecting',
    (tester) async {
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      await mount(tester, initial: 2, progress: progress);
      progress.value = .6;
      await tester.pump();
      final segment = center(tester, 2).dx - center(tester, 1).dx;
      expect(thumbX(tester), closeTo(center(tester, 2).dx - .6 * segment, 1));
      expect(current, 2);
      expect(committed, isEmpty);
      progress.value = 0;
      await tester.pumpAndSettle();
      expect(thumbX(tester), closeTo(center(tester, 2).dx, 1));
    },
  );

  testWidgets(
    'page swipe commit preserves its preview position before settling',
    (tester) async {
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      await mount(tester, initial: 2, progress: progress);
      progress.value = -1;
      await tester.pump();
      final previewX = thumbX(tester);
      progress.value = 0;
      update(() => current = 3);
      await tester.pump();
      expect(thumbX(tester), closeTo(previewX, 1));
      await tester.pumpAndSettle();
      expect(thumbX(tester), closeTo(center(tester, 3).dx, 1));
      expect(committed, isEmpty);
    },
  );

  testWidgets(
    'reordering during page preview cancels until the stream resets',
    (tester) async {
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      await mount(tester, initial: 2, progress: progress);
      progress.value = -.6;
      await tester.pump();
      update(() => visibleEntries = [entries[2], entries[1], entries[0]]);
      await tester.pumpAndSettle();
      progress.value = -1;
      await tester.pumpAndSettle();
      expect(thumbX(tester), closeTo(center(tester, 2).dx, 1));
      expect(current, 2);
      expect(committed, isEmpty);
      progress.value = 0;
    },
  );

  testWidgets(
    'reduced motion keeps direct preview and settles without a spring',
    (tester) async {
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      await mount(tester, initial: 1, progress: progress, reduceMotion: true);
      progress.value = -.5;
      await tester.pump();
      expect(thumbX(tester), greaterThan(center(tester, 1).dx));
      progress.value = 0;
      await tester.pump();
      expect(thumbX(tester), closeTo(center(tester, 1).dx, 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'mouse thumb drag follows across cells and commits only on release',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(current, 0);
      expect(committed, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current, 4);
      expect(committed, [4]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('short or vertical drag returns to the original destination', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('destination-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(4, 35));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(current, 0);
    expect(committed, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping still opens every destination exactly once', (
    tester,
  ) async {
    await mount(tester);
    for (var i = 1; i < entries.length; i++) {
      await tester.tap(find.byKey(ValueKey('destination-$i')));
      await tester.pumpAndSettle();
      expect(current, i);
    }
    expect(committed, [1, 2, 3, 4, 5]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard navigation preserves bounds and stops when idle', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(current, 1);
    expect(committed, [1]);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'filtering destinations preserves selected IDs and click mapping',
    (tester) async {
      await mount(tester, initial: 3);
      update(
        () => visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('destination-2')), findsNothing);
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
            .dx,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('destination-3'))).dx,
          1,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('destination-5')));
      await tester.pumpAndSettle();
      expect(current, 5);
      expect(committed, [5]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('same-length ID reordering moves the thumb to the selected ID', (
    tester,
  ) async {
    await mount(tester, initial: 4);
    update(() => visibleEntries = [entries[4], ...entries.take(4), entries[5]]);
    await tester.pumpAndSettle();
    expect(current, 4);
    expect(committed, isEmpty);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))).dx,
        1,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removing an ID during drag cancels remaining move and release', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('destination-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('destination-4'))),
    );
    await tester.pump();
    update(
      () => visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
    );
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('destination-5'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(current, 0);
    expect(committed, isEmpty);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))).dx,
        1,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'external selection during drag cannot be overwritten on release',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))),
      );
      await tester.pump();
      update(() => current = 1);
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-5'))),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current, 1);
      expect(committed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final direction in [
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
  ]) {
    testWidgets(
      'a hidden selected value has no false highlight and $direction chooses an edge',
      (tester) async {
        await mount(tester, initial: 2);
        update(
          () =>
              visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
        );
        await tester.pumpAndSettle();
        expect(current, 2);
        expect(
          find.byKey(const ValueKey('cinema-navigation-thumb')),
          findsNothing,
        );
        final selection = find.descendant(
          of: find.byType(CinemaNavigationIsland<int>),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.selected == true,
          ),
        );
        expect(selection, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(direction);
        await tester.pumpAndSettle();
        final expected = direction == LogicalKeyboardKey.arrowRight ? 0 : 5;
        expect(current, expected);
        expect(committed, [expected]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
