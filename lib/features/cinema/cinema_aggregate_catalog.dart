import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cinema_filters.dart';
import 'cinema_grouping.dart';
import 'cinema_models.dart';
import 'cinema_repository.dart';
import 'douban/douban_models.dart';
import 'douban/douban_repository.dart';

enum CinemaAggregateKind { movies, series }

bool cinemaOrdinaryCategory(String value) =>
    !RegExp('伦理|福利|情色|成人|里番|写真|三级|擦边').hasMatch(value);

bool cinemaMatchesAggregateKind(CinemaTitle title, CinemaAggregateKind kind) =>
    cinemaOrdinaryCategory('${title.category} ${title.genres}') &&
    _matchesKindName(title.category, kind);

bool _matchesKindName(String name, CinemaAggregateKind kind) => switch (kind) {
  CinemaAggregateKind.movies => RegExp(
    '电影|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|纪录片|记录片|悬疑片|动画片|犯罪片|奇幻片|冒险片|惊悚片|灾难片|家庭片|家庭篇|历史片|古装片|西部片|短片',
  ).hasMatch(name),
  CinemaAggregateKind.series => RegExp(
    '电视剧|连续剧|大陆剧|内地剧|国产剧|欧美剧|美国剧|英国剧|美剧|日剧|韩剧|日本剧|韩国剧|香港剧|港澳剧|台湾剧|海外剧|泰国剧|泰剧|马泰剧|Netflix自制剧|短剧',
  ).hasMatch(name),
};

class CinemaAggregateSourceState {
  const CinemaAggregateSourceState({
    required this.source,
    this.loading = false,
    this.hasMore = false,
    this.loadedCount = 0,
    this.error,
    this.yearUnsupported = false,
  });
  final CinemaSource source;
  final bool loading, hasMore, yearUnsupported;
  final int loadedCount;
  final String? error;
}

class CinemaAggregateSnapshot {
  const CinemaAggregateSnapshot({
    this.items = const [],
    this.groups = const [],
    this.sources = const [],
    this.loading = false,
    this.initialized = false,
    this.hasMore = false,
    this.usesMetadataDiscovery = false,
    this.error,
    this.message = '',
    this.fetchedAt,
  });
  final List<CinemaTitle> items;
  final List<CinemaTitleGroup> groups;
  final List<CinemaAggregateSourceState> sources;
  final bool loading, initialized, hasMore, usesMetadataDiscovery;
  final String? error;
  final String message;
  final DateTime? fetchedAt;
}

/// A page is a bounded round across enabled catalogues, with one request stream
/// per source and at most three streams in flight. Responses publish as they
/// arrive. Filtered discovery is metadata, never a claim of playable availability.
class CinemaAggregateCatalogController extends ChangeNotifier {
  CinemaAggregateCatalogController({
    required CinemaRepository repository,
    DoubanRepository? discoveryRepository,
    DateTime Function()? now,
  }) : _repository = repository,
       _discovery = discoveryRepository ?? DoubanRepository(),
       _now = now ?? DateTime.now;

  final CinemaRepository _repository;
  final DoubanRepository _discovery;
  final DateTime Function() _now;
  final _sessions = <String, _Session>{};
  // Capability evidence is scoped to the complete configuration, not a host
  // allowlist. Only an observed nonmatching year establishes ignored filtering.
  final _ignoredYear = <String>{};
  _Session? _active;
  var _generation = 0;
  var _disposed = false;
  var _activeWorkers = 0;
  final _workerWaiters = <Completer<void>>[];
  CinemaAggregateSnapshot _snapshot = const CinemaAggregateSnapshot();
  CinemaAggregateSnapshot get snapshot => _snapshot;

