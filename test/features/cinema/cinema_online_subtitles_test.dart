import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_fallbacks.dart';
import 'package:media_kit/media_kit.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  dynamic answer = <String, dynamic>{};
  List<int>? subtitleBytes;
  dynamic Function(RequestOptions)? respond;
  String Function(RequestOptions)? subtitleText;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'subs.example') {
      if (options.uri.path.contains('bad')) {
        return ResponseBody.fromString('<html>blocked</html>', 200);
      }
      if (subtitleBytes != null) {
        return ResponseBody.fromBytes(subtitleBytes!, 200);
      }
      return ResponseBody.fromString(
        subtitleText?.call(options) ??
            '1\n00:00:01,000 --> 00:00:02,000\n字幕内容\n',
        200,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(respond?.call(options) ?? answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Player implements Player {
  @override
  Future<void> pause() async {}
  @override
  PlatformPlayer? get platform => null;
  SubtitleTrack? selected;
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    selected = track;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'fallback metadata is episode-specific and never substitutes another work',
    () {
      List<Map<String, dynamic>> find(String name, String id, int episode) =>
          cinemaSubtitleFallbacks(
            title: name,
            imdbId: id,
            type: 'series',
            season: 10,
            episode: episode,
          );
      expect(find('美国恐怖故事', '', 2), hasLength(2));
      expect(
        find(
          'American Horror Story',
          '',
          2,
        ).every((row) => row['bilingual'] == true),
        isTrue,
      );
      expect(find('unrelated', 'tt1844624', 2), hasLength(2));
      expect(find('美国恐怖故事', 'tt9999999', 2), isEmpty);
      for (var episode = 1; episode <= 10; episode++) {
        if (episode == 2) continue;
        final rows = find('美国恐怖故事', '', episode);
        expect(rows, hasLength(1));
        expect(
          rows.single['archiveEntry'],
          contains('S10E${episode.toString().padLeft(2, '0')}'),
        );
        expect(rows.single['archiveEntry'], isNot(contains('S10E02')));
      }
      expect(find('美国恐怖故事', '', 11), isEmpty);
      expect(find('美国恐怖故事', '', 0), isEmpty);
      expect(
        cinemaSubtitleFallbacks(
          title: '美国恐怖故事',
          imdbId: '',
          type: 'series',
          season: 9,
          episode: 3,
        ),
        isEmpty,
      );
      expect(find('美国恐怖故事集', '', 2), isEmpty);
      expect(find('美国恐怖故事：双面 第十季', '', 2), hasLength(2));
      expect(find('美国恐怖故事 (American Horror Story)', '', 2), hasLength(2));
      expect(
        cinemaSubtitleAliases('美国恐怖故事 第十季'),
        contains('American Horror Story'),
      );
    },
  );
  test(
    'IMDb metadata resolves a standard search name without Chinese title lookup',
    () async {
      final adapter = _Adapter()
        ..respond = (request) {
          if (request.uri.path == '/meta/series/tt1844624.json') {
            return {
              'meta': {
                'id': 'tt1844624',
                'name': 'American Horror Story',
                'type': 'series',
              },
            };
          }
          return {'subtitles': <dynamic>[]};
        };
      final client = CinemaOnlineSubtitles(
        useFallbackCatalog: false,
        dio: Dio()..httpClientAdapter = adapter,
      );
      await client.aggregate(
        '不同发行片名',
        'series',
        imdbId: 'tt1844624',
        season: 10,
        episode: 2,
      );
      expect(
        adapter.requests.any(
          (request) => request.uri.path.startsWith('/catalog/'),
        ),
        isFalse,
      );
      expect(
        adapter.requests.any(
          (request) =>
              request.uri.queryParameters['searchword'] ==
              'American Horror Story S10E02',
        ),
        isTrue,
      );
      client.close();
    },
  );
  test(
    'current Chinese season, episode and release filename are parsed locally',
    () {
      final query = CinemaSubtitleQuery.parse('美国恐怖故事 第十季第二集');
      expect(query.title, '美国恐怖故事');
      expect(query.type, 'series');
      expect(query.season, 10);
      expect(query.episode, 2);
      final file = CinemaSubtitleQuery.parse(
        'American Horror Story',
        category: '电视剧',
        episodeName: 'American.Horror.Story.S10E02.1080p.mkv',
      );
      expect(file.season, 10);
      expect(file.episode, 2);
      final underscore = CinemaSubtitleQuery.parse(
        '作品',
        episodeName: 'American_Horror_Story_S10E02_1080p.mkv',
      );
      expect(underscore.season, 10);
      expect(underscore.episode, 2);
      expect(
        CinemaSubtitleQuery.parse(
          'American.Horror.Story.S10E02.1080p.mkv',
        ).title,
        'American Horror Story',
      );
      expect(
        CinemaSubtitleQuery.parse(
          'American Horror Story S10',
          episodeName: '02',
        ).season,
        10,
      );
      final special = CinemaSubtitleQuery.parse(
        '作品',
        category: '电视剧',
        episodeName: 'S00E03',
        fallbackEpisode: 8,
      );
      expect(special.season, 0);
      expect(special.episode, 3);
      expect(
        CinemaSubtitleQuery.parse(
          '作品',
          category: '电视剧',
          fallbackEpisode: 12,
        ).episode,
        12,
      );
      expect(CinemaSubtitleQuery.parse('Se7en').type, 'movie');
      expect(CinemaSubtitleQuery.parse('1917').title, '1917');
    },
  );

  test('regional Chinese and ISO language variants remain visible', () {
    for (final code in ['zh-CN', 'zh_TW', 'zho', 'chi', 'chs', 'cht']) {
      expect(cinemaSubtitleLanguageMatches(code, 'zh'), isTrue);
    }
    expect(cinemaSubtitleLanguageMatches('en', 'eng'), isTrue);
    expect(cinemaSubtitleLanguageMatches('ja', 'jpn'), isTrue);
    expect(cinemaSubtitleLanguageMatches('eng', 'zh'), isFalse);
    expect(cinemaSubtitleLanguageMatches('eng', 'zh-eng'), isTrue);
    expect(cinemaSubtitleLanguageMatches('zh-CN', 'zh-eng'), isTrue);
    expect(cinemaSubtitleLanguageMatches('jpn', 'zh-eng'), isFalse);
    expect(cinemaSubtitleLanguageMatches('spa', 'zh-eng'), isFalse);
  });

  test(
    'UTF16 subtitle download decodes and invalid web responses are rejected',
    () async {
      final adapter = _Adapter();
      final client = CinemaOnlineSubtitles(
        useFallbackCatalog: false,
        dio: Dio()..httpClientAdapter = adapter,
      );
      const text = '1\n00:00:01,000 --> 00:00:02,000\n中文字幕\n';
      for (final little in [true, false]) {
        adapter.subtitleBytes = [
          if (little) ...[0xff, 0xfe] else ...[0xfe, 0xff],
          for (final unit in text.codeUnits)
            ...(little ? [unit & 255, unit >> 8] : [unit >> 8, unit & 255]),
        ];
        expect(await client.download('https://subs.example/test.srt'), text);
      }
      adapter.subtitleBytes = utf8.encode('<html><!-- --> blocked</html>');
      await expectLater(
        client.download('https://subs.example/error'),
        throwsFormatException,
      );
      adapter.subtitleBytes = utf8.encode('not a subtitle');
      await expectLater(
        client.download('https://subs.example/error'),
        throwsFormatException,
      );
      await expectLater(
        client.download('file:///private'),
        throwsFormatException,
      );
    },
  );

  test(
    'search encodes keywords and series requests preserve season and episode',
    () async {
      final adapter = _Adapter()
        ..answer = {
          'metas': [
            {'id': 'tt123', 'name': '电影'},
          ],
        };
      final client = CinemaOnlineSubtitles(
        useFallbackCatalog: false,
        dio: Dio()..httpClientAdapter = adapter,
      );
      expect((await client.search('电影 & name', 'movie')).single['id'], 'tt123');
      final uri = adapter.requests.single.uri;
      expect(uri.host, 'v3-cinemeta.strem.io');
      expect(
        Uri.decodeComponent(uri.path),
        '/catalog/movie/top/search=电影 & name.json',
      );
      expect(uri.toString(), contains('%26'));
      adapter.answer = {
        'subtitles': [
          {'url': 'https://subs.example/1.srt', 'lang': 'zht'},
          {'url': 'https://subs.example/1.srt', 'lang': 'zht'},
          {'url': 'file:///private/1.srt'},
          {'url': 'https://user:pass@host/sub'},
        ],
      };
      expect(
        await client.subtitles('tt123', 'series', season: 2, episode: 3),
        hasLength(1),
      );
      expect(
        adapter.requests.last.uri.path,
        '/subtitles/series/tt123:2:3.json',
      );
      await expectLater(
        client.subtitles('../bad', 'movie'),
        throwsFormatException,
      );
      expect(adapter.requests, hasLength(2));
      adapter.answer = {'unexpected': []};
      await expectLater(
        client.subtitles('tt123', 'movie'),
        throwsFormatException,
      );
    },
  );

  test(
    'only matching episodes survive and matching release tags rank higher',
    () {
      expect(cinemaSubtitleEpisodeMatches('AHS.S10E02.ass', 10, 2), isTrue);
      expect(cinemaSubtitleEpisodeMatches('AHS.S10E01.ass', 10, 2), isFalse);
      expect(cinemaSubtitleEpisodeMatches('AHS.S01E02.ass', 10, 2), isFalse);
      expect(cinemaSubtitleEpisodeMatches('美国恐怖故事 第九季.ass', 10, 2), isFalse);
      expect(
        cinemaSubtitleEpisodeMatches('AHS.S10.complete.ass', 10, 2),
        isTrue,
      );
      const release = 'American.Horror.Story.S10E02.1080p.AMZN.WEB-DL.FLUX.mkv';
      expect(
        cinemaSubtitleReleaseScore('AHS.S10E02.AMZN.WEB-DL.FLUX.srt', release),
        greaterThan(
          cinemaSubtitleReleaseScore('AHS.S10E02.HDTV.TBS.srt', release),
        ),
      );
      expect(cinemaSubtitleReleaseScore('unknown.srt', release), 0);
      expect(
        cinemaSubtitleLanguageLabel({
          'lang': 'zh',
          'bilingual': true,
          'subtitleFileName': '简体中英.ass',
        }),
        '简体中文 / English 双语',
      );
    },
  );

  test('Windows GBK Chinese dialogue decodes without losing timecodes', () {
    final text = CinemaOnlineSubtitles.decodeSubtitle([
      ...utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n'),
      0xd6,
      0xd0,
      0xce,
      0xc4,
      0xd7,
      0xd6,
      0xc4,
      0xbb,
      0x0a,
    ]);
    expect(text, contains('中文字幕'));
  }, skip: !Platform.isWindows);

  test(
    'default aggregate retains Chinese after many English rows, rejects other languages and wrong episodes',
    () async {
      final adapter = _Adapter()
        ..subtitleText = (request) {
          final name = request.uri.path;
          final dialogue = name.contains('chinese')
              ? '中文字幕 $name'
              : 'English dialogue $name';
          return '1\n00:00:01,000 --> 00:00:02,000\n$dialogue\n';
        }
        ..respond = (request) {
          if (request.uri.path.startsWith('/catalog/')) {
            return {
              'metas': [
                {
                  'id': 'tt1844624',
                  'name': 'American Horror Story',
                  'type': 'series',
                },
              ],
            };
          }
          return {
            'subtitles': [
              for (var i = 0; i < 16; i++)
                {
                  'url': 'https://subs.example/english-$i.srt',
                  'lang': 'eng',
                  'subtitleFileName': 'AHS.S10E02.HDTV.TBS.$i.srt',
                },
              {
                'url': 'https://subs.example/chinese.srt',
                'lang': 'zh',
                'subtitleFileName': 'AHS.S10E02.AMZN.WEB-DL.FLUX.简体.ass',
              },
              {
                'url': 'https://subs.example/spanish.srt',
                'lang': 'spa',
                'subtitleFileName': 'AHS.S10E02.spa.srt',
              },
              {
                'url': 'https://subs.example/wrong.srt',
                'lang': 'eng',
                'subtitleFileName': 'AHS.S10E01.srt',
              },
              {
                'url': 'https://subs.example/fake-chs.srt',
                'lang': 'zh',
                'subtitleFileName': 'AHS.S10E02.中文.srt',
              },
            ],
          };
        };
      final client = CinemaOnlineSubtitles(
        useFallbackCatalog: false,
        dio: Dio()..httpClientAdapter = adapter,
      );
      try {
        final result = await client.aggregate(
          '美国恐怖故事',
          'series',
          season: 10,
          episode: 2,
          mediaRelease: 'AHS.S10E02.AMZN.WEB-DL.FLUX.mkv',
        );
        expect(result.rows.first['lang'], 'zh');
        expect(result.rows.first['chineseCueCount'], 1);
        expect(result.rows.where((row) => row['lang'] == 'eng'), hasLength(12));
        expect(
          result.rows.any((row) => '${row['url']}'.contains('spanish')),
          isFalse,
        );
        expect(
          result.rows.any((row) => '${row['url']}'.contains('wrong')),
          isFalse,
        );
        expect(
          result.rows.any((row) => '${row['url']}'.contains('fake-chs')),
          isFalse,
        );
        expect(
          adapter.requests.any(
            (request) => request.uri.path.contains('spanish'),
          ),
          isFalse,
        );
        expect(
          adapter.requests.any((request) => request.uri.path.contains('wrong')),
          isFalse,
        );
      } finally {
        client.close();
      }
    },
  );

  test(
    'known series identity survives an invalid NAS external id without querying an invalid IMDb path',
    () async {
      final adapter = _Adapter()
        ..respond = (request) {
          if (request.uri.path.startsWith('/catalog/')) {
            return {'metas': <dynamic>[]};
          }
          return {'subtitles': <dynamic>[]};
        };
      final client = CinemaOnlineSubtitles(
        useFallbackCatalog: false,
        dio: Dio()..httpClientAdapter = adapter,
      );
      try {
        await client.aggregate(
          '美国恐怖故事 第十季',
          'movie',
          imdbId: '1844624',
          season: 10,
          episode: 2,
        );
        expect(
          adapter.requests.any(
            (request) =>
                request.uri.path == '/subtitles/series/tt1844624:10:2.json',
          ),
          isTrue,
        );
        expect(
          adapter.requests.any(
            (request) => request.uri.path == '/subtitles/movie/1844624.json',
          ),
          isFalse,
        );
      } finally {
        client.close();
      }
    },
  );

  testWidgets(
    'one click aggregates, validates and loads without choosing a work',
    (tester) async {
      final adapter = _Adapter()
        ..respond = (request) {
          if (request.uri.path.startsWith('/catalog/')) {
            return {
              'metas': [
                {
                  'id': 'tt1844624',
                  'name': 'American Horror Story',
                  'type': 'series',
                },
              ],
            };
          }
          return {
            'subtitles': [
              {
                'id': '1',
                'url': 'https://subs.example/zh.srt',
                'lang': 'zh-TW',
                'subtitleFileName': 'AHS.S10E02.繁体.srt',
              },
              {
                'id': 'bad',
                'url': 'https://subs.example/bad.srt',
                'lang': 'zho',
                'subtitleFileName': '失效字幕.srt',
              },
            ],
          };
        };
      final player = _Player();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaOnlineSubtitlesPanel(
              player: player,
              title: '美国恐怖故事 第十季',
              category: '电视剧',
              episodeName: '第2集',
              client: CinemaOnlineSubtitles(
                useFallbackCatalog: false,
                dio: Dio()..httpClientAdapter = adapter,
              ),
            ),
          ),
        ),
      );
      expect(find.text('中文 + English（默认）'), findsOneWidget);
      expect(find.text('日语'), findsNothing);
      expect(find.text('全部语言'), findsNothing);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.ensureVisible(find.text('聚合搜索字幕'));
      await tester.tap(find.text('聚合搜索字幕'));
      await tester.pumpAndSettle();
      expect(find.text('American Horror Story'), findsNothing);
      expect(find.text('失效字幕.srt'), findsNothing);
      expect(find.text('AHS.S10E02.繁体.srt'), findsOneWidget);
      expect(
        adapter.requests.any(
          (r) => r.uri.path == '/subtitles/series/tt1844624:10:2.json',
        ),
        true,
      );
      final count = adapter.requests.length;
      await tester.ensureVisible(find.text('AHS.S10E02.繁体.srt'));
      await tester.tap(find.text('AHS.S10E02.繁体.srt'));
      await tester.pumpAndSettle();
      expect(player.selected?.id, contains('字幕内容'));
      expect(adapter.requests.length, count);
    },
  );
}
