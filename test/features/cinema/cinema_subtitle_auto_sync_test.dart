import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';

void main() {
  final random = Random(42);
  final cues = <CinemaSubtitleCue>[];
  var time = 2.0;
  for (var i = 0; i < 150; i++) {
    final length = 1 + random.nextDouble() * 3;
    cues.add(
      CinemaSubtitleCue(
        (time * 1000).round(),
        ((time + length) * 1000).round(),
        'self-authored $i',
      ),
    );
    time += length + .5 + random.nextDouble() * 4;
  }
  List<CinemaVoiceWindow> sample({double offset = 0, double scale = 1}) => [
    for (final start in [25.0, 400.0])
      CinemaVoiceWindow(
        start,
        Uint8List.fromList(
          List.generate(3750, (i) {
            final media = start + i * .02;
            return cues.any(
                  (cue) =>
                      media >= cue.start / 1000 * scale + offset &&
                      media < cue.end / 1000 * scale + offset,
                )
                ? 1
                : 0;
          }),
        ),
      ),
  ];
  test(
    'two independent voice windows recover positive and negative offsets',
    () {
      for (final offset in [6.7, -12.3, 0.0]) {
        final result = matchCinemaSubtitleVoice(cues, sample(offset: offset));
        expect(result.timing, isNotNull, reason: result.message);
        expect(result.timing!.offsetSeconds, closeTo(offset, .15));
        expect(result.timing!.scale, closeTo(1, .0005));
      }
    },
  );
  test('two distant dialogues recover gradual frame-rate drift', () {
    final result = matchCinemaSubtitleVoice(
      cues,
      sample(offset: 4.2, scale: 1.001),
    );
    expect(result.timing, isNotNull, reason: result.message);
    expect(result.timing!.offsetSeconds, closeTo(4.2, .3));
    expect(result.timing!.scale, closeTo(1.001, .0007));
  });
  test(
    'silence, music-like constant activity and unrelated speech never retime captions',
    () {
      for (final bits in [
        Uint8List(3750),
        Uint8List.fromList(List.filled(3750, 1)),
        Uint8List.fromList(
          List.generate(3750, (_) => random.nextBool() ? 1 : 0),
        ),
      ]) {
        expect(
          matchCinemaSubtitleVoice(cues, [
            CinemaVoiceWindow(25, bits),
            CinemaVoiceWindow(400, bits),
          ]).timing,
          isNull,
        );
      }
      expect(
        matchCinemaSubtitleVoice(cues, sample().take(1).toList()).timing,
        isNull,
      );
    },
  );
  test('different edits with inconsistent dialogue timing are rejected', () {
    final first = sample(offset: 4).first;
    final second = sample(offset: 60).last;
    expect(matchCinemaSubtitleVoice(cues, [first, second]).timing, isNull);
  });
  const fixture = String.fromEnvironment('SUBTITLE_VOICE_FIXTURE');
  test('real WebRTC VAD output aligns locally synthesized dialogue', () {
    final data = jsonDecode(File(fixture).readAsStringSync()) as Map;
    final original = [
      for (final row in data['cues'] as List)
        CinemaSubtitleCue(
          (row[0] as num).toInt(),
          (row[1] as num).toInt(),
          'self-authored voice',
        ),
    ];
    final speech = Uint8List.fromList((data['speech'] as List).cast<int>());
    final windows = [
      for (final start in [20.0, 230.0])
        CinemaVoiceWindow(
          start,
          Uint8List.sublistView(
            speech,
            (start * 50).round(),
            ((start + 75) * 50).round(),
          ),
        ),
    ];
    // Subtitles are 5 seconds early; raw audio supplies the reference clock.
    final early = original
        .map(
          (cue) =>
              CinemaSubtitleCue(cue.start - 5000, cue.end - 5000, cue.text),
        )
        .toList();
    final result = matchCinemaSubtitleVoice(early, windows);
    expect(result.timing, isNotNull, reason: result.message);
    expect(result.timing!.offsetSeconds, closeTo(5, .65));
  }, skip: fixture.isEmpty);
}