  Future<void> load({
    required List<CinemaSource> sources,
    required CinemaAggregateKind kind,
    CinemaFilters filters = const CinemaFilters(),
    CinemaCatalogSort sort = CinemaCatalogSort.latest,
    bool refresh = false,
  }) async {
    if (_disposed) return;
    final enabled = sources
        .where(
          (source) => source.enabled && source.kind == CinemaSourceKind.maccms,
        )
        .toList();
    final key = jsonEncode([
      kind.name,
      filters.year,
      filters.region,
      filters.genre,
      filters.isEmpty ? '' : sort.name,
      enabled.map((source) => source.toJson()).toList(),
    ]);
    if (!refresh && _active?.key == key && _active!.loading) {
      _active!.sort = sort;
      _publish(_active!);
      return;
    }
    _active?.cancel?.cancel('目录筛选已改变');
    if (_active != null) _active!.loading = false;
    final generation = ++_generation;
    var session = _sessions.remove(key);
    final cachedFresh =
        session?.fetchedAt != null &&
        _now().difference(session!.fetchedAt!) < const Duration(minutes: 5);
    if (refresh || !cachedFresh) {
      final oldItems = session == null
          ? const <CinemaTitle>[]
          : session.items.isEmpty
          ? session.staleItems
          : session.items.values.toList();
      if (refresh) {
        for (final source in enabled) {
          _repository.invalidateBrowseCache(source: source);
          _ignoredYear.remove(_sourceKey(source));
        }
      }
      session = _Session(key, kind, filters, sort, enabled);
      // A refresh leaves cards visible while the first new round is fetched.
      if (oldItems.isNotEmpty) session.staleItems = oldItems;
      if (session.metadataOnly) {
        for (final cached in _sessions.values.where((s) => s.kind == kind)) {
          for (final item in cached.items.values.where(
            (item) =>
                item.sourceId != 'douban-discovery' && filters.matches(item),
          )) {
            if (session.items.length >= 800) break;
            if (enabled.any(
              (source) =>
                  source.id == item.sourceId &&
                  cached.sources.any(
                    (cursor) => _sourceKey(cursor.source) == _sourceKey(source),
                  ),
            )) {
              session.items[item.key] = item;
            }
          }
        }
      }
    }
    _sessions[key] = session;
    session.sort = sort;
    while (_sessions.length > 6) {
      _sessions.remove(_sessions.keys.first);
    }
    _active = session;
    _publish(session);
    if (cachedFresh && !refresh) return;
    await _round(session, generation);
  }

  Future<void> loadMore() async {
    final session = _active;
    if (_disposed || session == null || session.loading || !snapshot.hasMore) {
      return;
    }
    await _round(session, _generation);
  }

  Future<void> _round(_Session session, int generation) async {
    session.loading = true;
    session.discoveryError = null;
    session.cancel = CancelToken();
    _publish(session);
    final jobs = session.metadataOnly
        ? <_SourceCursor>[]
        : session.sources.where((source) => source.hasMore).toList();
    var next = 0;
    Future<void> worker() async {
      while (_valid(session, generation) && next < jobs.length) {
        final cursor = jobs[next++];
        await _acquireWorker();
        try {
          if (!_valid(session, generation)) return;
          final firstRound = cursor.categories == null;
          await _fetchSource(session, cursor, generation);
          // The public MacCMS t parameter is an exact category, not a recursive
          // parent query. Sample a second distinct leaf on the first round so
          // the initial screen isn't confined to one provider genre.
          if (firstRound &&
              _valid(session, generation) &&
              cursor.hasMore &&
              cursor.error == null &&
              cursor.pages.any((page) => page.page == 1)) {
            await _fetchSource(session, cursor, generation);
          }
        } finally {
          _releaseWorker();
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 3 && i < jobs.length; i++) worker(),
      if (session.usesMetadata && session.discoveryHasMore)
        _fetchDiscovery(session, generation),
    ]);
    if (!_valid(session, generation)) return;
    session.loading = false;
    session.initialized = true;
    session.fetchedAt = _now();
    if (session.items.isNotEmpty ||
        (session.discoveryError == null &&
            session.sources.every((source) => source.error == null))) {
      session.staleItems = const [];
    }
    _publish(session);
  }

