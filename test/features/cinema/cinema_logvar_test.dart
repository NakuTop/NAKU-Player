import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';

final _config = LogvarConfiguration(
  baseUrl: 'http://192.168.1.10:9321',
  token: 'fixture-token',
);
const _query = CinemaLogvarQuery(
  title: '自写剧集',
  series: true,
  episode: 2,
  year: '2024',
);
Map<String, dynamic> _work(
  int id, {
  String year = '2024',
  String type = '电视剧',
}) => {
  'animeId': id,
  'animeTitle': '自写剧集($year)【$type】from youku',
  'typeDescription': type,
  'source': 'youku',
  'startDate': '$year-01-01',
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Object Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final value = reply(options);
    return ResponseBody.fromString(
      value is String ? value : jsonEncode(value),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Streams implements PlayerStream {
  final positions = StreamController<Duration>.broadcast();
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<double> get rate => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  final _Streams stream = _Streams();
  @override
  PlayerState state = PlayerState(playing: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends CinemaLogvarClient {
  _Client() : super(_config, dio: Dio());
  int calls = 0;
  Completer<CinemaLogvarSelection?>? gate;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    calls++;
    return gate == null ? selection(query.episode) : gate!.future;
  }
}

class _WindowTimeline implements CinemaDanmakuTimeline {
  bool closed = false;
  int loads = 0;
  @override
  double get endSeconds => 7200;
  @override
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  }) async {
    if (closed) throw StateError('closed');
    loads++;
    final entry = selection(1).entries.single..time = position + 1;
    return CinemaDanmakuWindow([entry], position - 30, position + 150);
  }

  @override
  void close() {
    closed = true;
  }
}

class _WindowClient extends _Client {
  final timeline = _WindowTimeline();
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    calls++;
    final s = selection(query.episode);
    return CinemaLogvarSelection(
      s.work,
      s.episode,
      s.entries,
      7200,
      provider: 'direct',
      timeline: timeline,
      windowStart: 0,
      windowEnd: 150,
    );
  }
}

