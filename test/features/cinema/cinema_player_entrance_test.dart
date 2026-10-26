import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_player_entrance.dart';

class _Counter extends StatefulWidget {
  const _Counter({super.key});
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int value = 0, builds = 0;
  @override
  Widget build(BuildContext context) {
    builds++;
    return ColoredBox(
      color: const Color(0xFF8090A0),
      child: Center(
        child: TextButton(
          onPressed: () => setState(() => value++),
          child: Text('播放器操作 $value'),
        ),
      ),
    );
  }
}

void main() {
  var generation = 0;
  var ready = false, hasError = false, enabled = true;
  var animateOnEntry = true;
  var reduceMotion = false, systemReduceMotion = false, tickerEnabled = true;
  var reveals = 0, cancellations = 0;
  var loadStage = CinemaPlayerLoadStage.connecting;
  late GlobalKey<_CounterState> childKey;

  Widget host() => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: systemReduceMotion),
      child: TickerMode(
        enabled: tickerEnabled,
        child: SizedBox(
          width: 640,
          height: 360,
          child: RepaintBoundary(
            key: const ValueKey('test-player-stage'),
            child: CinemaPlayerEntrance(
              generation: generation,
              ready: ready,
              hasError: hasError,
              enabled: enabled,
              animateOnEntry: animateOnEntry,
              reduceMotion: reduceMotion,
              loadStage: loadStage,
              onReveal: () => reveals++,
              onCancel: () => cancellations++,
              child: _Counter(key: childKey),
            ),
          ),
        ),
      ),
    ),
  );

  CinemaPlayerEntranceState state(WidgetTester tester) => tester
      .state<CinemaPlayerEntranceState>(find.byType(CinemaPlayerEntrance));

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  setUp(() {
    generation = 0;
    ready = false;
    hasError = false;
    enabled = true;
    animateOnEntry = true;
    reduceMotion = false;
    systemReduceMotion = false;
    tickerEnabled = true;
    reveals = 0;
    cancellations = 0;
    loadStage = CinemaPlayerLoadStage.connecting;
    childKey = GlobalKey<_CounterState>();
  });

  Future<void> expectDarkWithTopLamp(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('test-player-stage')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final width = image.width, height = image.height;
      int red(int x, int y) => pixels.getUint8((y * width + x) * 4);
      // The waiting indicator lights only the tube. No light field or visible
      // media/content is admitted anywhere in the body before the first frame.
      for (final fraction in [.35, .50, .80]) {
        final offset = ((height * fraction).floor() * width + width ~/ 2) * 4;
        expect(pixels.getUint8(offset), 0);
        expect(pixels.getUint8(offset + 1), 0);
        expect(pixels.getUint8(offset + 2), 0);
        expect(pixels.getUint8(offset + 3), 255);
      }
      expect(red(width ~/ 2, (height * .065).floor()), greaterThan(0));
      image.dispose();
    });
  }

  testWidgets('exit-only surfaces start idle without a lamp or sound hook', (
    tester,
  ) async {
    animateOnEntry = false;
    ready = true;
    await mount(tester);
    final surface = state(tester);
    expect(surface.debugPhase, 'complete');
    expect(surface.debugIsAnimating, isFalse);
    expect(surface.debugLampExtent, 0);
    expect(surface.debugLampTarget, 0);
    final frames = surface.debugFrameCount;
    await tester.pump(const Duration(seconds: 3));
    expect(surface.debugFrameCount, frames);
    expect(reveals, 0);
    expect(cancellations, 0);
    await tester.tap(find.text('播放器操作 0'));
    await tester.pump();
    expect(childKey.currentState!.value, 1);
    generation++;
    ready = false;
    loadStage = CinemaPlayerLoadStage.waitingForFrame;
    await tester.pumpWidget(host());
    ready = true;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 2));
    expect(surface.debugPhase, 'complete');
    expect(surface.debugLampExtent, 0);
    expect(surface.debugIsAnimating, isFalse);
    expect(reveals, 0);
    expect(cancellations, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit-only closing runs once and retains the mounted surface', (
    tester,
  ) async {
    animateOnEntry = false;
    ready = true;
    await mount(tester);
    final surface = state(tester);
    final child = childKey.currentState!;
    var completions = 0;
    final future = surface.closeForExit();
    future.then((_) => completions++);
    expect(surface.closeForExit(), same(future));
    await tester.pump();
    expect(surface.debugPhase, 'exiting');
    final builds = child.builds;
    await tester.pump(const Duration(milliseconds: 250));
    expect(surface.debugProgress, inExclusiveRange(0, 1));
    expect(surface.debugLampExtent, 0);
    expect(completions, 0);
    expect(childKey.currentState, same(child));
    expect(child.builds, builds);
    await tester.pump(const Duration(milliseconds: 251));
    expect(surface.debugPhase, 'exited');
    await future;
    await tester.pump();
    expect(surface.debugPhase, 'exited');
    expect(surface.debugIsAnimating, isFalse);
    expect(completions, 1);
    expect(childKey.currentState, same(child));
    // Changing the outer generation cannot replay an entry after exit.
    generation++;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 2));
    expect(surface.debugPhase, 'exited');
    expect(reveals, 0);
    expect(cancellations, 0);
    expect(tester.takeException(), isNull);
  });

  for (final reason in [
    'reduce',
    'system',
    'disabled',
    'ticker',
    'background',
  ]) {
    testWidgets('exit-only $reason skips closing without an entry reveal', (
      tester,
    ) async {
      animateOnEntry = false;
      ready = true;
      reduceMotion = reason == 'reduce';
      systemReduceMotion = reason == 'system';
      enabled = reason != 'disabled';
      tickerEnabled = reason != 'ticker';
      await mount(tester);
      final surface = state(tester);
      expect(surface.debugPhase, 'complete');
      if (reason == 'background') {
        surface.didChangeAppLifecycleState(AppLifecycleState.hidden);
      }
      await surface.closeForExit();
      await tester.pump();
      expect(surface.debugPhase, 'exited');
      expect(surface.debugIsAnimating, isFalse);
      expect(surface.debugLampExtent, 0);
      expect(reveals, 0);
      expect(cancellations, 0);
      surface.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 2));
      expect(surface.debugPhase, 'exited');
      expect(surface.debugIsAnimating, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('real observations extend the waiting tube continuously', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 501));
    final surface = state(tester);
    final child = childKey.currentState;
    expect(surface.debugPhase, 'waiting');
    expect(surface.debugLoadStage, CinemaPlayerLoadStage.connecting);
    final initialExtent = surface.debugLampExtent;
    final idleFrames = surface.debugFrameCount;
    await tester.pump(const Duration(seconds: 5));
    expect(surface.debugLampExtent, initialExtent);
    expect(surface.debugFrameCount, idleFrames);
    expect(surface.debugIsAnimating, isFalse);

    loadStage = CinemaPlayerLoadStage.opening;
    await tester.pumpWidget(host());
    expect(surface.debugLampExtent, initialExtent);
    expect(surface.debugLampTarget, greaterThan(initialExtent));
    expect(surface.debugIsAnimating, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final interruptedExtent = surface.debugLampExtent;
    final interruptedVelocity = surface.debugLampVelocity;
    expect(interruptedExtent, greaterThan(initialExtent));
    expect(interruptedExtent, lessThan(surface.debugLampTarget));
    expect(interruptedVelocity, greaterThan(0));
    await expectDarkWithTopLamp(tester);

    loadStage = CinemaPlayerLoadStage.waitingForFrame;
    await tester.pumpWidget(host());
    // A new observation changes the destination without snapping position or
    // restarting from zero velocity, even in the middle of the previous curve.
    expect(surface.debugLampExtent, interruptedExtent);
    expect(surface.debugLampVelocity, closeTo(interruptedVelocity, .00001));
    expect(surface.debugLampExtent, lessThan(surface.debugLampTarget));
    await tester.pump();
    var previous = interruptedExtent;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final extent = surface.debugLampExtent;
      expect(extent, greaterThanOrEqualTo(previous));
      expect(extent - previous, lessThan(.055));
      expect(extent, lessThanOrEqualTo(surface.debugLampTarget));
      previous = extent;
    }
    expect(surface.debugLampExtent, surface.debugLampTarget);
    expect(surface.debugLampExtent, lessThan(1));
    expect(surface.debugPhase, 'waiting');
    expect(surface.debugIsAnimating, isFalse);
    expect(reveals, 0);
    await expectDarkWithTopLamp(tester);
    final settledFrames = surface.debugFrameCount;
    await tester.pump(const Duration(seconds: 20));
    expect(surface.debugFrameCount, settledFrames);
    expect(surface.debugLampExtent, previous);

    // Lower transient milestones cannot make the same source's tube retreat.
    loadStage = CinemaPlayerLoadStage.connecting;
    await tester.pumpWidget(host());
    expect(surface.debugLampExtent, previous);
    expect(surface.debugIsAnimating, isFalse);
    ready = true;
    await tester.pumpWidget(host());
    expect(surface.debugPhase, 'lighting');
    expect(surface.debugLampExtent, previous);
    expect(reveals, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1551));
    expect(surface.debugPhase, 'complete');
    expect(childKey.currentState, same(child));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a fast first frame continues the painted lamp and only repaints its light',
    (tester) async {
      await mount(tester);
      await tester.pump(const Duration(milliseconds: 501));
      final surface = state(tester);
      loadStage = CinemaPlayerLoadStage.opening;
      await tester.pumpWidget(host());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final paintedExtent = surface.debugLampExtent;
      expect(paintedExtent, lessThan(surface.debugLampTarget));
      ready = true;
      loadStage = CinemaPlayerLoadStage.waitingForFrame;
      await tester.pumpWidget(host());
      expect(surface.debugPhase, 'lighting');
      expect(surface.debugLampExtent, closeTo(paintedExtent, 1e-9));
      expect(reveals, 1);
      final content = tester.widget<Transform>(
        find.byKey(const ValueKey('cinema-player-entrance-content')),
      );
      final builds = childKey.currentState!.builds;
      await tester.pump();
      var previous = paintedExtent;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final extent = surface.debugLampExtent;
        expect(extent, greaterThan(previous));
        expect(extent - previous, lessThan(.055));
        previous = extent;
        expect(
          tester.widget<Transform>(
            find.byKey(const ValueKey('cinema-player-entrance-content')),
          ),
          same(content),
        );
        expect(childKey.currentState!.builds, builds);
      }
      expect(surface.debugPhase, 'lighting');
      await tester.pump(const Duration(milliseconds: 551));
      expect(surface.debugPhase, 'complete');
      expect(reveals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding stops a warming filament without a late tick', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 501));
    final surface = state(tester);
    loadStage = CinemaPlayerLoadStage.opening;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(surface.debugIsAnimating, isTrue);
    surface.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    expect(surface.debugIsAnimating, isFalse);
    final frames = surface.debugFrameCount;
    surface.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 4));
    expect(surface.debugFrameCount, frames);
    expect(surface.debugPhase, 'cancelled');
    expect(reveals, 0);
    generation++;
    loadStage = CinemaPlayerLoadStage.connecting;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 501));
    expect(surface.debugPhase, 'waiting');
    expect(surface.debugLampExtent, closeTo(.10, .0001));
    expect(surface.debugIsAnimating, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion still gates the dark body on the first frame', (
    tester,
  ) async {
    reduceMotion = true;
    loadStage = CinemaPlayerLoadStage.waitingForFrame;
    await mount(tester);
    final surface = state(tester);
    expect(surface.debugPhase, 'cancelled');
    expect(surface.debugIsAnimating, isFalse);
    await tester.pump(const Duration(seconds: 5));
    await expectDarkWithTopLamp(tester);
    expect(reveals, 0);
    ready = true;
    await tester.pumpWidget(host());
    expect(surface.debugPhase, 'cancelled');
    expect(surface.debugLampExtent, 0);
    expect(surface.debugIsAnimating, isFalse);
    expect(reveals, 0);
    await tester.tap(find.text('播放器操作 0'));
    expect(childKey.currentState!.value, 1);
    expect(tester.takeException(), isNull);
  });

  Future<CinemaPlayerEntranceState> completeEntrance(
    WidgetTester tester,
  ) async {
    ready = true;
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1551));
    expect(state(tester).debugPhase, 'complete');
    return state(tester);
  }

  testWidgets('exit closes once, retains the child and never lights again', (
    tester,
  ) async {
    final surface = await completeEntrance(tester);
    final original = childKey.currentState!;
    await tester.tap(find.text('播放器操作 0'));
    await tester.pump();
    var completions = 0;
    final future = surface.closeForExit();
    future.then((_) => completions++);
    expect(identical(surface.closeForExit(), future), isTrue);
    expect(surface.debugPhase, 'exiting');
    expect(cancellations, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(surface.debugPhase, 'exiting');
    expect(completions, 0);
    expect(childKey.currentState, same(original));
    generation++;
    ready = false;
    await tester.pumpWidget(host());
    ready = true;
    await tester.pumpWidget(host());
    expect(surface.debugPhase, 'exiting');
    await tester.pump(const Duration(milliseconds: 251));
    await future;
    expect(surface.debugPhase, 'exited');
    expect(surface.debugIsAnimating, isFalse);
    expect(completions, 1);
    expect(identical(surface.closeForExit(), future), isTrue);
    expect(childKey.currentState, same(original));
    expect(original.value, 1);
    expect(reveals, 1);
    generation++;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 3));
    expect(surface.debugPhase, 'exited');
    expect(reveals, 1);
    expect(
      find.byKey(const ValueKey('cinema-player-entrance-exited')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    expect(cancellations, 1);
    expect(tester.takeException(), isNull);
  });

  for (final pending in ['loading', 'waiting']) {
    testWidgets(
      '$pending exit finishes immediately without waiting for readiness',
      (tester) async {
        await mount(tester);
        if (pending == 'waiting') {
          await tester.pump(const Duration(milliseconds: 501));
        }
        final surface = state(tester);
        await surface.closeForExit();
        expect(surface.debugPhase, 'exited');
        expect(surface.debugIsAnimating, isFalse);
        ready = true;
        generation++;
        await tester.pumpWidget(host());
        await tester.pump(const Duration(seconds: 3));
        expect(surface.debugPhase, 'exited');
        expect(reveals, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('explicitly unanimated exit completes immediately', (
    tester,
  ) async {
    final surface = await completeEntrance(tester);
    await surface.closeForExit(animate: false);
    expect(surface.debugPhase, 'exited');
    expect(surface.debugIsAnimating, isFalse);
    expect(reveals, 1);
    expect(tester.takeException(), isNull);
  });

  for (final reason in ['reduce', 'error', 'disabled']) {
    testWidgets('$reason exit completes immediately without a lamp', (
      tester,
    ) async {
      ready = true;
      reduceMotion = reason == 'reduce';
      hasError = reason == 'error';
      enabled = reason != 'disabled';
      await mount(tester);
      final surface = state(tester);
      await surface.closeForExit();
      expect(surface.debugPhase, 'exited');
      expect(surface.debugIsAnimating, isFalse);
      expect(reveals, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('background exit completes immediately', (tester) async {
    final surface = await completeEntrance(tester);
    surface.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();
    await surface.closeForExit();
    expect(surface.debugPhase, 'exited');
    expect(surface.debugIsAnimating, isFalse);
    expect(reveals, 1);
    expect(tester.takeException(), isNull);
  });

  for (final reason in [
    'reduce',
    'system',
    'ticker',
    'error',
    'disabled',
    'background',
    'dispose',
  ]) {
    testWidgets(
      '$reason during exit completes the same future without a late reveal',
      (tester) async {
        final surface = await completeEntrance(tester);
        final original = childKey.currentState!;
        final future = surface.closeForExit();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(surface.debugPhase, 'exiting');
        switch (reason) {
          case 'reduce':
            reduceMotion = true;
          case 'system':
            systemReduceMotion = true;
          case 'ticker':
            tickerEnabled = false;
          case 'error':
            hasError = true;
          case 'disabled':
            enabled = false;
          case 'background':
            surface.didChangeAppLifecycleState(AppLifecycleState.hidden);
          case 'dispose':
            break;
        }
        await tester.pumpWidget(
          reason == 'dispose' ? const SizedBox() : host(),
        );
        await future;
        expect(surface.debugPhase, 'exited');
        if (reason != 'dispose') {
          expect(surface.debugIsAnimating, isFalse);
          expect(childKey.currentState, same(original));
        }
        expect(reveals, 1);
        expect(cancellations, 1);
        await tester.pump(const Duration(seconds: 3));
        expect(surface.debugPhase, 'exited');
        expect(reveals, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('early readiness still completes closing before revealing', (
    tester,
  ) async {
    ready = true;
    await mount(tester);
    expect(state(tester).debugPhase, 'closing');
    await tester.pump(const Duration(milliseconds: 499));
    expect(state(tester).debugPhase, 'closing');
    expect(reveals, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(state(tester).debugPhase, 'lighting');
    expect(reveals, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1549));
    expect(state(tester).debugPhase, 'lighting');
    await tester.pump(const Duration(milliseconds: 2));
    expect(state(tester).debugPhase, 'complete');
    expect(state(tester).debugIsAnimating, isFalse);
    expect(reveals, 1);
    await tester.pumpWidget(const SizedBox());
    expect(cancellations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delayed readiness stays black without a running ticker', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 501));
    expect(state(tester).debugPhase, 'waiting');
    expect(state(tester).debugIsAnimating, isFalse);
    final frames = state(tester).debugFrameCount;
    await tester.pump(const Duration(seconds: 4));
    expect(state(tester).debugPhase, 'waiting');
    expect(state(tester).debugFrameCount, frames);
    expect(reveals, 0);
    ready = true;
    await tester.pumpWidget(host());
    await tester.pump();
    expect(state(tester).debugPhase, 'lighting');
    expect(reveals, 1);
    await tester.pump(const Duration(milliseconds: 1551));
    expect(state(tester).debugPhase, 'complete');
    expect(state(tester).debugIsAnimating, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('errors remove the effect and late readiness cannot restart it', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 150));
    hasError = true;
    await tester.pumpWidget(host());
    expect(state(tester).debugPhase, 'cancelled');
    expect(state(tester).debugIsAnimating, isFalse);
    expect(cancellations, 1);
    hasError = false;
    ready = true;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 3));
    expect(state(tester).debugPhase, 'cancelled');
    expect(reveals, 0);
    await tester.tap(find.text('播放器操作 0'));
    expect(childKey.currentState!.value, 1);
    await tester.pumpWidget(const SizedBox());
    expect(cancellations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement generation cancels the previous reveal', (
    tester,
  ) async {
    ready = true;
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state(tester).debugPhase, 'lighting');
    generation = 1;
    ready = false;
    await tester.pumpWidget(host());
    await tester.pump();
    expect(cancellations, 1);
    expect(state(tester).debugGeneration, 1);
    expect(state(tester).debugPhase, 'closing');
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump(const Duration(seconds: 2));
    expect(state(tester).debugPhase, 'waiting');
    expect(state(tester).debugIsAnimating, isFalse);
    expect(reveals, 1);
    ready = true;
    await tester.pumpWidget(host());
    await tester.pump();
    expect(reveals, 2);
    await tester.pump(const Duration(milliseconds: 1551));
    expect(state(tester).debugPhase, 'complete');
    await tester.pumpWidget(const SizedBox());
    expect(cancellations, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ready interruptions wait again without repeating the sound hook',
    (tester) async {
      ready = true;
      await mount(tester);
      await tester.pump(const Duration(milliseconds: 501));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      ready = false;
      await tester.pumpWidget(host());
      expect(state(tester).debugPhase, 'waiting');
      expect(state(tester).debugIsAnimating, isFalse);
      expect(cancellations, 1);
      ready = true;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(state(tester).debugPhase, 'lighting');
      expect(reveals, 1);
      await tester.pump(const Duration(milliseconds: 1551));
      expect(state(tester).debugPhase, 'complete');
      await tester.pumpWidget(const SizedBox());
      expect(cancellations, 1);
    },
  );

  for (final environment in ['prop', 'system', 'disabled', 'ticker']) {
    testWidgets(
      '$environment reduction cancels and requires a new generation',
      (tester) async {
        await mount(tester);
        await tester.pump(const Duration(milliseconds: 120));
        switch (environment) {
          case 'prop':
            reduceMotion = true;
          case 'system':
            systemReduceMotion = true;
          case 'disabled':
            enabled = false;
          case 'ticker':
            tickerEnabled = false;
        }
        await tester.pumpWidget(host());
        expect(state(tester).debugPhase, 'cancelled');
        expect(state(tester).debugIsAnimating, isFalse);
        expect(cancellations, 1);
        ready = true;
        reduceMotion = false;
        systemReduceMotion = false;
        enabled = true;
        tickerEnabled = true;
        await tester.pumpWidget(host());
        await tester.pump(const Duration(seconds: 3));
        expect(state(tester).debugPhase, 'cancelled');
        expect(reveals, 0);
        generation++;
        await tester.pumpWidget(host());
        await tester.pump();
        expect(state(tester).debugPhase, 'closing');
        await tester.pump(const Duration(milliseconds: 501));
        expect(state(tester).debugPhase, 'lighting');
        expect(reveals, 1);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'initial reduced motion displays the child without a sound hook',
    (tester) async {
      reduceMotion = true;
      ready = true;
      await mount(tester);
      expect(state(tester).debugPhase, 'cancelled');
      expect(state(tester).debugIsAnimating, isFalse);
      await tester.tap(find.text('播放器操作 0'));
      expect(childKey.currentState!.value, 1);
      await tester.pumpWidget(const SizedBox());
      expect(reveals, 0);
      expect(cancellations, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final lifecycle in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$lifecycle terminates this generation without a late reveal', (
      tester,
    ) async {
      await mount(tester);
      await tester.pump(const Duration(milliseconds: 120));
      state(tester).didChangeAppLifecycleState(lifecycle);
      await tester.pump();
      expect(state(tester).debugPhase, 'cancelled');
      expect(state(tester).debugIsAnimating, isFalse);
      final frames = state(tester).debugFrameCount;
      ready = true;
      await tester.pumpWidget(host());
      state(tester).didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 4));
      expect(state(tester).debugPhase, 'cancelled');
      expect(state(tester).debugFrameCount, frames);
      expect(reveals, 0);
      expect(cancellations, 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'the player child retains its state and hit targets in every phase',
    (tester) async {
      await mount(tester);
      final original = childKey.currentState!;
      await tester.tap(find.text('播放器操作 0'));
      await tester.pump(const Duration(milliseconds: 501));
      expect(state(tester).debugPhase, 'waiting');
      expect(childKey.currentState, same(original));
      await tester.tap(find.text('播放器操作 1'));
      await tester.pump();
      expect(original.value, 2);
      ready = true;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(childKey.currentState, same(original));
      await tester.pump(const Duration(milliseconds: 1551));
      expect(childKey.currentState, same(original));
      generation++;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(childKey.currentState, same(original));
      hasError = true;
      await tester.pumpWidget(host());
      expect(childKey.currentState, same(original));
      expect(original.value, 2);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
