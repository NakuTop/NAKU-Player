import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_fallbacks.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';

// Preserve the installed app's Windows system proxy and production adapter.
class _ProductionHttp extends HttpOverrides {}

void main() {
  test(
    'a public full-season archive contains distinct Chinese dialogue for E01 to E10',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        SystemProxyService.refresh();
        final client = CinemaOnlineSubtitles();
        try {
          const groups = [
            'GLHF',
            'GLHF',
            'GGEZ',
            'GGWP',
            'GGWP',
            'GGEZ',
            'GGEZ',
            'GGEZ',
            'GGEZ',
            'GGWP',
          ];
          final fingerprints = <String>{};
          for (var episode = 1; episode <= 10; episode++) {
            final code = 'S10E${episode.toString().padLeft(2, '0')}';
            final entry =
                'American.Horror.Story.$code.'
                '${episode == 8 ? 'REPACK.' : ''}2160p.WEB.H265-${groups[episode - 1]}.ass';
            final text = await client.download(
              'https://assrt.net/download/645218/American.Horror.Story.S10.2160p.WEB.H265-GGEZ.rar',
              archiveEntry: entry,
            );
            final cues = cinemaSubtitleCues(text);
            final chinese = cues
                .where((cue) => RegExp(r'[\u4e00-\u9fff]').hasMatch(cue.text))
                .length;
            final english = cues
                .where((cue) => RegExp(r'[A-Za-z]{2,}').hasMatch(cue.text))
                .length;
            expect(chinese, greaterThan(100), reason: entry);
            expect(english, greaterThan(100), reason: entry);
            expect(
              fingerprints.add(text),
              isTrue,
              reason: '$code must not reuse another episode',
            );
            if (episode == 2) {
              final original = cinemaSubtitleFallbacks(
                title: '美国恐怖故事',
                imdbId: 'tt1844624',
                type: 'series',
                season: 10,
                episode: 2,
              ).first;
              final previous = await client.download(
                '${original['url']}',
                archiveEntry: original['archiveEntry'] as String?,
              );
              // ignore: avoid_print
              print(
                'E02 selected/full-season normalized dialogue and timing identical: '
                '${cinemaSubtitleSrt(previous) == cinemaSubtitleSrt(text)}',
              );
            }
            // ignore: avoid_print
            print(
              'Verified $code: $entry; Chinese=$chinese, English=$english, total=${cues.length}',
            );
          }
        } finally {
          client.close();
        }
      }, _ProductionHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_SEASON_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'a selected S10E02 Chinese family has a real downloadable S10E03 successor',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        SystemProxyService.refresh();
        final client = CinemaOnlineSubtitles();
        try {
          final selected = cinemaSubtitleFallbacks(
            title: '美国恐怖故事',
            imdbId: 'tt1844624',
            type: 'series',
            season: 10,
            episode: 2,
          ).first;
          final previous = await client.download(
            '${selected['url']}',
            archiveEntry: selected['archiveEntry'] as String?,
          );
          int chinese(String text) => cinemaSubtitleCues(text)
              .where((cue) => RegExp(r'[\u4e00-\u9fff]').hasMatch(cue.text))
              .length;
          expect(chinese(previous), greaterThan(100));
          final profile = CinemaSeasonSubtitleProfile(
            season: 10,
            fromEpisode: 2,
            queryTitle: '美国恐怖故事',
            imdbId: 'tt1844624',
            language: 'zh',
            name: '${selected['archiveEntry']}',
            provider: '${selected['provider']}',
            releaseFormat: '${selected['releaseFormat']}',
            bilingual: true,
          );
          final result = await client.aggregate(
            profile.queryTitle,
            'series',
            imdbId: profile.imdbId,
            season: 10,
            episode: 3,
            language: profile.language,
            mediaRelease: 'American.Horror.Story.S10E03.AMZN.WEB-DL.FLUX.mkv',
          );
          // Counts and public release metadata only; no private media or dialogue.
          // ignore: avoid_print
          print('Production S10E03 season successor: ${result.status}');
          final chosen = chooseCinemaSeasonSubtitle(
            profile,
            result.rows,
            season: 10,
            episode: 3,
            playbackName: 'American.Horror.Story.S10E03.AMZN.FLUX.mkv',
          );
          expect(chosen, isNotNull, reason: result.status.toString());
          final row = chosen!;
          final name = '${row['archiveEntry'] ?? row['subtitleFileName']}';
          expect(name.toUpperCase(), contains('S10E03'));
          expect(cinemaSubtitleEpisodeMatches(name, 10, 2), false);
          final text = await client.download(
            '${row['url']}',
            archiveEntry: row['archiveEntry'] as String?,
          );
          final count = chinese(text);
          expect(count, greaterThan(100));
          // ignore: avoid_print
          print('Verified E03 public file: $name; Chinese timed cues: $count');
        } finally {
          client.close();
        }
      }, _ProductionHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_SEASON_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
