import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const directory = String.fromEnvironment('SUBTITLE_NATIVE_FIXTURES');
  testWidgets(
    'packaged Flutter MPV extracts bounded PCM and calibrates real dialogue offline',
    (tester) async {
      debugPrint('PIPELINE_STAGE: starting file check');
      final media = File('$directory/dialogue.wav');
      expect(await media.exists(), isTrue);
      final rows =
          (jsonDecode(await File('$directory/cues.json').readAsString())
                  as Map)['cues']
              as List;
      String stamp(int milliseconds) {
        final t = Duration(milliseconds: milliseconds);
        return '${t.inHours.toString().padLeft(2, '0')}:${(t.inMinutes % 60).toString().padLeft(2, '0')}:${(t.inSeconds % 60).toString().padLeft(2, '0')},${(milliseconds % 1000).toString().padLeft(3, '0')}';
      }

      final text = [
        for (var i = 0; i < rows.length; i++)
          '${i + 1}\n${stamp((rows[i][0] as num).toInt() + 5000)} --> ${stamp((rows[i][1] as num).toInt() + 5000)}\nSelf authored dialogue $i\n',
      ].join('\n');
      debugPrint('PIPELINE_STAGE: creating player');
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native
          .setProperty('ao', 'null')
          .timeout(const Duration(seconds: 15));
      debugPrint('PIPELINE_STAGE: opening media');
      final duration = player.stream.duration.firstWhere(
        (d) => d.inSeconds > 300,
      );
      await player.open(Media(media.path)).timeout(const Duration(seconds: 15));
      await duration.timeout(const Duration(seconds: 15));
      await player.setRate(1.5);
      await player.seek(const Duration(milliseconds: 4500));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await player.pause();
      debugPrint('PIPELINE_STAGE: applying subtitle');
      await applyCinemaExternalSubtitle(
        player,
        text,
        title: 'self-authored.srt',
        language: 'en',
      );
      final sync = CinemaSubtitleAutoSync(player, media: () => media.path);
      try {
        debugPrint('PIPELINE_STAGE: extracting audio');
        final watch = Stopwatch()..start();
        await sync
            .run(anchorCue: cinemaExternalSubtitleState(player).cues.first)
            .timeout(const Duration(seconds: 18));
        debugPrint('FIVE_SECOND_SYNC_WALL_MS: ${watch.elapsedMilliseconds}');
        expect(sync.busy, isFalse);
        expect(
          sync.outcome,
          CinemaSubtitleSyncOutcome.succeeded,
          reason: sync.message,
        );
        final timing = cinemaExternalSubtitleState(player).timing.value;
        expect(timing.offsetSeconds, closeTo(-5, .7), reason: sync.message);
        expect(timing.scale, closeTo(1, .002));
        expect(player.state.playing, isFalse);
        expect(player.state.rate, 1.5);
        debugPrint('NATIVE_PIPELINE: ${sync.message}');
      } finally {
        sync.dispose();
        await closeCinemaExternalSubtitles(player);
        await player.dispose();
      }
    },
    skip: directory.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
