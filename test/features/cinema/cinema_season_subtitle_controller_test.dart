import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_controller.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_saved_subtitle.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

const _line2 = '1\n00:00:01,000 --> 00:00:03,000\n第二集自写测试对白\n';
const _line3 = '1\n00:00:01,000 --> 00:00:03,000\n第三集自写测试对白\n';

class _Player implements Player {
  _Player({bool playing = false})
    : _state = PlayerState(
        playing: playing,
        position: const Duration(seconds: 15),
      );
  PlayerState _state;
  int pauses = 0, plays = 0;
  Completer<void>? pauseGate;
  Completer<void>? playObserved;
  Completer<void>? pauseObserved;
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => _state;
  @override
  Future<void> pause() async {
    pauses++;
    if (pauseObserved?.isCompleted == false) pauseObserved!.complete();
    await pauseGate?.future;
    _state = _state.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    plays++;
    if (playObserved?.isCompleted == false) playObserved!.complete();
    _state = _state.copyWith(playing: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends CinemaOnlineSubtitles {
  _Client() : super(dio: Dio(), useFallbackCatalog: false);
  final requests =
      <
        ({
          String title,
          String type,
          int season,
          int episode,
          String language,
          String release,
        })
      >[];
  final downloads = <String>[];
  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>>? earlyRows;
  Completer<void>? aggregateGate, downloadGate;
  final downloadStarted = Completer<void>();
  bool emitEarly = false;
  int closes = 0;
  void Function()? onAggregate;

  @override
  void close() {
    closes++;
  }

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
    onAggregate?.call();
    requests.add((
      title: query,
      type: type,
      season: season,
      episode: episode,
      language: language,
      release: mediaRelease,
    ));
    if (emitEarly) onVerified?.call(List.of(earlyRows ?? rows));
    await aggregateGate?.future;
    return CinemaSubtitleCatalogResult(List.of(rows), const {});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async {
    downloads.add(url);
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    await downloadGate?.future;
    return url.contains('E02') ? _line2 : _line3;
  }
}

Map<String, dynamic> _row(
  int episode, {
  String lang = 'zh',
  String provider = 'fixture',
}) => {
  'url':
      'https://public-subtitles.invalid/AHS.S10E${episode.toString().padLeft(2, '0')}.srt',
  'subtitleFileName':
      'AHS.S10E${episode.toString().padLeft(2, '0')}.AMZN.FLUX.srt',
  'lang': lang,
  'provider': provider,
  'verified': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  final controllers = <CinemaSeasonSubtitleController>[];
  final players = <Player>[];
  final applied =
      <({Player player, String text, String title, String language})>[];
  Completer<void>? applyGate;
  Completer<void>? applyEntered;
  var applyStarted = 0;

  Future<void> apply(
    Player player,
    String text, {
    String title = '在线字幕',
    String language = 'zh',
    bool Function()? isCurrent,
  }) async {
    applyStarted++;
    if (applyEntered case final signal? when !signal.isCompleted) {
      signal.complete();
    }
    await applyGate?.future;
    if (isCurrent?.call() == false) return;
    applied.add((player: player, text: text, title: title, language: language));
    cinemaExternalSubtitleState(player).select(
      cinemaSubtitleSrt(text),
      'fixture-${applied.length}.srt',
      '${applied.length}',
      0,
    );
  }

  CinemaSeasonSubtitleController controller(
    int episode, {
    _Client? client,
    int season = 10,
    String series = 'private-nas-library::AHS',
    bool playing = false,
    bool automateMissing = false,
    bool Function()? canResume,
  }) {
    final player = _Player(playing: playing);
    players.add(player);
    final result = CinemaSeasonSubtitleController(
      player: player,
      automateMissing: automateMissing,
      store: store,
      seriesIdentity: series,
      mediaIdentity: 'private-media-S${season}E$episode?token=DO_NOT_SAVE',
      query: CinemaSubtitleQuery('美国恐怖故事', 'series', season, episode),
      imdbId: 'tt1844624',
      mediaRelease: 'AHS.S${season}E$episode.AMZN.FLUX.mkv',
      canResume: canResume,
      client: client ?? _Client(),
      apply: apply,
    );
    controllers.add(result);
    return result;
  }

  Future<CinemaSeasonSubtitleController> seed({
    CinemaSubtitleTiming timing = const CinemaSubtitleTiming(
      scale: .96,
      offsetSeconds: 12.25,
    ),
  }) async {
    final selected = controller(2);
    selected.beginManualSelection();
    final session = cinemaExternalSubtitleState(selected.player);
    session.select(_line2, 'manual-S10E02.srt', 'manual', 0);
    session.setTiming(timing);
    await selected.remember(
      CinemaOnlineSubtitleSelection(
        query: selected.query,
        imdbId: 'tt1844624',
        row: _row(2),
        applyToSeason: true,
      ),
    );
    await store.flush();
    return selected;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'naku-season-controller-',
    );
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [],
    );
    await store.load();
    applied.clear();
    applyGate = null;
    applyEntered = null;
    applyStarted = 0;
  });

