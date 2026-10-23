import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const directory = String.fromEnvironment('NAKU_WORD_NATIVE_FIXTURES');
  testWidgets(
    'native five-second speech, subtitle text matching and saving run without AI service',
    (tester) async {
      final file = File('$directory/word-dialogue.wav');
      expect(await file.exists(), isTrue);
      final rows =
          jsonDecode(await File('$directory/word-cues.json').readAsString())
              as List;
      String stamp(int n) {
        final d = Duration(milliseconds: n);
        return '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')},${(n % 1000).toString().padLeft(3, '0')}';
      }

      final text = [
        for (final (i, row) in rows.indexed)
          '${i + 1}\n${stamp((row[0] as num).round() + 7000)} --> ${stamp((row[1] as num).round() + 7000)}\n${row[2]}\n',
      ].join('\n');
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      final duration = player.stream.duration.firstWhere(
        (d) => d.inSeconds > 20,
      );
      await player.open(Media(file.path));
      await duration.timeout(const Duration(seconds: 15));
      await player.seek(const Duration(seconds: 12));
      await player.pause();
      await player.setRate(1.5);
      await applyCinemaExternalSubtitle(
        player,
        text,
        title: 'unique-self-authored.srt',
        language: 'en',
      );
      var saves = 0;
      final session = cinemaExternalSubtitleState(player);
      session.saveTiming = (_, _) async {
        saves++;
      };
      final diagnostics = <Map<String, dynamic>>[];
      final sync = CinemaSubtitleAutoSync(
        player,
        media: () => file.path,
        inspectRecognition: (window, words) {
          diagnostics.add({
            'start': window.startSeconds,
            'bytes': window.pcm?.length,
            'speech': window.speech.toList(),
            'words': [
              for (final w in words)
                {
                  'text': w.text,
                  'start': w.start,
                  'end': w.end,
                  'confidence': w.confidence,
                },
            ],
          });
        },
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final reports = <Map<String, dynamic>>[];
        for (final seconds in [5, 20]) {
          sync.setSampleSeconds(seconds);
          final position = player.state.position;
          final watch = Stopwatch()..start();
          await sync.run().timeout(const Duration(seconds: 48));
          await File(
            '$directory/word-sync-diagnostic.json',
          ).writeAsString(jsonEncode(diagnostics));
          expect(sync.busy, isFalse);
          expect(
            sync.outcome,
            CinemaSubtitleSyncOutcome.succeeded,
            reason: sync.message,
          );
          expect(
            session.timing.value.offsetSeconds,
            closeTo(-7, .6),
            reason: sync.message,
          );
          expect(session.timing.value.scale, 1);
          expect(saves, greaterThanOrEqualTo(1));
          expect(
            diagnostics.last['bytes'] as int,
            inInclusiveRange((seconds - 1) * 32000, seconds * 32000),
          );
          expect(player.state.playing, isFalse);
          expect(player.state.rate, 1.5);
          expect(
            (player.state.position - position).inMilliseconds.abs(),
            lessThan(250),
          );
          final row = {
            'seconds': watch.elapsedMilliseconds / 1000,
            'offset': session.timing.value.offsetSeconds,
            'saved': saves,
            'terminal': sync.message,
            'sampleSeconds': seconds,
          };
          debugPrint('NATIVE_WORD_SYNC: ${jsonEncode(row)}');
          reports.add(row);
        }
        await File(
          '$directory/word-sync-result.json',
        ).writeAsString(jsonEncode(reports));
        // Silence must not hallucinate a subtitle anchor or leave native work running.
        final silent = await const MethodChannel('naku/subtitle-tools')
            .invokeListMethod('transcribeClip', {
              'id': 'native-silence-check',
              'locale': 'en-US',
              'pcm': Uint8List(160000),
            });
        expect(silent, isEmpty);
      } finally {
        sync.dispose();
        await closeCinemaExternalSubtitles(player);
        await player.dispose();
      }
    },
    skip: directory.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
