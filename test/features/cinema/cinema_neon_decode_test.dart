import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_neon_decode.dart';

void main() {
  CinemaNeonDecodeState decodeState(WidgetTester tester) =>
      tester.state<CinemaNeonDecodeState>(find.byType(CinemaNeonDecode));
  var loading = false;
  var reduceMotion = false;
  var tickerEnabled = true;
  var taps = 0;
  double? sourceProgress;

  Widget host() => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: tickerEnabled,
        child: SizedBox(
          width: 700,
          height: 450,
          child: CinemaNeonDecode(
            loading: loading,
            progress: sourceProgress,
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('原有功能'),
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    loading = false;
    reduceMotion = false;
    tickerEnabled = true;
    taps = 0;
    sourceProgress = null;
  });

  testWidgets(
    'refinement follows every display frame without rebuilding live content',
    (tester) async {
      var builds = 0;
      var pending = true;
      final content = Builder(
        builder: (_) {
          builds++;
          return const Text('真实内容');
        },
      );
      Widget sample() => MaterialApp(
        home: CinemaNeonDecode(loading: pending, child: content),
      );
      await tester.pumpWidget(sample());
      final state = decodeState(tester);
      final initialBuilds = builds;
      var previous = state.debugSnapshot;
      // Exercise 120 Hz frame intervals, below the former 42 ms timer period.
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(microseconds: 8333));
        final current = state.debugSnapshot;
        expect(current.elapsed - previous.elapsed, closeTo(.008333, .000001));
        expect(current.pixelSize, lessThan(previous.pixelSize));
        previous = current;
      }
      expect(builds, initialBuilds);
      // A delayed display frame advances once by the actual elapsed time.
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        state.debugSnapshot.elapsed - previous.elapsed,
        closeTo(.4, .000001),
      );
      expect(builds, initialBuilds);
      pending = false;
      await tester.pumpWidget(sample());
      await tester.pump(const Duration(milliseconds: 520));
      expect(state.debugSnapshot.running, isFalse);
      expect(state.debugSnapshot.filtersEnabled, isFalse);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'only real loading enables the field and child stays actionable',
    (tester) async {
      await tester.pumpWidget(host());
      final buttonState = tester.state(find.byType(TextButton));
      expect(decodeState(tester).debugSnapshot.visible, isFalse);
      loading = true;
      await tester.pumpWidget(host());
      expect(decodeState(tester).debugSnapshot.visible, isTrue);
      await tester.pump(const Duration(milliseconds: 700));
      expect(decodeState(tester).debugSnapshot.visible, isTrue);
      await tester.tap(find.text('原有功能'));
      expect(taps, 1);
      expect(tester.state(find.byType(TextButton)), same(buttonState));
      loading = false;
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 519));
      expect(decodeState(tester).debugSnapshot.visible, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(decodeState(tester).debugSnapshot.visible, isFalse);
      expect(tester.state(find.byType(TextButton)), same(buttonState));
      await tester.tap(find.text('原有功能'));
      expect(taps, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual content refines from coarse blurred pixels while resources stay pending',
    (tester) async {
      loading = true;
      sourceProgress = 0;
      await tester.pumpWidget(host());
      final state = tester.state<CinemaNeonDecodeState>(
        find.byType(CinemaNeonDecode),
      );
      final initial = state.debugSnapshot;
      expect(initial.pixelSize, 32);
      expect(initial.blurSigma, 7);
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered).first).enabled,
        isTrue,
      );
      await tester.pump(const Duration(seconds: 1));
      final early = state.debugSnapshot;
      await tester.pump(const Duration(seconds: 3));
      final middle = state.debugSnapshot;
      expect(early.visualReveal, greaterThan(initial.visualReveal));
      expect(middle.visualReveal, greaterThan(early.visualReveal));
      expect(middle.visualReveal, lessThan(.9));
      expect(early.pixelSize, lessThan(initial.pixelSize));
      expect(middle.pixelSize, lessThan(early.pixelSize));
      expect(middle.blurSigma, lessThan(early.blurSigma));
      expect(middle.sourceProgress, 0);
      expect(middle.settling, isFalse);
      expect(middle.visible, isTrue);
      await tester.pump(const Duration(seconds: 8));
      final longWait = state.debugSnapshot;
      expect(longWait.visualReveal, closeTo(.9, .0001));
      expect(longWait.pixelSize, closeTo(3, .0001));
      expect(longWait.blurSigma, closeTo(.45, .0001));
      expect(longWait.filtersEnabled, isTrue);
      expect(longWait.assembly, 0);
      expect(longWait.sourceProgress, 0);
      expect(longWait.generation, initial.generation);
      await tester.pump(const Duration(seconds: 3));
      expect(state.debugSnapshot.visualReveal, longWait.visualReveal);
      expect(state.debugSnapshot.elapsed, longWait.elapsed);
      expect(state.debugSnapshot.running, isFalse);
      expect(state.debugSnapshot.filtersEnabled, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('static pending material wakes only for a newly ready region', (
    tester,
  ) async {
    final firstKey = GlobalKey<CinemaNeonRegionState>();
    final otherKey = GlobalKey<CinemaNeonRegionState>();
    var firstReady = false;
    Widget sample() => MaterialApp(
      home: SizedBox(
        width: 320,
        height: 160,
        child: CinemaNeonDecode(
          loading: true,
          regional: true,
          child: Row(
            children: [
              Expanded(
                child: CinemaNeonRegion(
                  key: firstKey,
                  ready: firstReady,
                  child: const Text('先到达的评分'),
                ),
              ),
              Expanded(
                child: CinemaNeonRegion(
                  key: otherKey,
                  ready: false,
                  child: const Text('仍在等待的图片'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(sample());
    final state = decodeState(tester);
    await tester.pump(const Duration(seconds: 9));
    final idle = state.debugSnapshot;
    expect(idle.running, isFalse);
    expect(idle.filtersEnabled, isTrue);
    expect(otherKey.currentState!.debugSnapshot.filtered, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(state.debugSnapshot.elapsed, idle.elapsed);

    firstReady = true;
    await tester.pumpWidget(sample());
    expect(state.debugSnapshot.running, isTrue);
    await tester.pump(const Duration(milliseconds: 126));
    expect(firstKey.currentState!.debugSnapshot.pixelSize, lessThan(3));
    await tester.pump(const Duration(milliseconds: 126));
    expect(firstKey.currentState!.debugSnapshot.filtered, isFalse);
    expect(otherKey.currentState!.debugSnapshot.filtered, isTrue);
    expect(state.debugSnapshot.running, isFalse);
    expect(state.debugSnapshot.visible, isTrue);
    final afterRegion = state.debugSnapshot;
    await tester.pump(const Duration(seconds: 2));
    expect(state.debugSnapshot.elapsed, afterRegion.elapsed);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'static wait wakes for final assembly and future requests stay bounded',
    (tester) async {
      loading = true;
      await tester.pumpWidget(host());
      final state = decodeState(tester);
      await tester.pump(const Duration(seconds: 9));
      final previousGeneration = state.debugSnapshot.generation;
      expect(state.debugSnapshot.running, isFalse);

      loading = false;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.running, isTrue);
      await tester.pump(const Duration(milliseconds: 252));
      expect(state.debugSnapshot.assembly, greaterThan(0));
      expect(state.debugSnapshot.visible, isTrue);
      await tester.pump(const Duration(milliseconds: 268));
      expect(state.debugSnapshot.visible, isFalse);
      expect(state.debugSnapshot.running, isFalse);

      loading = true;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.generation, greaterThan(previousGeneration));
      expect(state.debugSnapshot.pixelSize, 32);
      expect(state.debugSnapshot.running, isTrue);
      sourceProgress = .95;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.pixelSize, 3);
      expect(state.debugSnapshot.running, isFalse);
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(state.debugSnapshot.filtersEnabled, isFalse);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.debugSnapshot.filtersEnabled, isTrue);
      expect(state.debugSnapshot.running, isFalse);
      loading = false;
      await tester.pumpWidget(host());
      await tester.pump(const Duration(milliseconds: 520));
      expect(state.debugSnapshot.running, isFalse);
      expect(state.debugSnapshot.filtersEnabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'real progress refines pixels and only ready permits final assembly',
    (tester) async {
      loading = true;
      await tester.pumpWidget(host());
      final state = tester.state<CinemaNeonDecodeState>(
        find.byType(CinemaNeonDecode),
      );
      await tester.pump(const Duration(milliseconds: 700));
      sourceProgress = .78;
      await tester.pumpWidget(host());
      final driven = state.debugSnapshot;
      expect(driven.visualReveal, .78);
      expect(driven.sourceProgress, .78);
      sourceProgress = .2;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.visualReveal, .78);
      loading = false;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.settling, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.debugSnapshot.visualReveal, driven.visualReveal);
      expect(state.debugSnapshot.sourceProgress, driven.sourceProgress);
      expect(state.debugSnapshot.opacity, lessThan(1));
      expect(state.debugSnapshot.assembly, greaterThan(0));
      expect(state.debugSnapshot.pixelSize, lessThan(driven.pixelSize));
      expect(state.debugSnapshot.blurSigma, lessThan(driven.blurSigma));
      await tester.pump(const Duration(milliseconds: 420));
      expect(decodeState(tester).debugSnapshot.visible, isFalse);
      final complete = state.debugSnapshot;
      expect(complete.running, isFalse);
      expect(complete.filtersEnabled, isFalse);
      expect(complete.pixelSize, 1);
      expect(complete.blurSigma, 0);
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered).first).enabled,
        isFalse,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(state.debugSnapshot.elapsed, complete.elapsed);
      expect(state.debugSnapshot.assembly, complete.assembly);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fast readiness assembles once without waiting for the eight second motif',
    (tester) async {
      loading = true;
      await tester.pumpWidget(host());
      final state = tester.state<CinemaNeonDecodeState>(
        find.byType(CinemaNeonDecode),
      );
      loading = false;
      await tester.pumpWidget(host());
      expect(state.debugSnapshot.settling, isTrue);
      expect(state.debugSnapshot.visualReveal, 0);
      await tester.pump(const Duration(milliseconds: 250));
      expect(decodeState(tester).debugSnapshot.visible, isTrue);
      expect(state.debugSnapshot.assembly, greaterThan(0));
      expect(state.debugSnapshot.pixelSize, lessThan(32));
      await tester.pump(const Duration(milliseconds: 270));
      expect(decodeState(tester).debugSnapshot.visible, isFalse);
      expect(state.debugSnapshot.running, isFalse);
      expect(state.debugSnapshot.visualReveal, 0);
      expect(state.debugSnapshot.filtersEnabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('rapid load replacement cannot be removed by an old finish', (
    tester,
  ) async {
    loading = true;
    await tester.pumpWidget(host());
    loading = false;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    loading = true;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 400));
    expect(decodeState(tester).debugSnapshot.visible, isTrue);
    loading = false;
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 520));
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduce motion and disabled TickerMode remove pending effects', (
    tester,
  ) async {
    loading = true;
    reduceMotion = true;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    reduceMotion = false;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isTrue);
    final state = tester.state<CinemaNeonDecodeState>(
      find.byType(CinemaNeonDecode),
    );
    await tester.pump(const Duration(seconds: 2));
    final beforePause = state.debugSnapshot;
    tickerEnabled = false;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    expect(state.debugSnapshot.running, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(state.debugSnapshot.visualReveal, beforePause.visualReveal);
    tickerEnabled = true;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isTrue);
    expect(state.debugSnapshot.generation, beforePause.generation);
    expect(state.debugSnapshot.visualReveal, beforePause.visualReveal);
    reduceMotion = true;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('background, readiness and disposal leave no residual timer', (
    tester,
  ) async {
    loading = true;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isTrue);
    final observer =
        tester.state(find.byType(CinemaNeonDecode)) as WidgetsBindingObserver;
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    loading = false;
    await tester.pumpWidget(host());
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(decodeState(tester).debugSnapshot.visible, isFalse);
    loading = true;
    await tester.pumpWidget(host());
    expect(decodeState(tester).debugSnapshot.visible, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the live content is visibly filtered, then returns to sharp pixels',
    (tester) async {
      final captureKey = GlobalKey();
      var pending = true;
      Widget sample() => MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: captureKey,
            child: SizedBox(
              width: 160,
              height: 160,
              child: CinemaNeonDecode(
                loading: pending,
                child: const CustomPaint(painter: _StripePainter()),
              ),
            ),
          ),
        ),
      );

      Future<Uint8List> capture() async {
        final bytes = await tester.runAsync(() async {
          final boundary =
              captureKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return Uint8List.fromList(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        return bytes!;
      }

      double edgeContrast(Uint8List pixels) {
        var total = 0.0;
        for (var x = 20; x < 139; x++) {
          final a = (80 * 160 + x) * 4;
          final b = a + 4;
          total += (pixels[a] - pixels[b]).abs();
        }
        return total;
      }

      await tester.pumpWidget(sample());
      final coarse = await capture();
      pending = false;
      await tester.pumpWidget(sample());
      await tester.pump(const Duration(milliseconds: 520));
      final sharp = await capture();
      expect(edgeContrast(sharp), greaterThan(edgeContrast(coarse) * 4));
      expect(
        tester.widget<ImageFiltered>(find.byType(ImageFiltered).first).enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed resource regions clear before an unrelated pending region',
    (tester) async {
      final captureKey = GlobalKey();
      final loadedKey = GlobalKey<CinemaNeonRegionState>();
      final pendingKey = GlobalKey<CinemaNeonRegionState>();
      var leftReady = false;
      Widget sample() => MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: captureKey,
            child: SizedBox(
              width: 160,
              height: 160,
              child: CinemaNeonDecode(
                loading: true,
                regional: true,
                child: Row(
                  children: [
                    Expanded(
                      child: CinemaNeonRegion(
                        key: loadedKey,
                        ready: leftReady,
                        child: const CustomPaint(
                          painter: _StripePainter(),
                          child: SizedBox.expand(),
                        ),
                      ),
                    ),
                    Expanded(
                      child: CinemaNeonRegion(
                        key: pendingKey,
                        ready: false,
                        child: const CustomPaint(
                          painter: _StripePainter(),
                          child: SizedBox.expand(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(sample());
      expect(loadedKey.currentState!.debugSnapshot.filtered, isTrue);
      leftReady = true;
      await tester.pumpWidget(sample());
      await tester.pump(const Duration(milliseconds: 252));
      expect(loadedKey.currentState!.debugSnapshot.filtered, isFalse);
      expect(pendingKey.currentState!.debugSnapshot.filtered, isTrue);
      expect(decodeState(tester).debugSnapshot.settling, isFalse);
      final image = await _capturePixels(tester, captureKey);
      double contrast(int start, int end) {
        var result = 0.0;
        for (var x = start; x < end; x++) {
          final index = (80 * 160 + x) * 4;
          result += (image[index] - image[index + 4]).abs();
        }
        return result;
      }

      expect(contrast(8, 64), greaterThan(contrast(88, 144) * 4));
      // Grayscale source remains grayscale: there are no synthetic neon tiles.
      for (var x = 8; x < 152; x++) {
        final index = (80 * 160 + x) * 4;
        expect(image[index], image[index + 1]);
        expect(image[index], image[index + 2]);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rounded content cells have feathered resource edges, not a hard rectangle',
    (tester) async {
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: captureKey,
              child: SizedBox(
                width: 160,
                height: 160,
                child: CinemaNeonDecode(
                  loading: true,
                  regional: true,
                  child: const ColoredBox(
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(child: SizedBox.expand()),
                        Expanded(
                          child: CinemaNeonRegion(
                            ready: false,
                            child: ColoredBox(
                              color: Colors.blue,
                              child: SizedBox.expand(),
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
        ),
      );
      final clip = tester.widget<ClipPath>(find.byType(ClipPath));
      final path = clip.clipper!.getClip(const Size(80, 160));
      expect(path.contains(const Offset(0.1, .1)), isFalse);
      expect(path.contains(const Offset(16, 16)), isTrue);
      final pixels = await _capturePixels(tester, captureKey);
      final edge = [
        for (final x in [74, 76, 78, 80, 82, 84]) pixels[(80 * 160 + x) * 4],
      ];
      expect(edge.any((r) => r > 40 && r < 245), isTrue);
      for (var i = 1; i < edge.length; i++) {
        expect((edge[i] - edge[i - 1]).abs(), lessThan(90));
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _StripePainter extends CustomPainter {
  const _StripePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var x = 0.0; x < size.width; x += 4) {
      paint.color = (x ~/ 4).isEven ? Colors.black : Colors.white;
      canvas.drawRect(Rect.fromLTWH(x, 0, 4, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => false;
}

Future<Uint8List> _capturePixels(WidgetTester tester, GlobalKey key) async {
  final bytes = await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  return bytes!;
}
