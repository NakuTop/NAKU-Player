import 'dart:convert';
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

  test('bounded discoveries retain selected topics and allow newer topics', () {
    final catalog = DoubanThemeCatalog();
    catalog.remember(DoubanKind.movie, [for (var i = 0; i < 240; i++) '主题$i']);
    final topics = catalog.remember(
      DoubanKind.movie,
      ['新主题', '带,逗号', '', '新主题'],
      selected: ['主题0'],
    );
    expect(topics, hasLength(DoubanThemeCatalog.capacity));
    expect(topics, containsAll(['主题0', '新主题']));
    expect(topics, isNot(contains('主题1')));
    expect(topics, isNot(contains('带,逗号')));
    expect(
      () => catalog.topics(DoubanKind.movie).add('external'),
      throwsUnsupportedError,
    );
  });

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
