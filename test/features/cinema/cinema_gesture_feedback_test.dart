import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_navigation_island.dart';
import 'package:kazumi/features/cinema/cinema_swipe_navigation.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? back,
    VoidCallback? forward,
    ValueChanged<double>? onProgress,
    bool reduced = false,
    Object? destination,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: CinemaSwipeNavigation(
              destination: destination,
              onBack: back,
              onForward: forward,
              onProgress: onProgress,
              backLabel: '电影',
              forwardLabel: '继续观看',
              child: const ColoredBox(
                color: Colors.black,
                key: ValueKey('feedback-surface'),
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('partial touch previews its target and cancellation resets it', (
    tester,
  ) async {
    var committed = 0;
    final progress = <double>[];
    await mount(tester, back: () => committed++, onProgress: progress.add);
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    expect(progress.last, inExclusiveRange(0, 1));
    expect(find.text('电影'), findsOneWidget);
    expect(committed, 0);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(progress.last, 0);
    expect(committed, 0);
    expect(find.byKey(const ValueKey('cinema-swipe-feedback')), findsNothing);
  });

  testWidgets('threshold commit resets the linked preview before navigation', (
    tester,
  ) async {
    var value = 0.0;
    final atCommit = <double>[];
    await mount(
      tester,
      back: () => atCommit.add(value),
      onProgress: (v) => value = v,
    );
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(70, 0));
    await gesture.moveBy(const Offset(70, 0));
    await tester.pump();
    expect(value, 1);
    expect(atCommit, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(atCommit, [0]);
    expect(value, 0);
  });

  testWidgets(
    'short release and reduced motion finish without idle animation',
    (tester) async {
      var commits = 0;
      var value = 0.0;
      await mount(
        tester,
        back: () => commits++,
        onProgress: (v) => value = v,
        reduced: true,
      );
      await tester.timedDrag(
        find.byKey(const ValueKey('feedback-surface')),
        const Offset(40, 0),
        const Duration(milliseconds: 500),
      );
      await tester.pump();
      expect(commits, 0);
      expect(value, 0);
      expect(find.byKey(const ValueKey('cinema-swipe-feedback')), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('an unavailable direction never advertises a destination', (
    tester,
  ) async {
    final progress = <double>[];
    await mount(tester, forward: () {}, onProgress: progress.add);
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(80, 0));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(progress, isNotEmpty);
    expect(progress.every((v) => v == 0), isTrue);
    expect(find.byKey(const ValueKey('cinema-swipe-feedback')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('external destination changes invalidate the active gesture', (
    tester,
  ) async {
    var commits = 0;
    var value = 0.0;
    await mount(
      tester,
      back: () => commits++,
      onProgress: (v) => value = v,
      destination: 'first',
    );
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(70, 0));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(value, greaterThan(0));
    await mount(
      tester,
      back: () => commits++,
      onProgress: (v) => value = v,
      destination: 'second',
    );
    expect(value, 0);
    await gesture.moveBy(const Offset(160, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(commits, 0);
  });

  testWidgets(
    'vertical wheel owns its diagonal tail until the stream is quiet',
    (tester) async {
      var commits = 0;
      await mount(tester, back: () => commits++);
      Future<void> wheel(Offset delta, int milliseconds) =>
          tester.sendEventToBinding(
            PointerScrollEvent(
              device: 914,
              position: const Offset(200, 200),
              timeStamp: Duration(milliseconds: milliseconds),
              scrollDelta: delta,
            ),
          );
      await wheel(const Offset(2, -60), 1000);
      await tester.pump(const Duration(milliseconds: 30));
      await wheel(const Offset(-140, -10), 1030);
      await tester.pump(const Duration(milliseconds: 200));
      expect(commits, 0);
      await wheel(const Offset(-140, 0), 1300);
      await tester.pumpAndSettle(const Duration(milliseconds: 150));
      expect(commits, 1);
    },
  );

  for (final interruption in ['vertical', 'pinch', 'rotation']) {
    testWidgets('native pan zoom $interruption cancels page navigation', (
      tester,
    ) async {
      var commits = 0;
      var progress = 0.0;
      await mount(
        tester,
        back: () => commits++,
        onProgress: (v) => progress = v,
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      const anchor = Offset(200, 200);
      await gesture.panZoomStart(anchor);
      if (interruption == 'vertical') {
        await gesture.panZoomUpdate(anchor, pan: const Offset(2, 40));
      } else {
        await gesture.panZoomUpdate(anchor, pan: const Offset(50, 0));
        expect(progress, greaterThan(0));
        await gesture.panZoomUpdate(
          anchor,
          pan: const Offset(70, 0),
          scale: interruption == 'pinch' ? 1.1 : 1,
          rotation: interruption == 'rotation' ? .1 : 0,
        );
      }
      await gesture.panZoomUpdate(anchor, pan: const Offset(180, 0));
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(progress, 0);
      expect(commits, 0);
    });
  }

  testWidgets('reversing a short swipe does not commit the old direction', (
    tester,
  ) async {
    var commits = 0;
    var progress = 0.0;
    await mount(tester, back: () => commits++, onProgress: (v) => progress = v);
    final gesture = await tester.createGesture();
    await gesture.down(
      const Offset(200, 200),
      timeStamp: const Duration(seconds: 10),
    );
    await gesture.moveBy(
      const Offset(40, 0),
      timeStamp: const Duration(milliseconds: 10100),
    );
    await gesture.moveBy(
      const Offset(50, 0),
      timeStamp: const Duration(milliseconds: 10200),
    );
    await gesture.moveBy(
      const Offset(-20, 0),
      timeStamp: const Duration(milliseconds: 10210),
    );
    await tester.pump();
    expect(progress, inExclusiveRange(0, 1));
    await gesture.up(timeStamp: const Duration(milliseconds: 10211));
    await tester.pumpAndSettle();
    expect(commits, 0);
  });

  testWidgets(
    'page preview follows the island then settles on commit or cancel',
    (tester) async {
      final preview = ValueNotifier<double>(0);
      var selected = 1;
      final commits = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => CinemaSwipeNavigation(
                destination: selected,
                onProgress: (v) => preview.value = v,
                onBack: selected > 0
                    ? () => update(() {
                        selected--;
                        commits.add(selected);
                      })
                    : null,
                onForward: selected < 2
                    ? () => update(() {
                        selected++;
                        commits.add(selected);
                      })
                    : null,
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const SizedBox(key: ValueKey('linked-surface')),
                      Positioned(
                        left: 100,
                        right: 100,
                        bottom: 20,
                        child: Center(
                          child: CinemaNavigationIsland<int>(
                            value: selected,
                            swipeProgress: preview,
                            destinations: const [
                              (0, Icons.movie, '电影'),
                              (1, Icons.tv, '剧集'),
                              (2, Icons.history, '继续观看'),
                            ],
                            keyFor: (v) => ValueKey('linked-$v'),
                            onChanged: (v) => update(() => selected = v),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      double thumbX() => tester
          .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
          .dx;
      final origin = thumbX();
      final partial = await tester.startGesture(const Offset(300, 180));
      await partial.moveBy(const Offset(-40, 0));
      await partial.moveBy(const Offset(-10, 0));
      await tester.pump();
      expect(selected, 1);
      expect(thumbX(), greaterThan(origin));
      await partial.cancel();
      await tester.pumpAndSettle();
      expect(thumbX(), closeTo(origin, .1));
      expect(commits, isEmpty);

      final full = await tester.startGesture(const Offset(300, 180));
      await full.moveBy(const Offset(-70, 0));
      await full.moveBy(const Offset(-70, 0));
      await tester.pump();
      expect(selected, 1);
      expect(thumbX(), greaterThan(origin));
      await full.up();
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(commits, [2]);
      expect(
        thumbX(),
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('linked-2'))).dx,
          .1,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      preview.dispose();
    },
  );
}
