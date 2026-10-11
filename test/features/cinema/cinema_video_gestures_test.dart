import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_video_gestures.dart';

void main() {
  testWidgets(
    'toolbar clicks do not wait for the video double-click deadline',
    (tester) async {
      var presses = 0, play = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 600,
            height: 400,
            child: CinemaVideoGestures(
              controlsInsets: const EdgeInsets.only(top: 52, bottom: 100),
              onTogglePlayback: () => play++,
              onToggleFullscreen: () {},
              child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  tooltip: 'pip',
                  onPressed: () => presses++,
                  icon: const Icon(Icons.picture_in_picture),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('pip'));
      await tester.pump();
      expect(presses, 1);
      expect(play, 0);
    },
  );

  testWidgets(
    'single click toggles once; double click only toggles fullscreen; buttons remain independent',
    (tester) async {
      var playback = 0, fullscreen = 0, buttons = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaVideoGestures(
              onTogglePlayback: () => playback++,
              onToggleFullscreen: () => fullscreen++,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.black)),
                  Center(
                    child: IconButton(
                      tooltip: 'setting',
                      onPressed: () => buttons++,
                      icon: const Icon(Icons.settings),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      const video = Offset(40, 40);
      await tester.tapAt(video);
      await tester.pump(const Duration(milliseconds: 350));
      expect(playback, 1);
      await tester.tapAt(video);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(video);
      await tester.pump(const Duration(milliseconds: 350));
      expect(fullscreen, 1);
      expect(playback, 1);
      await tester.tap(find.byTooltip('setting'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(buttons, 1);
      expect(playback, 1);
      expect(fullscreen, 1);
    },
  );
}
