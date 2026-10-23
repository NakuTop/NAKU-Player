import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_clip_match.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

List<CinemaSpokenWord> phrase(String text, double start) => [
  for (final (i, token) in text.split(' ').indexed)
    CinemaSpokenWord(token, start + i * .25, start + i * .25 + .2, .95),
];

void main() {
  test(
    'five-second words locate a unique bilingual cue and preserve time scale',
    () {
      final result = matchCinemaSubtitleWords(
        [
          const CinemaSubtitleCue(
            10000,
            13000,
            '中文字幕\nWe found another blue planet today',
          ),
          const CinemaSubtitleCue(
            20000,
            23000,
            '中文字幕\nNobody will ever forget this moment',
          ),
        ],
        phrase('We found another blue planet today', .4),
        startSeconds: 15,
        current: const CinemaSubtitleTiming(scale: 1.001),
      );
      expect(result.timing, isNotNull);
      expect(result.timing!.offsetSeconds, closeTo(5.39, .01));
      expect(result.timing!.scale, 1.001);
    },
  );
  test(
    'repeated dialogue, clipped onsets and unrelated translated text do not retime',
    () {
      for (final cues in [
        [
          const CinemaSubtitleCue(
            10000,
            13000,
            'We found another blue planet today',
          ),
          const CinemaSubtitleCue(
            60000,
            63000,
            'We found another blue planet today',
          ),
        ],
        [const CinemaSubtitleCue(10000, 13000, '我们发现了另一个蓝色星球')],
      ]) {
        expect(
          matchCinemaSubtitleWords(
            cues,
            phrase('We found another blue planet today', .4),
            startSeconds: 15,
          ).timing,
          isNull,
        );
      }
      expect(
        matchCinemaSubtitleWords(
          [
            const CinemaSubtitleCue(
              10000,
              13000,
              'We found another blue planet today',
            ),
          ],
          phrase('We found another blue planet today', 0),
          startSeconds: 15,
        ).timing,
        isNull,
      );
    },
  );
  test(
    'dialogue planner finds words near silence without seeking the player',
    () {
      final start = cinemaSubtitleDialogueStart(
        [
          const CinemaSubtitleCue(
            40000,
            44000,
            'Only a distant sentence is available here',
          ),
          const CinemaSubtitleCue(
            100000,
            104000,
            'Our spaceship has finally reached the blue planet',
          ),
        ],
        position: 108,
        duration: 180,
      );
      expect(start, closeTo(99.6, .01));
      expect(start, greaterThanOrEqualTo(0));
      expect(cinemaSubtitleDialogueStart([], position: 1, duration: 4), 0);
    },
  );

  const directory = String.fromEnvironment('NAKU_WORD_MATCH_FIXTURES');
  test(
    'native recognized real five-second speech matches the saved subtitle',
    () async {
      final subtitle =
          jsonDecode(await File('$directory/subtitle.json').readAsString())
              as Map;
      final cues = cinemaSubtitleCues(subtitle['text']);
      var accepted = 0;
      for (final clip in [0, 5, 10]) {
        final d =
            jsonDecode(
                  await File(
                    '$directory/clip-$clip-recognition.json',
                  ).readAsString(),
                )
                as Map;
        final words = [
          for (final w in d['segments'] as List)
            CinemaSpokenWord(
              w['text'],
              (w['start'] as num).toDouble(),
              (w['end'] as num).toDouble(),
              (w['confidence'] as num).toDouble(),
            ),
        ];
        final watch = Stopwatch()..start();
        final result = matchCinemaSubtitleWords(
          cues,
          words,
          startSeconds: 2000.0 + clip,
        );
        debugPrint(
          'REAL_WORD_MATCH: clip=$clip words=${words.length} offset=${result.timing?.offsetSeconds} score=${result.confidence} ms=${watch.elapsedMilliseconds}',
        );
        if (result.timing != null) {
          accepted++;
          expect(
            result.timing!.offsetSeconds,
            closeTo((subtitle['offset'] as num).toDouble(), 1.5),
          );
        }
      }
      expect(accepted, greaterThanOrEqualTo(1));
    },
    skip: directory.isEmpty,
  );
}