  Future<void> _fetchSource(
    _Session session,
    _SourceCursor cursor,
    int generation,
  ) async {
    cursor.loading = true;
    cursor.error = null;
    _publish(session);
    try {
      final sourceKey = _sourceKey(cursor.source);
      if (session.filters.year.isNotEmpty && _ignoredYear.contains(sourceKey)) {
        cursor.yearUnsupported = true;
        cursor.exhausted = true;
        return;
      }
      if (cursor.categories == null) {
        final categories = await _repository.categories(cursor.source);
        if (!_valid(session, generation)) return;
        cursor.categories = categories;
        cursor.blockedIds.addAll(_blockedCategoryIds(categories));
        cursor.allowedIds.addAll(_categoryIds(categories, session.kind));
        _includeDescendants(cursor.allowedIds, categories);
        cursor.pages.addAll(
          _categoryIds(categories, session.kind).map(_CategoryCursor.new),
        );
      }
      if (cursor.pages.isEmpty) {
        cursor.exhausted = true;
        return;
      }
      final category = cursor.pages.removeAt(0);
      final page = await _repository.browseFiltered(
        cursor.source,
        categoryId: category.id.isEmpty ? null : category.id,
        year: session.filters.year,
        page: category.page,
      );
      if (!_valid(session, generation)) return;
      final year = session.filters.year;
      if (year.isNotEmpty &&
          page.items.any((item) {
            final found = RegExp(r'\d{4}').firstMatch(item.year)?.group(0);
            return found != null && found != year;
          })) {
        cursor.yearUnsupported = true;
        cursor.exhausted = true;
        _ignoredYear.add(sourceKey);
        if (_ignoredYear.length > 48) _ignoredYear.remove(_ignoredYear.first);
      }
      final fingerprint = page.items.map((item) => item.key).join('|');
      final newPage =
          fingerprint.isNotEmpty &&
          cursor.fingerprints.add('${category.id}:$fingerprint');
      for (final title in page.items.where(
        (title) =>
            !cursor.blockedIds.contains(title.categoryId) &&
            (cinemaMatchesAggregateKind(title, session.kind) ||
                (cinemaOrdinaryCategory('${title.category} ${title.genres}') &&
                    cursor.allowedIds.contains(title.categoryId))) &&
            session.filters.matches(title),
      )) {
        if (session.items.length >= 800) break;
        session.items[title.key] = title;
        cursor.keys.add(title.key);
      }
      if (page.hasMore && newPage && !cursor.yearUnsupported) {
        category.page = page.page + 1;
        cursor.pages.add(category);
      }
      cursor.exhausted = cursor.yearUnsupported || cursor.pages.isEmpty;
    } catch (error) {
      if (_valid(session, generation)) {
        cursor.error = error.toString();
        // A failed provider is retried by explicit refresh, not every page.
        cursor.exhausted = true;
      }
    } finally {
      cursor.loading = false;
      if (_valid(session, generation)) _publish(session);
    }
  }

