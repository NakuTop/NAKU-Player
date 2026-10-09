import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_themes.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'items': [],
        'recommend_tags': ['旅行', '女性'],
      }),
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
  test('official recommendation links enrich themes without mixing taxonomy', () {
    final json = {
      'recommend_tags': ['漫画改编', '科幻', '美国'],
      'bottom_recommend_tags': ['独立电影', '漫画改编'],
      'recommend_categories': [
        {
          'type': '类型',
          'data': [
            {'text': '科幻'},
          ],
        },
        {
          'type': '地区',
          'data': [
            {'text': '美国'},
          ],
        },
      ],
      'items': [
        {
          'card': 'subject',
          'type': 'movie',
          'tags': [
            {
              'name': 'unparsed display label',
              'uri':
                  'douban://douban.com/movie/recommend_tag?type=tags&tag=美国,公路,女性,2024',
            },
            {'uri': 'douban://douban.com/subject_collection/123?tag=不可用'},
            {
              'uri':
                  'https://foreign.example/movie/recommend_tag?type=tags&tag=伪造',
            },
          ],
        },
        {
          'card': 'subject',
          'type': 'tv',
          'tags': [
            {'uri': 'douban://douban.com/tv/recommend_tag?type=tags&tag=剧集专属'},
          ],
        },
      ],
    };
    expect(parseDoubanThemes(json, DoubanKind.movie), [
      '漫画改编',
      '独立电影',
      '公路',
      '女性',
    ]);
  });

  test(
    'new discoveries survive the old forty-topic boundary and reopening',
    () {
      final catalog = DoubanThemeCatalog();
      catalog.remember(DoubanKind.movie, [for (var i = 0; i < 40; i++) '主题$i']);
      catalog.remember(DoubanKind.movie, ['新电影主题'], selected: ['主题0']);
      expect(catalog.topics(DoubanKind.movie), hasLength(41));
      expect(catalog.topics(DoubanKind.movie).last, '新电影主题');
      expect(catalog.topics(DoubanKind.tv), isEmpty);
      catalog.remember(DoubanKind.tv, ['剧集主题']);
      expect(catalog.topics(DoubanKind.movie).last, '新电影主题');
    },
  );

  test('discoveries retain older and selected topics beyond 240 entries', () {
    final catalog = DoubanThemeCatalog();
    catalog.remember(DoubanKind.movie, [for (var i = 0; i < 240; i++) '主题$i']);
    final topics = catalog.remember(
      DoubanKind.movie,
      ['新主题', '带,逗号', '', '新主题'],
      selected: ['主题0'],
    );
    expect(topics, hasLength(241));
    expect(topics, containsAll(['主题0', '新主题']));
    expect(topics, contains('主题1'));
    expect(topics, isNot(contains('带,逗号')));
    expect(
      () => catalog.topics(DoubanKind.movie).add('external'),
      throwsUnsupportedError,
    );
  });

  Future<File> temporaryFile() async {
    final directory = await Directory.systemTemp.createTemp(
      'naku-douban-themes-',
    );
    addTearDown(() => directory.delete(recursive: true));
    return File('${directory.path}/themes.json');
  }

  test(
    'new process restores every discovered theme and next exploration seed',
    () async {
      final file = await temporaryFile();
      final first = DoubanThemeCatalog(storageFile: file);
      await first.initialize();
      first.remember(DoubanKind.movie, [
        for (var i = 0; i < 320; i++) '电影主题$i',
      ]);
      first.remember(DoubanKind.tv, ['剧集主题']);
      expect(first.nextSeed(DoubanKind.movie), '电影主题0');
      await first.flush();

      final second = DoubanThemeCatalog(storageFile: file);
      await second.initialize();
      expect(second.topics(DoubanKind.movie), hasLength(320));
      expect(second.topics(DoubanKind.tv), ['剧集主题']);
      expect(second.nextSeed(DoubanKind.movie), '电影主题1');
      second.remember(DoubanKind.movie, ['新发现']);
      await second.flush();

      final third = DoubanThemeCatalog(storageFile: file);
      await third.initialize();
      expect(third.topics(DoubanKind.movie), [
        ...first.topics(DoubanKind.movie),
        '新发现',
      ]);
      expect(third.nextSeed(DoubanKind.movie), '电影主题2');
      await third.flush();
    },
  );

  test(
    'discovery finishing before disk restore merges rather than losing either list',
    () async {
      final file = await temporaryFile();
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'topics': {
            'movie': ['旧主题'],
            'tv': ['旧剧集主题'],
          },
        }),
      );
      final catalog = DoubanThemeCatalog(storageFile: file);
      catalog.remember(DoubanKind.movie, ['本次发现']);
      catalog.remember(DoubanKind.tv, ['本次剧集']);
      await catalog.flush();
      expect(catalog.topics(DoubanKind.movie), ['旧主题', '本次发现']);
      final restored = DoubanThemeCatalog(storageFile: file);
      await restored.initialize();
      expect(
        restored.topics(DoubanKind.movie),
        catalog.topics(DoubanKind.movie),
      );
      expect(restored.topics(DoubanKind.tv), ['旧剧集主题', '本次剧集']);
    },
  );

  test(
    'unreadable saved topics are retained and a retry can merge discoveries',
    () async {
      final file = await temporaryFile();
      await file.writeAsString('{broken old catalogue');
      final catalog = DoubanThemeCatalog(storageFile: file);
      await catalog.initialize();
      catalog.remember(DoubanKind.movie, ['离线主题']);
      await catalog.flush();
      expect(catalog.storageError, contains('读取'));
      expect(await file.readAsString(), '{broken old catalogue');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'topics': {
            'movie': ['原有主题'],
          },
        }),
      );
      await catalog.retryPersistence();
      expect(catalog.storageError, isNull);
      final restored = DoubanThemeCatalog(storageFile: file);
      await restored.initialize();
      expect(restored.topics(DoubanKind.movie), ['原有主题', '离线主题']);
    },
  );

  test(
    'a failed write reports the problem and can save the retained discoveries later',
    () async {
      final file = await temporaryFile();
      final blockedParent = File('${file.parent.path}/blocked');
      await blockedParent.writeAsString('not a directory');
      final destination = File('${blockedParent.path}/themes.json');
      final catalog = DoubanThemeCatalog(storageFile: destination);
      await catalog.initialize();
      catalog.remember(DoubanKind.movie, ['待保存']);
      await catalog.flush();
      expect(catalog.storageError, contains('保存'));
      expect(catalog.topics(DoubanKind.movie), ['待保存']);
      await blockedParent.delete();
      await catalog.retryPersistence();
      expect(catalog.storageError, isNull);
      final restored = DoubanThemeCatalog(storageFile: destination);
      await restored.initialize();
      expect(restored.topics(DoubanKind.movie), ['待保存']);
    },
  );

  test(
    'theme discovery uses one bounded query and no active board filters',
    () async {
      final adapter = _Adapter();
      final repo = DoubanRepository(dio: Dio()..httpClientAdapter = adapter);
      final tags = await repo.discoverThemes(kind: DoubanKind.tv, seed: '旅行');
      expect(tags, ['旅行', '女性']);
      expect(adapter.requests, hasLength(1));
      final params = adapter.requests.single.uri.queryParameters;
      expect(params['tags'], '旅行');
      expect(params['count'], '20');
      expect(params['start'], '0');
      expect(params['selected_categories'], '{}');
      expect(params['sort'], isNull);
    },
  );
}
