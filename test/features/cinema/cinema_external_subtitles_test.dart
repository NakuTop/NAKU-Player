import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_appearance.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state =>
      const PlayerState(position: Duration(milliseconds: 1500));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'downloaded captions render from playback time without a native subtitle event',
    (tester) async {
      final player = _Player();
      final state = cinemaExternalSubtitleState(player);
      state.select(
        '1\n00:00:01,000 --> 00:00:02,000\n中文字幕\nOriginal line\n',
        'fixture.srt',
        '1',
        0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 450,
            child: CinemaExternalSubtitleOverlay(
              player: player,
              appearance: const CinemaSubtitleAppearance(),
            ),
          ),
        ),
      );
      expect(find.text('中文字幕\nOriginal line'), findsOneWidget);
      state.setDelay(1);
      await tester.pump();
      expect(find.text('中文字幕\nOriginal line'), findsNothing);
      state.updatePosition(const Duration(milliseconds: 2500));
      await tester.pump();
      expect(find.text('中文字幕\nOriginal line'), findsOneWidget);
      state.updatePosition(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('中文字幕\nOriginal line'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await state.close();
    },
  );
  test(
    'styled bilingual ASS becomes a timed UTF8-compatible SRT without drawings',
    () {
      const text = r'''[Script Info]
ScriptType: v4.00+
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.25,0:00:03.50,Default,,0,0,0,,{\fn微软雅黑\fs36}中文字幕\NOriginal, with comma
Dialogue: 1,0:00:01.25,0:00:03.50,Default,,0,0,0,,中文字幕
Dialogue: 0,0:00:03.50,0:00:04.00,Default,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}下一句
''';
      final srt = cinemaSubtitleSrt(text.replaceAll(r'\\', r'\'));
      expect(srt, contains('00:00:01,250 --> 00:00:03,500'));
      expect(srt, contains('中文字幕\nOriginal, with comma'));
      expect(srt, contains('下一句'));
      expect(srt, isNot(contains('m 0 0')));
      expect(srt, isNot(contains(r'\fn')));
      expect(cinemaSubtitleCues(srt), hasLength(2));
    },
  );
  test(
    'WebVTT short timestamps, cue settings and HTML formatting are preserved as plain cues',
    () {
      final text = cinemaSubtitleSrt(
        'WEBVTT\n\ncue-1\n00:01.250 --> 00:02.500 align:start\n<b>中文字幕</b>\nOriginal\n',
      );
      expect(text, contains('00:00:01,250 --> 00:00:02,500'));
      expect(text, contains('中文字幕\nOriginal'));
    },
  );
  test('header-only and malformed subtitles are not marked usable', () {
    for (final text in [
      '[Script Info]\n[Events]',
      'not subtitles --> error',
      '1\n00:00:04,000 --> 00:00:03,000\nwrong order',
    ]) {
      expect(() => cinemaSubtitleSrt(text), throwsFormatException);
    }
  });
}
