import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';

CinemaSource source(String id, {bool enabled = true}) => CinemaSource(
  id: id,
  name: id,
  kind: CinemaSourceKind.maccms,
  url: 'https://$id.example/api.php/provide/vod',
  enabled: enabled,
);
CinemaTitle movie(
  String sourceId,
  String id, {
  String year = '2020',
  String name = '共同电影',
  String category = '剧情片',
  String categoryId = '2',
  String area = '中国大陆',
}) => CinemaTitle(
  sourceId: sourceId,
  id: id,
  title: name,
  year: year,
  category: category,
  categoryId: categoryId,
  doubanId: '12345',
  area: area,
  genres: '剧情',
);

class _Repo extends CinemaRepository {
  List<CinemaCategory> categoryData = const [
    CinemaCategory(id: '1', name: '电影'),
    CinemaCategory(id: '3', name: '电视剧'),
  ];
  final calls = <(String, String?, String, int)>[];
  Future<CinemaPage> Function(CinemaSource, String?, String, int)? respond;
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async =>
      categoryData;
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) async {
    calls.add((source.id, categoryId, year, page));
    return respond?.call(source, categoryId, year, page) ??
        CinemaPage(items: [movie(source.id, '1')]);
  }
}

class _Discovery extends DoubanRepository {
  final calls = <(DoubanKind, DoubanFilters, int, String?)>[];
  Future<DoubanResultPage> Function(DoubanKind, DoubanFilters, int)? respond;
  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async {
    calls.add((kind, filters, start, sort));
    return respond?.call(kind, filters, start) ??
        const DoubanResultPage(
          items: [],
          start: 0,
          nextStart: 20,
          hasMore: false,
        );
  }
}

