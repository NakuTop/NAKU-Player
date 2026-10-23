import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_dandan_client.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    Object body;
    if (options.path.contains('/search/')) {
      body = {
        'success': true,
        'animes': [
          {'animeId': 12, 'animeTitle': '自写电影', 'typeDescription': '电影'},
        ],
      };
    } else if (options.path.contains('/bangumi/')) {
      body = {
        'success': true,
        'bangumi': {
          'episodes': [
            {'episodeId': 987654321012, 'episodeTitle': '正片'},
          ],
        },
      };
    } else {
      body = {
        'success': true,
        'comments': [
          {'m': '自写弹幕', 'p': '1.2,1,16777215,unit'},
        ],
      };
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'public source accepts only a public page and strips signed queries',
    () {
      expect(
        cinemaPublicDanmakuLink(
          'https://v.qq.com/x/cover/a/b.html?token=private',
        ).toString(),
        'https://v.qq.com/x/cover/a/b.html',
      );
      for (final link in [
        'http://127.0.0.1/a',
        'https://nas.example/a.m3u8',
        'https://v.qq.com.evil.org/a',
        'https://user:pass@v.qq.com/a',
        'https://v.qq.com:444/a',
      ]) {
        expect(() => cinemaPublicDanmakuLink(link), throwsFormatException);
      }
    },
  );
  test('timeline respects rate, pause gap, seeks, density and duplicates', () {
    final entries = [
      for (var i = 0; i < 20; i++)
        DanmakuEntry(
          message: 'self $i',
          time: i * .1,
          type: 1,
          color: Colors.white,
          source: '[Local]',
        ),
    ];
    final clock = CinemaDanmakuClock();
    expect(clock.advance(entries, 0), isEmpty);
    expect(clock.advance(entries, .8).length, 4);
    expect(clock.advance(entries, .8), isEmpty);
    expect(clock.advance(entries, 50), isEmpty);
    expect(clock.reset, isTrue);
    expect(clock.advance(entries, .5), isEmpty);
    expect(clock.advance(entries, .9).map((e) => e.message), [
      'self 6',
      'self 7',
      'self 8',
      'self 9',
    ]);
    final doubled = CinemaDanmakuClock();
    doubled.advance(entries, 0, rate: 2);
    expect(doubled.advance(entries, 3, rate: 2), hasLength(4));
  });
  test(
    'official flow uses returned 64-bit episode IDs and caches repeat reads',
    () async {
      final adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final service = CinemaDandanClient(
        client: DanmakuClient(
          dio: dio,
          credentials: const DandanCredentials(id: 'test', secret: 'fixture'),
        ),
      );
      final works = await service.search('自写电影');
      final episodes = await service.episodes(works.single.id);
      final comments = await service.comments(episodes.single.id);
      expect(comments.single.message, '自写弹幕');
      expect(adapter.requests.last.path, endsWith('/comment/987654321012'));
      expect(adapter.requests.last.queryParameters['withRelated'], isTrue);
      await service.search('自写电影');
      await service.episodes(12);
      await service.comments(987654321012);
      expect(adapter.requests, hasLength(3));
      expect(
        () => service.search('https://nas/private'),
        throwsFormatException,
      );
    },
  );
}
