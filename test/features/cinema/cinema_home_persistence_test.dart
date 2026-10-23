import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_home_cache.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_resource_availability.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/services/network/cinema_poster_file_system.dart';

const _source = CinemaSource(
  id: 'one',
  name: 'fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://source.example/api?token=do-not-store-config',
);
const _card = CinemaTitle(
  id: '10001',
  sourceId: 'douban-discovery',
  title: 'Fixture',
  year: '2020',
  category: '电影',
  poster: 'https://poster.example/one.jpg',
  doubanId: '10001',
  imdbId: 'tt1234567',
  rottenTomatoesId: 'm/fixture',
);
const _video = CinemaTitle(
  id: 'playable',
  sourceId: 'one',
  title: 'Fixture 4K',
  year: '2020',
  category: '电影',
  routes: [
    CinemaRoute(
      name: 'line',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://video.example/movie.m3u8'),
      ],
    ),
  ],
);

class _Source extends CinemaRepository {
  int calls = 0;
  final browsed = <int>[];
  bool offline = false;
  Completer<void>? gate;
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '1', name: '电影'),
  ];
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) async {
    browsed.add(page);
    if (offline) throw const HttpException('offline fixture');
    return CinemaPage(
      items: [
        CinemaTitle(
          id: 'page$page',
          sourceId: source.id,
          title: 'Page $page',
          category: '电影',
          year: year.isEmpty ? '2020' : year,
        ),
      ],
      page: page,
      pageCount: 5,
    );
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    calls++;
    await gate?.future;
    if (offline) throw const HttpException('offline fixture');
    return CinemaPage(items: keyword.contains('Missing') ? [] : [_video]);
  }
}

DoubanTitle _metadata(String id, {String? name, String? poster}) => DoubanTitle(
  id: id,
  title: name ?? (id == '10001' ? 'Fixture' : 'Movie $id'),
  kind: DoubanKind.movie,
  year: '2020',
  score: 8.2,
  poster: poster ?? 'https://poster.example/$id.jpg',
);

class _Feed extends DoubanRepository {
  final calls = <int>[];
  bool updated = false, offline = false;
  Completer<void>? gate;
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
    calls.add(start);
    await gate?.future;
    if (offline) throw const HttpException('offline fixture');
    return DoubanResultPage(
      items: start == 0
          ? (updated
                ? [_metadata('10003'), _metadata('10001')]
                : [_metadata('10001'), _metadata('10002')])
          : [_metadata('${10000 + start}')],
      start: start,
      nextStart: start + 20,
      hasMore: true,
    );
  }
}

Future<void> _load(CinemaAggregateCatalogController controller) =>
    controller.load(
      sources: [_source],
      kind: CinemaAggregateKind.movies,
      sort: CinemaCatalogSort.popular,
    );