  Future<void> _fetchDiscovery(_Session session, int generation) async {
    try {
      final filters = session.filters;
      final cursor = session.discoveryPages.removeAt(0);
      final page = await _discovery.browse(
        kind: session.kind == CinemaAggregateKind.movies
            ? DoubanKind.movie
            : DoubanKind.tv,
        sort: switch (session.sort) {
          CinemaCatalogSort.latest => 'R',
          CinemaCatalogSort.popular => 'U',
          CinemaCatalogSort.rating => 'S',
        },
        filters: DoubanFilters(
          year: cursor.year,
          region: switch (filters.region) {
            '大陆' => '中国大陆',
            '香港' => '中国香港',
            '台湾' => '中国台湾',
            _ => filters.region,
          },
          genre: filters.genre,
        ),
        start: cursor.start,
        cancelToken: session.cancel,
      );
      if (!_valid(session, generation)) return;
      for (final title in page.items) {
        if (session.items.length >= 800) break;
        final metadata = CinemaTitle(
          id: title.id,
          sourceId: 'douban-discovery',
          title: title.title,
          category: title.genres.any((genre) => genre.contains('纪录'))
              ? '纪录片'
              : title.genres.any((genre) => genre.contains('动画'))
              ? '动画片'
              : session.kind == CinemaAggregateKind.movies
              ? '电影'
              : '电视剧',
          year: title.year,
          poster: title.poster,
          aliases: title.originalTitle,
          actors: title.actors.join(' / '),
          genres: title.genres.join(' / '),
          area: title.regions.join(' / '),
          doubanId: title.id,
          sourceDoubanScore: title.score,
        );
        // The public endpoint can degrade to an unfiltered feed. Check actual
        // returned metadata; never silently show the wrong year or region.
        if (cinemaOrdinaryCategory(metadata.genres) &&
            filters.matches(metadata)) {
          session.items[metadata.key] = metadata;
        }
      }
      if (page.hasMore) {
        cursor.start = page.nextStart;
        session.discoveryPages.add(cursor);
      }
      session.discoveryHasMore = session.discoveryPages.isNotEmpty;
    } catch (error) {
      if (_valid(session, generation) &&
          !(error is DioException && CancelToken.isCancel(error))) {
        session.discoveryError = error.toString();
        session.discoveryHasMore = false;
      }
    } finally {
      if (_valid(session, generation)) _publish(session);
    }
  }

  void _publish(_Session session) {
    if (_disposed || _active != session) return;
    final raw = session.items.isEmpty
        ? session.staleItems
        : session.items.values.toList();
    // Real-source variants come first, so an unplayable metadata card never
    // supplants an already available source when the default source is absent.
    final ordered = [
      ...raw.where((item) => item.sourceId != 'douban-discovery'),
      ...raw.where((item) => item.sourceId == 'douban-discovery'),
    ];
    final groups = groupCinemaTitles(ordered);
    final representatives = sortCinemaTitles(
      groups.map((g) => g.representative).toList(),
      session.sort,
    );
    final byKey = {for (final group in groups) group.representative.key: group};
    final statuses = session.sources
        .map(
          (cursor) => CinemaAggregateSourceState(
            source: cursor.source,
            loading: cursor.loading,
            hasMore: !session.metadataOnly && cursor.hasMore,
            loadedCount: cursor.keys.length,
            error: cursor.error,
            yearUnsupported: cursor.yearUnsupported,
          ),
        )
        .toList();
    final errors = statuses.where((source) => source.error != null).length;
    final limited = session.items.length >= 800;
    _snapshot = CinemaAggregateSnapshot(
      items: List.unmodifiable(ordered),
      groups: List.unmodifiable(
        representatives.map((title) => byKey[title.key]!),
      ),
      sources: List.unmodifiable(statuses),
      loading: session.loading,
      initialized: session.initialized,
      hasMore:
          !limited &&
          ((!session.metadataOnly &&
                  session.sources.any((source) => source.hasMore)) ||
              (session.usesMetadata && session.discoveryHasMore)),
      usesMetadataDiscovery: session.usesMetadata,
      error:
          session.discoveryError ??
          (session.sources.isEmpty
              ? '还没有启用的影视接口，请在设置中添加或启用片源。'
              : errors == session.sources.length
              ? '当前片源暂时无法连接，请刷新重试。'
              : null),
      message: limited
          ? '已加载 800 条目录记录，请使用筛选缩小范围。'
          : session.usesMetadata
          ? '按作品资料筛选，点开查找全部片源'
          : errors > 0
          ? '$errors 个片源暂时不可用，已保留其他片源内容'
          : '已合并全部已启用片源，继续加载可查看更多内容',
      fetchedAt: session.fetchedAt,
    );
    notifyListeners();
  }

  bool _valid(_Session session, int generation) =>
      !_disposed && _active == session && _generation == generation;

  Future<void> _acquireWorker() async {
    if (_activeWorkers < 3) {
      _activeWorkers++;
      return;
    }
    final waiter = Completer<void>();
    _workerWaiters.add(waiter);
    await waiter.future;
  }

