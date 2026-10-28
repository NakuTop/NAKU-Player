import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_application.dart';
import 'package:kazumi/features/cinema/cinema_tv_session.dart';
import 'package:kazumi/services/platform/naku_device.dart';

void main() {
  late GlobalKey<CinemaTVApplicationState> app;
  late FocusNode buttonFocus;
  late Duration now;
  late int presses;
  final owners = <Object>[];
  setUp(() {
    NakuDevice.isTV = true;
    app = GlobalKey<CinemaTVApplicationState>();
    buttonFocus = FocusNode(debugLabel: 'tv-underlying-action');
    now = Duration.zero;
    presses = 0;
  });
  tearDown(() {
    for (final owner in owners) {
      CinemaTVPlaybackActivity.instance.release(owner);
    }
    owners.clear();
    buttonFocus.dispose();
    NakuDevice.isTV = false;
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaTVApplication(
          key: app,
          now: () => now,
          home: Scaffold(
            body: Center(
              child: FilledButton(
                focusNode: buttonFocus,
                autofocus: true,
                onPressed: () {
                  presses++;
                },
                child: const Text('底层确定动作'),
              ),
            ),
          ),
          screensaverBuilder: (_) => const ColoredBox(
            color: Colors.black,
            child: Center(child: Text('Home Display 屏保探针')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(buttonFocus.hasFocus, isTrue);
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    'platform Back pops the inner TV route and wakes a saver without leaving the app',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVApplication(
            key: app,
            now: () => now,
            screensaverBuilder: (_) => const Scaffold(body: Text('系统返回屏保探针')),
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('TV 内层详情')),
                    ),
                  ),
                  child: const Text('进入详情'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入详情'));
      await tester.pumpAndSettle();
      expect(find.text('TV 内层详情'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('TV 内层详情'), findsNothing);
      expect(find.text('进入详情'), findsOneWidget);
      unawaited(app.currentState!.showScreensaver());
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, false);
      expect(find.text('进入详情'), findsOneWidget);
      await cleanup(tester);
    },
  );

  testWidgets(
    'manual Home Display consumes first Enter and restores original focus',
    (tester) async {
      await mount(tester);
      unawaited(app.currentState!.showScreensaver());
      await tester.pumpAndSettle();
      expect(find.text('Home Display 屏保探针'), findsOneWidget);
      expect(app.currentState!.screensaverVisible, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, isFalse);
      expect(presses, 0);
      expect(buttonFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(presses, 1);
      await cleanup(tester);
    },
  );
  testWidgets('held wake key and repeats never activate the restored page', (
    tester,
  ) async {
    await mount(tester);
    unawaited(app.currentState!.showScreensaver());
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(app.currentState!.screensaverVisible, isFalse);
    expect(presses, 0);
    expect(buttonFocus.hasFocus, isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);
    await cleanup(tester);
  });
  testWidgets(
    'automatic Home Display enters exactly at the injected ten-minute boundary',
    (tester) async {
      await mount(tester);
      now = const Duration(minutes: 10) - const Duration(milliseconds: 1);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      now = const Duration(minutes: 10);
      app.currentState!.checkIdle();
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, isFalse);
      expect(presses, 0);
      now = const Duration(minutes: 19, seconds: 59);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      await cleanup(tester);
    },
  );
  testWidgets(
    'watching owners block idle and stale owner release cannot unblock a new player',
    (tester) async {
      await mount(tester);
      final first = Object(), second = Object();
      owners.addAll([first, second]);
      final activity = CinemaTVPlaybackActivity.instance;
      activity.setWatching(first, true);
      activity.setWatching(second, true);
      now = const Duration(hours: 1);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      activity.release(first);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(activity.isWatching, isTrue);
      expect(app.currentState!.screensaverVisible, isFalse);
      await app.currentState!.showScreensaver();
      expect(
        app.currentState!.screensaverVisible,
        isFalse,
        reason: 'manual route also protects active video',
      );
      activity.release(second);
      await tester.pump();
      now = const Duration(hours: 1, minutes: 9, seconds: 59);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      now = const Duration(hours: 1, minutes: 10);
      app.currentState!.checkIdle();
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await cleanup(tester);
    },
  );
  testWidgets(
    'background time is excluded by the mounted application observer',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = const Duration(hours: 2);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      now = const Duration(hours: 2, minutes: 9, seconds: 59);
      app.currentState!.checkIdle();
      await tester.pump();
      expect(app.currentState!.screensaverVisible, isFalse);
      now = const Duration(hours: 2, minutes: 10);
      app.currentState!.checkIdle();
      await tester.pumpAndSettle();
      expect(app.currentState!.screensaverVisible, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await cleanup(tester);
    },
  );
}
