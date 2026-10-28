import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_history_swipe_actions.dart';
import 'package:kazumi/features/cinema/cinema_swipe_navigation.dart';

void main() {
  var opened = 0, deleted = 0, navigated = 0, backs = 0, forwards = 0;
  final previews = <double>[];
  late Future<bool> Function() remove;

  Future<void> mount(
    WidgetTester tester, {
    bool reduced = false,
    bool navigation = false,
  }) async {
    opened = deleted = navigated = 0;
    backs = forwards = 0;
    previews.clear();
    remove = () async {
      deleted++;
      return true;
    };
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: CinemaSwipeNavigation(
              onProgress: previews.add,
              onBack: navigation
                  ? () {
                      backs++;
                      navigated++;
                    }
                  : null,
              onForward: navigation
                  ? () {
                      forwards++;
                      navigated++;
                    }
                  : null,
              child: ListView(
                children: [
                  const SizedBox(height: 80, child: Text('header')),
                  for (var i = 0; i < 3; i++)
                    CinemaHistorySwipeActions(
                      key: ValueKey('row-$i'),
                      onDelete: () => remove(),
                      child: SizedBox(
                        height: 100,
                        child: ListTile(
                          key: ValueKey('play-$i'),
                          title: Text('video-$i'),
                          onTap: () => opened++,
                        ),
                      ),
                    ),
                  const SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder row(int index) => find.byKey(ValueKey('row-$index'));
  Finder action(int index) => find.descendant(
    of: row(index),
    matching: find.byKey(const ValueKey('cinema-history-delete')),
  );
  double offset(WidgetTester tester, int index) => tester
      .widget<Transform>(
        find.descendant(
          of: row(index),
          matching: find.byKey(const ValueKey('cinema-history-swipe-offset')),
        ),
      )
      .transform
      .storage[12];

  Future<void> swipe(
    WidgetTester tester,
    int index,
    Offset delta, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(row(index)),
      kind: kind,
    );
    await gesture.moveBy(delta / 2);
    await gesture.moveBy(delta / 2);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  var device = 500;
  Future<void> pan(
    WidgetTester tester,
    int index,
    Offset delta, {
    double scale = 1,
    double rotation = 0,
    int? nativeDevice,
    int stamp = 10000,
  }) async {
    final point = tester.getCenter(row(index));
    final id = nativeDevice ?? device++;
    await tester.sendEventToBinding(
      PointerPanZoomStartEvent(
        pointer: id,
        device: id,
        timeStamp: Duration(milliseconds: stamp),
        position: point,
      ),
    );
    await tester.sendEventToBinding(
      PointerPanZoomUpdateEvent(
        pointer: id,
        device: id,
        timeStamp: Duration(milliseconds: stamp + 20),
        position: point,
        pan: delta,
        panDelta: delta,
        scale: scale,
        rotation: rotation,
      ),
    );
    await tester.sendEventToBinding(
      PointerPanZoomEndEvent(
        pointer: id,
        device: id,
        timeStamp: Duration(milliseconds: stamp + 40),
        position: point,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> wheel(
    WidgetTester tester,
    int index,
    Offset delta, {
    int? id,
    int stamp = 20000,
  }) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        device: id ?? device++,
        timeStamp: Duration(milliseconds: stamp),
        position: tester.getCenter(row(index)),
        scrollDelta: delta,
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
  }

  testWidgets('touch swipe reveals; only explicit button press deletes', (
    tester,
  ) async {
    await mount(tester);
    expect(action(0), findsNothing);
    await swipe(tester, 0, const Offset(-220, 0));
    expect(offset(tester, 0), -92);
    expect(action(0), findsOneWidget);
    expect(opened, 0);
    expect(deleted, 0);
    expect(navigated, 0);
    await tester.tap(action(0));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(action(0), findsNothing);
    await tester.tap(find.byKey(const ValueKey('play-0')));
    expect(opened, 1);
  });

  testWidgets('open row absorbs first tap and next tap opens normally', (
    tester,
  ) async {
    await mount(tester);
    await swipe(tester, 0, const Offset(-100, 0));
    await tester.tapAt(tester.getCenter(row(0)));
    await tester.pumpAndSettle();
    expect(action(0), findsNothing);
    expect(opened, 0);
    await tester.tap(find.text('video-0'));
    expect(opened, 1);
  });

  testWidgets('right swipe closes and only one row is open', (tester) async {
    await mount(tester);
    await swipe(tester, 0, const Offset(-100, 0));
    await swipe(tester, 1, const Offset(-100, 0));
    expect(action(0), findsNothing);
    expect(action(1), findsOneWidget);
    await swipe(tester, 1, const Offset(70, 0));
    expect(action(1), findsNothing);
    expect(deleted, 0);
    expect(navigated, 0);
  });

  testWidgets('short swipe returns and vertical movement keeps scrolling', (
    tester,
  ) async {
    await mount(tester);
    await swipe(tester, 0, const Offset(-25, 0));
    expect(offset(tester, 0), 0);
    expect(action(0), findsNothing);
    await swipe(tester, 0, const Offset(0, -70));
    expect(action(0), findsNothing);
    expect(deleted, 0);
    expect(opened, 0);
    expect(navigated, 0);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
  });

  testWidgets('mouse drag reveals without opening or deleting', (tester) async {
    await mount(tester);
    await swipe(
      tester,
      0,
      const Offset(-100, 0),
      kind: PointerDeviceKind.mouse,
    );
    expect(action(0), findsOneWidget);
    expect(opened, 0);
    expect(deleted, 0);
    expect(navigated, 0);
  });

  testWidgets('trackpad pan belongs to row and never changes page', (
    tester,
  ) async {
    await mount(tester);
    await pan(tester, 0, const Offset(-120, 0));
    expect(action(0), findsOneWidget);
    expect(offset(tester, 0), -92);
    expect(navigated, 0);
    expect(deleted, 0);
    await pan(tester, 0, const Offset(120, 0));
    expect(action(0), findsNothing);
    expect(navigated, 0);
  });

  testWidgets('horizontal pan owns small vertical drift on a scrolled list', (
    tester,
  ) async {
    await mount(tester);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    scroll.jumpTo(40);
    await tester.pumpAndSettle();
    await pan(tester, 0, const Offset(-120, 20));
    expect(action(0), findsOneWidget);
    expect(scroll.pixels, 40);
    expect(navigated, 0);
  });

  for (final sample in [
    (const Offset(-80, 90), 1.0, 0.0),
    (const Offset(-100, 0), 1.1, 0.0),
    (const Offset(-100, 0), 1.0, .2),
  ]) {
    testWidgets('diagonal or transformed pan $sample does not reveal', (
      tester,
    ) async {
      await mount(tester);
      await pan(tester, 0, sample.$1, scale: sample.$2, rotation: sample.$3);
      expect(action(0), findsNothing);
      expect(deleted, 0);
      expect(navigated, 0);
    });
  }

  testWidgets('horizontal wheel reveals and tail cannot close another row', (
    tester,
  ) async {
    await mount(tester);
    final id = device++;
    await wheel(tester, 0, const Offset(100, 0), id: id);
    expect(action(0), findsOneWidget);
    await wheel(tester, 1, const Offset(120, 0), id: id, stamp: 20200);
    expect(action(0), findsOneWidget);
    expect(action(1), findsNothing);
    expect(navigated, 0);
    expect(deleted, 0);
    await wheel(tester, 1, const Offset(100, 0), id: id, stamp: 21200);
    expect(action(0), findsNothing);
    expect(action(1), findsOneWidget);
  });

  testWidgets(
    'vertical wheel closes exposed action and continues list scroll',
    (tester) async {
      await mount(tester);
      await swipe(tester, 0, const Offset(-100, 0));
      await wheel(tester, 0, const Offset(0, 25));
      expect(action(0), findsNothing);
      expect(deleted, 0);
      expect(navigated, 0);
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        greaterThan(0),
      );
    },
  );

  testWidgets(
    'horizontal wheel owns small dy while vertical browsing stays locked',
    (tester) async {
      await mount(tester);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      scroll.jumpTo(40);
      await tester.pumpAndSettle();
      await wheel(tester, 0, const Offset(80, 5));
      expect(scroll.pixels, 40);
      expect(action(0), findsOneWidget);
      final id = device++;
      await wheel(tester, 0, const Offset(0, 6), id: id, stamp: 30000);
      expect(action(0), findsNothing);
      final scrolled = scroll.pixels;
      expect(scrolled, greaterThan(40));
      // A diagonal tail in the same vertical stream must never become delete.
      await wheel(tester, 0, const Offset(100, 1), id: id, stamp: 30080);
      expect(action(0), findsNothing);
      expect(deleted, 0);
      expect(navigated, 0);
      await wheel(tester, 0, const Offset(90, 1), id: id, stamp: 31000);
      expect(action(0), findsOneWidget);
    },
  );

  testWidgets('button is disabled while deletion awaits and failure closes', (
    tester,
  ) async {
    await mount(tester);
    final pending = Completer<bool>();
    remove = () {
      deleted++;
      return pending.future;
    };
    await swipe(tester, 0, const Offset(-100, 0));
    await tester.tap(action(0));
    await tester.pump();
    await tester.tap(action(0));
    expect(deleted, 1);
    expect(tester.widget<TextButton>(action(0)).onPressed, isNull);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(action(0), findsNothing);
    await tester.tap(find.text('video-0'));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion snaps; no timer or ticker survives disposal', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await swipe(tester, 0, const Offset(-100, 0));
    expect(offset(tester, 0), -92);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        device: device++,
        timeStamp: const Duration(seconds: 40),
        position: tester.getCenter(row(1)),
        scrollDelta: const Offset(50, 0),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal swipe outside rows still changes destination', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    await tester.dragFrom(const Offset(300, 40), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(navigated, 1);
    expect(deleted, 0);
  });

  testWidgets('closed left swipe reveals; next left swipe navigates once', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    await swipe(tester, 0, const Offset(-400, 0));
    expect(action(0), findsOneWidget);
    expect(navigated, 0);
    expect(previews.where((value) => value != 0), isEmpty);
    await swipe(tester, 0, const Offset(-160, 0));
    expect(forwards, 1);
    expect(backs, 0);
    expect(deleted, 0);
    expect(action(0), findsNothing);
    expect(previews, contains(-1));
    expect(previews.last, 0);
  });

  testWidgets(
    'right swipe on a closed row immediately previews previous page',
    (tester) async {
      await mount(tester, navigation: true);
      await swipe(tester, 0, const Offset(180, 0));
      expect(backs, 1);
      expect(forwards, 0);
      expect(action(0), findsNothing);
      expect(previews, contains(1));
      expect(previews.last, 0);
      expect(opened, 0);
      expect(deleted, 0);
    },
  );

  testWidgets('short, canceled and vertical handoffs never navigate', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    await swipe(tester, 0, const Offset(-180, 0));
    await tester.timedDrag(
      row(0),
      const Offset(-60, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(forwards, 0);
    expect(action(0), findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(row(0)));
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(find.byKey(const ValueKey('cinema-swipe-feedback')), findsOneWidget);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(forwards, 0);
    expect(previews.last, 0);
    expect(action(0), findsOneWidget);
    await swipe(tester, 0, const Offset(0, -60));
    expect(navigated, 0);
    expect(action(0), findsNothing);
  });

  testWidgets('one stream cannot change its purpose by reversing direction', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    var gesture = await tester.startGesture(tester.getCenter(row(0)));
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.moveBy(const Offset(320, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(navigated, 0);
    expect(action(0), findsNothing);
    await swipe(tester, 0, const Offset(-160, 0));
    gesture = await tester.startGesture(tester.getCenter(row(0)));
    await gesture.moveBy(const Offset(-100, 0));
    await gesture.moveBy(const Offset(240, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(navigated, 0);
    expect(action(0), findsOneWidget);
    expect(previews.last, 0);
  });

  testWidgets('short right swipe closes an open row without changing page', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    await swipe(tester, 0, const Offset(-160, 0));
    await tester.timedDrag(
      row(0),
      const Offset(65, 0),
      const Duration(seconds: 1),
    );
    await tester.pumpAndSettle();
    expect(navigated, 0);
    expect(action(0), findsNothing);
  });

  testWidgets('consecutive phased trackpad gestures reveal then navigate', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    final id = device++;
    await pan(tester, 0, const Offset(-180, 0), nativeDevice: id, stamp: 80000);
    expect(action(0), findsOneWidget);
    expect(forwards, 0);
    await pan(tester, 0, const Offset(-180, 0), nativeDevice: id, stamp: 80050);
    expect(forwards, 1);
    expect(backs, 0);
    expect(deleted, 0);
  });

  for (final phased in [false, true]) {
    testWidgets(
      'native handoff (phased:$phased) guards next page against momentum',
      (tester) async {
        var page = 0, switches = 0;
        final id = device++;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) {
                  return CinemaSwipeNavigation(
                    destination: page,
                    onBack: () => update(() {
                      page--;
                      switches++;
                    }),
                    onForward: () => update(() {
                      page++;
                      switches++;
                    }),
                    child: page == 0
                        ? ListView(
                            children: [
                              const SizedBox(height: 80),
                              CinemaHistorySwipeActions(
                                key: const ValueKey('row-0'),
                                onDelete: () async => true,
                                child: const SizedBox(height: 100),
                              ),
                            ],
                          )
                        : const SizedBox.expand(key: ValueKey('next-screen')),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (phased) {
          await pan(
            tester,
            0,
            const Offset(-180, 0),
            nativeDevice: id,
            stamp: 90000,
          );
        } else {
          await wheel(tester, 0, const Offset(180, 0), id: id, stamp: 90000);
        }
        expect(switches, 0);
        if (phased) {
          await pan(
            tester,
            0,
            const Offset(-180, 0),
            nativeDevice: id,
            stamp: 90050,
          );
        } else {
          await wheel(tester, 0, const Offset(180, 0), id: id, stamp: 91000);
        }
        expect(switches, 1);
        expect(find.byKey(const ValueKey('next-screen')), findsOneWidget);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            device: id,
            timeStamp: Duration(milliseconds: phased ? 90200 : 91200),
            position: const Offset(300, 130),
            scrollDelta: const Offset(180, 0),
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pumpAndSettle();
        expect(switches, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('native wheel outside rows retains page navigation', (
    tester,
  ) async {
    await mount(tester, navigation: true);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        device: device++,
        timeStamp: const Duration(seconds: 60),
        position: const Offset(300, 40),
        scrollDelta: const Offset(150, 0),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(navigated, 1);
    expect(deleted, 0);
  });
}