Future<List<int>> _ratingsFetch(Uri uri, int _) async {
  if (uri.host == 'm.douban.com') {
    return utf8.encode(
      jsonEncode({
        'id': '10001',
        'title': 'Fixture',
        'type': 'movie',
        'rating': {'max': 10, 'value': 8.2, 'count': 200},
      }),
    );
  }
  if (uri.host == 'datasets.imdbws.com') {
    return gzip.encode(
      utf8.encode('tconst\taverageRating\tnumVotes\ntt1234567\t7.6\t240\n'),
    );
  }
  if (uri.host == 'www.rottentomatoes.com') {
    return utf8.encode(
      '<script type="application/ld+json">${jsonEncode({
        '@type': 'Movie',
        'url': uri.toString(),
        'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 88},
      })}</script>',
    );
  }
  throw StateError('Unexpected request ${uri.host}');
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6foUAAAAASUVORK5CYII=',
);
CacheManager _posters(Directory directory, void Function() request) {
  final repo = JsonCacheInfoRepository.withFile(
    File('${directory.path}/posters.json'),
  );
  return CacheManager(
    Config(
      'restart-posters',
      repo: repo,
      fileSystem: CinemaPosterFileSystem(root: '${directory.path}/images'),
      fileService: HttpFileService(
        httpClient: MockClient((_) async {
          request();
          return http.Response.bytes(
            _png,
            200,
            headers: {
              'content-type': 'image/png',
              'cache-control': 'max-age=86400',
            },
          );
        }),
      ),
    ),
  );
}

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('naku-home-cache-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'source catalogue restores category cursors without reloading prior pages',
    () async {
      final first = CinemaAggregateCatalogController(
        repository: _Source(),
        cache: CinemaHomeCache(directory: directory),
      );
      await first.load(sources: [_source], kind: CinemaAggregateKind.movies);
      await first.loadMore();
      expect(first.snapshot.items.map((t) => t.id), ['page1', 'page2']);
      first.dispose();
      final repo = _Source();
      final second = CinemaAggregateCatalogController(
        repository: repo,
        cache: CinemaHomeCache(directory: directory),
      );
      addTearDown(second.dispose);
      await second.load(sources: [_source], kind: CinemaAggregateKind.movies);
      expect(repo.browsed, isEmpty);
      await second.loadMore();
      expect(repo.browsed, [3]);
    },
  );

  test(
    'cache count is bounded and storage failures leave live values available',
    () async {
      final cache = CinemaHomeCache(directory: directory);
      await Future.wait([
        for (var i = 0; i <= CinemaHomeCache.maxEntries; i++)
          cache.put('resource', '$i', {'value': i}),
      ]);
      expect(
        (await directory.list().where((f) => f.path.endsWith('.json')).toList())
            .length,
        CinemaHomeCache.maxEntries,
      );
      final restored = CinemaHomeCache(directory: directory);
      await restored.load();
      expect(
        restored.get('resource', '${CinemaHomeCache.maxEntries}')?['value'],
        CinemaHomeCache.maxEntries,
      );
      final blocker = File('${directory.path}/not-a-directory');
      await blocker.writeAsString('keep me');
      final unavailable = CinemaHomeCache(
        directory: Directory('${blocker.path}/cache'),
      );
      await unavailable.put('catalog', 'live', {'title': 'still visible'});
      expect(unavailable.get('catalog', 'live')?['title'], 'still visible');
      expect(unavailable.lastError, isNotNull);
      expect(await blocker.readAsString(), 'keep me');
    },
  );

  test(
    'complete recreation restores cards, covers, scores and pagination without requests',
    () async {
      final cache = CinemaHomeCache(directory: directory);
      final feed = _Feed();
      final first = CinemaAggregateCatalogController(
        repository: _Source(),
        discoveryRepository: feed,
        cache: cache,
      );
      await _load(first);
      await first.loadMore();
      expect(feed.calls, [0, 20]);
      first.dispose();

      final restoredCache = CinemaHomeCache(directory: directory);
      final restoredFeed = _Feed()..offline = true;
      final second = CinemaAggregateCatalogController(
        repository: _Source(),
        discoveryRepository: restoredFeed,
        cache: restoredCache,
      );
      addTearDown(second.dispose);
      await _load(second);
      expect(restoredFeed.calls, isEmpty);
      expect(second.snapshot.items.map((t) => t.id), [
        '10001',
        '10002',
        '10020',
      ]);
      expect(
        second.snapshot.items.first.poster,
        'https://poster.example/10001.jpg',
      );
      expect(second.snapshot.items.first.sourceDoubanScore, 8.2);
      expect(second.snapshot.initialized, isTrue);
      restoredFeed.offline = false;
      await second.loadMore();
      expect(restoredFeed.calls, [40]);
      final bytes = (await directory
          .list()
          .where((f) => f.path.endsWith('.json'))
          .cast<File>()
          .toList());
      for (final file in bytes) {
        expect(
          await file.readAsString(),
          isNot(contains('do-not-store-config')),
        );
      }
    },
  );

  test(
    'expired feed refreshes one head page, keeps later pages and does not blank old cards',
    () async {
      var now = DateTime(2026, 10, 24);
      final cache = CinemaHomeCache(directory: directory);
      final first = CinemaAggregateCatalogController(
        repository: _Source(),
        discoveryRepository: _Feed(),
        cache: cache,
        now: () => now,
      );
      await _load(first);
      await first.loadMore();
      first.dispose();
      now = now.add(const Duration(minutes: 31));
      final feed = _Feed()
        ..updated = true
        ..gate = Completer<void>();
      final next = CinemaAggregateCatalogController(
        repository: _Source(),
        discoveryRepository: feed,
        cache: CinemaHomeCache(directory: directory),
        now: () => now,
      );
      addTearDown(next.dispose);
      final seen = <List<CinemaTitle>>[];
      next.addListener(() => seen.add(next.snapshot.items));
      final pending = _load(next);
      while (feed.calls.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final savedCard = next.snapshot.items.first;
      expect(next.snapshot.items, hasLength(3));
      feed.gate!.complete();
      await pending;
      expect(feed.calls, [0]);
      expect(seen.every((items) => items.length >= 2), isTrue);
      expect(next.snapshot.items.map((t) => t.id), ['10003', '10001', '10020']);
      expect(identical(next.snapshot.items[1], savedCard), isTrue);
      await next.loadMore();
      expect(feed.calls, [0, 40]);
    },
  );

  test(
    'offline expired refresh leaves the persisted homepage usable on the next launch',
    () async {
      var now = DateTime(2026, 10, 24);
      final first = CinemaAggregateCatalogController(
        repository: _Source(),
        discoveryRepository: _Feed(),
        cache: CinemaHomeCache(directory: directory),
        now: () => now,
      );
      await _load(first);
      first.dispose();
      now = now.add(const Duration(days: 1));
      for (var i = 0; i < 2; i++) {
        final next = CinemaAggregateCatalogController(
          repository: _Source(),
          discoveryRepository: _Feed()..offline = true,
          cache: CinemaHomeCache(directory: directory),
          now: () => now,
        );
        await _load(next);
        expect(next.snapshot.items, hasLength(2));
        expect(next.snapshot.error, isNotNull);
        next.dispose();
      }
    },
  );

  test(
    'resource badges persist positive and missing results and isolate source configuration',
    () async {
      final cache = CinemaHomeCache(directory: directory);
      await cache.load();
      final repo = _Source();
      final first = CinemaResourceAvailabilityService(repo, cache: cache);
      const missing = CinemaTitle(
        id: 'missing',
        sourceId: 'douban-discovery',
        title: 'Missing',
        year: '2020',
        category: '电影',
      );
      expect(
        (await first.check(_card, [_source])).state,
        CinemaResourceState.found,
      );
      expect(
        (await first.check(missing, [_source])).state,
        CinemaResourceState.missing,
      );
      first.dispose();

      final restored = CinemaHomeCache(directory: directory);
      await restored.load();
      final offline = _Source()..offline = true;
      final next = CinemaResourceAvailabilityService(offline, cache: restored);
      addTearDown(next.dispose);
      expect(next.entry(_card, [_source]).value.has4K, isTrue);
      expect(
        (await next.check(_card, [
          _source,
        ])).variants.single.routes.single.episodes.single.url,
        'https://video.example/movie.m3u8',
      );
      expect(
        (await next.check(missing, [_source])).state,
        CinemaResourceState.missing,
      );
      expect(offline.calls, 0);
      const changed = CinemaSource(
        id: 'one',
        name: 'fixture',
        kind: CinemaSourceKind.maccms,
        url: 'https://changed.example/api',
      );
      expect(
        next.entry(_card, [changed]).value.state,
        CinemaResourceState.waiting,
      );
      await next.check(_card, [changed]);
      expect(offline.calls, greaterThan(0));
    },
  );

  test(
    'failed resource revalidation preserves a badge and throttles retries across restarts',
    () async {
      var now = DateTime(2026, 10, 24);
      final cache = CinemaHomeCache(directory: directory);
      await cache.load();
      final first = CinemaResourceAvailabilityService(
        _Source(),
        cache: cache,
        now: () => now,
      );
      await first.check(_card, [_source]);
      first.dispose();
      now = now.add(const Duration(hours: 7));
      final restored = CinemaHomeCache(directory: directory);
      await restored.load();
      final repo = _Source()
        ..offline = true
        ..gate = Completer<void>();
      final next = CinemaResourceAvailabilityService(
        repo,
        cache: restored,
        now: () => now,
      );
      final pending = next.check(_card, [_source]);
      expect(
        next.entry(_card, [_source]).value.state,
        CinemaResourceState.found,
      );
      repo.gate!.complete();
      expect((await pending).state, CinemaResourceState.found);
      final count = repo.calls;
      await next.check(_card, [_source]);
      expect(repo.calls, count);
      next.dispose();
      final thirdCache = CinemaHomeCache(directory: directory);
      await thirdCache.load();
      final thirdRepo = _Source()..offline = true;
      final third = CinemaResourceAvailabilityService(
        thirdRepo,
        cache: thirdCache,
        now: () => now,
      );
      addTearDown(third.dispose);
      expect(
        (await third.check(_card, [_source])).state,
        CinemaResourceState.found,
      );
      expect(thirdRepo.calls, 0);
    },
  );

  test(
    'corrupt cache and interrupted temp files do not erase other entries or user files',
    () async {
      final cache = CinemaHomeCache(directory: directory);
      await Future.wait([
        cache.put('resource', 'first', {'value': 1}),
        cache.put('resource', 'second', {'value': 2}),
      ]);
      final files = await directory
          .list()
          .where((f) => f.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final broken = files.first;
      await broken.writeAsString('{broken');
      await File('${broken.path}.tmp').writeAsString('{unfinished');
      final userFile = File('${directory.path}/downloads.json');
      await userFile.writeAsString('keep original');
      final next = CinemaHomeCache(directory: directory);
      await next.load();
      final retained = [
        next.get('resource', 'first'),
        next.get('resource', 'second'),
      ].whereType<Map>().toList();
      expect(retained, hasLength(1));
      await next.put('catalog', 'new', {'items': []});
      expect(await userFile.readAsString(), 'keep original');
    },
  );

  test(
    'completed card scores and hydrated IDs restore before any source or rating lookup',
    () async {
      final ratingsDir = Directory('${directory.path}/ratings');
      final first = CinemaRatingsRepository(
        directory: ratingsDir,
        fetch: _ratingsFetch,
      );
      // The original source card has no IDs; its resolved identity must survive too.
      const original = CinemaTitle(
        id: '10001',
        sourceId: 'douban-discovery',
        title: 'Fixture',
        category: '电影',
        year: '2020',
      );
      await first.loadForCard(original, resolveTitle: (_) async => _card);
      var requests = 0, resolutions = 0;
      final next = CinemaRatingsRepository(
        directory: ratingsDir,
        fetch: (_, _) async {
          requests++;
          throw const HttpException('offline');
        },
      );
      await next.restore();
      expect(next.peek(original)!.ratings.map((r) => r.value), [8.2, 7.6, 88]);
      expect(next.peek(original)!.identity.imdbId, 'tt1234567');
      expect(
        (await next.loadForCard(
          original,
          resolveTitle: (t) async {
            resolutions++;
            return t;
          },
        )).ratings.map((r) => r.value),
        [8.2, 7.6, 88],
      );
      expect(requests, 0);
      expect(resolutions, 0);
      // A user correction must invalidate the old card and remain authoritative.
      await next.setIdentity(
        original,
        const RatingIdentity(rottenTomatoesId: 'm/other', confirmed: true),
      );
      final third = CinemaRatingsRepository(
        directory: ratingsDir,
        fetch: (_, _) async => throw const HttpException('offline'),
      );
      await third.restore();
      expect(third.peek(original), isNull);
    },
  );

  test(
    'poster bytes survive cache manager recreation outside the temporary directory',
    () async {
      var requests = 0;
      final first = _posters(directory, () => requests++);
      final file = await first.getSingleFile(_card.poster);
      expect(file.path, startsWith('${directory.path}/images/'));
      expect(await file.readAsBytes(), _png);
      await first.dispose();
      final next = _posters(directory, () => requests++);
      final restored = await next.getSingleFile(_card.poster);
      expect(await restored.readAsBytes(), _png);
      expect(requests, 1);
      await next.dispose();
    },
  );

  final restartRoot = Platform.environment['NAKU_HOME_CACHE_RESTART_DIR'];
  final phase = Platform.environment['NAKU_HOME_CACHE_RESTART_PHASE'];
  test(
    'separate process restores the complete homepage with all requests disabled',
    () async {
      final root = Directory(restartRoot!);
      await root.create(recursive: true);
      final cache = CinemaHomeCache(directory: Directory('${root.path}/home'));
      await cache.load();
      final source = _Source()..offline = phase != 'write';
      final feed = _Feed()..offline = phase != 'write';
      final controller = CinemaAggregateCatalogController(
        repository: source,
        discoveryRepository: feed,
        cache: cache,
      );
      final resources = CinemaResourceAvailabilityService(source, cache: cache);
      var ratingsRequests = 0, posterRequests = 0;
      final ratings = CinemaRatingsRepository(
        directory: Directory('${root.path}/ratings'),
        fetch: (uri, limit) async {
          ratingsRequests++;
          if (phase != 'write') {
            throw const HttpException('requests disabled in second process');
          }
          return _ratingsFetch(uri, limit);
        },
      );
      final posters = _posters(root, () {
        posterRequests++;
        if (phase != 'write') {
          throw const HttpException('poster requests disabled');
        }
      });
      await ratings.restore();
      await _load(controller);
      expect(controller.snapshot.items.first.poster, isNotEmpty);
      expect((await resources.check(_card, [_source])).has4K, isTrue);
      final scores = await ratings.loadForCard(_card);
      expect(scores.ratings.map((r) => r.value), [8.2, 7.6, 88]);
      expect(
        await (await posters.getSingleFile(_card.poster)).readAsBytes(),
        _png,
      );
      if (phase != 'write') {
        expect(source.calls, 0);
        expect(feed.calls, isEmpty);
        expect(ratingsRequests, 0);
        expect(posterRequests, 0);
      }
      await posters.dispose();
      resources.dispose();
      controller.dispose();
      await File('${root.path}/$phase.json').writeAsString(
        jsonEncode({
          'phase': phase,
          'catalogueRequests': feed.calls.length,
          'resourceRequests': source.calls,
          'ratingRequests': ratingsRequests,
          'posterRequests': posterRequests,
          'scores': scores.ratings.map((r) => r.value).toList(),
        }),
      );
    },
    skip: restartRoot == null || phase == null,
  );
}
