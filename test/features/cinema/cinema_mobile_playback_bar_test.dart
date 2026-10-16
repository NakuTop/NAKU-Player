import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_mobile_playback_bar.dart';

void main() {
  for (final width in [288.0, 328.0, 720.0]) {
    testWidgets(
      'mobile touch controls remain visible and actionable at $width',
      (tester) async {
        final calls = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: CinemaMobilePlaybackBar(
                    playing: false,
                    fullscreen: false,
                    position: '02:03',
                    duration: '20:00',
                    onBackward: () => calls.add('back'),
                    onPlay: () => calls.add('play'),
                    onForward: () => calls.add('forward'),
                    onQuality: () => calls.add('quality'),
                    onTracks: () => calls.add('tracks'),
                    onFullscreen: () => calls.add('fullscreen'),
                  ),
                ),
              ),
            ),
          ),
        );
        for (final label in ['后退', '播放', '快进', '清晰度与播放设置', '字幕与音轨', '全屏']) {
          final button = find.byTooltip(label);
          expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
          await tester.tap(button);
        }
        expect(calls, [
          'back',
          'play',
          'forward',
          'quality',
          'tracks',
          'fullscreen',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
