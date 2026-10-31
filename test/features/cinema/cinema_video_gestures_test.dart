import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_video_gestures.dart';

void main() {
  testWidgets('mouse drag moves the window once without toggling playback', (
    tester,
  ) async {
    var drags = 0, playback = 0, fullscreen = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaVideoGestures(
          controlsInsets: const EdgeInsets.only(top: 52, bottom: 100),
          onWindowDrag: () => drags++,
          onTogglePlayback: () => playback++,
          onToggleFullscreen: () => fullscreen++,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    await tester.dragFrom(
      const Offset(100, 180),
      const Offset(110, 80),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(drags, 1);
    expect(playback, 0);
    expect(fullscreen, 0);
    await tester.dragFrom(
      const Offset(100, 24),
      const Offset(110, 80),
      kind: PointerDeviceKind.mouse,
    );
    await tester.dragFrom(
      const Offset(100, 570),
      const Offset(110, -80),
      kind: PointerDeviceKind.mouse,
    );
    await tester.dragFrom(const Offset(100, 180), const Offset(110, 80));
    await tester.pump(const Duration(milliseconds: 350));
    expect(drags, 1, reason: 'toolbar and touch drags keep their own gestures');
    expect(playback, 0);
    await tester.tapAt(const Offset(100, 180), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 350));
    expect(playback, 1);
    await tester.tapAt(const Offset(100, 180), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(100, 180), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 350));
    expect(playback, 1);
    expect(fullscreen, 1);
    expect(drags, 1);
  });

  testWidgets('volume slider drags stay independent of window dragging', (
    tester,
  ) async {
    var drags = 0, playback = 0;
    var volume = .5;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => CinemaVideoGestures(
            controlsInsets: const EdgeInsets.only(top: 52, bottom: 100),
            onWindowDrag: () => drags++,
            onTogglePlayback: () => playback++,
            onToggleFullscreen: () {},
            child: Material(
              color: Colors.black,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: 400,
                  height: 100,
                  child: Slider(
                    value: volume,
                    onChanged: (value) => update(() => volume = value),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byType(Slider),
      const Offset(100, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(volume, greaterThan(.5));
    expect(drags, 0);
    expect(playback, 0);
  });

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