DoubanResultPage metadataPage({
  String year = '2020',
  String region = '中国大陆',
  int start = 0,
  bool hasMore = false,
}) => DoubanResultPage(
  items: [
    DoubanTitle(
      id: '12345',
      title: '共同电影',
      kind: DoubanKind.movie,
      year: year,
      regions: [region],
      genres: const ['剧情'],
      originalTitle: 'Shared Movie',
      score: 8.5,
    ),
  ],
  start: start,
  nextStart: start + 20,
  hasMore: hasMore,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all enabled sources stream progressively with at most three in flight',
    () async {
      final repo = _Repo();
      final gates = <String, Completer<void>>{};
      var active = 0, maximum = 0;
      repo.respond = (s, category, year, page) async {
        active++;
        if (active > maximum) maximum = active;
        await (gates[s.id] = Completer<void>()).future;
        active--;
        return CinemaPage(items: [movie(s.id, '1')]);
      };
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      final pending = controller.load(
        sources: [
          for (var i = 0; i < 5; i++) source('s$i'),
          source('disabled', enabled: false),
        ],
        kind: CinemaAggregateKind.movies,
      );
      await Future<void>.delayed(Duration.zero);
      expect(gates.keys, ['s0', 's1', 's2']);
      gates['s1']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.loading, isTrue);
      expect(controller.snapshot.items.single.sourceId, 's1');
      expect(gates, contains('s3'));
      gates['s0']!.complete();
      gates['s2']!.complete();
      gates['s3']!.complete();
      await Future<void>.delayed(Duration.zero);
      gates['s4']!.complete();
      await pending;
      expect(maximum, 3);
      expect(controller.snapshot.groups, hasLength(1));
      expect(controller.snapshot.groups.single.variants, hasLength(5));
      expect(controller.snapshot.sources, hasLength(5));
      expect(controller.snapshot.loading, isFalse);
    },
  );

  test(
    'source cursors paginate independently and local sort keeps the cursor',
    () async {
      final repo = _Repo()
        ..respond = (s, category, year, page) async => CinemaPage(
          items: [movie(s.id, '$page', name: '${s.id} page $page')],
          page: page,
          pageCount: s.id == 'short' ? 1 : 3,
        );
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      final sources = [source('short'), source('long')];
      await controller.load(sources: sources, kind: CinemaAggregateKind.movies);
      await controller.loadMore();
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        sort: CinemaCatalogSort.popular,
      );
      expect(repo.calls, hasLength(3));
      await controller.loadMore();
      expect(repo.calls.last, ('long', '1', '', 3));
      expect(controller.snapshot.items, hasLength(4));
      expect(controller.snapshot.hasMore, isFalse);
    },
  );

  test(
    'year predicates are requested and ignored provider years never leak',
    () async {
      final repo = _Repo()
        ..respond = (s, category, year, page) async => CinemaPage(
          items: [
            movie(s.id, '$page', year: s.id == 'ignores' ? '2026' : year),
          ],
          page: page,
          pageCount: 9,
        );
      final discovery = _Discovery()
        ..respond = (_, filters, start) async =>
            metadataPage(year: filters.year);
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: discovery,
      );
      addTearDown(controller.dispose);
      final sources = [source('supports'), source('ignores')];
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        filters: const CinemaFilters(year: '2020'),
      );
      expect(
        controller.snapshot.items.every((item) => item.year == '2020'),
        isTrue,
      );
      expect(controller.snapshot.sources.last.yearUnsupported, isTrue);
      expect(
        controller.snapshot.groups.single.representative.sourceId,
        'supports',
      );
      expect(
        controller.snapshot.groups.single.variants.any(
          (t) => t.aliases == 'Shared Movie',
        ),
        isTrue,
      );
      await controller.loadMore();
      expect(repo.calls.where((call) => call.$1 == 'ignores'), hasLength(1));
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        filters: const CinemaFilters(year: '2019'),
      );
      expect(repo.calls.where((call) => call.$1 == 'ignores'), hasLength(1));
      expect(repo.calls.last.$3, '2019');
      expect(
        controller.snapshot.items.every((item) => item.year == '2019'),
        isTrue,
      );
    },
  );

  test(
    'region discovery sends structured filters and reuses matching real variants',
    () async {
      final repo = _Repo();
      final discovery = _Discovery()
        ..respond = (_, filters, start) async =>
            metadataPage(start: start, hasMore: start == 0);
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: discovery,
      );
      addTearDown(controller.dispose);
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
      );
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
        filters: const CinemaFilters(region: '大陆', genre: '剧情'),
      );
      expect(repo.calls, hasLength(1));
      expect(discovery.calls.single.$2.region, '中国大陆');
      expect(controller.snapshot.groups, hasLength(1));
      expect(controller.snapshot.groups.single.variants, hasLength(2));
      expect(controller.snapshot.groups.single.representative.sourceId, 's');
      expect(controller.snapshot.message, contains('点开查找全部片源'));
      await controller.loadMore();
      expect(discovery.calls.last.$3, 20);
      expect(controller.snapshot.hasMore, isFalse);
    },
  );

  test(
    'movie and series sessions retain loaded pages and reject late results',
    () async {
      final repo = _Repo();
      final late = Completer<CinemaPage>();
      repo.respond = (s, category, year, page) async => category == '1'
          ? late.future
          : CinemaPage(
              items: [movie(s.id, 'tv', category: '电视剧', categoryId: '3')],
            );
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      final first = controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
      );
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.series,
      );
      late.complete(CinemaPage(items: [movie('s', 'late')]));
      await first;
      expect(controller.snapshot.items.single.id, 'tv');
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.series,
      );
      expect(repo.calls, hasLength(2));
    },
  );

  test(
    'partial failures do not discard good sources and refresh is explicit retry',
    () async {
      final repo = _Repo()
        ..respond = (s, category, year, page) async {
          if (s.id == 'fails') throw const CinemaSourceException('HTTP 403');
          return CinemaPage(items: [movie(s.id, '1')]);
        };
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      final sources = [source('good'), source('fails')];
      await controller.load(sources: sources, kind: CinemaAggregateKind.movies);
      expect(controller.snapshot.items.single.sourceId, 'good');
      expect(controller.snapshot.error, isNull);
      expect(controller.snapshot.sources.last.error, 'HTTP 403');
      expect(controller.snapshot.message, contains('1 个片源'));
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        refresh: true,
      );
      expect(repo.calls.where((call) => call.$1 == 'fails'), hasLength(2));
    },
  );

  test(
    'blocked branches cannot reappear through neutral child labels; independent categories remain',
    () async {
      final repo = _Repo()
        ..categoryData = const [
          CinemaCategory(id: '1', name: '电影'),
          CinemaCategory(id: '2', name: '剧情片', parentId: '1'),
          CinemaCategory(id: '6', name: 'Netflix电影'),
          CinemaCategory(id: '8', name: '伦理片'),
          CinemaCategory(id: '9', name: '剧情片', parentId: '8'),
          CinemaCategory(id: '10', name: '擦边短剧'),
        ];
      repo.respond = (s, category, year, page) async => CinemaPage(
        items: [
          movie(s.id, category!, categoryId: category),
          movie(s.id, 'bad', categoryId: '9'),
          movie(s.id, 'bad2', category: '擦边短剧', categoryId: '10'),
        ],
      );
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
      );
      await controller.loadMore();
      expect(repo.calls.map((call) => call.$2), ['2', '6', '1']);
      expect(controller.snapshot.items.map((item) => item.id), ['2', '6', '1']);
      expect(cinemaOrdinaryCategory('擦边短剧'), isFalse);
    },
  );

  test(
    'earlier years use supported decade tags and filter wrong metadata',
    () async {
      final discovery = _Discovery()
        ..respond = (_, filters, start) async =>
            metadataPage(year: filters.year == '90年代' ? '1994' : '2026');
      final controller = CinemaAggregateCatalogController(
        repository: _Repo(),
        discoveryRepository: discovery,
      );
      addTearDown(controller.dispose);
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
        filters: const CinemaFilters(year: '更早'),
      );
      await controller.loadMore();
      expect(discovery.calls.map((call) => call.$2.year), ['90年代', '80年代']);
      expect(controller.snapshot.items.single.year, '1994');
      expect(controller.snapshot.hasMore, isTrue);
    },
  );
  test(
    'failed refresh retains old usable cards and a successful empty refresh clears them',
    () async {
      final repo = _Repo();
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: _Discovery(),
      );
      addTearDown(controller.dispose);
      final sources = [source('s')];
      await controller.load(sources: sources, kind: CinemaAggregateKind.movies);
      repo.respond = (_, c, y, p) async =>
          throw const CinemaSourceException('offline');
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        refresh: true,
      );
      expect(controller.snapshot.items.single.title, '共同电影');
      expect(controller.snapshot.error, isNotNull);
      repo.respond = (_, c, y, p) async => const CinemaPage(items: []);
      await controller.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        refresh: true,
      );
      expect(controller.snapshot.items, isEmpty);
    },
  );

  test(
    'documentary metadata keeps its category when joining real source variants',
    () async {
      final repo = _Repo()
        ..respond = (s, c, y, p) async =>
            CinemaPage(items: [movie(s.id, '1', category: '纪录片')]);
      final discovery = _Discovery()
        ..respond = (_, f, start) async => const DoubanResultPage(
          items: [
            DoubanTitle(
              id: '12345',
              title: '共同电影',
              kind: DoubanKind.movie,
              year: '2020',
              regions: ['中国大陆'],
              genres: ['纪录片'],
            ),
          ],
          start: 0,
          nextStart: 20,
          hasMore: false,
        );
      final controller = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: discovery,
      );
      addTearDown(controller.dispose);
      await controller.load(
        sources: [source('s')],
        kind: CinemaAggregateKind.movies,
        filters: const CinemaFilters(year: '2020'),
      );
      expect(controller.snapshot.groups, hasLength(1));
      expect(controller.snapshot.groups.single.variants, hasLength(2));
      expect(controller.snapshot.groups.single.representative.sourceId, 's');
    },
  );
}
