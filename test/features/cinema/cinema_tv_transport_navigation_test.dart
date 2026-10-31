import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_player_controls.dart';
import 'package:kazumi/features/cinema/cinema_tv_auxiliary.dart';
import 'package:kazumi/features/cinema/cinema_tv_motion.dart';

void main() {
  for (final width in [960.0, 1280.0]) {
    for (final episodes in [false, true]) {
      testWidgets(
        'TV $width episodes=$episodes reaches subtitles/danmaku across the wide gap',
        (tester) async {
          tester.view.physicalSize = Size(width, 540);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final timeline = FocusNode(debugLabel: 'timeline');
          final play = FocusNode(debugLabel: 'play'),
              episode = FocusNode(debugLabel: 'episodes');
          final subtitle = FocusNode(debugLabel: 'subtitle'),
              danmaku = FocusNode(debugLabel: 'danmaku');
          final preview = CinemaTVSeekPreview();
          var plays = 0;
          late BuildContext pageContext;
          Future<void> panel(String title, FocusNode restore) async {
            await showCinemaTVPanel<void>(
              pageContext,
              title: title,
              builder: (_) => Center(
                child: TextButton(
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('面板操作'),
                ),
              ),
            );
            restore.requestFocus();
          }

          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) {
                  pageContext = context;
                  return Scaffold(
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: CinemaTVControlSurface(
                        child: CinemaTVControlNavigation(
                          timeline: timeline,
                          actions: [
                            play,
                            if (episodes) episode,
                            subtitle,
                            danmaku,
                          ],
                          onActivity: () {},
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CinemaTVTimeline(
                                compact: true,
                                position: const Duration(seconds: 30),
                                duration: const Duration(seconds: 120),
                                preview: preview,
                                focusNode: timeline,
                                onCommit: (_) {},
                                onActivity: () {},
                              ),
                              Row(
                                children: [
                                  FilledButton(
                                    focusNode: play,
                                    autofocus: true,
                                    onPressed: () => plays++,
                                    child: const Text('播放'),
                                  ),
                                  if (episodes)
                                    TextButton(
                                      focusNode: episode,
                                      onPressed: () {},
                                      child: const Text('选集'),
                                    ),
                                  const Spacer(),
                                  OutlinedButton(
                                    focusNode: subtitle,
                                    onPressed: () => panel('字幕', subtitle),
                                    child: const Text('字幕'),
                                  ),
                                  const SizedBox(width: 14),
                                  OutlinedButton(
                                    focusNode: danmaku,
                                    onPressed: () => panel('弹幕', danmaku),
                                    child: const Text('弹幕'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(play.hasFocus, true);
          expect(
            tester.getSize(find.byType(CinemaTVControlSurface)).height,
            lessThan(160),
          );
          if (episodes) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pump();
            expect(episode.hasFocus, true);
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(subtitle.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(find.text('面板操作'), findsOneWidget);
          expect(plays, 0);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(subtitle.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(danmaku.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('面板操作'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(danmaku.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
          await tester.pumpAndSettle();
          expect(find.text('面板操作'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(danmaku.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump();
          expect(timeline.hasFocus, true);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(preview.target, const Duration(seconds: 40));
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          expect(danmaku.hasFocus, true);
          expect(preview.active, false);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          for (final node in [timeline, play, episode, subtitle, danmaku]) {
            node.dispose();
          }
          preview.dispose();
        },
      );
    }
  }
  testWidgets(
    'system Reduce Motion disables TV focus/panel animation durations',
    (tester) async {
      late Duration duration;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) {
                duration = CinemaTVMotion.duration(
                  context,
                  CinemaTVMotion.panel,
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(duration, Duration.zero);
    },
  );
}
