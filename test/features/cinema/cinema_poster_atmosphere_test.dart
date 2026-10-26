import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_poster_atmosphere.dart';

const _palette = [Color(0xFFFF452A), Color(0xFF225AFF), Color(0xFFB77720)];
const _similarPalette = [
  Color(0xFF913D28),
  Color(0xFF8A402C),
  Color(0xFF994C30),
];
const _rasterKey = ValueKey('atmosphere-raster');

Widget _host({
  required GlobalKey<CinemaPosterAtmosphereState> surfaceKey,
  List<Color>? palette = _palette,
  bool active = true,
  bool reduceMotion = false,
  bool tickerEnabled = true,
  Widget? child,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Center(
        child: RepaintBoundary(
          key: _rasterKey,
          child: ColoredBox(
            color: const Color(0xFF17181A),
            child: SizedBox(
              width: 320,
              height: 180,
              child: CinemaPosterAtmosphere(
                key: surfaceKey,
                palette: palette,
                active: active,
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_rasterKey),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    return Uint8List.fromList(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

int _pixelDifference(Uint8List a, Uint8List b) {
  var difference = 0;
  for (var index = 0; index < a.length; index += 4) {
    for (var channel = 0; channel < 3; channel++) {
      difference += (a[index + channel] - b[index + channel]).abs();
    }
  }
  return difference;
}

// Compare the entire quiet background, including where color moved away from.
// Signed tile changes distinguish traveling color from a uniform brightness pulse.
({double meanDelta, double changedFraction, int brighterTiles, int darkerTiles})
_spatialChange(Uint8List before, Uint8List after) {
  const width = 320, height = 180;
  var totalDelta = 0, changed = 0, brighter = 0, darker = 0;
  final tileChanges = List<double>.filled(32, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      var peakDelta = 0, signedDelta = 0;
      for (var channel = 0; channel < 3; channel++) {
        final delta = after[offset + channel] - before[offset + channel];
        signedDelta += delta;
        totalDelta += delta.abs();
        if (delta.abs() > peakDelta) peakDelta = delta.abs();
      }
      if (peakDelta >= 6) changed++;
      tileChanges[(y ~/ 45) * 8 + x ~/ 40] += signedDelta / 3;
    }
  }
  for (final sum in tileChanges) {
    final mean = sum / (40 * 45);
    if (mean > 2) brighter++;
    if (mean < -2) darker++;
  }
  return (
    meanDelta: totalDelta / (width * height * 3),
    changedFraction: changed / (width * height),
    brighterTiles: brighter,
    darkerTiles: darker,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('poster colors flow in paint without rebuilding the content', (
    tester,
  ) async {
    final key = GlobalKey<CinemaPosterAtmosphereState>();
    var builds = 0, taps = 0;
    await tester.pumpWidget(
      _host(
        surfaceKey: key,
        child: Align(
          alignment: Alignment.topLeft,
          child: Builder(
            builder: (_) {
              builds++;
              return GestureDetector(
                onTap: () => taps++,
                child: const SizedBox(
                  width: 24,
                  height: 24,
                  child: ColoredBox(color: Color(0xFF00FF00)),
                ),
              );
            },
          ),
        ),
      ),
    );
    final baselineBuilds = builds;
    final before = await _pixels(tester);
    await tester.pump(const Duration(seconds: 8));
    final after = await _pixels(tester);
    expect(key.currentState!.debugSnapshot.running, isTrue);
    expect(key.currentState!.debugSnapshot.phase, closeTo(1 / 3, .001));
    expect(_pixelDifference(before, after), greaterThan(50000));
    expect(builds, baselineBuilds);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.tap(find.byType(GestureDetector));
    expect(taps, 1);
    // The foreground stays exact and the color field keeps a cinema-dark range.
    final origin = (12 * 320 + 12) * 4;
    expect(after.sublist(origin, origin + 4), [0, 255, 0, 255]);
    var brightest = 0;
    for (var index = 0; index < after.length; index += 4) {
      final pixel = index ~/ 4;
      if (pixel % 320 < 24 && pixel ~/ 320 < 24) continue;
      for (var channel = 0; channel < 3; channel++) {
        if (after[index + channel] > brightest) {
          brightest = after[index + channel];
        }
      }
    }
    expect(brightest, lessThan(100));
    await tester.pumpWidget(const SizedBox());
    // Disposal cancels the callback; Flutter can still have the frame that was
    // scheduled before unmount queued. Drain it and ensure no successor exists.
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final entry in {
    'different hues': _palette,
    'similar hues': _similarPalette,
  }.entries) {
    testWidgets(
      '${entry.key} travel across the quiet surface within four to eight seconds',
      (tester) async {
        final key = GlobalKey<CinemaPosterAtmosphereState>();
        await tester.pumpWidget(_host(surfaceKey: key, palette: entry.value));
        final before = await _pixels(tester);
        await tester.pump(const Duration(seconds: 4));
        final atFour = _spatialChange(before, await _pixels(tester));
        // A visible fraction of the surface changes by several RGB levels.
        expect(atFour.meanDelta, greaterThan(2));
        expect(atFour.changedFraction, greaterThan(.35));
        await tester.pump(const Duration(seconds: 4));
        final after = await _pixels(tester);
        final atEight = _spatialChange(before, after);
        expect(atEight.meanDelta, greaterThan(4));
        expect(atEight.changedFraction, greaterThan(.5));
        expect(atEight.brighterTiles, greaterThanOrEqualTo(8));
        expect(atEight.darkerTiles, greaterThanOrEqualTo(8));
        var peak = 0;
        for (var offset = 0; offset < after.length; offset += 4) {
          for (var channel = 0; channel < 3; channel++) {
            if (after[offset + channel] > peak) peak = after[offset + channel];
          }
        }
        expect(peak, lessThan(90));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
  }

  for (final mode in ['active', 'ticker', 'reduce']) {
    testWidgets('$mode suspends the clock and resumes from the same phase', (
      tester,
    ) async {
      final key = GlobalKey<CinemaPosterAtmosphereState>();
      await tester.pumpWidget(_host(surfaceKey: key));
      await tester.pump(const Duration(seconds: 2));
      final phase = key.currentState!.debugSnapshot.phase;
      await tester.pumpWidget(
        _host(
          surfaceKey: key,
          active: mode != 'active',
          tickerEnabled: mode != 'ticker',
          reduceMotion: mode == 'reduce',
        ),
      );
      expect(key.currentState!.debugSnapshot.running, isFalse);
      final before = await _pixels(tester);
      await tester.pump(const Duration(seconds: 20));
      expect(key.currentState!.debugSnapshot.phase, phase);
      expect(_pixelDifference(before, await _pixels(tester)), 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(_host(surfaceKey: key));
      expect(key.currentState!.debugSnapshot.phase, phase);
      await tester.pump(const Duration(seconds: 1));
      expect(
        key.currentState!.debugSnapshot.phase,
        closeTo(phase + 1 / 24, .001),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('hidden and inactive stop frames without a resume time jump', (
    tester,
  ) async {
    final key = GlobalKey<CinemaPosterAtmosphereState>();
    await tester.pumpWidget(_host(surfaceKey: key));
    await tester.pump(const Duration(seconds: 2));
    final surface = key.currentState!;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      final phase = surface.debugSnapshot.phase;
      // Use the observer directly so the test harness can still render pixels.
      surface.didChangeAppLifecycleState(state);
      await tester.pump();
      expect(surface.debugSnapshot.running, isFalse);
      await tester.pump(const Duration(seconds: 40));
      expect(surface.debugSnapshot.phase, phase);
      expect(tester.binding.hasScheduledFrame, isFalse);
      surface.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(surface.debugSnapshot.phase, phase);
      await tester.pump(const Duration(seconds: 1));
      expect(surface.debugSnapshot.phase, closeTo(phase + 1 / 24, .001));
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('neutral initial color and palette replacement remain low-light', (
    tester,
  ) async {
    final key = GlobalKey<CinemaPosterAtmosphereState>();
    await tester.pumpWidget(_host(surfaceKey: key, palette: null));
    final neutral = await _pixels(tester);
    await tester.pumpWidget(_host(surfaceKey: key));
    // A new poster blends from existing pixels rather than flashing a new tint.
    expect(_pixelDifference(neutral, await _pixels(tester)), 0);
    await tester.pump(const Duration(milliseconds: 300));
    final midway = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 300));
    final colored = await _pixels(tester);
    expect(_pixelDifference(neutral, midway), greaterThan(0));
    expect(_pixelDifference(midway, colored), greaterThan(0));
    await tester.pumpWidget(
      _host(surfaceKey: key, palette: const [], reduceMotion: true),
    );
    expect(key.currentState!.debugSnapshot.running, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
