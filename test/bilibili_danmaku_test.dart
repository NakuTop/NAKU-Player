import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';

class _Adapter implements HttpClientAdapter {
  bool blockSearch = false;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (options.uri.path == '/pgc/review/user') {
      return _json({
        'code': 0,
        'result': {
          'media': {'season_id': 42},
        },
      });
    }
    if (options.uri.path == '/x/web-interface/search/type') {
      if (blockSearch) return ResponseBody.fromString('unavailable', 412);
      return _json({
        'code': 0,
        'data': {
          'result': [
            {
              'season_id': 42,
              'title': '<em class="keyword">孤独摇滚</em>！',
              'org_title': 'ぼっち・ざ・ろっく！',
              'pubtime':
                  DateTime.utc(2022, 10, 8).millisecondsSinceEpoch ~/ 1000,
            },
            {'title': 'invalid'},
          ],
        },
      });
    }
    if (options.uri.host == 'comment.bilibili.com') {
      final bytes = ZLibEncoder(raw: true).convert(
        utf8.encode('<i><d p="3.5,1,25,16777215,0,0,0">fixture</d></i>'),
      );
      return ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          'content-encoding': ['deflate'],
        },
      );
    }
    final pgc = options.uri.path.contains('pgc');
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        pgc ? 'result' : 'data': {
          'title': 'fixture',
          pgc ? 'episodes' : 'pages': pgc
              ? [
                  {
                    'id': 100,
                    'cid': 201,
                    'title': '1',
                    'long_title': 'Episode 1',
                  },
                  {
                    'id': 101,
                    'cid': 202,
                    'title': '2',
                    'long_title': 'Episode 2',
                  },
                  {
                    'id': 102,
                    'cid': 203,
                    'title': 'PV',
                    'long_title': 'Preview',
                  },
                ]
              : [
                  {'page': 1, 'cid': 201, 'part': 'Part 1'},
                  {'page': 2, 'cid': 202, 'part': 'Part 2'},
                ],
        },
      }),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  ResponseBody _json(Object value) => ResponseBody.fromString(
    jsonEncode(value),
    200,
    headers: {
      'content-type': ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'only public Bilibili identifiers are accepted; arbitrary URLs never requested',
    () {
      expect(
        BilibiliDanmakuLink.parse(
          'https://www.bilibili.com/video/BV1GJ411x7h7?p=2',
        ).page,
        2,
      );
      expect(BilibiliDanmakuLink.parse('av170001').kind, 'av');
      expect(
        BilibiliDanmakuLink.parse(
          'https://www.bilibili.com/bangumi/play/ep101',
        ).id,
        '101',
      );
      expect(BilibiliDanmakuLink.parse('ss200').kind, 'ss');
      expect(BilibiliDanmakuLink.parse('md28339735').kind, 'md');
      expect(
        BilibiliDanmakuLink.parse(
          'https://www.bilibili.com/bangumi/media/md28339735/',
        ).id,
        '28339735',
      );
      for (final input in [
        'https://evil.invalid/video/BV1GJ411x7h7',
        'https://www.bilibili.com.evil.invalid/video/BV1GJ411x7h7',
        'file:///etc/passwd',
        'https://user:pass@www.bilibili.com/video/BV1GJ411x7h7',
        'av0',
        'https://b23.tv/abc',
        'https://www.bilibili.com/video/BV1GJ411x7h7?p=0',
      ]) {
        expect(() => BilibiliDanmakuLink.parse(input), throwsFormatException);
      }
    },
  );
  test(
    'media IDs resolve to seasons, preserving numeric episode identities',
    () async {
      final adapter = _Adapter(), dio = Dio();
      dio.httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = BilibiliDanmakuClient(dio: dio);
      final video = await client.video('md28339735');
      expect(adapter.requests[0].queryParameters, {'media_id': '28339735'});
      expect(
        adapter.requests[0].headers['User-Agent'],
        contains('AppleWebKit/'),
      );
      expect(adapter.requests[0].headers['User-Agent'], isNot('Mozilla/5.0'));
      expect(adapter.requests[1].queryParameters, {'season_id': '42'});
      expect(video.pages.map((p) => p.episodeNumber), [1, 2, null]);
    },
  );
  test(
    'public search rejection falls back to an independent title index',
    () async {
      final adapter = _Adapter()..blockSearch = true;
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      var fallbacks = 0;
      final client = BilibiliDanmakuClient(
        dio: dio,
        animeSearchFallback: (query) async {
          fallbacks++;
          expect(query, '孤独摇滚');
          return const [
            BilibiliAnimeCandidate('md28339735', '孤独摇滚！', year: 2022),
          ];
        },
      );
      final found = await client.searchAnime('孤独摇滚');
      expect(found.single.reference, 'md28339735');
      expect(found.single.year, 2022);
      expect(fallbacks, 1);
      await expectLater(
        client.searchFilms('孤独摇滚'),
        throwsA(isA<DioException>()),
      );
      expect(
        fallbacks,
        1,
        reason: 'Anime data must never replace a movie search',
      );
    },
  );
  test('anime search decodes highlighted names, year and season IDs', () async {
    final adapter = _Adapter(), dio = Dio();
    dio.httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = BilibiliDanmakuClient(dio: dio);
    await expectLater(client.searchAnime('  '), throwsFormatException);
    expect(adapter.requests, isEmpty);
    final result = await client.searchAnime('  孤独摇滚  ');
    expect(result.single.reference, 'ss42');
    expect(result.single.title, '孤独摇滚！');
    expect(result.single.originalTitle, 'ぼっち・ざ・ろっく！');
    expect(result.single.year, 2022);
    expect(adapter.requests.single.queryParameters, {
      'search_type': 'media_bangumi',
      'keyword': '孤独摇滚',
    });
  });
  test(
    'UGC page/PGC episode selection and raw deflate work without credentials',
    () async {
      final adapter = _Adapter(), dio = Dio();
      dio.httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = BilibiliDanmakuClient(dio: dio);
      final video = await client.video(
        'https://www.bilibili.com/video/BV1GJ411x7h7?p=2',
      );
      expect(video.selectedIndex, 1);
      expect(video.pages[1].cid, 202);
      final anime = await client.video('ep101');
      expect(anime.selectedIndex, 1);
      expect(adapter.requests[1].queryParameters, {'ep_id': '101'});
      final comments = await client.comments(202);
      expect(comments.single.message, 'fixture');
      expect(comments.single.time, 3.5);
      expect(comments.single.source, '[BiliBili]');
      expect(
        adapter.requests.every(
          (r) =>
              !r.headers.containsKey('X-AppId') &&
              !r.headers.containsKey('Cookie'),
        ),
        isTrue,
      );
      final dir = await Directory.systemTemp.createTemp('bili-cache-');
      addTearDown(() => dir.delete(recursive: true));
      await LocalDanmakuStore(directory: dir).save(309311, 1, comments);
      final cached = await LocalDanmakuStore(directory: dir).read(309311, 1);
      expect(cached!.single.source, '[BiliBili]');
    },
  );
  test(
    'live public metadata and comments without cookies or application credentials',
    () async {
      final dio = Dio();
      addTearDown(dio.close);
      final client = BilibiliDanmakuClient(dio: dio);
      final video = await client.video('BV1GJ411x7h7');
      expect(video.pages, isNotEmpty);
      final comments = await client.comments(video.pages.first.cid);
      expect(comments, isNotEmpty);
      final anime = await client.video('ep317925');
      expect(anime.pages, isNotEmpty);
    },
    skip: Platform.environment['NAKU_BILIBILI_LIVE_TESTS'] != '1',
  );
}