  tearDown(() async {
    for (final item in controllers) {
      item.close();
    }
    controllers.clear();
    for (final player in players) {
      await closeCinemaExternalSubtitles(player);
    }
    players.clear();
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'first playback makes no subtitle searches until a manual choice',
    () async {
      final client = _Client()..rows = [_row(3)];
      final first = controller(3, client: client);
      await first.load();
      expect(client.requests, isEmpty);
      expect(client.downloads, isEmpty);
      expect(applied, isEmpty);
      expect(first.status.value, contains('手动搜索'));
    },
  );

  test(
    'film ignores an unrelated legacy subtitle and a stale series profile',
    () async {
      final original = await seed();
      await original.preferences.remember(
        seriesIdentity: 'private-nas-library::AHS',
        season: 1,
        fromEpisode: 1,
        queryTitle: 'Shakugan no Shana',
        imdbId: 'tt0000001',
        row: {
          'verified': true,
          'subtitleFileName': 'Shakugan no Shana 01.srt',
          'lang': 'eng',
          'provider': 'legacy',
        },
        timing: const CinemaSubtitleTiming(),
      );
      final saved = CinemaSavedSubtitleStore(store, 'titanic-dubbed');
      await saved.save(
        const CinemaSavedSubtitle(
          text: _line2,
          title: 'Shakugan no Shana 01.srt',
          language: 'eng',
          inheritToSeason: true,
        ),
      );
      final player = _Player();
      players.add(player);
      final client = _Client()..rows = [_row(3)];
      final movie = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'private-nas-library::AHS',
        mediaIdentity: 'titanic-dubbed',
        query: const CinemaSubtitleQuery('泰坦尼克号（普通话版）', 'movie', 1, 1),
        client: client,
        apply: apply,
      );
      controllers.add(movie);
      applied.clear();
      await movie.load();
      expect(applied, isEmpty);
      expect(client.requests, isEmpty);
      expect(client.downloads, isEmpty);
      expect(
        await saved.read(),
        isNotNull,
        reason: 'Keep the old file available for recovery',
      );
    },
  );

