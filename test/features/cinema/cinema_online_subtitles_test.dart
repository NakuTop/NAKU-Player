import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:media_kit/media_kit.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  dynamic answer = <String, dynamic>{};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'subs.example') {
      return ResponseBody.fromString(
        '1\n00:00:01,000 --> 00:00:02,000\n字幕内容\n',
        200,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(answer),
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
    'search encodes keywords and series requests preserve season and episode',
    () async {
      final adapter = _Adapter()
        ..answer = {
          'metas': [
            {'id': 'tt123', 'name': '电影'},
          ],
        };
      final client = CinemaOnlineSubtitles(
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
  testWidgets(
    'search, explicit work match, Chinese result and click load subtitle',
    (tester) async {
      final adapter = _Adapter()
        ..answer = {
          'metas': [
            {'id': 'tt123', 'name': '影片', 'releaseInfo': '2020'},
          ],
        };
      final player = _Player();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaOnlineSubtitlesPanel(
              player: player,
              title: '影片',
              client: CinemaOnlineSubtitles(
                dio: Dio()..httpClientAdapter = adapter,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('搜索作品'));
      await tester.pumpAndSettle();
      adapter.answer = {
        'subtitles': [
          {
            'id': '1',
            'url': 'https://subs.example/zh.srt',
            'lang': 'zht',
            'subtitleFileName': '繁体中文.srt',
          },
          {
            'id': '2',
            'url': 'https://subs.example/en.srt',
            'lang': 'eng',
            'subtitleFileName': 'English.srt',
          },
        ],
      };
      await tester.tap(find.text('影片').last);
      await tester.pumpAndSettle();
      expect(find.text('繁体中文.srt'), findsOneWidget);
      expect(find.text('English.srt'), findsNothing);
      await tester.ensureVisible(find.text('繁体中文.srt'));
      await tester.tap(find.text('繁体中文.srt'));
      await tester.pumpAndSettle();
      expect(player.selected?.data, true);
      expect(player.selected?.id, contains('字幕内容'));
    },
  );
}
