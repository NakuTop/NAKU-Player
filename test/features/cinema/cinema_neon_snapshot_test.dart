import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_neon_decode.dart';

Future<ui.Image> _image(
  WidgetTester tester,
  Color left,
  Color right,
) async => (await tester.runAsync(() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 160, 160), Paint()..color = left);
  canvas.drawRect(const Rect.fromLTWH(80, 0, 80, 160), Paint()..color = right);
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 160);
  picture.dispose();
  return image;
}))!;

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(key))
          .toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return Uint8List.fromList(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }))!;

Widget _host({
  required GlobalKey capture,
  required GlobalKey<CinemaNeonDecodeState> state,
  required bool loading,
  ui.Image? image,
  bool reduced = false,
  bool tickerEnabled = true,
  double? progress,
  Widget child = const SizedBox.expand(),
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Center(
        child: RepaintBoundary(
          key: capture,
          child: SizedBox(
            width: 160,
            height: 160,
            child: CinemaNeonDecode(
              key: state,
              loading: loading,
              progress: progress,
              snapshotRendering: true,
              rasterSnapshot: image,
              child: child,
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('snapshot shader compiles and paints original image colors', (
    tester,
  ) async {
    final program = await tester.runAsync(
      () => ui.FragmentProgram.fromAsset('shaders/cinema_snapshot_decode.frag'),
    );
    expect(program, isNotNull);
    final image = await _image(
      tester,
      const Color(0xFFFF0000),
      const Color(0xFF0000FF),
    );
    final capture = GlobalKey(), state = GlobalKey<CinemaNeonDecodeState>();
    await tester.pumpWidget(
      _host(capture: capture, state: state, loading: true, image: image),
    );
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final shader = state.currentState!.debugSnapshotShader;
    expect(shader, isNotNull);
    final pixels = await _pixels(tester, capture);
    int channel(int x, int y, int c) => pixels[(y * 160 + x) * 4 + c];
    expect(channel(32, 80, 0), greaterThan(200));
    expect(channel(32, 80, 2), lessThan(20));
    expect(channel(128, 80, 2), greaterThan(200));
    expect(channel(128, 80, 0), lessThan(20));
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byType(ClipPath), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(shader!.debugDisposed, isTrue);
    expect(
      image.debugDisposed,
      isFalse,
      reason: 'The caller owns the snapshot.',
    );
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('snapshot frames paint without rebuilding their real child', (
    tester,
  ) async {
    final image = await _image(tester, Colors.green, Colors.blue);
    final capture = GlobalKey(), state = GlobalKey<CinemaNeonDecodeState>();
    var builds = 0;
    final child = Builder(
      builder: (_) {
        builds++;
        return const SizedBox.expand();
      },
    );
    await tester.pumpWidget(
      _host(
        capture: capture,
        state: state,
        loading: true,
        image: image,
        child: child,
      ),
    );
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final initial = builds;
    final customPaints = find.byType(CustomPaint).evaluate().toSet();
    var painterBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (customPaints.contains(element)) painterBuilds++;
    };
    try {
      for (var frame = 0; frame < 36; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect(builds, initial);
    expect(painterBuilds, 0);
    expect(state.currentState!.debugSnapshot.elapsed, greaterThan(.28));
    await tester.pumpWidget(const SizedBox());
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty preview is visible and continues subtle motion after eight seconds',
    (tester) async {
      final capture = GlobalKey(), state = GlobalKey<CinemaNeonDecodeState>();
      await tester.pumpWidget(
        _host(capture: capture, state: state, loading: true),
      );
      final first = await _pixels(tester, capture);
      expect(first[(80 * 160 + 80) * 4], greaterThan(15));
      await tester.pump(const Duration(seconds: 9));
      expect(state.currentState!.debugSnapshot.visualReveal, closeTo(.9, .001));
      expect(state.currentState!.debugSnapshot.running, isTrue);
      expect(state.currentState!.debugSnapshot.visible, isTrue);
      final late = await _pixels(tester, capture);
      await tester.pump(const Duration(milliseconds: 700));
      final later = await _pixels(tester, capture);
      expect(listEquals(late, later), isFalse);
      await tester.pumpWidget(
        _host(capture: capture, state: state, loading: false),
      );
      await tester.pump(const Duration(milliseconds: 520));
      expect(state.currentState!.debugSnapshot.running, isFalse);
      expect(state.currentState!.debugSnapshot.visible, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('snapshot replacement preserves the reveal and fast readiness', (
    tester,
  ) async {
    final red = await _image(
      tester,
      const Color(0xFFFF0000),
      const Color(0xFFFF0000),
    );
    final blue = await _image(
      tester,
      const Color(0xFF0000FF),
      const Color(0xFF0000FF),
    );
    final capture = GlobalKey(), state = GlobalKey<CinemaNeonDecodeState>();
    await tester.pumpWidget(
      _host(capture: capture, state: state, loading: true, image: red),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final before = state.currentState!.debugSnapshot;
    await tester.pumpWidget(
      _host(
        capture: capture,
        state: state,
        loading: true,
        image: blue,
        progress: 1,
      ),
    );
    final after = state.currentState!.debugSnapshot;
    expect(after.generation, before.generation);
    expect(after.elapsed, before.elapsed);
    expect(after.visualReveal, before.visualReveal);
    final pixels = await _pixels(tester, capture);
    expect(pixels[(80 * 160 + 80) * 4 + 2], greaterThan(200));
    expect(pixels[(80 * 160 + 80) * 4], lessThan(20));
    expect(red.debugDisposed, isFalse);
    await tester.pumpWidget(
      _host(capture: capture, state: state, loading: false, image: blue),
    );
    await tester.pump(const Duration(milliseconds: 520));
    expect(state.currentState!.debugSnapshot.visible, isFalse);
    expect(state.currentState!.debugSnapshot.running, isFalse);
    await tester.pumpWidget(const SizedBox());
    red.dispose();
    blue.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('snapshot mode pauses in background and honors reduced motion', (
    tester,
  ) async {
    final capture = GlobalKey(), state = GlobalKey<CinemaNeonDecodeState>();
    await tester.pumpWidget(
      _host(capture: capture, state: state, loading: true),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final before = state.currentState!.debugSnapshot;
    state.currentState!.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 2));
    expect(state.currentState!.debugSnapshot.running, isFalse);
    expect(state.currentState!.debugSnapshot.visualReveal, before.visualReveal);
    state.currentState!.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(state.currentState!.debugSnapshot.running, isTrue);
    await tester.pumpWidget(
      _host(capture: capture, state: state, loading: true, reduced: true),
    );
    expect(state.currentState!.debugSnapshot.running, isFalse);
    await tester.pumpWidget(
      _host(
        capture: capture,
        state: state,
        loading: true,
        tickerEnabled: false,
      ),
    );
    expect(state.currentState!.debugSnapshot.running, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