  test(
    'reopening the same video restores its calibrated file without network',
    () async {
      final first = await seed();
      // Exit immediately after a new calibration: no direct save callback or
      // artificial wait is allowed to make persistence pass.
      cinemaExternalSubtitleState(first.player).setTiming(
        const CinemaSubtitleTiming(scale: 1.025, offsetSeconds: 6.793222),
      );
      first.close();
      await closeCinemaExternalSubtitles(first.player);
      await store.flush();
      store.dispose();
      store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: const [],
      );
      await store.load();
      applied.clear();
      final unavailable = _Client();
      final reopened = controller(2, client: unavailable);
      await reopened.load();
      expect(applied, hasLength(1));
      expect(applied.single.text, cinemaSubtitleSrt(_line2));
      expect(unavailable.requests, isEmpty);
      final session = cinemaExternalSubtitleState(reopened.player);
      expect(session.timing.value.scale, 1.025);
      expect(session.delay, 6.793222);
      expect(session.sourceLabel.value, contains('手动搜索'));
    },
  );

  test(
    'first use automatically chooses Chinese before a better-matched English release',
    () async {
      final client = _Client()..rows = [_row(3, lang: 'eng'), _row(3)];
      final selected = controller(3, client: client, automateMissing: true);
      await selected.load();
      expect(applied.single.language, 'zh');
      expect(selected.status.value, contains('中文字幕'));
      expect((selected.player as _Player).pauses, 0);
      selected.close();
      await closeCinemaExternalSubtitles(selected.player);
      applied.clear();
      final offline = _Client();
      await controller(3, client: offline, automateMissing: true).load();
      expect(applied, hasLength(1));
      expect(offline.requests, isEmpty);
    },
  );

  test(
    'first use ignores an unverified candidate and another episode',
    () async {
      final client = _Client()
        ..rows = [
          _row(2),
          {..._row(3), 'verified': false},
        ];
      final selected = controller(3, client: client, automateMissing: true);
      await selected.load();
      expect(applied, isEmpty);
      expect(client.downloads, isEmpty);
    },
  );

  test('manual selection cancels a pending first-use search', () async {
    final gate = Completer<void>();
    final client = _Client()
      ..rows = [_row(3)]
      ..aggregateGate = gate;
    final selected = controller(3, client: client, automateMissing: true);
    final loading = selected.load();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    selected.beginManualSelection();
    gate.complete();
    await loading;
    expect(applied, isEmpty);
  });

  test(
    'explicitly disabling subtitles does not resurrect the saved file',
    () async {
      final first = await seed();
      await cinemaExternalSubtitleState(first.player).disableSavedSelection!();
      first.close();
      await closeCinemaExternalSubtitles(first.player);
      applied.clear();
      final client = _Client()..rows = [_row(2)];
      await controller(2, client: client).load();
      expect(applied, isEmpty);
      expect(client.requests, isEmpty);
    },
  );

  test(
    'the next episode searches its own file and inherits timing after reload',
    () async {
      await seed();
      await store.flush();
      store.dispose();
      store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: const [],
      );
      await store.load();
      final client = _Client()..rows = [_row(2), _row(3)];
      final next = controller(3, client: client);
      final notices = <String>[];
      await next.load(onNotice: notices.add);
      expect(client.requests.single.season, 10);
      expect(client.requests.single.episode, 3);
      expect(client.requests.single.language, 'zh');
      expect(client.downloads.single, contains('S10E03'));
      expect(applied.single.text, _line3);
      final session = cinemaExternalSubtitleState(next.player);
      expect(session.timing.value.scale, .96);
      expect(session.delay, 12.25);
      expect(notices.last, contains('已自动加载'));
      final text = await File('${directory.path}/library.json').readAsString();
      expect(text, isNot(contains('DO_NOT_SAVE')));
      expect(text, isNot(contains('private-nas-library')));
      expect(text, isNot(contains(_line2)));
    },
  );

  test(
    'an exact episode and content calibration takes priority over the season',
    () async {
      await seed();
      final previous = controller(3);
      final old = cinemaExternalSubtitleState(previous.player);
      old.select(cinemaSubtitleSrt(_line3), 'old-E03.srt', 'old', 0);
      await old.saveTiming!(
        old.fingerprint,
        const CinemaSubtitleTiming(scale: 1.001, offsetSeconds: -7.5),
      );
      previous.close();
      final next = controller(3, client: _Client()..rows = [_row(3)]);
      await next.load();
      final session = cinemaExternalSubtitleState(next.player);
      expect(session.timing.value.scale, 1.001);
      expect(session.delay, -7.5);
    },
  );

  test('later calibration is saved for subsequent episodes', () async {
    await seed();
    final current = controller(3, client: _Client()..rows = [_row(3)]);
    await current.load();
    final session = cinemaExternalSubtitleState(current.player);
    const adjusted = CinemaSubtitleTiming(scale: 1.02, offsetSeconds: -1.75);
    session.setTiming(adjusted);
    await session.saveTiming!(session.fingerprint, adjusted);
    final fourth = controller(4, client: _Client()..rows = [_row(4)]);
    await fourth.load();
    expect(cinemaExternalSubtitleState(fourth.player).timing.value.scale, 1.02);
    expect(cinemaExternalSubtitleState(fourth.player).delay, -1.75);
  });

  test(
    'calibration followed immediately by an episode change preserves latest timing',
    () async {
      await seed();
      final current = controller(3, client: _Client()..rows = [_row(3)]);
      await current.load();
      final session = cinemaExternalSubtitleState(current.player);
      session.setTiming(
        const CinemaSubtitleTiming(scale: .999, offsetSeconds: 8.125),
      );
      current.close();
      final fourth = controller(4, client: _Client()..rows = [_row(4)]);
      await fourth.load();
      expect(
        cinemaExternalSubtitleState(fourth.player).timing.value.scale,
        .999,
      );
      expect(cinemaExternalSubtitleState(fourth.player).delay, 8.125);
    },
  );

  test(
    'manual selection prevents late aggregate results from loading',
    () async {
      await seed();
      final gate = Completer<void>();
      final client = _Client()
        ..rows = [_row(3)]
        ..aggregateGate = gate;
      final next = controller(3, client: client);
      final pending = next.load();
      for (var index = 0; index < 8; index++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(client.requests, hasLength(1));
      next.beginManualSelection();
      gate.complete();
      await pending;
      expect(applied, isEmpty);
      expect(client.downloads, isEmpty);
      expect(client.closes, 1);
    },
  );

  test(
    'manual selection prevents an in-flight download from applying',
    () async {
      await seed();
      final gate = Completer<void>();
      final client = _Client()
        ..rows = [_row(3)]
        ..downloadGate = gate;
      final next = controller(3, client: client);
      final pending = next.load();
      await client.downloadStarted.future.timeout(const Duration(seconds: 5));
      expect(client.downloads, hasLength(1));
      next.beginManualSelection();
      gate.complete();
      await pending;
      expect(applied, isEmpty);
    },
  );

  test('closing a session prevents a late download from applying', () async {
    await seed();
    final gate = Completer<void>();
    final client = _Client()
      ..rows = [_row(3)]
      ..downloadGate = gate;
    final next = controller(3, client: client);
    final pending = next.load();
    await client.downloadStarted.future.timeout(const Duration(seconds: 5));
    expect(client.downloads, hasLength(1));
    next.close();
    next.close();
    gate.complete();
    await pending;
    expect(applied, isEmpty);
    expect(client.closes, 1);
  });

  test(
    'manual selection during native apply never overrides the user choice',
    () async {
      await seed();
      applyGate = Completer<void>();
      applyEntered = Completer<void>();
      final client = _Client()..rows = [_row(3)];
      final next = controller(3, client: client);
      final pending = next.load();
      // Await the native apply boundary, rather than guessing how many event
      // loop turns filesystem work needs under concurrent test/build load.
      await applyEntered!.future.timeout(const Duration(seconds: 5));
      expect(applyStarted, 1);
      next.beginManualSelection();
      final session = cinemaExternalSubtitleState(next.player);
      session.select(_line2, 'USER_SELECTED.srt', 'manual', 0);
      applyGate!.complete();
      await pending;
      expect(applied, isEmpty);
      expect(session.sourceIdentity, 'USER_SELECTED.srt');
      expect(session.cues.single.text, contains('第二集'));
    },
  );

  test(
    'missing Chinese does not silently load English or the preceding episode',
    () async {
      await seed();
      final client = _Client()..rows = [_row(2), _row(3, lang: 'eng')];
      final next = controller(3, client: client);
      final notices = <String>[];
      await next.load(onNotice: notices.add);
      expect(applied, isEmpty);
      expect(client.downloads, isEmpty);
      expect(notices.last, contains('暂无'));
    },
  );

  test(
    'earlier episodes, other seasons and other works do not inherit',
    () async {
      await seed();
      for (final next in [
        controller(1),
        controller(3, season: 11),
        controller(3, series: 'some-other-work'),
      ]) {
        await next.load();
        expect(cinemaExternalSubtitleState(next.player).active.value, false);
      }
      expect(applied, isEmpty);
    },
  );

  test(
    'early verified rows load once while remaining catalogs continue',
    () async {
      await seed();
      final gate = Completer<void>();
      final client = _Client()
        ..rows = [_row(3)]
        ..emitEarly = true
        ..aggregateGate = gate;
      final next = controller(3, client: client);
      final pending = next.load();
      for (var index = 0; index < 8; index++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(applied, hasLength(1));
      gate.complete();
      await pending;
      await next.load();
      expect(applied, hasLength(1));
      expect(client.requests, hasLength(1));
      expect(client.downloads, hasLength(1));
    },
  );

  test(
    'an early unrelated release waits for the selected family in final results',
    () async {
      await seed();
      final gate = Completer<void>();
      final unrelated = {
        ..._row(3),
        'url': 'https://public-subtitles.invalid/AHS.S10E03.HDTV.TBS.srt',
        'subtitleFileName': 'AHS.S10E03.HDTV.TBS.srt',
      };
      final preferred = _row(3);
      final client = _Client()
        ..rows = [unrelated, preferred]
        ..earlyRows = [unrelated]
        ..emitEarly = true
        ..aggregateGate = gate;
      final next = controller(3, client: client);
      final pending = next.load();
      for (var index = 0; index < 8; index++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(applied, isEmpty);
      expect(client.downloads, isEmpty);
      gate.complete();
      await pending;
      expect(client.downloads, [preferred['url']]);
      expect(applied.single.title, preferred['subtitleFileName']);
    },
  );

  test('opting out clears the season rule for later episodes', () async {
    final selected = await seed();
    await selected.remember(
      CinemaOnlineSubtitleSelection(
        query: selected.query,
        imdbId: 'tt1844624',
        row: _row(2),
        applyToSeason: false,
      ),
    );
    final client = _Client()..rows = [_row(3)];
    await controller(3, client: client).load();
    expect(client.requests, isEmpty);
    expect(applied, isEmpty);
  });

  test(
    'automatic search awaits pause before issuing an aggregate request',
    () async {
      await seed();
      final gate = Completer<void>();
      final client = _Client()..rows = [_row(3)];
      final next = controller(3, client: client, playing: true);
      final player = next.player as _Player;
      player.pauseGate = gate;
      player.pauseObserved = Completer<void>();
      client.onAggregate = () {
        expect(player.state.playing, false);
        expect(player.pauses, 1);
      };
      final pending = next.load();
      await player.pauseObserved!.future.timeout(const Duration(seconds: 3));
      expect(player.pauses, 1);
      expect(client.requests, isEmpty);
      gate.complete();
      await pending;
      expect(applied, hasLength(1));
      expect(player.plays, 1);
      expect(player.state.playing, true);
    },
  );

  test(
    'an early matching subtitle resumes once before slower catalogs finish',
    () async {
      await seed();
      final gate = Completer<void>();
      final client = _Client()
        ..rows = [_row(3)]
        ..emitEarly = true
        ..aggregateGate = gate;
      final next = controller(3, client: client, playing: true);
      final player = next.player as _Player;
      player.playObserved = Completer<void>();
      final pending = next.load();
      await player.playObserved!.future.timeout(const Duration(seconds: 3));
      expect(applied, hasLength(1));
      expect(player.pauses, 1);
      expect(player.plays, 1);
      expect(player.state.playing, true);
      gate.complete();
      await pending;
      expect(player.plays, 1);
      expect(applied, hasLength(1));
    },
  );

  test(
    'an originally paused episode stays paused after automatic search',
    () async {
      await seed();
      final next = controller(3, client: _Client()..rows = [_row(3)]);
      final player = next.player as _Player;
      await next.load();
      expect(applied, hasLength(1));
      expect(player.pauses, 0);
      expect(player.plays, 0);
      expect(player.state.playing, false);
    },
  );

  test(
    'a completed empty search restores its owned playing intention',
    () async {
      await seed();
      final next = controller(3, client: _Client(), playing: true);
      final player = next.player as _Player;
      await next.load();
      expect(applied, isEmpty);
      expect(player.pauses, 1);
      expect(player.plays, 1);
      expect(player.state.playing, true);
    },
  );

  test('manual selection suppresses automatic playback resume', () async {
    await seed();
    final gate = Completer<void>();
    final client = _Client()
      ..rows = [_row(3)]
      ..aggregateGate = gate;
    final next = controller(3, client: client, playing: true);
    final player = next.player as _Player;
    final pending = next.load();
    for (var index = 0; index < 8; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(player.state.playing, false);
    next.beginManualSelection();
    gate.complete();
    await pending;
    expect(player.plays, 0);
    expect(player.state.playing, false);
    expect(applied, isEmpty);
  });

  test('closing a playback suppresses automatic playback resume', () async {
    await seed();
    final gate = Completer<void>();
    final client = _Client()
      ..rows = [_row(3)]
      ..aggregateGate = gate;
    final next = controller(3, client: client, playing: true);
    final player = next.player as _Player;
    final pending = next.load();
    for (var index = 0; index < 8; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    next.close();
    gate.complete();
    await pending;
    expect(player.pauses, 1);
    expect(player.plays, 0);
    expect(player.state.playing, false);
  });

  test('a hidden window or changed manual intent can block resume', () async {
    await seed();
    final gate = Completer<void>();
    var allowed = true;
    final client = _Client()
      ..rows = [_row(3)]
      ..aggregateGate = gate;
    final next = controller(
      3,
      client: client,
      playing: true,
      canResume: () => allowed,
    );
    final player = next.player as _Player;
    final pending = next.load();
    for (var index = 0; index < 8; index++) {
      await Future<void>.delayed(Duration.zero);
    }
    allowed = false;
    gate.complete();
    await pending;
    expect(applied, hasLength(1));
    expect(player.pauses, 1);
    expect(player.plays, 0);
    expect(player.state.playing, false);
  });
}
