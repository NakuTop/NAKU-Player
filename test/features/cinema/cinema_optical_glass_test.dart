import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_optical_glass.dart';

void main() {
  testWidgets(
    'light follows the pointer without rebuilding or moving content',
    (tester) async {
      final key = GlobalKey<CinemaOpticalGlassState>();
      var builds = 0, taps = 0;
      await tester.pumpWidget(
        _host(
          key: key,
          child: Builder(
            builder: (_) {
              builds++;
              return TextButton(
                onPressed: () => taps++,
                child: const Text('播放影片'),
              );
            },
          ),
        ),
      );
      final original = tester.getRect(find.text('播放影片'));
      final initialBuilds = builds;
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byKey(key)));
      await tester.pump(const Duration(milliseconds: 40));
      expect(key.currentState!.debugIsAnimating, isTrue);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(key.currentState!.debugIsAnimating, isFalse);
      expect(key.currentState!.debugLightIntensity, 1);
      expect(builds, initialBuilds);
      expect(tester.getRect(find.text('播放影片')), original);
      await tester.tap(find.text('播放影片'));
      expect(taps, 1);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(key.currentState!.debugIsAnimating, isFalse);
      expect(key.currentState!.debugRippleAge, greaterThanOrEqualTo(.76));
      await pointer.moveTo(const Offset(2000, 2000));
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      final position = key.currentState!.debugLightPosition;
      expect(position.dx, inInclusiveRange(0, 1));
      expect(position.dy, inInclusiveRange(0, 1));
      expect(key.currentState!.debugIsAnimating, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await pointer.removePointer();
    },
  );

  testWidgets('reduced motion leaves static light and passes through clicks', (
    tester,
  ) async {
    final key = GlobalKey<CinemaOpticalGlassState>();
    var taps = 0;
    await tester.pumpWidget(
      _host(
        key: key,
        reduceMotion: true,
        child: TextButton(onPressed: () => taps++, child: const Text('选择片源')),
      ),
    );
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(find.byKey(key)));
    await tester.pump();
    expect(key.currentState!.debugIsAnimating, isFalse);
    expect(key.currentState!.debugLightIntensity, 1);
    await tester.tap(find.text('选择片源'));
    expect(taps, 1);
    expect(key.currentState!.debugIsAnimating, isFalse);
    expect(key.currentState!.debugRippleAge, 1);
    await tester.pumpAndSettle();
    await pointer.removePointer();
  });

  testWidgets('opaque fallback omits blur and glass light layers', (
    tester,
  ) async {
    final key = GlobalKey<CinemaOpticalGlassState>();
    await tester.pumpWidget(
      _host(key: key, reduceTransparency: true, child: const Text('字幕与音轨')),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('字幕与音轨'), findsOneWidget);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(find.byKey(key)));
    await tester.pump();
    expect(key.currentState!.debugIsAnimating, isFalse);
    await pointer.removePointer();
  });

  testWidgets('background, TickerMode and unmount stop reflection ticks', (
    tester,
  ) async {
    final key = GlobalKey<CinemaOpticalGlassState>();
    await tester.pumpWidget(_host(key: key, child: const Text('弹幕')));
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(find.byKey(key)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(key.currentState!.debugIsAnimating, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(key.currentState!.debugIsAnimating, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      _host(key: key, tickerEnabled: false, child: const Text('弹幕')),
    );
    await pointer.moveTo(
      tester.getCenter(find.byKey(key)) + const Offset(20, 8),
    );
    await tester.pump();
    expect(key.currentState!.debugIsAnimating, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await pointer.removePointer();
  });
}

Widget _host({
  required GlobalKey<CinemaOpticalGlassState> key,
  required Widget child,
  bool reduceMotion = false,
  bool reduceTransparency = false,
  bool tickerEnabled = true,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.macOS, brightness: Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Center(
        child: SizedBox(
          width: 320,
          height: 160,
          child: CinemaOpticalGlass(
            key: key,
            fluted: true,
            reduceTransparency: reduceTransparency,
            child: Center(child: child),
          ),
        ),
      ),
    ),
  ),
);
