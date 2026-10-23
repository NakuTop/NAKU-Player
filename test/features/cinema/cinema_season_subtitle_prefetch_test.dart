import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_saved_subtitle.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_controller.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_prefetch.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

Map<String, dynamic> _row(int episode, {String family = 'AMZN.FLUX'}) => {
  'url': 'https://subtitles.invalid/$family-$episode.srt',
  'subtitleFileName':
      'Fixture.S02E${episode.toString().padLeft(2, '0')}.$family.srt',
  'lang': 'zh',
  'provider': 'fixture',
  'verified': true,
};
String _text(int episode) =>
    '1\n00:00:01,000 --> 00:00:03,000\n第 $episode 集自写对白\n';
const _episodes = [
  CinemaSubtitleQuery('Fixture', 'series', 2, 1),
  CinemaSubtitleQuery('Fixture', 'series', 2, 2),
  CinemaSubtitleQuery('Fixture', 'series', 2, 3),
  CinemaSubtitleQuery('Fixture', 'series', 3, 1),
];

class _Client extends CinemaOnlineSubtitles {
  final requests = <int>[];
  final unavailable = <int>{};
  String family = 'AMZN.FLUX';
  Completer<void>? gate;
  final started = Completer<void>();
  bool closed = false;
  bool emitEarly = false;
  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    requests.add(episode);
    expect(query, 'Fixture');
    expect(type, 'series');
    expect(season, 2);
    if (!started.isCompleted) started.complete();
    final rows = [
      if (!unavailable.contains(episode)) _row(episode, family: family),
      // A better-looking file from a different episode is never reused.
      _row(99),
    ];
    if (emitEarly) onVerified?.call(rows);
    await gate?.future;
    return CinemaSubtitleCatalogResult(rows, const {});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async =>
      _text(int.parse(RegExp(r'-(\d+)\.srt$').firstMatch(url)![1]!));
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => PlayerState(playing: true, rate: 1.5);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ArchiveAdapter implements HttpClientAdapter {
  _ArchiveAdapter(this.bytes);
  final List<int> bytes;
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests++;
    expect(options.uri.host, 'captions.invalid');
    return ResponseBody.fromBytes(bytes, 200);
  }

  @override
  void close({bool force = false}) {}
}

class _ArchiveClient extends CinemaOnlineSubtitles {
  _ArchiveClient(_ArchiveAdapter adapter)
    : super(dio: Dio()..httpClientAdapter = adapter);
  int searches = 0;
  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    searches++;
    return CinemaSubtitleCatalogResult(const [], const {});
  }
}

