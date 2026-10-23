import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_controller.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_prefetch.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_fallbacks.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/request/core/network_config.dart';

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => PlayerState();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _apply(
  Player player,
  String text, {
  String title = '',
  String language = '',
  bool Function()? isCurrent,
}) async {
  if (isCurrent?.call() == false) return;
  cinemaExternalSubtitleState(player).select(
    cinemaSubtitleSrt(text),
    title,
    'live-test',
    0,
    title: title,
    language: language,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a live selected season archive fills all episodes and next episode restores offline',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      CinemaOnlineSubtitles networkClient() => CinemaOnlineSubtitles(
        dio: Dio()
          ..httpClientAdapter = const NetworkConfig(
            proxyHost: '127.0.0.1',
            proxyPort: 7897,
            enableLog: false,
          ).createAdapter(),
      );
      final directory = await Directory.systemTemp.createTemp(
        'naku-season-live-',
      );
      final store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: [],
      );
      await store.load();
      final row = cinemaSubtitleFallbacks(
        title: '美国恐怖故事',
        imdbId: 'tt1844624',
        type: 'series',
        season: 10,
        episode: 3,
      ).first;
      final client = networkClient();
      final batch = CinemaSeasonSubtitlePrefetch.forStore(store);
      final player = _Player();
      final query = const CinemaSubtitleQuery('美国恐怖故事', 'series', 10, 3);
      final episodes = [
        for (var e = 1; e <= 10; e++)
          CinemaSubtitleQuery(query.title, 'series', 10, e),
      ];
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'live-work',
        mediaIdentity: 'third-video',
        query: query,
        seasonEpisodes: episodes,
        apply: _apply,
        prefetchClientFactory: networkClient,
      );
      try {
        final text = await client.download(
          '${row['url']}',
          archiveEntry: row['archiveEntry'] as String,
        );
        await _apply(
          player,
          text,
          title: '${row['subtitleFileName']}',
          language: 'zh',
        );
        await controller.remember(
          CinemaOnlineSubtitleSelection(
            query: query,
            imdbId: 'tt1844624',
            row: {...row, 'verified': true},
            applyToSeason: true,
          ),
        );
        cinemaExternalSubtitleState(
          player,
        ).setTiming(const CinemaSubtitleTiming(offsetSeconds: 7.4));
        await controller.flush();
        await batch.idle.timeout(const Duration(seconds: 110));
        expect(batch.ready, 10);
        expect(batch.failed, 0);
        final profile = CinemaSeasonSubtitlePreferences(
          store,
        ).read('live-work', 10)!;
        expect(profile.timing.offsetSeconds, closeTo(7.4, .01));
        final report = <String, dynamic>{
          'ready': batch.ready,
          'failed': batch.failed,
          'episodes': <Map<String, Object>>[],
        };
        for (var e = 1; e <= 10; e++) {
          final saved = await batch.read('live-work', profile, e);
          expect(saved, isNotNull);
          expect(cinemaSubtitleCues(saved!.text), isNotEmpty);
          (report['episodes'] as List).add({
            'episode': e,
            'cues': cinemaSubtitleCues(saved.text).length,
            'title': saved.title,
            'inheritsTiming': saved.inheritToSeason,
          });
        }
        controller.close();
        final nextPlayer = _Player();
        final next = CinemaSeasonSubtitleController(
          player: nextPlayer,
          store: store,
          seriesIdentity: 'live-work',
          mediaIdentity: 'fourth-video-new-url',
          query: episodes[3],
          apply: _apply,
        );
        await next.load();
        expect(cinemaExternalSubtitleState(nextPlayer).active.value, true);
        expect(
          cinemaExternalSubtitleState(nextPlayer).title,
          contains('S10E04'),
        );
        expect(next.status.value, contains('本季缓存'));
        next.close();
        await next.flush();
        await closeCinemaExternalSubtitles(nextPlayer);
        debugPrint('LIVE_SEASON_SUBTITLES: ${jsonEncode(report)}');
        final path = Platform.environment['NAKU_SEASON_SUBTITLE_EVIDENCE'];
        if (path != null) await File(path).writeAsString(jsonEncode(report));
      } finally {
        controller.close();
        batch.cancel('live-work');
        await batch.idle;
        client.close();
        await controller.flush();
        await closeCinemaExternalSubtitles(player);
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('NAKU_SEASON_SUBTITLE_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
