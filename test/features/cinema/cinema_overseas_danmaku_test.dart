import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_overseas_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_platform_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_overseas_danmaku_parser.dart';
import 'package:flutter/foundation.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    calls.add(o);
    final data = await respond(o);
    return data is ResponseBody
        ? data
        : ResponseBody.fromString(jsonEncode(data), 200);
  }

  @override
  void close({bool force = false}) {}
}

class _HangingAdapter implements HttpClientAdapter {
  _HangingAdapter({this.aiyifanWins = false});
  final bool aiyifanWins;
  final started = Completer<void>(), cancelled = Completer<void>();
  final cancellation = <Future<void>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    if (aiyifanWins && options.uri.host != 'api.pleasfun.com') {
      return ResponseBody.fromString(jsonEncode(_aiFixture(options)), 200);
    }
    if (!started.isCompleted) started.complete();
    final done = cancel!.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    cancellation.add(done);
    await done;
    throw StateError('adapter request cancelled');
  }

  @override
  void close({bool force = false}) {}
}

Map _ok(Object data) => {
  'ret': 200,
  'data': {'list': data},
};
const query = CinemaLogvarQuery(
  title: '样例剧',
  series: true,
  season: 2,
  episode: 2,
  year: '2024',
);
Object _aiFixture(RequestOptions o) {
  if (o.uri.path.endsWith('/config')) {
    return _ok({
      'pConfig': {
        'publicKey': 'fixture',
        'privateKey': ['fixture-key'],
      },
    });
  }
  if (o.uri.path.endsWith('briefsearch')) {
    return {
      'data': {
        'info': [
          {
            'result': [
              {'contxt': 'work1', 'postTime': '2024-01-01T00:00:00'},
            ],
          },
        ],
      },
    };
  }
  expect(o.headers['x-pub'], 'fixture');
  if (o.uri.path.endsWith('GetTitleGetData')) {
    return _ok([
      {
        'mediaKey': 'work1',
        'title': '样例剧第二季',
        'mediaType': '电视剧',
        'postTime': '2026-11-01',
      },
    ]);
  }
  if (o.uri.path.endsWith('VideoChooseGather')) {
    return _ok([
      {
        'episodeKey': 'e2',
        'episodeTitle': '02',
        'uniqueID': 202,
        'episodeId': 999,
      },
      {'episodeKey': 'e1', 'episodeTitle': '01', 'uniqueID': 201},
    ]);
  }
  if (o.uri.path.endsWith('GetBarrages')) {
    expect(o.uri.queryParameters['videoId'], '202');
    return _ok([
      {'second': 12, 'contxt': '第二集', 'color': '#ff0000', 'position': 1},
      {'second': 12, 'contxt': '第二集', 'color': '#ff0000', 'position': 1},
      {'second': -2, 'contxt': '无效'},
    ]);
  }
  throw StateError('Unexpected public request');
}

Object _rrFixture(RequestOptions o) {
  if (o.uri.host == 'api.pleasfun.com') {
    return {
      'code': '0000',
      'data': {
        'seasonList': [
          {
            'id': 11,
            'title': '',
            'alias': '样例剧第二季',
            'year': 2024,
            'classify': 'TV',
            'highlights': {'original_name': 'Sample Drama'},
          },
          {
            'id': 12,
            'title': '样例剧第一季',
            'year': 2020,
            'classify': 'TV',
            'highlights': {'original_name': 'Sample Drama'},
          },
        ],
      },
    };
  }
  if (o.uri.path.endsWith('/details')) {
    return {
      'code': '0000',
      'data': {
        'dramaInfo': {
          'title': '样例剧第二季',
          'year': 2024,
          'dramaType': 'TV',
          'enName': 'Sample Drama',
        },
        'episodeList': [
          {'sid': 'sid2', 'episodeNo': 2, 'title': '第2集'},
          {'sid': 'sid1', 'episodeNo': 1, 'title': '第1集'},
        ],
        'watchInfo': {
          'm3u8': {'startingLength': 5000},
        },
      },
    };
  }
  expect(o.uri.path.endsWith('/sid2'), isTrue);
  return [
    {'p': '4,1,25,16777215,0,0,uid,1', 'd': '片头前'},
    {'p': '6,5,25,16711680,0,0,uid,2', 'd': '第二集弹幕'},
  ];
}

