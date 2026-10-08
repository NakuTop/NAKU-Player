import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

const source = CinemaSource(
  id: 'movies',
  name: '测试片源',
  kind: CinemaSourceKind.maccms,
  url: 'https://catalogue.example/api.php?token=public',
);

class FixtureAdapter implements HttpClientAdapter {
  FixtureAdapter(this.respond);
  final ResponseBody Function(RequestOptions options) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'MacCMS parses route separators, entities, query dollars and direct-first order',
    () {
      final page = CinemaRepository.parseMacCmsPage(source, {
        'page': '2',
        'pagecount': 4,
        'total': '61',
        'list': [
          {
            'vod_id': 19,
            'vod_name': 'A &amp; B',
            'vod_pic': '//cdn.example/poster.jpg',
            'vod_content': '<p>第一段 &lt;真实&gt;</p><script>unsafe()</script>',
            'type_id': 7,
            'type_name': '喜剧片',
            'vod_year': 2026,
            'vod_actor': '演员甲,&amp;演员乙',
            'vod_director': '<b>导演甲</b>',
            'vod_area': '中国',
            'vod_lang': '普通话',
            'vod_remarks': 'HD中字',
            'vod_play_from': r'web$$$m3u8',
            'vod_play_url':
                r'正片$https://player.example/watch?id=19$$$第1集$https://cdn.example/1.m3u8?x=$value&amp;y=1#第2集$https://cdn.example/2.mp4#坏地址$javascript:alert(1)',
          },
        ],
      });
      expect(page.page, 2);
      expect(page.hasMore, isTrue);
      expect(page.total, 61);
      final item = page.items.single;
      expect(item.title, 'A & B');
      expect(item.actors, '演员甲,&演员乙');
      expect(item.director, '导演甲');
      expect(item.area, '中国');
      expect(item.language, '普通话');
      final restored = CinemaTitle.fromJson(
        jsonDecode(jsonEncode(item.toJson())),
      );
      expect(restored.actors, item.actors);
      expect(restored.director, item.director);
      expect(restored.area, item.area);
      expect(restored.language, item.language);
      expect(item.description, '第一段 <真实>');
      expect(item.poster, 'https://cdn.example/poster.jpg');
      expect(item.categoryId, '7');
      expect(item.remarks, 'HD中字');
      expect(item.routes.map((route) => route.name), ['m3u8', 'web']);
      expect(item.routes.first.episodes, hasLength(2));
      expect(
        item.routes.first.episodes.first.url,
        r'https://cdn.example/1.m3u8?x=$value&y=1',
      );
      expect(item.routes.first.episodes.first.isDirect, isTrue);
    },
  );

  test(
    'browse gets source categories and encodes category/page query without dropping existing query',
    () async {
      final adapter = FixtureAdapter((options) {
        final query = options.uri.queryParameters;
        if (query['ac'] == 'list') {
          return jsonResponse({
            'code': 1,
            'list': [],
            'class': [
              {'type_id': 70, 'type_name': '电影', 'type_pid': 0},
              {'type_id': 71, 'type_name': '科幻片', 'type_pid': 70},
            ],
          });
        }
        return jsonResponse({
          'code': 1,
          'page': query['pg'],
          'pagecount': 3,
          'list': [
            {'vod_id': 1, 'vod_name': '测试', 'type_id': 71, 'type_name': '科幻片'},
          ],
        });
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final repository = CinemaRepository(dio: dio);
      final result = await repository.browse(source, categoryId: '71', page: 2);
      expect(result.categories.last.parentId, '70');
      expect(result.page, 2);
      final detail = adapter.requests.singleWhere(
        (request) => request.uri.queryParameters['ac'] == 'detail',
      );
      expect(detail.uri.queryParameters, {
        'token': 'public',
        'ac': 'detail',
        'pg': '2',
        't': '71',
      });
      await repository.browse(source, page: 3);
      expect(
        adapter.requests.where(
          (request) => request.uri.queryParameters['ac'] == 'list',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'malformed catalogue entries fail visibly instead of appearing empty',
    () {
      expect(
        () => CinemaRepository.parseMacCmsPage(source, {
          'list': [null],
        }),
        throwsFormatException,
      );
      expect(
        () => CinemaRepository.parseMacCmsPage(source, {
          'list': [
            {'vod_id': 1},
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test('search preserves Unicode keywords and real empty results', () async {
    final adapter = FixtureAdapter(
      (_) => jsonResponse({'code': 1, 'list': [], 'total': 0}),
    );
    final repository = CinemaRepository(
      dio: Dio()..httpClientAdapter = adapter,
    );
    final results = await repository.search(source, '电影 & test');
    expect(results.items, isEmpty);
    expect(adapter.requests.single.uri.queryParameters['wd'], '电影 & test');
  });

  test(
    'HTTP errors, provider errors, malformed JSON are not empty results',
    () async {
      for (final response in [
        jsonResponse({'list': []}, 503),
        jsonResponse({'code': 0, 'msg': '维护中', 'list': []}),
        ResponseBody.fromString('<html>Cloudflare challenge</html>', 200),
        jsonResponse({'code': 1, 'other': []}),
      ]) {
        final adapter = FixtureAdapter((_) => response);
        final repository = CinemaRepository(
          dio: Dio()..httpClientAdapter = adapter,
        );
        await expectLater(
          repository.search(source, 'test'),
          throwsA(isA<CinemaSourceException>()),
        );
      }
    },
  );

  test('detail only accepts the requested source and requested ID', () async {
    final adapter = FixtureAdapter(
      (_) => jsonResponse({
        'code': 1,
        'list': [
          {'vod_id': 88, 'vod_name': '错误影片'},
        ],
      }),
    );
    final repository = CinemaRepository(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const title = CinemaTitle(id: '19', sourceId: 'movies', title: '选择的影片');
    await expectLater(
      repository.detail(source, title),
      throwsA(isA<CinemaSourceException>()),
    );
    await expectLater(
      repository.detail(
        source,
        const CinemaTitle(id: '19', sourceId: 'other', title: '另一个源'),
      ),
      throwsA(isA<CinemaSourceException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('source import rejects scripts and non-web protocols', () {
    expect(
      () => source.copyWith(url: 'file:///tmp/a').validate(),
      throwsFormatException,
    );
    expect(
      () =>
          source.copyWith(url: 'https://user:password@example.com/').validate(),
      throwsFormatException,
    );
    final ruleSource = bundledCinemaSources.firstWhere(
      (entry) => entry.kind == CinemaSourceKind.kazumi,
    );
    final rule = {
      ...ruleSource.rule!,
      'antiCrawlerConfig': {'enabled': true, 'captchaScript': 'run()'},
    };
    expect(
      () => ruleSource.copyWith(rule: rule).validate(),
      throwsFormatException,
    );
    expect(
      () => ruleSource
          .copyWith(rule: {...ruleSource.rule!, 'searchMode': 'api'})
          .validate(),
      throwsFormatException,
    );
    for (final preset in bundledCinemaSources) {
      preset.validate();
    }
    expect(
      CinemaSource.fromJson(source.copyWith(enabled: false).toJson()).enabled,
      isFalse,
    );
  });

  group('independent library persistence', () {
    late Directory directory;
    late File file;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'kazumi-cinema-data-test-',
      );
      file = File('${directory.path}/cinema/library-v1.json');
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'same ID on two sources keeps independent favourite and playback state across restart',
      () async {
        final store = CinemaStore(file: file, defaults: [source]);
        await store.load();
        const first = CinemaTitle(id: '19', sourceId: 'movies', title: '电影');
        const second = CinemaTitle(id: '19', sourceId: 'anime', title: '动漫');
        await store.toggleFavorite(first);
        await store.toggleFavorite(second);
        await Future.wait([
          store.recordProgress(
            title: first,
            routeIndex: 1,
            episodeIndex: 2,
            positionSeconds: 75,
            durationSeconds: 120,
          ),
          store.recordProgress(
            title: second,
            routeIndex: 0,
            episodeIndex: 8,
            positionSeconds: 300,
          ),
        ]);
        await store.flush();
        store.dispose();
        final restored = CinemaStore(file: file);
        await restored.load();
        expect(restored.favorites, hasLength(2));
        expect(restored.history, hasLength(2));
        expect(restored.historyFor(first)?.positionSeconds, 75);
        expect(restored.historyFor(second)?.episodeIndex, 8);
        expect(restored.historyFor(first)?.routeIndex, 1);
        expect(restored.sources.single.id, source.id);
        await restored.toggleFavorite(first);
        expect(restored.isFavorite(first), isFalse);
        expect(restored.isFavorite(second), isTrue);
        restored.dispose();
      },
    );

    test('removing all presets persists an empty source list', () async {
      final store = CinemaStore(file: file, defaults: [source]);
      await store.load();
      await store.removeSource(source.id);
      final restored = CinemaStore(file: file, defaults: [source]);
      await restored.load();
      expect(restored.sources, isEmpty);
      store.dispose();
      restored.dispose();
    });

    test('corrupt JSON remains intact and prevents silent overwrite', () async {
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      final store = CinemaStore(file: file);
      await expectLater(store.load(), throwsFormatException);
      expect(store.lastError, contains('读取失败'));
      await expectLater(store.saveSource(source), throwsFormatException);
      expect(await file.readAsString(), '{broken');
      store.dispose();
    });
  });
}