CinemaLogvarSelection selection(int number) => CinemaLogvarSelection(
  const CinemaLogvarWork(id: 1, title: '自写剧集', type: '电视剧'),
  CinemaLogvarEpisode(number, '第$number集', number),
  [
    DanmakuEntry(
      message: '自写第$number集弹幕',
      time: 1.2,
      type: 1,
      color: Colors.white,
      source: 'fixture',
    ),
  ],
  10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('query parses filename and Chinese season/episode before fallback', () {
    final q = CinemaLogvarQuery.parse(
      '自写剧集.S02E03.2160p',
      category: '电视剧',
      fallbackEpisode: 9,
    );
    expect(q.title, '自写剧集');
    expect(q.season, 2);
    expect(q.episode, 3);
    final cn = CinemaLogvarQuery.parse(
      '自写剧集第二季',
      episodeName: '第六集',
      fallbackEpisode: 9,
    );
    expect(cn.series, isTrue);
    expect(cn.season, 2);
    expect(cn.episode, 6);
    expect(cinemaLogvarEpisodeNumber('【youku】 第十二集 自写剧集 12'), 12);
    expect(cinemaLogvarEpisodeNumber('S02E03'), 3);
    expect(cinemaLogvarEpisodeNumber('第2集预告'), isNull);
  });
  test(
    'matching removes API decorations and rejects another year, season, title or official source',
    () {
      const q = CinemaLogvarQuery(
        title: '自写剧集',
        series: true,
        season: 2,
        year: '2024',
      );
      CinemaLogvarWork w(
        String title, {
        String year = '2024',
        String source = 'youku',
      }) => CinemaLogvarWork(
        id: 1,
        title: title,
        year: year,
        type: '电视剧',
        source: source,
      );
      expect(
        cinemaLogvarWorkMatches(q, w('自写剧集 第二季(2024)【电视剧】from youku')),
        isTrue,
      );
      expect(
        cinemaLogvarWorkMatches(q, w('自写剧集 第一季(2024)【电视剧】from youku')),
        isFalse,
      );
      expect(cinemaLogvarWorkMatches(q, w('自写剧集 第二季', year: '2023')), isFalse);
      expect(cinemaLogvarWorkMatches(q, w('自写剧集 第二季幕后特辑')), isFalse);
      expect(
        cinemaLogvarWorkMatches(q, w('自写剧集 第二季', source: 'dandan')),
        isFalse,
      );
      expect(cinemaLogvarWorkMatches(q, w('自写剧集后传 第二季')), isFalse);
    },
  );
  test(
    'transport uses only title and verified catalogue ID; explicit episode overrides list index',
    () async {
      final adapter = _Adapter((o) {
        if (o.uri.path.endsWith('search/anime')) {
          return {
            'animes': [_work(7)],
          };
        }
        if (o.uri.path.contains('bangumi/')) {
          return {
            'bangumi': {
              'episodes': [
                {
                  'episodeId': 555,
                  'episodeTitle': '第2集预告',
                  'episodeNumber': '2',
                },
                {
                  'episodeId': 987654321012,
                  'episodeTitle': '【youku】 第2集 自写剧集 02',
                  'episodeNumber': '1',
                },
              ],
            },
          };
        }
        return {
          'comments': [
            {'m': '真实格式的自写弹幕', 'p': '1.2,1,16777215,unit'},
          ],
          'videoDuration': 120.5,
        };
      });
      final client = CinemaLogvarClient(
        _config,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      final result = await client.match(_query);
      expect(result!.episode.id, 987654321012);
      expect(result.entries.single.time, 1.2);
      expect(result.duration, 120.5);
      expect(
        adapter.requests.last.uri.path,
        endsWith('/api/v2/comment/987654321012'),
      );
      expect(adapter.requests.first.uri.queryParameters, {
        'keyword': '自写剧集',
        'season': '1',
        'episode': '2',
      });
      expect(
        adapter.requests.every(
          (r) =>
              !r.followRedirects &&
              !r.headers.keys.any((k) => k.toLowerCase().startsWith('x-app')),
        ),
        isTrue,
      );
      expect(_config.toString(), isNot(contains('fixture-token')));
    },
  );
  test(
    'ambiguous remake years never fetch a catalogue automatically',
    () async {
      final adapter = _Adapter(
        (_) => {
          'animes': [_work(1, year: '2023'), _work(2, year: '2024')],
        },
      );
      final client = CinemaLogvarClient(
        _config,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      await expectLater(
        client.match(const CinemaLogvarQuery(title: '自写剧集', series: true)),
        throwsFormatException,
      );
      expect(adapter.requests, hasLength(1));
    },
  );
  test(
    'wrong or duplicated episode does not silently use its position in a list',
    () async {
      final adapter = _Adapter(
        (o) => o.uri.path.endsWith('search/anime')
            ? {
                'animes': [_work(1)],
              }
            : {
                'bangumi': {
                  'episodes': [
                    {
                      'episodeId': 11,
                      'episodeTitle': '第3集',
                      'episodeNumber': '2',
                    },
                    {
                      'episodeId': 12,
                      'episodeTitle': '第1集',
                      'episodeNumber': '1',
                    },
                  ],
                },
              },
      );
      final client = CinemaLogvarClient(
        _config,
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      expect(await client.match(_query), isNull);
      expect(
        adapter.requests.any((o) => o.uri.path.contains('/comment/')),
        isFalse,
      );
    },
  );
  test('empty platform comments fall back to another matching work', () async {
    var downloads = 0;
    final adapter = _Adapter((o) {
      if (o.uri.path.endsWith('search/anime')) {
        return {
          'animes': [_work(1), _work(2)],
        };
      }
      if (o.uri.path.contains('/bangumi/')) {
        return {
          'bangumi': {
            'episodes': [
              {
                'episodeId': o.uri.path.endsWith('/1') ? 111 : 222,
                'episodeTitle': '第2集',
                'episodeNumber': '2',
              },
            ],
          },
        };
      }
      downloads++;
      return {
        'comments': downloads == 1
            ? []
            : [
                {'m': '备用平台自写弹幕', 'p': '2,1,16777215,u'},
              ],
      };
    });
    final client = CinemaLogvarClient(
      _config,
      dio: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(client.close);
    expect((await client.match(_query))!.work.id, 2);
    expect(downloads, 2);
  });
  test('segmented metadata is never reported as loaded comments', () async {
    final client = CinemaLogvarClient(
      _config,
      dio: Dio()
        ..httpClientAdapter = _Adapter(
          (_) => {
            'segmentList': [
              {'url': 'https://example.com'},
            ],
          },
        ),
    );
    addTearDown(client.close);
    await expectLater(client.comments(1), throwsFormatException);
  });
  test(
    'configuration rejects remote plaintext, credentials in URL and malformed tokens',
    () {
      for (final url in [
        'http://public.example.com',
        'https://u:p@nas.example.com',
        'https://nas.example.com?token=leak',
      ]) {
        expect(
          () => LogvarConfiguration(baseUrl: url, token: 'fixture-token'),
          throwsFormatException,
        );
      }
      expect(
        () => LogvarConfiguration(
          baseUrl: 'https://nas.example.com',
          token: 'line\nbreak',
        ),
        throwsFormatException,
      );
    },
  );

  group('playback ownership and saved preferences', () {
    late Directory directory;
    late CinemaStore store;
    late _Player player;
    final controllers = <CinemaDanmakuController>[];
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('naku-danmu-test-');
      store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: const [],
      );
      await store.load();
      player = _Player();
    });
    tearDown(() async {
      for (final c in controllers) {
        await c.close();
      }
      controllers.clear();
      await player.stream.positions.close();
      await store.flush();
      store.dispose();
      await directory.delete(recursive: true);
    });
    CinemaDanmakuController make(
      String identity,
      _Client client, {
      int episode = 2,
    }) {
      final c = CinemaDanmakuController(
        player,
        store,
        identity,
        autoQuery: CinemaLogvarQuery(
          title: '自写剧集',
          series: true,
          episode: episode,
        ),
        readLogvarConfiguration: () async => _config,
        logvarClientFactory: (_) => client,
      );
      controllers.add(c);
      return c;
    }

    test(
      'direct playback needs no NAS configuration and refills a bounded window on seek',
      () async {
        final client = _WindowClient();
        final c = CinemaDanmakuController(
          player,
          store,
          'window-fixture',
          autoQuery: _query,
          readLogvarConfiguration: () async =>
              throw StateError('NAS credentials must never be read'),
          directClientFactory: () => client,
        );
        controllers.add(c);
        await c.loadAutomatic();
        expect(c.entries.single.time, 1.2);
        player.state = player.state.copyWith(
          position: const Duration(seconds: 240),
        );
        player.stream.positions.add(player.state.position);
        for (var i = 0; i < 30 && c.entries.single.time < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(c.entries.single.time, 241);
        expect(client.timeline.loads, 1);
        await c.setEnabled(false);
        expect(client.timeline.closed, isTrue);
        player.stream.positions.add(const Duration(seconds: 600));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(client.timeline.loads, 1);
        await c.close();
        controllers.remove(c);
        expect(c.entries, isEmpty);
      },
    );

    test(
      'automatic loading reaches terminal state and preserves disabled cache on reopening',
      () async {
        final service = _Client();
        final first = make('episode-2', service);
        await first.loadAutomatic();
        expect(first.enabled, isTrue);
        expect(first.matching, isFalse);
        expect(first.matchMessage, contains('已加载 1 条'));
        await first.setEnabled(false);
        final reopened = make('episode-2', service);
        await reopened.loadAutomatic();
        expect(reopened.enabled, isFalse);
        expect(reopened.entries.single.message, '自写第2集弹幕');
        expect(service.calls, 1);
      },
    );
    test(
      'switching episodes requests the new number and does not reuse previous comments',
      () async {
        final service = _Client();
        final first = make('episode-1', service, episode: 1);
        await first.loadAutomatic();
        final second = make('episode-2', service);
        await second.loadAutomatic();
        expect(first.entries.single.message, '自写第1集弹幕');
        expect(second.entries.single.message, '自写第2集弹幕');
        expect(service.calls, 2);
      },
    );
    test('display off and style preferences follow the next episode', () async {
      final service = _Client();
      final first = make('style-1', service);
      await first.loadAutomatic();
      first.setFontSize(28);
      first.setOpacity(.6);
      first.setArea(.25);
      first.setDuration(12);
      await first.setEnabled(false);
      final next = make('style-2', service);
      await next.loadAutomatic();
      expect(next.enabled, isFalse);
      expect(service.calls, 1);
      expect(next.option.fontSize, 28);
      expect(next.option.opacity, .6);
      expect(next.option.area, .25);
      expect(next.option.duration, 12);
      await next.setEnabled(true);
      await next.loadAutomatic();
      while (next.matching) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(next.enabled, isTrue);
      expect(next.entries, isNotEmpty);
      expect(service.calls, 2);
    });

    test('late automatic result cannot replace a manual selection', () async {
      final service = _Client()..gate = Completer<CinemaLogvarSelection?>();
      final c = make('manual-race', service);
      final loading = c.loadAutomatic();
      while (service.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.setEntries(selection(9).entries, '手动选择');
      service.gate!.complete(selection(2));
      await loading;
      expect(c.source, '手动选择');
      expect(c.entries.single.message, '自写第9集弹幕');
      expect(c.matching, isFalse);
    });
    test(
      'global automatic matching off persists and blocks next video network calls',
      () async {
        await store.setExtra('danmakuAutoMatch', false);
        final service = _Client();
        final c = make('opt-out', service);
        await c.loadAutomatic();
        expect(service.calls, 0);
        expect(c.entries, isEmpty);
      },
    );
    test('closing a playback discards an in-flight response', () async {
      final service = _Client()..gate = Completer<CinemaLogvarSelection?>();
      final c = make('close-race', service);
      final loading = c.loadAutomatic();
      while (service.calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.close();
      controllers.remove(c);
      service.gate!.complete(selection(2));
      await loading;
      expect(c.entries, isEmpty);
    });

    testWidgets(
      'switching the overlay binds the new episode to its own Canvas',
      (tester) async {
        late CinemaDanmakuController first;
        await tester.runAsync(() async {
          first = make('canvas-1', _Client(), episode: 1);
          await first.setEntries(selection(1).entries, '第一集');
        });
        Widget view(CinemaDanmakuController c) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: CinemaDanmakuOverlay(controller: c),
            ),
          ),
        );
        int visible() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .where((w) => w.painter is BaseDanmakuPainter)
            .fold(
              0,
              (n, w) =>
                  n + (w.painter! as BaseDanmakuPainter).danmakuItems.length,
            );
        await tester.pumpWidget(view(first));
        player.stream.positions.add(const Duration(milliseconds: 900));
        await tester.pump();
        player.stream.positions.add(const Duration(milliseconds: 1300));
        await tester.pump();
        expect(visible(), greaterThan(0));
        late CinemaDanmakuController second;
        await tester.runAsync(() async {
          second = make('canvas-2', _Client());
          await second.setEntries(selection(2).entries, '第二集');
        });
        await tester.pumpWidget(view(second));
        await tester.runAsync(first.close);
        controllers.remove(first);
        player.stream.positions.add(const Duration(milliseconds: 900));
        await tester.pump();
        player.stream.positions.add(const Duration(milliseconds: 1300));
        await tester.pump();
        expect(visible(), greaterThan(0));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