class _Matcher implements CinemaDanmakuMatcher {
  _Matcher(this.fn);
  final Future<CinemaLogvarSelection?> Function() fn;
  int called = 0, closed = 0;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery q, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) {
    called++;
    return fn();
  }

  @override
  void close() {
    closed++;
  }
}

void main() {
  test(
    'first successful platform cancels the losing pending network request',
    () async {
      final adapter = _HangingAdapter(aiyifanWins: true);
      final client = CinemaOverseasDanmakuClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      final result = await client
          .match(query)
          .timeout(const Duration(seconds: 5));
      expect(result!.provider, '爱一帆');
      await adapter.cancelled.future.timeout(const Duration(seconds: 1));
    },
  );
  test(
    'external cancellation settles match while both platforms are stalled',
    () async {
      final adapter = _HangingAdapter();
      final client = CinemaOverseasDanmakuClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      final token = CancelToken();
      final pending = client.match(query, cancelToken: token);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await adapter.started.future;
      token.cancel('切集');
      await assertion.timeout(const Duration(seconds: 1));
      await Future.wait(
        adapter.cancellation,
      ).timeout(const Duration(seconds: 1));
    },
  );
  test(
    'close cancels direct provider requests without cancelling caller token',
    () async {
      final adapter = _HangingAdapter();
      final client = CinemaOverseasDanmakuClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final token = CancelToken();
      final pending = client.matchRenren(query, cancelToken: token);
      final assertion = expectLater(pending, throwsA(anything));
      await adapter.started.future;
      client.close();
      await assertion.timeout(const Duration(seconds: 1));
      await adapter.cancelled.future.timeout(const Duration(seconds: 1));
      expect(token.isCancelled, isFalse);
    },
  );
  test(
    'large worker parse normalizes, deduplicates and sorts plain values',
    () async {
      final rows = List<Map>.generate(
        1000,
        (i) => {
          'second': 1000 - i,
          'contxt': '<b>弹幕 $i</b>  &amp; 测试',
          'color': '#ff0000',
          'position': 1,
        },
      );
      rows.addAll([
        rows.first,
        {'second': -1, 'contxt': 'invalid'},
      ]);
      final result = await compute(parseOverseasComments, (
        rows: rows,
        renren: false,
        leadInSeconds: 0.0,
      ));
      expect(result.length, 1000);
      expect(result.first.time, 1);
      expect(result.last.message, '弹幕 0 & 测试');
      expect(result.first.color, 0xffff0000);
      expect(result.first.type, 5);
    },
  );
  test('worker decoder handles bounded gzip and nested JSON', () async {
    final raw = Uint8List.fromList(
      gzip.encode(
        utf8.encode(
          jsonEncode(
            jsonEncode([
              {'p': '6,5,25,16711680', 'd': 'test'},
            ]),
          ),
        ),
      ),
    );
    final data = await compute(decodeOverseasResponse, raw);
    expect(data, [
      {'p': '6,5,25,16711680', 'd': 'test'},
    ]);
    final tooLarge = Uint8List.fromList(
      gzip.encode(List.filled(8 * 1024 * 1024 + 1, 32)),
    );
    await expectLater(
      compute(decodeOverseasResponse, tooLarge),
      throwsFormatException,
    );
  });

  test(
    'aiyifan selects exact numbered episode and uniqueID, not array index or episodeId',
    () async {
      final c = CinemaOverseasDanmakuClient(
        dio: Dio()..httpClientAdapter = _Adapter(_aiFixture),
      );
      addTearDown(c.close);
      final result = await c.matchAiyifan(query);
      expect(result!.provider, '爱一帆');
      expect(result.entries.single.message, '第二集');
      expect(result.entries.single.type, 5);
      expect(result.work.year, '2024');
      expect(result.episode.number, 2);
    },
  );
  test(
    'aiyifan does not use site insertion date as release year or choose a remake',
    () async {
      var comments = 0;
      final a = _Adapter((o) {
        if (o.uri.path.endsWith('GetBarrages')) comments++;
        if (o.uri.path.endsWith('briefsearch')) {
          return {
            'data': {
              'info': [
                {
                  'result': [
                    {'contxt': 'work1', 'postTime': '2010-01-01'},
                  ],
                },
              ],
            },
          };
        }
        return _aiFixture(o);
      });
      final c = CinemaOverseasDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      expect(await c.matchAiyifan(query), isNull);
      expect(comments, 0);
    },
  );
  test(
    'aiyifan missing target episode never falls back to list position',
    () async {
      final c = CinemaOverseasDanmakuClient(
        dio: Dio()
          ..httpClientAdapter = _Adapter((o) {
            if (o.uri.path.endsWith('VideoChooseGather')) {
              return _ok([
                {
                  'episodeKey': 'trailer',
                  'episodeTitle': '预告',
                  'uniqueID': 999,
                },
                {'episodeKey': 'e7', 'episodeTitle': '第7集', 'uniqueID': 207},
              ]);
            }
            return _aiFixture(o);
          }),
      );
      addTearDown(c.close);
      expect(await c.matchAiyifan(query), isNull);
    },
  );
  test(
    'renren checks aliases with source season, exact episode, and episode-specific lead-in',
    () async {
      final a = _Adapter(_rrFixture);
      final c = CinemaOverseasDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      final r = await c.matchRenren(
        const CinemaLogvarQuery(
          title: 'Sample Drama',
          series: true,
          season: 2,
          episode: 2,
          year: '2024',
        ),
      );
      expect(r!.provider, '人人视频');
      expect(r.work.title, '样例剧第二季');
      expect(a.calls.first.uri.query, contains('searchAfter='));
      expect(
        a.calls.firstWhere((o) => o.uri.path.endsWith('/details')).uri.query,
        contains('episodeId='),
      );
      expect(r.entries.single.message, '第二集弹幕');
      expect(r.entries.single.time, 1);
      expect(r.entries.single.type, 5);
      expect(
        a.calls
            .where((o) => o.uri.path.endsWith('/details'))
            .last
            .uri
            .queryParameters['episodeId'],
        'sid2',
      );
      expect(
        a.calls.every(
          (o) =>
              !o.uri.host.contains('dandan') && !o.uri.host.contains('ug.link'),
        ),
        isTrue,
      );
    },
  );
  test(
    'renren cannot match a generic English alias to the wrong season',
    () async {
      final c = CinemaOverseasDanmakuClient(
        dio: Dio()..httpClientAdapter = _Adapter(_rrFixture),
      );
      addTearDown(c.close);
      expect(
        await c.matchRenren(
          const CinemaLogvarQuery(
            title: 'Sample Drama',
            series: true,
            season: 3,
            episode: 2,
            year: '2024',
          ),
        ),
        isNull,
      );
    },
  );
  test('malformed public title is rejected before networking', () async {
    final a = _Adapter((_) => throw StateError('no request'));
    final c = CinemaOverseasDanmakuClient(dio: Dio()..httpClientAdapter = a);
    addTearDown(c.close);
    await expectLater(
      c.match(const CinemaLogvarQuery(title: 'https://private.example/movie')),
      throwsFormatException,
    );
    expect(a.calls, isEmpty);
  });
  test(
    'cancellation is preserved, no fallback after a cancelled domestic lookup',
    () async {
      final token = CancelToken()..cancel();
      final d = _Matcher(() async => throw token.cancelError!);
      final f = _Matcher(() async => null);
      final c = CinemaPlatformDanmakuClient(domestic: d, overseas: f);
      await expectLater(
        c.match(query, cancelToken: token),
        throwsA(isA<DioException>()),
      );
      expect(f.called, 0);
      c.close();
      c.close();
      expect(d.closed, 1);
      expect(f.closed, 1);
    },
  );
  test('overseas fallback runs after domestic connection errors', () async {
    final d = _Matcher(
      () async => throw const FormatException('domestic unavailable'),
    );
    final expected = CinemaLogvarSelection(
      const CinemaLogvarWork(id: 1, title: '样例剧'),
      const CinemaLogvarEpisode(2, '第2集', 2),
      [],
      0,
      provider: '人人视频',
    );
    final f = _Matcher(() async => expected);
    final c = CinemaPlatformDanmakuClient(domestic: d, overseas: f);
    addTearDown(c.close);
    expect(await c.match(query), same(expected));
    expect(f.called, 1);
  });
  test(
    'existing confirmed domestic comments keep priority and skip overseas traffic',
    () async {
      final expected = CinemaLogvarSelection(
        const CinemaLogvarWork(id: 1, title: '样例剧'),
        const CinemaLogvarEpisode(2, '第2集', 2),
        [],
        0,
      );
      final f = _Matcher(() async => null);
      final c = CinemaPlatformDanmakuClient(
        domestic: _Matcher(() async => expected),
        overseas: f,
      );
      addTearDown(c.close);
      expect(await c.match(query), same(expected));
      expect(f.called, 0);
    },
  );
}
