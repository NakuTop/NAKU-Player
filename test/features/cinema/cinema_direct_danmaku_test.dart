import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/features/cinema/cinema_direct_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<Object> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = await respond(options);
    return body is ResponseBody
        ? body
        : ResponseBody.fromString(jsonEncode(body), 200);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> catalogue(List<Map> rows) => {
  'data': {
    'longData': {'rows': rows},
  },
};
Map<String, dynamic> series({
  String title = '自写剧',
  String year = '2024',
  List? links,
}) => {
  'id': 1,
  'titleTxt': title,
  'year': year,
  'cat_name': '电视剧',
  'cat_id': '2',
  'en_id': 'fixture',
  'playlinks': {'qq': 'https://v.qq.com/x/cover/fixture/episode00001.html'},
  'seriesSite': 'qq',
  'seriesPlaylinks':
      links ??
      [
        {
          'url':
              'https://v.qq.com/x/cover/fixture/episode00001.html?tracking=removed',
        },
        {'url': 'https://v.qq.com/x/cover/fixture/episode00002.html'},
      ],
};

void main() {
  test(
    'dub labels normalize the lookup and prefer the same dubbed movie',
    () async {
      for (final edition in ['普通话版', '国语版', '粤语版']) {
        final adapter = _Adapter((o) {
          if (o.uri.host == 'api.so.360kan.com') {
            expect(o.queryParameters['kw'], '泰坦尼克号');
            return catalogue([
              {
                'titleTxt': '泰坦尼克号',
                'cat_name': '电影',
                'year': '1997',
                'playlinks': {
                  'qq': 'https://v.qq.com/x/cover/fixture/original0001.html',
                },
              },
              {
                'titleTxt': '泰坦尼克号（${edition == '粤语版' ? '粤语' : '普通话'}）',
                'cat_name': '电影',
                'year': '1997',
                'playlinks': {
                  'qq': 'https://v.qq.com/x/cover/fixture/dubbed000001.html',
                },
              },
              {
                'titleTxt': '泰坦尼克号2',
                'cat_name': '电影',
                'year': '2010',
                'playlinks': {
                  'qq': 'https://v.qq.com/x/cover/fixture/sequel000001.html',
                },
              },
            ]);
          }
          expect(o.uri.path, contains('dubbed000001'));
          if (o.uri.path.contains('/base/')) {
            return {
              'segment_index': {
                '0': {'segment_name': 't/v1/0/30000'},
              },
            };
          }
          return {
            'barrage_list': [
              {'time_offset': '1000', 'content': '同配音版弹幕'},
            ],
          };
        });
        final client = CinemaDirectDanmakuClient(
          dio: Dio()..httpClientAdapter = adapter,
        );
        try {
          final r = await client.match(
            CinemaLogvarQuery.parse(
              '泰坦尼克号（$edition）',
              category: '剧情片',
              year: '1997',
            ),
          );
          expect(r?.entries.single.message, '同配音版弹幕');
        } finally {
          client.close();
        }
      }
    },
  );

  test(
    'empty catalogue is retried once without relaxing movie identity',
    () async {
      var searches = 0;
      final adapter = _Adapter((o) {
        if (o.uri.host == 'api.so.360kan.com') {
          searches++;
          if (searches == 1) {
            return {
              'code': 0,
              'data': {'longData': []},
            };
          }
          expect(o.queryParameters['_'], isNotNull);
          return catalogue([
            {
              'titleTxt': '《给阿嬷的情书》深度推荐',
              'cat_name': '电影',
              'year': '2026',
              'playlinks': {
                'qq': 'https://v.qq.com/x/cover/fixture/trailer00001.html',
              },
            },
            {
              'titleTxt': '给阿嬷的情书—阿嬷讲给孩子的南洋故事',
              'cat_name': '动漫',
              'year': '2026',
              'playlinks': {
                'qq': 'https://v.qq.com/x/cover/fixture/spinoff00001.html',
              },
            },
          ]);
        }
        fail('Extras must not trigger platform loading');
      });
      final client = CinemaDirectDanmakuClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(client.close);
      expect(
        await client.match(
          CinemaLogvarQuery.parse('给阿嬷的情书', category: '剧情片', year: '2026'),
        ),
        isNull,
      );
      expect(searches, 2);
    },
  );

  test('drama and comedy films stay movies in automatic matching', () async {
    for (final category in ['剧情片', '喜剧片', '动画片', '电影', 'movie']) {
      final query = CinemaLogvarQuery.parse(
        '泰坦尼克号',
        category: category,
        episodeName: 'HD中字',
        fallbackEpisode: 1,
        year: '1997',
      );
      expect(query.series, isFalse, reason: category);
      final adapter = _Adapter((o) {
        if (o.uri.host == 'api.so.360kan.com') {
          return catalogue([
            {
              'id': 46699,
              'titleTxt': '泰坦尼克号',
              'year': '1997',
              'cat_name': '电影',
              'playlinks': {
                'qq': 'https://v.qq.com/x/cover/fixture/p0046jmjyte.html',
              },
            },
          ]);
        }
        if (o.uri.path.contains('/base/')) {
          return {
            'segment_index': {
              '0': {'segment_name': 't/v1/0/30000'},
            },
          };
        }
        return {
          'barrage_list': [
            {'time_offset': '1000', 'content': '正片弹幕'},
          ],
        };
      });
      final client = CinemaDirectDanmakuClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      try {
        final result = await client.match(query);
        expect(result?.entries.single.message, '正片弹幕');
      } finally {
        client.close();
      }
    }
    expect(
      CinemaLogvarQuery.parse(
        '自写剧',
        category: '电视剧',
        episodeName: '第3集',
      ).series,
      isTrue,
    );
  });

  test(
    'direct matching checks episode identity and uses platform hosts only',
    () async {
      final a = _Adapter((o) {
        if (o.uri.host == 'api.so.360kan.com') return catalogue([series()]);
        if (o.uri.path.contains('/base/')) {
          return {
            'segment_index': {
              '0': {'segment_name': 't/v1/0/60000'},
            },
          };
        }
        expect(o.uri.path, contains('episode00002'));
        return {
          'barrage_list': [
            {
              'time_offset': '1230',
              'content': '自写第二集弹幕',
              'content_style': '{"color":"ff0000","position":2}',
            },
            {'time_offset': '-10', 'content': '无效时间'},
          ],
        };
      });
      final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      final result = await c.match(
        const CinemaLogvarQuery(
          title: '自写剧',
          series: true,
          episode: 2,
          year: '2024',
        ),
      );
      expect(result!.provider, '腾讯视频');
      expect(result.entries.single.message, '自写第二集弹幕');
      expect(result.entries.single.time, 1.23);
      expect(result.entries.single.type, 5);
      expect(
        a.requests.every(
          (o) => {'api.so.360kan.com', 'dm.video.qq.com'}.contains(o.uri.host),
        ),
        isTrue,
      );
      expect(
        a.requests.any((o) => o.uri.toString().contains('tracking')),
        isFalse,
      );
      expect(a.requests.every((o) => !o.headers.containsKey('Cookie')), isTrue);
    },
  );

  test(
    'different seasons, films, extras and years cannot substitute for a TV episode',
    () async {
      final a = _Adapter(
        (o) => catalogue([
          series(title: '自写剧 第2季'),
          series(year: '2020'),
          {...series(), 'cat_name': '电影'},
          series(title: '自写剧 花絮'),
        ]),
      );
      final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      expect(
        await c.match(
          const CinemaLogvarQuery(title: '自写剧', series: true, year: '2024'),
        ),
        isNull,
      );
      expect(a.requests.length, 1);
    },
  );

  test('ambiguous remakes are not selected automatically', () async {
    final a = _Adapter(
      (_) => catalogue([series(year: '2024'), series(year: '2000')]),
    );
    final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
    addTearDown(c.close);
    await expectLater(
      c.match(const CinemaLogvarQuery(title: '自写剧', series: true)),
      throwsFormatException,
    );
    expect(a.requests.length, 1);
  });

  test(
    'repeated catalogue landing URLs are rejected instead of reusing episode one',
    () async {
      final a = _Adapter(
        (o) => o.uri.path == '/index'
            ? catalogue([
                series(
                  links: List.generate(
                    3,
                    (_) => {
                      'url':
                          'https://v.qq.com/x/cover/fixture/episode00001.html',
                    },
                  ),
                ),
              ])
            : {},
      );
      final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      expect(
        await c.match(
          const CinemaLogvarQuery(title: '自写剧', series: true, episode: 2),
        ),
        isNull,
      );
      expect(a.requests.any((o) => o.uri.host == 'dm.video.qq.com'), isFalse);
    },
  );

  test('cancelled matching makes no network request', () async {
    final a = _Adapter((_) => {});
    final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
    addTearDown(c.close);
    final token = CancelToken()..cancel('new episode');
    await expectLater(
      c.match(const CinemaLogvarQuery(title: '自写电影'), cancelToken: token),
      throwsA(isA<DioException>()),
    );
    expect(a.requests, isEmpty);
  });

  test(
    'a failed segment is explicit partial loading, with bounded parallelism',
    () async {
      var active = 0, peak = 0;
      final a = _Adapter((o) async {
        if (o.uri.path.contains('/base/')) {
          return {
            'segment_index': {
              for (var i = 0; i < 8; i++) '$i': {'segment_name': '${i}_end'},
            },
          };
        }
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
        if (o.uri.path.endsWith('/3_end')) {
          throw const FormatException('fixture failed');
        }
        return {
          'barrage_list': [
            {'time_offset': '1000', 'content': o.uri.pathSegments.last},
          ],
        };
      });
      final c = CinemaDirectDanmakuClient(dio: Dio()..httpClientAdapter = a);
      addTearDown(c.close);
      final comments = await c.loadPage(
        'https://v.qq.com/x/cover/fixture/episode00001.html',
      );
      expect(comments.partial, isTrue);
      expect(comments.entries.length, inInclusiveRange(4, 6));
      expect(peak, lessThanOrEqualTo(3));
    },
  );

  test(
    'public page extraction strips tracking and rejects NAS/private URLs',
    () {
      expect(
        cinemaDirectDanmakuPage(
          'https://v.youku.com/video?vid=XMzcxNDY5ODQ4&token=tracking',
        ).toString(),
        'https://v.youku.com/v_show/id_XMzcxNDY5ODQ4.html',
      );
      for (final url in [
        'http://192.168.1.10:9321/movie',
        'https://user:pass@v.qq.com/x/test',
        'https://v.qq.com.evil.test/x/test',
        'file:///Users/test/movie.mkv',
      ]) {
        expect(() => cinemaDirectDanmakuPage(url), throwsFormatException);
      }
    },
  );
  test(
    'a long film keeps a bounded window and fetches only around a seek',
    () async {
      final requested = <int>[];
      final timeline = CinemaDirectDanmakuTimeline(
        List.generate(600, (i) => i * 60.0),
        60,
        (index, token) async {
          requested.add(index);
          return [
            for (var i = 0; i < 5000; i++)
              DanmakuEntry(
                message: '自写 $index $i',
                time: index * 60 + i / 100,
                type: 1,
                color: const Color(0xffffffff),
                source: 'fixture',
              ),
          ];
        },
        endSeconds: 36000,
      );
      final first = await timeline.window(0);
      expect(requested.length, lessThanOrEqualTo(4));
      expect(first.entries.length, lessThanOrEqualTo(6000));
      await timeline.window(3600);
      expect(
        requested.where((i) => i > 4).every((i) => i >= 59 && i <= 62),
        isTrue,
      );
      expect(timeline.cachedSegments, lessThanOrEqualTo(6));
      expect(timeline.cachedEntries, lessThanOrEqualTo(12000));
      final token = CancelToken()..cancel('seek cancelled');
      await expectLater(
        timeline.window(6000, cancelToken: token),
        throwsA(isA<DioException>()),
      );
      timeline.close();
      expect(timeline.cachedEntries, 0);
    },
  );

  test(
    'expired anonymous platform tokens refresh once and retry the segment',
    () async {
      var leases = 0;
      final old = List.filled(32, 'a').join(),
          fresh = List.filled(32, 'b').join();
      final a = _Adapter((o) {
        if (o.uri.host == 'openapi.youku.com') return {'duration': 7200};
        if (o.uri.path.contains('weakget')) {
          leases++;
          final tk = leases == 1 ? old : fresh;
          return ResponseBody.fromString(
            '{}',
            200,
            headers: {
              'set-cookie': [
                '_m_h5_tk=${tk}_fixture; Path=/',
                '_m_h5_tk_enc=fixture; Path=/',
              ],
            },
          );
        }
        if ('${o.headers['Cookie']}'.contains(old)) {
          return {
            'ret': ['FAIL_SYS_TOKEN_EXPIRED'],
          };
        }
        final body =
            jsonDecode(Uri.splitQueryString('${o.data}')['data']!) as Map;
        return {
          'data': {
            'result': jsonEncode({
              'data': {
                'result': [
                  {
                    'content': '自写令牌恢复弹幕',
                    'playat': (body['mat'] as int) * 60000 + 1000,
                  },
                ],
              },
            }),
          },
        };
      });
      final client = CinemaDirectDanmakuClient(
        dio: Dio()..httpClientAdapter = a,
      );
      addTearDown(client.close);
      final comments = await client.loadPage(
        'https://v.youku.com/v_show/id_XMzcxNDY5ODQ4.html',
      );
      expect(comments.entries, isNotEmpty);
      expect(comments.partial, isFalse);
      expect(leases, 2);
    },
  );
}