Future<void> _apply(
  Player player,
  String text, {
  String title = '',
  String language = '',
  bool Function()? isCurrent,
}) async {
  if (isCurrent?.call() == false) return;
  cinemaExternalSubtitleState(
    player,
  ).select(text, title, 'fixture', 0, title: title, language: language);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  late CinemaSeasonSubtitlePreferences prefs;
  late CinemaSeasonSubtitlePrefetch batch;
  late CinemaSeasonSubtitleProfile profile;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-season-prefetch-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [],
    );
    await store.load();
    prefs = CinemaSeasonSubtitlePreferences(store);
    await prefs.remember(
      seriesIdentity: 'work',
      season: 2,
      fromEpisode: 2,
      queryTitle: 'Fixture',
      row: _row(2),
      timing: const CinemaSubtitleTiming(offsetSeconds: 1.5),
    );
    profile = prefs.read('work', 2)!;
    batch = CinemaSeasonSubtitlePrefetch.forStore(store);
  });
  tearDown(() async {
    batch.cancel('work');
    await batch.idle;
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'downloads all known episodes once, next first, excludes other season and wrong episode',
    () async {
      final client = _Client();
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => client,
      );
      expect(client.requests, [3, 1, 2]);
      expect(batch.ready, 3);
      expect(batch.failed, 0);
      expect(batch.busy, false);
      for (final n in [1, 2, 3]) {
        final cached = await batch.read('work', profile, n);
        expect(cached!.text, contains('第 $n 集'));
        expect(cached.inheritToSeason, true);
      }
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => throw StateError('must deduplicate'),
      );
      expect(client.requests, hasLength(3));
      expect(await batch.read('another-work', profile, 3), isNull);
    },
  );

  test(
    'a selected archive supplies an arbitrary whole season without repeated catalog searches',
    () async {
      final pack = Directory('${directory.path}/pack')..createSync();
      final names = <String>[];
      for (final n in [1, 2, 3]) {
        final name = '${_row(n)['subtitleFileName']}';
        names.add(name);
        await File('${pack.path}/$name').writeAsString(_text(n));
      }
      await File(
        '${pack.path}/Fixture.S03E01.AMZN.FLUX.srt',
      ).writeAsString(_text(99));
      await File('${pack.path}/readme.srt').writeAsString(_text(98));
      final archive = File('${directory.path}/season.tar');
      final tar = await Process.run('/usr/bin/tar', [
        '-cf',
        archive.path,
        '-C',
        pack.path,
        '.',
      ]);
      expect(tar.exitCode, 0);
      final adapter = _ArchiveAdapter(await archive.readAsBytes());
      final client = _ArchiveClient(adapter);
      await batch.rememberSource('work', profile, {
        ..._row(2),
        'url': 'https://captions.invalid/season.tar',
        'archiveEntry': './${names[1]}',
      });
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => client,
      );
      expect(batch.ready, 3);
      expect(batch.failed, 0);
      expect(
        adapter.requests,
        1,
        reason: 'the whole archive is downloaded once',
      );
      expect(client.searches, 0);
      for (final n in [1, 2, 3]) {
        expect(
          (await batch.read('work', profile, n))!.text,
          contains('第 $n 集'),
        );
      }
      expect(
        (await store.exportLibrary()).toString(),
        isNot(contains('captions.invalid')),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'entering an episode waits for its background file instead of starting a second search',
    () async {
      final client = _Client()..gate = Completer<void>();
      final pending = batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => client,
      );
      await client.started.future;
      final player = _Player();
      final foreground = _Client();
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'work',
        mediaIdentity: 'new-next-video',
        query: _episodes[2],
        seasonEpisodes: _episodes,
        client: foreground,
        prefetchClientFactory: () => client,
        apply: _apply,
      );
      final loading = controller.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.status.value, contains('本季字幕缓存'));
      client.gate!.complete();
      await loading;
      await pending;
      expect(
        cinemaExternalSubtitleState(player).normalizedSubtitle,
        contains('第 3 集'),
      );
      expect(foreground.requests, isEmpty);
      expect(client.requests.where((n) => n == 3), hasLength(1));
      controller.close();
      await controller.flush();
      await closeCinemaExternalSubtitles(player);
    },
  );

  test(
    'an uncached active episode moves ahead of the remaining queue',
    () async {
      final client = _Client()..gate = Completer<void>();
      final pending = batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => client,
      );
      await client.started.future;
      final waiting = batch.waitForEpisode('work', profile, 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      client.gate!.complete();
      expect((await waiting)!.text, contains('第 2 集'));
      await pending;
      expect(client.requests, [3, 2, 1]);
    },
  );

  test(
    'cached next episode loads offline and inherits the latest calibration without changing playback',
    () async {
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: _Client.new,
      );
      await prefs.updateTiming(
        'work',
        2,
        const CinemaSubtitleTiming(scale: .99, offsetSeconds: -2.5),
      );
      final offline = _Client()..unavailable.addAll([1, 2, 3]);
      final player = _Player();
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'work',
        mediaIdentity: 'new-rotating-url',
        query: _episodes[2],
        client: offline,
        apply: _apply,
      );
      await controller.load();
      final session = cinemaExternalSubtitleState(player);
      expect(session.normalizedSubtitle, contains('第 3 集'));
      expect(session.delay, -2.5);
      expect(session.timing.value.scale, .99);
      expect(offline.requests, isEmpty);
      expect(player.state.playing, true);
      expect(player.state.rate, 1.5);
      controller.close();
      await controller.flush();
      await session.close();
      offline.close();
    },
  );

  test(
    'one verified early match completes the job while another catalog is still waiting',
    () async {
      final client = _Client()
        ..emitEarly = true
        ..gate = Completer<void>();
      try {
        await batch
            .start(
              series: 'work',
              profile: profile,
              episodes: [_episodes[2]],
              currentEpisode: 2,
              clientFactory: () => client,
            )
            .timeout(const Duration(seconds: 2));
        expect(client.gate!.isCompleted, false);
        expect(batch.ready, 1);
        expect((await batch.read('work', profile, 3))!.text, contains('第 3 集'));
        expect(client.closed, true);
      } finally {
        client.gate!.complete();
      }
    },
  );

  test(
    'reopening the library restores the downloaded next episode and latest timing offline',
    () async {
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: _Client.new,
      );
      await prefs.updateTiming(
        'work',
        2,
        const CinemaSubtitleTiming(offsetSeconds: -3),
      );
      await store.flush();
      final reopened = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: [],
      );
      await reopened.load();
      final offline = _Client()..unavailable.addAll([1, 2, 3]);
      final player = _Player();
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: reopened,
        seriesIdentity: 'work',
        mediaIdentity: 'a-different-route-url',
        query: _episodes[2],
        client: offline,
        apply: _apply,
      );
      try {
        await controller.load();
        expect(
          cinemaExternalSubtitleState(player).normalizedSubtitle,
          contains('第 3 集'),
        );
        expect(cinemaExternalSubtitleState(player).delay, -3);
        expect(offline.requests, isEmpty);
      } finally {
        controller.close();
        await controller.flush();
        await closeCinemaExternalSubtitles(player);
        reopened.dispose();
        offline.close();
      }
    },
  );

  test(
    'entering a later episode retries only failed files without redoing successful downloads',
    () async {
      final initial = _Client()..unavailable.add(2);
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 1,
        clientFactory: () => initial,
      );
      expect(batch.failed, 1);
      final next = _Client();
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 3,
        clientFactory: () => next,
      );
      expect(next.requests, [2]);
      expect(batch.ready, 3);
    },
  );

  test(
    'one missing episode does not abort the season and retry only searches missing episodes',
    () async {
      final client = _Client()..unavailable.add(2);
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 1,
        clientFactory: () => client,
      );
      expect(batch.ready, 2);
      expect(batch.failed, 1);
      final retry = _Client();
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 1,
        clientFactory: () => retry,
        retry: true,
      );
      expect(retry.requests, [2]);
      expect(batch.ready, 3);
      expect(batch.failed, 0);
    },
  );

  test(
    'another cut may download but never inherits an incompatible timeline',
    () async {
      final client = _Client()..family = 'BluRay.Other';
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: () => client,
      );
      final cached = await batch.read('work', profile, 3);
      expect(cached!.inheritToSeason, false);
      expect(cached.timing.offsetSeconds, 0);
      await prefs.remember(
        seriesIdentity: 'work',
        season: 2,
        fromEpisode: 2,
        queryTitle: 'Fixture',
        row: _row(2, family: 'Different.Version'),
      );
      expect(await batch.read('work', prefs.read('work', 2)!, 3), isNull);
    },
  );

  test('cancellation discards a late search result', () async {
    final client = _Client()..gate = Completer<void>();
    final pending = batch.start(
      series: 'work',
      profile: profile,
      episodes: _episodes,
      currentEpisode: 2,
      clientFactory: () => client,
    );
    await client.started.future;
    batch.cancel('work');
    client.gate!.complete();
    await pending;
    expect(await batch.read('work', profile, 3), isNull);
    expect(client.requests, [3]);
    expect(client.closed, true);
  });

  test('closing the current video leaves the season queue running', () async {
    final player = _Player(), client = _Client()..gate = Completer<void>();
    final controller = CinemaSeasonSubtitleController(
      player: player,
      store: store,
      seriesIdentity: 'work',
      mediaIdentity: 'episode-2',
      query: _episodes[1],
      seasonEpisodes: _episodes,
      prefetchClientFactory: () => client,
      apply: _apply,
    );
    await _apply(
      player,
      _text(2),
      title: '${_row(2)['subtitleFileName']}',
      language: 'zh',
    );
    await controller.remember(
      CinemaOnlineSubtitleSelection(
        query: _episodes[1],
        imdbId: '',
        row: _row(2),
        applyToSeason: true,
      ),
    );
    await client.started.future;
    controller.close();
    client.gate!.complete();
    await batch.idle;
    expect((await batch.read('work', profile, 3))!.text, contains('第 3 集'));
    expect(client.requests, [3, 1]); // The selected episode was already cached.
    await controller.flush();
    await closeCinemaExternalSubtitles(player);
  });

  test(
    'turning captions off for one video does not stop the selected season downloads',
    () async {
      final player = _Player(), client = _Client()..gate = Completer<void>();
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'work',
        mediaIdentity: 'only-this-video-off',
        query: _episodes[1],
        seasonEpisodes: _episodes,
        prefetchClientFactory: () => client,
        apply: _apply,
      );
      controller.prefetchSeason();
      await client.started.future;
      await controller.disable();
      expect(batch.busy, true);
      expect(
        (await CinemaSavedSubtitleStore(
          store,
          'only-this-video-off',
        ).read())!.disabled,
        true,
      );
      client.gate!.complete();
      await batch.idle;
      expect(batch.ready, 3);
      expect((await batch.read('work', profile, 3))!.text, contains('第 3 集'));
      controller.close();
      await controller.flush();
      await closeCinemaExternalSubtitles(player);
    },
  );

  test('a previously saved season file seeds background downloads', () async {
    await prefs.clear('work', 2);
    final player = _Player();
    final selected = CinemaSavedSubtitleStore(store, 'legacy-episode');
    await selected.save(
      CinemaSavedSubtitle(
        text: _text(2),
        title: 'Fixture.S02E02.AMZN.FLUX.srt',
      ),
    );
    final client = _Client();
    final controller = CinemaSeasonSubtitleController(
      player: player,
      store: store,
      seriesIdentity: 'work',
      mediaIdentity: 'legacy-episode',
      query: _episodes[1],
      seasonEpisodes: _episodes,
      prefetchClientFactory: () => client,
      apply: _apply,
    );
    await controller.load();
    await batch.idle;
    expect(client.requests, [3, 1]);
    expect(batch.ready, 3);
    expect(prefs.read('work', 2), isNotNull);
    controller.close();
    await controller.flush();
    await closeCinemaExternalSubtitles(player);
  });

  test(
    'explicitly opting out of season downloads survives reopening',
    () async {
      await prefs.clear('work', 2);
      final player = _Player();
      await CinemaSavedSubtitleStore(
        store,
        'only-this-episode',
      ).save(CinemaSavedSubtitle(text: _text(2), seasonPrefetch: false));
      final client = _Client();
      final controller = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'work',
        mediaIdentity: 'only-this-episode',
        query: _episodes[1],
        seasonEpisodes: _episodes,
        prefetchClientFactory: () => client,
        apply: _apply,
      );
      await controller.load();
      expect(client.requests, isEmpty);
      expect(batch.total, 0);
      expect(prefs.read('work', 2), isNull);
      controller.close();
      await controller.flush();
      await closeCinemaExternalSubtitles(player);
      client.close();
    },
  );

  test(
    'explicit per-video off still wins over a downloaded season file',
    () async {
      await batch.cache(
        'work',
        profile,
        3,
        CinemaSavedSubtitle(text: _text(3)),
      );
      // The existing controller's off workflow is tested separately. Check that
      // the cache never overwrites its persistent per-video selection marker.
      final saved = CinemaSavedSubtitleStore(store, 'episode-3');
      await saved.disable();
      await batch.start(
        series: 'work',
        profile: profile,
        episodes: _episodes,
        currentEpisode: 2,
        clientFactory: _Client.new,
      );
      expect((await saved.read())!.disabled, true);
    },
  );
}
