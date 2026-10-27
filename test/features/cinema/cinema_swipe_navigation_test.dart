import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_swipe_navigation.dart';
import 'package:kazumi/features/cinema/cinema_route_motion.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? back,
    VoidCallback? forward,
    Widget? child,
    bool edge = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CinemaSwipeNavigation(
            onBack: back,
            onForward: forward,
            edgeOnly: edge,
            child:
                child ??
                const ColoredBox(
                  color: Colors.black,
                  key: ValueKey('surface'),
                  child: SizedBox.expand(),
                ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'touch swipe follows finger, commits once and rejects vertical or short movement',
    (tester) async {
      var backs = 0, forwards = 0;
      await mount(tester, back: () => backs++, forward: () => forwards++);
      final gesture = await tester.startGesture(const Offset(170, 240));
      await gesture.moveBy(const Offset(65, 0));
      await gesture.moveBy(const Offset(65, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('cinema-swipe-feedback')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 1);
      await tester.drag(
        find.byKey(const ValueKey('surface')),
        const Offset(0, -200),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 1);
      await tester.drag(
        find.byKey(const ValueKey('surface')),
        const Offset(-160, 0),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(forwards, 1);
      await tester.timedDrag(
        find.byKey(const ValueKey('surface')),
        const Offset(25, 0),
        const Duration(milliseconds: 500),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 1);
    },
  );

  testWidgets(
    'horizontal trackpad scroll commits and momentum cannot trigger another destination',
    (tester) async {
      var backs = 0;
      await mount(tester, back: () => backs++);
      var stamp = Duration.zero;
      Future<void> wheel(Offset delta) async {
        stamp += const Duration(milliseconds: 150);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            device: 42,
            timeStamp: stamp,
            position: const Offset(130, 240),
            scrollDelta: delta,
          ),
        );
      }

      await wheel(const Offset(-120, 1));
      await tester.pump(const Duration(milliseconds: 150));
      expect(backs, 1);
      await wheel(const Offset(-140, 0));
      await tester.pump(const Duration(milliseconds: 150));
      expect(backs, 1);
      await tester.pump(const Duration(milliseconds: 600));
      await wheel(const Offset(0, -160));
      await tester.pump(const Duration(milliseconds: 150));
      expect(backs, 1);
    },
  );

  testWidgets(
    'hero/island exclusions and native horizontal lists keep their own movement',
    (tester) async {
      var backs = 0;
      await mount(
        tester,
        back: () => backs++,
        child: const CinemaSwipeExclusion(child: SizedBox.expand()),
      );
      await tester.drag(
        find.byType(CinemaSwipeExclusion),
        const Offset(180, 0),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 0);
      final scroll = ScrollController();
      await mount(
        tester,
        back: () => backs++,
        child: ListView(
          controller: scroll,
          scrollDirection: Axis.horizontal,
          children: const [SizedBox(width: 1600)],
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(backs, 0);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'slider keeps value adjustment and edge-limited pages ignore central drags',
    (tester) async {
      var backs = 0;
      double value = .5;
      await mount(
        tester,
        back: () => backs++,
        child: Center(
          child: SizedBox(
            width: 400,
            child: CinemaSwipeExclusion(
              child: StatefulBuilder(
                builder: (_, update) => Slider(
                  value: value,
                  onChanged: (v) => update(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(Slider), const Offset(135, 0));
      await tester.pump(const Duration(milliseconds: 600));
      expect(value, greaterThan(.5));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          device: 63,
          timeStamp: const Duration(seconds: 1),
          position: tester.getCenter(find.byType(Slider)),
          scrollDelta: const Offset(-150, 0),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(backs, 0);
      await mount(tester, back: () => backs++, edge: true);
      await tester.dragFrom(const Offset(200, 240), const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 0);
      await tester.dragFrom(const Offset(12, 240), const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 600));
      expect(backs, 1);
    },
  );

  testWidgets(
    'ordinary page uses existing Navigator pop and preserves the home state',
    (tester) async {
      final input = TextEditingController(text: 'keep');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.macOS: CinemaPageTransitionsBuilder()},
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextField(controller: input),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(body: Text('details')),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(100, 240), const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(find.text('details'), findsNothing);
      expect(input.text, 'keep');
      await tester.pumpWidget(const SizedBox());
      input.dispose();
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
  for (final name in ['naku-native-player', '/video/']) {
    testWidgets(
      'playback route $name is never given application navigation gestures',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.macOS: CinemaPageTransitionsBuilder(),
                },
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: RouteSettings(name: name),
                      builder: (_) =>
                          const Scaffold(body: Text('playback only')),
                    ),
                  ),
                  child: const Text('open player'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open player'));
        await tester.pumpAndSettle();
        expect(find.byType(CinemaSwipeNavigation), findsNothing);
        await tester.dragFrom(const Offset(12, 240), const Offset(180, 0));
        await tester.pumpAndSettle();
        expect(find.text('playback only'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.macOS}),
    );
  }
}