  void _releaseWorker() {
    if (_workerWaiters.isNotEmpty) {
      _workerWaiters.removeAt(0).complete();
    } else {
      _activeWorkers--;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _active?.cancel?.cancel('目录已关闭');
    super.dispose();
  }
}

String _sourceKey(CinemaSource source) => jsonEncode(source.toJson());

List<String> _categoryIds(
  List<CinemaCategory> categories,
  CinemaAggregateKind kind,
) {
  final blocked = _blockedCategoryIds(categories);
  final roots = categories
      .where(
        (category) =>
            !blocked.contains(category.id) &&
            (kind == CinemaAggregateKind.movies
                ? ['电影', '电影片'].contains(category.name)
                : ['电视剧', '连续剧'].contains(category.name)),
      )
      .toList();
  final eligible = categories
      .where(
        (category) =>
            !blocked.contains(category.id) &&
            _matchesKindName(category.name, kind),
      )
      .map((category) => category.id)
      .toSet();
  eligible.addAll(roots.map((category) => category.id));
  _includeDescendants(eligible, categories);
  eligible.removeAll(blocked);
  final allowed = categories
      .where((category) => eligible.contains(category.id))
      .toList();
  final parents = allowed.map((category) => category.parentId).toSet();
  final selected = [
    ...allowed.where((category) => !parents.contains(category.id)),
    // A few records may be assigned directly to a parent; keep it in later
    // rounds instead of silently dropping those records or pretending it
    // includes all of its children.
    ...allowed.where((category) => parents.contains(category.id)),
  ];
  if (selected.isNotEmpty) {
    return selected.map((category) => category.id).toList();
  }
  // Some providers omit class metadata; a general page remains useful after
  // checking each item's actual category. A known incompatible catalogue does not.
  return categories.isEmpty ? [''] : [];
}

Set<String> _blockedCategoryIds(List<CinemaCategory> categories) {
  final blocked = categories
      .where((category) => !cinemaOrdinaryCategory(category.name))
      .map((category) => category.id)
      .toSet();
  _includeDescendants(blocked, categories);
  return blocked;
}

void _includeDescendants(Set<String> ids, List<CinemaCategory> categories) {
  var changed = true;
  while (changed) {
    changed = false;
    for (final category in categories) {
      if (ids.contains(category.parentId) && ids.add(category.id)) {
        changed = true;
      }
    }
  }
}

class _Session {
  _Session(
    this.key,
    this.kind,
    this.filters,
    this.sort,
    List<CinemaSource> sources,
  ) : sources = sources.map(_SourceCursor.new).toList(),
      discoveryPages =
          (filters.year == '更早'
                  ? ['90年代', '80年代', '70年代', '60年代', '更早']
                  : [filters.year])
              .map(_DiscoveryCursor.new)
              .toList();
  final String key;
  final CinemaAggregateKind kind;
  final CinemaFilters filters;
  CinemaCatalogSort sort;
  final List<_SourceCursor> sources;
  final items = <String, CinemaTitle>{};
  List<CinemaTitle> staleItems = const [];
  bool loading = false, initialized = false, discoveryHasMore = true;
  final List<_DiscoveryCursor> discoveryPages;
  String? discoveryError;
  DateTime? fetchedAt;
  CancelToken? cancel;
  bool get usesMetadata => !filters.isEmpty;
  bool get metadataOnly =>
      filters.region.isNotEmpty ||
      filters.genre.isNotEmpty ||
      filters.year == '更早';
}

class _SourceCursor {
  _SourceCursor(this.source);
  final CinemaSource source;
  List<CinemaCategory>? categories;
  final pages = <_CategoryCursor>[];
  final keys = <String>{}, fingerprints = <String>{};
  final blockedIds = <String>{};
  final allowedIds = <String>{};
  bool loading = false, exhausted = false, yearUnsupported = false;
  String? error;
  bool get hasMore => !exhausted;
}

class _CategoryCursor {
  _CategoryCursor(this.id);
  final String id;
  int page = 1;
}

class _DiscoveryCursor {
  _DiscoveryCursor(this.year);
  final String year;
  int start = 0;
}
