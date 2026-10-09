import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'cinema_appearance_settings.dart';
import 'cinema_pane_transition.dart';
import 'cinema_catalog_view.dart';
import 'cinema_settings_page.dart';
import 'cinema_filters.dart';
import 'cinema_aggregate_catalog.dart';
import 'cinema_discovery_resolver.dart';
import 'cinema_search_discovery.dart';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_models.dart';
import 'cinema_follow_resolver.dart';
import 'cinema_sync_session.dart';
import 'cinema_sync_sheet.dart';
import 'cinema_watch_together.dart';
import 'cinema_work_sources.dart';
import 'douban/douban_page.dart';
import 'douban/douban_models.dart';
import 'douban/douban_repository.dart';
import 'douban/douban_image_headers.dart';
import 'naku_update_page.dart';
import 'naku_update_service.dart';
import 'cinema_grouping.dart';
import 'cinema_card_ratings.dart';
import 'cinema_repository.dart';
import 'cinema_ratings_panel.dart';
import 'cinema_ratings.dart';
import 'cinema_rating_title_resolver.dart';
import 'cinema_rating_identity_search.dart';
import 'cinema_store.dart';
import 'cinema_library_actions.dart';
import 'cinema_player_page.dart';
import 'cinema_theme.dart';
import 'cinema_websites_page.dart';

enum _Section { movies, series, anime, favorites, history, settings }

/// Each sidebar destination owns its catalogue, search and scroll state.
/// Requests may finish offscreen, but can only update the state they started in.
class _CatalogState {
  final search = TextEditingController();
  List<CinemaTitle> items = [];
  final viewCache = CinemaCatalogViewCache();
  List<CinemaCategory> categories = [];
  final sourceStatus = <String, String>{};
  final searchPages = <String, int>{};
  final searchMore = <String>{};
  String activeKeyword = '';
  CinemaFilters filters = const CinemaFilters();
  CinemaSearchDiscovery discovery = const CinemaSearchDiscovery();
  CancelToken? discoveryCancel;
  String discoveryMessage = '';
  bool discoveryLoading = false;
  String? itemsContext;
  CinemaSource? source;
  String? categoryId, error;
  bool loading = false, searching = false, initialized = false;
  int page = 1, pageCount = 1, generation = 0;
  DateTime? fetchedAt;
}

class CinemaHomePage extends StatefulWidget {
  const CinemaHomePage({
    super.key,
    this.store,
    this.repository,
    this.ratingsRepository,
    this.watchTogether,
    this.enableWatchTogether = true,
    this.enableSearchDiscovery = true,
    this.searchDiscovery,
    this.catalogDiscovery,
  });
  final CinemaStore? store;
  final CinemaRepository? repository;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaWatchTogether? watchTogether;
  final bool enableWatchTogether;
  final bool enableSearchDiscovery;
  final CinemaSearchDiscoveryRepository? searchDiscovery;
  final DoubanRepository? catalogDiscovery;

  @override
  State<CinemaHomePage> createState() => _CinemaHomePageState();
}

class _CinemaHomePageState extends State<CinemaHomePage> {
  late final CinemaStore _store = widget.store ?? CinemaStore();
  late final CinemaRepository _repository =
      widget.repository ?? CinemaRepository();
  late final _discoveryRepository =
      widget.searchDiscovery ?? CinemaSearchDiscoveryRepository();
  late final _ratings =
      widget.ratingsRepository ?? CinemaRatingsRepository.instance;
  late final _ratingIdentity = CinemaRatingIdentitySearch(
    search: (keyword) => _discoveryRepository.search(keyword),
  );
  late final _ratingTitles = CinemaRatingTitleResolver(
    repository: _repository,
    sourceFor: _findSource,
    discoverTitle: widget.enableSearchDiscovery
        ? _ratingIdentity.resolve
        : null,
  );
  final _scoreProviders = <_Section, String>{};
  final _ratingPreloads = <_Section>{};
  final _ratingLoadedContexts = <(_Section, String), String>{};
  Timer? _ratingRefresh;
  int _ratingRevision = 0;
  late final _together = widget.watchTogether ?? CinemaWatchTogether.instance;
  StreamSubscription<String>? _togetherNotices;
  _Section _section = _Section.movies;
  bool _showSourceManager = false;
  final _catalogs = {
    for (final section in _Section.values) section: _CatalogState(),
  };
  final _knownCategories = <String, List<CinemaCategory>>{};
  final _aggregateControllers = <_Section, CinemaAggregateCatalogController>{};
  String _sourceConfiguration = '';
  final Map<_Section, CinemaCatalogSort> _catalogSort = {
    _Section.movies: CinemaCatalogSort.latest,
    _Section.series: CinemaCatalogSort.latest,
  };
  _CatalogState get _catalog => _catalogs[_section]!;
  TextEditingController get _search => _catalog.search;
  List<CinemaTitle> get _items => _catalog.items;
  List<CinemaCategory> get _categories => _catalog.categories;
  set _categories(List<CinemaCategory> value) => _catalog.categories = value;
  Map<String, String> get _sourceStatus => _catalog.sourceStatus;
  Set<String> get _searchMore => _catalog.searchMore;
  CinemaSource? get _source => _catalog.source;
  set _source(CinemaSource? value) => _catalog.source = value;
  String? get _categoryId => _catalog.categoryId;
  set _categoryId(String? value) => _catalog.categoryId = value;
  String? get _error => _catalog.error;
  bool get _loading => _catalog.loading;
  bool get _searching => _catalog.searching;
  int get _page => _catalog.page;
  int get _pageCount => _catalog.pageCount;

  String _sourceKey(CinemaSource source) => jsonEncode(source.toJson());

  bool _aggregates(_Section section) =>
      section == _Section.movies || section == _Section.series;

  CinemaAggregateCatalogController _aggregateFor(_Section section) =>
      _aggregateControllers.putIfAbsent(section, () {
        final controller = CinemaAggregateCatalogController(
          repository: _repository,
          discoveryRepository: widget.catalogDiscovery,
        );
        controller.addListener(() {
          final state = _catalogs[section]!;
          if (!mounted || state.searching) return;
          final snapshot = controller.snapshot;
          _changed(state, () {
            state.items = snapshot.items;
            state.loading = snapshot.loading;
            state.initialized = snapshot.initialized;
            state.error = snapshot.error;
            state.fetchedAt = snapshot.fetchedAt;
          });
          if (!snapshot.loading) unawaited(_preloadRatings(section));
        });
        return controller;
      });

  void _changed(_CatalogState state, VoidCallback change) {
    if (!mounted) return;
    if (identical(state, _catalog)) {
      setState(change);
    } else {
      change();
    }
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _ratings.changes.addListener(_onRatingsChanged);
    if (widget.enableWatchTogether) {
      _together.onFollowRequested = _followPeer;
      _togetherNotices = _together.notices.listen((message) {
        if (mounted) _toast(message);
      });
      unawaited(_initializeTogether());
    }
    unawaited(_initialize());
  }

  String get _scoreProvider => _scoreProviders[_section] ?? '豆瓣';

  void _onRatingsChanged() {
    _ratingRevision++;
    if (!mounted ||
        !_showsCatalogSort ||
        _currentCatalogSort != CinemaCatalogSort.rating) {
      return;
    }
    _ratingRefresh ??= Timer(const Duration(milliseconds: 350), () {
      _ratingRefresh = null;
      if (mounted &&
          _showsCatalogSort &&
          _currentCatalogSort == CinemaCatalogSort.rating) {
        setState(() {});
      }
    });
  }

  Future<void> _preloadRatings(_Section section) async {
    final state = _catalogs[section]!;
    if (!mounted ||
        state.loading ||
        _catalogSort[section] != CinemaCatalogSort.rating ||
        _ratingPreloads.contains(section)) {
      return;
    }
    final provider = _scoreProviders[section] ?? '豆瓣';
    final works = [
      ...groupCinemaTitles(
        state.items.where(state.filters.matches).toList(),
      ).map((group) => group.catalogTitle),
      if (state.searching)
        ..._visibleDiscoveryTitles(
          state,
          section,
        ).map((title) => title.metadata),
    ];
    int priority(CinemaTitle title) {
      final directId = switch (provider) {
        'IMDb' => title.imdbId,
        '烂番茄' => title.rottenTomatoesId,
        _ => title.doubanId,
      };
      if (directId.isNotEmpty) return 0;
      return title.doubanId.isNotEmpty ? 1 : 2;
    }

    // Start exact IDs first; a slow name lookup must not occupy both sort
    // workers while straightforward provider requests remain undispatched.
    final titles = [
      for (var tier = 0; tier <= 2; tier++)
        ...works.where((title) => priority(title) == tier),
    ];
    final generation = state.generation;
    final fingerprint = jsonEncode([
      generation,
      provider,
      for (final title in titles)
        [
          title.key,
          title.title,
          title.year,
          title.doubanId,
          title.imdbId,
          title.rottenTomatoesId,
          title.sourceDoubanScore,
        ],
    ]);
    if (_ratingLoadedContexts[(section, provider)] == fingerprint) return;
    _ratingPreloads.add(section);
    if (_section == section) setState(() {});
    bool current() =>
        mounted &&
        state.generation == generation &&
        _catalogSort[section] == CinemaCatalogSort.rating &&
        (_scoreProviders[section] ?? '豆瓣') == provider;
    var next = 0;
    Future<void> worker() async {
      while (current() && next < titles.length) {
        final title = titles[next++];
        try {
          await _ratings.loadForProvider(
            title,
            provider,
            isCurrent: current,
            resolveTitle: _ratingTitles.resolve,
          );
        } catch (_) {
          // A failed provider remains unscored; other works can still resolve.
        }
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      if (current() && next >= titles.length) {
        _ratingLoadedContexts[(section, provider)] = fingerprint;
      }
    } finally {
      _ratingPreloads.remove(section);
      if (mounted) {
        if (_section == section) setState(() {});
        // A catalogue refresh or load-more may have arrived during this batch.
        unawaited(_preloadRatings(section));
      }
    }
  }

  Future<void> _initializeTogether() async {
    try {
      await _together.initialize();
    } catch (_) {
      if (mounted) _toast('一起看设置暂时无法读取，请稍后重试。');
    }
  }

  Future<bool> _followPeer(CinemaPeerActivity peer) async {
    final media = peer.media;
    if (media == null) return false;
    final room = _together.roomName;
    final endpoint = _together.endpoint;
    bool current() =>
        mounted &&
        _together.isPaired &&
        _together.isCurrentFollow(peer) &&
        _together.roomName == room &&
        _together.endpoint == endpoint &&
        _together.peers.any(
          (p) =>
              p.username == peer.username &&
              p.media?.identity == media.identity,
        );
    await _store.load();
    final candidate = await resolveCinemaPeerPlayback(
      media: media,
      sources: _store.enabledSources,
      repository: _repository,
      isCurrent: current,
    );
    if (!current()) return false;
    if (candidate == null) {
      _toast('当前启用的片源未找到对方正在看的同一作品和集数，可启用其他片源后重试。');
      return false;
    }
    _playTitle(
      candidate.title,
      candidate.source,
      candidate.routeIndex,
      candidate.episodeIndex,
      [candidate.title],
    );
    return true;
  }

  void _playTitle(
    CinemaTitle detail,
    CinemaSource source,
    int road,
    int episode,
    List<CinemaTitle> variants,
  ) {
    unawaited(
      Navigator.of(context)
          .push(
            MaterialPageRoute<void>(
              builder: (context) => Theme(
                data: CinemaTheme.of(context),
                child: CinemaPlayerPage(
                  title: detail,
                  source: source,
                  watchTogether: widget.enableWatchTogether ? _together : null,
                  store: _store,
                  variants: variants,
                  repository: _repository,
                  ratingsRepository: _ratings,
                  onRecommendationSelected: (recommendation) async {
                    if (!mounted) return;
                    await _selectSection(
                      _matchesCategory(detail.category, _Section.series)
                          ? _Section.series
                          : _Section.movies,
                    );
                    if (!mounted) return;
                    _search.text = recommendation.title;
                    unawaited(_runSearch());
                  },
                  routeIndex: road,
                  episodeIndex: episode,
                ),
              ),
            ),
          )
          .then((_) {
            if (mounted) setState(() {});
          }),
    );
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final configuration = jsonEncode(
      _store.sources.map((s) => s.toJson()).toList(),
    );
    final sourcesChanged = configuration != _sourceConfiguration;
    if (sourcesChanged) {
      _sourceConfiguration = configuration;
      for (final controller in _aggregateControllers.values) {
        controller.dispose();
      }
      _aggregateControllers.clear();
      _knownCategories.clear();
      _repository.invalidateBrowseCache();
      for (final state in _catalogs.values) {
        state.generation++;
        state.initialized = false;
        state.loading = false;
        state.items = [];
        state.categories = [];
        state.categoryId = null;
      }
    }
    // Progress saves every few seconds should not rebuild an offscreen poster grid.
    if (sourcesChanged || !_isCatalog) setState(() {});
    if (sourcesChanged && _isCatalog && !_searching) unawaited(_browse());
  }

  Future<void> _initialize() async {
    try {
      await _store.load();
      _sourceConfiguration = jsonEncode(
        _store.sources.map((s) => s.toJson()).toList(),
      );
      if (!mounted) return;
      await _browse();
    } catch (e) {
      if (mounted) {
        setState(() {
          _catalog.error = '$e';
          _catalog.loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _ratings.changes.removeListener(_onRatingsChanged);
    _ratingRefresh?.cancel();
    _ratingTitles.dispose();
    for (final controller in _aggregateControllers.values) {
      controller.dispose();
    }
    for (final state in _catalogs.values) {
      state.generation++;
      state.discoveryCancel?.cancel();
      state.search.dispose();
    }
    unawaited(_togetherNotices?.cancel());
    if (widget.enableWatchTogether &&
        _together.onFollowRequested == _followPeer) {
      _together.onFollowRequested = null;
    }
    _store.removeListener(_onStoreChanged);
    unawaited(_store.flush());
    if (widget.store == null) _store.dispose();
    super.dispose();
  }

  String get _heading => switch (_section) {
    _Section.movies => '电影',
    _Section.series => '剧集',
    _Section.anime => '动漫',
    _Section.favorites => '我的收藏',
    _Section.history => '继续观看',
    _Section.settings => _showSourceManager ? '片源管理' : '设置',
  };

  bool get _isCatalog => _section.index <= _Section.anime.index;

  bool get _showsCatalogSort =>
      _section == _Section.movies || _section == _Section.series;

  CinemaCatalogSort get _currentCatalogSort =>
      _catalogSort[_section] ?? CinemaCatalogSort.latest;

  String get _catalogSortExplanation {
    if (_currentCatalogSort == CinemaCatalogSort.rating) {
      final works = [
        ..._catalogView.representatives,
        if (_searching)
          ..._visibleDiscoveryTitles(
            _catalog,
            _section,
          ).map((title) => title.metadata),
      ];
      final available = works
          .where((title) => _ratings.scoreFor(title, _scoreProvider) != null)
          .length;
      final loading = _ratingPreloads.contains(_section) ? ' · 后台补充评分中' : '';
      final scope = _searching && _catalog.discovery.titles.isNotEmpty
          ? '；片源结果与相关作品分别排序'
          : '';
      return '已加载 $available/${works.length} 部有$_scoreProvider评分，缺失项排后$loading$scope';
    }
    if (_items.isEmpty) return _loading ? '正在汇总片源。' : '暂无片源作品可排序。';
    final popular = _currentCatalogSort == CinemaCatalogSort.popular;
    final available = _items
        .where(
          (item) =>
              popular ? item.sourceHits != null : item.sourceUpdatedAt != null,
        )
        .length;
    final metric = popular ? '热度' : '更新时间';
    if (available == 0) return '片源未提供可用$metric，保留目录顺序。';
    final scope = available < _items.length
        ? '已加载 $available/${_items.length} 项有$metric，缺失项排后。'
        : '';
    return popular
        ? '$scope按片源提供的数值排序，不代表真实播放量或外部榜单。'
        : '$scope按片源更新时间排序，不是影片上映时间。';
  }

  bool _matchesCategory(String name, [_Section? section]) {
    return switch (section ?? _section) {
      _Section.movies => RegExp(
        '电影|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|纪录片|记录片|悬疑片|动画片|犯罪片|奇幻片|冒险片|惊悚片',
      ).hasMatch(name),
      _Section.series => RegExp(
        '电视剧|连续剧|大陆剧|国产剧|欧美剧|美国剧|英国剧|美剧|日剧|韩剧|日本剧|韩国剧|香港剧|港澳剧|台湾剧|海外剧|泰国剧|泰剧|Netflix自制剧|短剧',
      ).hasMatch(name),
      _Section.anime => RegExp('动漫|动画').hasMatch(name),
      _ => true,
    };
  }

  bool _ordinaryCategory(String name) => cinemaOrdinaryCategory(name);

  List<CinemaCategory> get _visibleCategories =>
      _categoryChoices(_categories, _section);

  List<CinemaCategory> _categoryChoices(
    List<CinemaCategory> categories,
    _Section section,
  ) {
    final roots = categories
        .where((c) => _matchesCategory(c.name, section))
        .map((c) => c.id)
        .toSet();
    final matches = categories
        .where(
          (c) =>
              _ordinaryCategory(c.name) &&
              (roots.contains(c.id) || roots.contains(c.parentId)),
        )
        .toList();
    final leaves = matches
        .where(
          (c) => !['电影', '电影片', '电视剧', '连续剧', '动漫', '动漫片'].contains(c.name),
        )
        .toList();
    return leaves.isEmpty ? matches : leaves;
  }

  CinemaSource? _findSource(String id) {
    for (final source in _store.sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<void> _selectSection(_Section value) async {
    if (value == _section && !_showSourceManager) return;
    setState(() {
      _section = value;
      _showSourceManager = false;
    });
    final state = _catalog;
    if (!_isCatalog || state.loading) return;
    if (!state.initialized) {
      await _browse();
    } else if (!state.searching &&
        state.fetchedAt != null &&
        DateTime.now().difference(state.fetchedAt!) >
            const Duration(minutes: 5)) {
      // Refresh stale catalogues in place; the visible cards remain available.
      await _browse(page: state.page);
    }
  }

  String? _preferredCategory(_CatalogState state, _Section section) {
    final names = switch (section) {
      _Section.movies => ['剧情片', '科幻片', '动作片'],
      _Section.series => ['欧美剧', '美国剧', '国产剧', '大陆剧', '日剧'],
      _ => ['日韩动漫', '日本动漫', '国产动漫'],
    };
    for (final name in names) {
      final match = state.categories.where((c) => c.name == name).firstOrNull;
      if (match != null) return match.id;
    }
    return _categoryChoices(state.categories, section).firstOrNull?.id;
  }

  Future<void> _browse({
    int page = 1,
    bool refresh = false,
    bool append = false,
  }) async {
    final state = _catalog;
    final section = _section;
    final generation = ++state.generation;
    state.discoveryCancel?.cancel();
    if (_aggregates(section)) {
      state.searching = false;
      state.source = null;
      state.categories = [];
      state.categoryId = null;
      await _aggregateFor(section).load(
        sources: _store.enabledSources,
        kind: section == _Section.movies
            ? CinemaAggregateKind.movies
            : CinemaAggregateKind.series,
        filters: state.filters,
        sort: _catalogSort[section] ?? CinemaCatalogSort.latest,
        refresh: refresh,
      );
      return;
    }
    final choices = _store.enabledSources
        .where((s) => s.kind == CinemaSourceKind.maccms)
        .toList();
    if (choices.isEmpty) {
      _changed(state, () {
        state.loading = false;
        state.items = [];
        state.source = null;
        state.error = '还没有启用的影视接口。请到片源管理添加或启用一个接口。';
      });
      return;
    }
    final source =
        choices.where((s) => s.id == state.source?.id).firstOrNull ??
        choices.where((s) => s.id == 'maccms-modu').firstOrNull ??
        choices.first;
    if (refresh) _repository.invalidateBrowseCache(source: source);
    final sourceKey = _sourceKey(source);
    _changed(state, () {
      state.source = source;
      state.loading = true;
      state.error = null;
      state.searching = false;
      state.categories = _knownCategories[sourceKey] ?? state.categories;
      state.categoryId ??= _preferredCategory(state, section);
      if (state.itemsContext != '$sourceKey|${state.categoryId}') {
        state.items = [];
        state.page = page;
        state.pageCount = 1;
      }
    });
    try {
      var result = await _repository.browse(
        source,
        categoryId: state.categoryId,
        page: page,
      );
      if (!mounted || generation != state.generation) return;
      if (result.categories.isNotEmpty) {
        state.categories = result.categories;
        _knownCategories[sourceKey] = result.categories;
      }
      if (state.categoryId == null) {
        state.categoryId = _preferredCategory(state, section);
        if (state.categoryId != null) {
          result = await _repository.browse(
            source,
            categoryId: state.categoryId,
            page: page,
          );
          if (!mounted || generation != state.generation) return;
        }
      }
      _changed(state, () {
        final existing = append ? state.items : <CinemaTitle>[];
        final keys = existing.map((t) => t.key).toSet();
        state.items = [
          ...existing,
          ...result.items.where(
            (t) => _ordinaryCategory(t.category) && keys.add(t.key),
          ),
        ];
        state.itemsContext = '$sourceKey|${state.categoryId}';
        state.page = result.page;
        state.pageCount = result.pageCount;
        state.loading = false;
        state.initialized = true;
        state.fetchedAt = DateTime.now();
      });
    } catch (e) {
      if (mounted && generation == state.generation) {
        _changed(state, () {
          state.error = '$e';
          state.loading = false;
        });
      }
    }
  }

  Future<void> _runSearch({bool loadMore = false}) async {
    final state = _catalog;
    final section = _section;
    final keyword = loadMore ? state.activeKeyword : state.search.text.trim();
    if (keyword.isEmpty) {
      await _browse();
      return;
    }
    final resetFilters =
        !loadMore && (!state.searching || state.activeKeyword != keyword);
    final generation = loadMore ? state.generation : ++state.generation;
    final sources = _store.enabledSources
        .where(
          (s) =>
              (section == _Section.anime ||
                  s.kind == CinemaSourceKind.maccms) &&
              (!loadMore || state.searchMore.contains(s.id)),
        )
        .toList();
    _changed(state, () {
      state.loading = true;
      state.error = null;
      state.searching = true;
      if (resetFilters) state.filters = const CinemaFilters();
      state.itemsContext = null;
      state.initialized = true;
      if (!loadMore) {
        state.items =
            [
                  for (final catalogue in _catalogs.values) ...catalogue.items,
                  ..._store.favorites,
                  ..._store.history.map((h) => h.title),
                ]
                .where(
                  (t) =>
                      cinemaMatchesKeyword(t, keyword) &&
                      (t.category.isEmpty ||
                          _matchesCategory(t.category, section)),
                )
                .toList();
        state.discoveryCancel?.cancel();
        state.discovery = const CinemaSearchDiscovery();
        state.discoveryMessage = '';
        state.sourceStatus.clear();
        state.searchPages.clear();
        state.searchMore.clear();
        state.activeKeyword = keyword;
      }
      for (final source in sources) {
        state.sourceStatus[source.name] = '搜索中';
      }
    });
    if (sources.isEmpty) {
      _changed(state, () {
        state.error = '没有启用的片源，请先添加或启用。';
        state.loading = false;
      });
      return;
    }
    final discoveryFuture = !loadMore && widget.enableSearchDiscovery
        ? _discoverSearch(state, section, keyword, generation, sources)
        : Future<void>.value();
    // Each destination owns its generation; slower sources don't hold up the
    // next available worker or overwrite a newer search.
    await _searchInPool(
      sources,
      () => mounted && generation == state.generation,
      (source) async {
        try {
          final page = loadMore ? (state.searchPages[source.id] ?? 1) + 1 : 1;
          final result = await _repository.search(source, keyword, page: page);
          if (!mounted || generation != state.generation) return;
          _changed(state, () {
            final items = result.items
                .map((title) => _withDiscoveryIdentity(title, state.discovery))
                .where(
                  (t) =>
                      _ordinaryCategory(t.category) &&
                      (t.category.isEmpty ||
                          _matchesCategory(t.category, section)),
                )
                .toList();
            final existing = state.items.map((item) => item.key).toSet();
            state.items = [
              ...state.items,
              ...items.where((item) => existing.add(item.key)),
            ];
            state.searchPages[source.id] = result.page;
            if (result.hasMore) {
              state.searchMore.add(source.id);
            } else {
              state.searchMore.remove(source.id);
            }
            state.sourceStatus[source.name] =
                '${state.items.where((t) => t.sourceId == source.id).length} 个结果';
          });
        } catch (e) {
          if (!mounted || generation != state.generation) return;
          _changed(state, () => state.sourceStatus[source.name] = '连接失败：$e');
        }
      },
    );
    await discoveryFuture;
    if (mounted && generation == state.generation) {
      _changed(state, () => state.loading = false);
      unawaited(_preloadRatings(section));
    }
  }

  CinemaTitle _withDiscoveryIdentity(
    CinemaTitle title,
    CinemaSearchDiscovery discovery,
  ) => title.doubanId.isNotEmpty
      ? title
      : CinemaRatingIdentitySearch.match(title, discovery.titles) ?? title;

  Future<void> _searchInPool(
    List<CinemaSource> sources,
    bool Function() current,
    Future<void> Function(CinemaSource) search,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (current() && next < sources.length) {
        await search(sources[next++]);
      }
    }

    await Future.wait(
      List.generate(sources.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> _discoverSearch(
    _CatalogState state,
    _Section section,
    String keyword,
    int generation,
    List<CinemaSource> sources,
  ) async {
    final cancel = state.discoveryCancel = CancelToken();
    bool current() =>
        mounted && generation == state.generation && !cancel.isCancelled;
    _changed(state, () => state.discoveryLoading = true);
    try {
      final discovery = await _discoveryRepository.search(
        keyword,
        cancelToken: cancel,
      );
      if (!current()) return;
      _changed(state, () {
        state.discovery = discovery;
        state.items = state.items
            .map((title) => _withDiscoveryIdentity(title, discovery))
            .toList();
        state.discoveryMessage = discovery.message;
        state.discoveryLoading = false;
      });
      // Resolve at most two suggested Chinese titles, with three source requests
      // in flight. Original source search and its pagination remain independent.
      for (final query in discovery.queries) {
        if (!current()) return;
        await _searchInPool(sources, current, (source) async {
          try {
            final result = await _repository.search(source, query);
            if (!current()) return;
            final keys = state.items.map((t) => t.key).toSet();
            final matches = result.items
                .map((title) => _withDiscoveryIdentity(title, discovery))
                .where(
                  (t) =>
                      _ordinaryCategory(t.category) &&
                      (t.category.isEmpty ||
                          _matchesCategory(t.category, section)) &&
                      keys.add(t.key),
                )
                .toList();
            _changed(state, () {
              state.items = [...state.items, ...matches];
              final count = state.items
                  .where((t) => t.sourceId == source.id)
                  .length;
              if (count > 0) state.sourceStatus[source.name] = '$count 个结果';
            });
          } catch (_) {
            /* Ordinary source status remains visible. */
          }
        });
      }
    } catch (e) {
      if (current()) {
        _changed(
          state,
          () => state.discoveryMessage = '中英文与演员资料暂时不可用，已保留片源搜索结果。',
        );
      }
    } finally {
      if (current()) _changed(state, () => state.discoveryLoading = false);
    }
  }

  Future<void> _selectActor(CinemaDiscoveryPerson person) async {
    final state = _catalog;
    final section = _section;
    final people = state.discovery.people;
    state.discoveryCancel?.cancel('演员选择已改变');
    final cancel = state.discoveryCancel = CancelToken();
    final generation = ++state.generation;
    _changed(state, () {
      state.items = [];
      state.loading = false;
      state.discoveryLoading = true;
      state.discoveryMessage = '';
      state.searchMore.clear();
      state.searchPages.clear();
      state.sourceStatus.clear();
      state.discovery = CinemaSearchDiscovery(
        people: people,
        celebrityId: person.id,
        celebrityName: person.name,
      );
    });
    try {
      final result = await _discoveryRepository.actorWorks(
        person.id,
        person.name,
        cancelToken: cancel,
      );
      if (!mounted || generation != state.generation || cancel.isCancelled) {
        return;
      }
      _changed(state, () {
        state.discovery = CinemaSearchDiscovery(
          titles: result.titles,
          people: people,
          celebrityId: result.celebrityId,
          celebrityName: result.celebrityName,
          nextStart: result.nextStart,
          hasMore: result.hasMore,
          message: result.message,
        );
        state.discoveryMessage = result.message;
      });
    } catch (_) {
      if (mounted && generation == state.generation && !cancel.isCancelled) {
        _changed(state, () => state.discoveryMessage = '暂时无法读取这位演员的作品，请重试。');
      }
    } finally {
      if (mounted && generation == state.generation) {
        _changed(state, () => state.discoveryLoading = false);
        unawaited(_preloadRatings(section));
      }
    }
  }

  Future<void> _moreActorWorks() async {
    final state = _catalog;
    final section = _section;
    final generation = state.generation;
    final previous = state.discovery;
    if (state.discoveryLoading || !previous.hasMore) return;
    _changed(state, () => state.discoveryLoading = true);
    try {
      final next = await _discoveryRepository.actorWorks(
        previous.celebrityId,
        previous.celebrityName,
        start: previous.nextStart,
        cancelToken: state.discoveryCancel,
      );
      if (!mounted || generation != state.generation) return;
      final ids = previous.titles.map((t) => t.id).toSet();
      _changed(state, () {
        state.discovery = CinemaSearchDiscovery(
          titles: [
            ...previous.titles,
            ...next.titles.where((t) => ids.add(t.id)),
          ],
          people: previous.people,
          celebrityId: next.celebrityId,
          celebrityName: next.celebrityName,
          nextStart: next.nextStart,
          hasMore: next.hasMore,
        );
        state.discoveryMessage = next.message;
      });
    } catch (_) {
      if (mounted && generation == state.generation) {
        _changed(state, () => state.discoveryMessage = '暂时无法加载更多演员作品，请重试。');
      }
    } finally {
      if (mounted && generation == state.generation) {
        _changed(state, () => state.discoveryLoading = false);
        unawaited(_preloadRatings(section));
      }
    }
  }

  void _changeCatalogueFilters(CinemaFilters value) {
    if (_aggregates(_section) && !_searching) {
      setState(() => _catalog.filters = value);
      unawaited(_browse());
      return;
    }
    final previous = _catalog.filters;
    final category =
        !_searching && value.genre != previous.genre && value.genre.isNotEmpty
        ? _visibleCategories
              .where(
                (c) =>
                    c.name == '${value.genre}片' || c.name == '${value.genre}电影',
              )
              .firstOrNull
        : null;
    setState(() => _catalog.filters = value);
    if (_searching) unawaited(_preloadRatings(_section));
    if (category != null && category.id != _categoryId) {
      _categoryId = category.id;
      _browse();
    }
  }

  List<CinemaDiscoveryTitle> _visibleDiscoveryTitles(
    _CatalogState state,
    _Section section,
  ) => state.discovery.titles
      .where(
        (title) =>
            state.filters.matches(title.metadata) &&
            (section == _Section.anime ||
                title.kind.isEmpty ||
                (section == _Section.series
                    ? title.kind == 'tv'
                    : title.kind != 'tv')) &&
            !state.items.any(
              (item) =>
                  item.doubanId == title.id ||
                  (cinemaSearchKey(item.title) ==
                          cinemaSearchKey(title.title) &&
                      (item.year.isEmpty ||
                          title.year.isEmpty ||
                          item.year == title.year)),
            ),
      )
      .toList();

  Widget _discoveryResults() {
    final discovery = _catalog.discovery;
    var titles = _visibleDiscoveryTitles(_catalog, _section);
    if (_showsCatalogSort && _currentCatalogSort == CinemaCatalogSort.rating) {
      final byId = {for (final title in titles) title.id: title};
      titles = sortCinemaTitles(
        titles.map((title) => title.metadata).toList(),
        CinemaCatalogSort.rating,
        scoreOf: (title) => _ratings.scoreFor(title, _scoreProvider),
      ).map((title) => byId[title.id]!).toList();
    }
    if (titles.isEmpty &&
        discovery.people.isEmpty &&
        !_catalog.discoveryLoading &&
        _catalog.discoveryMessage.isEmpty &&
        !discovery.hasMore) {
      return const SizedBox();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (discovery.people.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final person in discovery.people)
                    ChoiceChip(
                      key: ValueKey('discovery-person:${person.id}'),
                      selected: discovery.celebrityId == person.id,
                      avatar: const Icon(
                        Icons.person_outline_rounded,
                        size: 16,
                      ),
                      label: Text(
                        [
                          person.name,
                          person.originalName,
                        ].where((s) => s.isNotEmpty).toSet().join(' · '),
                      ),
                      onSelected:
                          _catalog.discoveryLoading &&
                              discovery.celebrityId == person.id
                          ? null
                          : (_) => _selectActor(person),
                    ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  discovery.celebrityName.isEmpty
                      ? '相关作品 · 点击查找片源'
                      : '${discovery.celebrityName}参演作品 · 点击查找片源',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (discovery.hasMore)
                TextButton(
                  onPressed: _catalog.discoveryLoading ? null : _moreActorWorks,
                  child: const Text('更多参演作品'),
                ),
            ],
          ),
          if (_catalog.discoveryLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_catalog.discoveryMessage.isNotEmpty)
            Text(
              _catalog.discoveryMessage,
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          if (titles.isNotEmpty)
            SizedBox(
              height: 252,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: titles.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final title = titles[index];
                  return SizedBox(
                    width: 110,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      key: ValueKey('discovery-title:${title.id}'),
                      onTap: () => _openTitle(title.metadata),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: _poster(title.metadata, 110, 151),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            title.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            title.year,
                            style: const TextStyle(
                              fontSize: 10,
                              color: CinemaTheme.muted,
                            ),
                          ),
                          const SizedBox(height: 5),
                          CinemaCardRatings(
                            title: title.metadata,
                            repository: _ratings,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openTitle(
    CinemaTitle title, {
    CinemaHistory? resume,
    List<CinemaTitle> variants = const [],
  }) async {
    if (title.sourceId == 'douban-discovery') {
      final found = await resolveCinemaDiscoverySources(
        context,
        anchor: title,
        sources: _store.enabledSources,
        repository: _repository,
      );
      if (!mounted || found == null || found.isEmpty) return;
      final available = found
          .where((t) => _findSource(t.sourceId)?.enabled == true)
          .toList();
      if (available.isEmpty) return;
      final representative = groupCinemaTitles([
        ...available,
        title,
      ]).first.catalogTitle;
      await _openTitle(representative, variants: available);
      return;
    }
    final source = _findSource(title.sourceId);
    if (source == null) {
      _toast('此片源已移除，请重新添加后播放。');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CinemaTheme.surface,
      constraints: const BoxConstraints(maxWidth: 920),
      builder: (context) => _TitleDetails(
        title: title,
        source: source,
        variants: variants
            .where((v) => v.sourceId != 'douban-discovery')
            .toList(),
        ratingsRepository: widget.ratingsRepository,
        repository: _repository,
        store: _store,
        resume: resume,
        onRecommendationSelected: (recommendation) {
          Navigator.pop(context);
          if (!_isCatalog) {
            setState(
              () => _section = _matchesCategory(title.category, _Section.series)
                  ? _Section.series
                  : _Section.movies,
            );
          }
          _search.text = recommendation.title;
          _runSearch();
        },
        onPlay: (detail, selectedSource, road, episode, allVariants) {
          Navigator.pop(context);
          _playTitle(detail, selectedSource, road, episode, allVariants);
        },
      ),
    );
    if (mounted) {
      setState(() {}); // Refresh poster summaries after rating edits.
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: CinemaTheme.of(context),
      child: Builder(
        builder: (context) {
          final wide = MediaQuery.sizeOf(context).width >= 860;
          return Scaffold(
            backgroundColor: CinemaTheme.background,
            drawer: wide
                ? null
                : Drawer(
                    backgroundColor: CinemaTheme.surface,
                    child: _navigation(closeDrawer: true),
                  ),
            body: CinemaCanvas(
              child: SafeArea(
                child: Column(
                  children: [
                    DragToMoveArea(
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.only(left: 96, right: 24),
                        child: Row(
                          children: [
                            const Text(
                              'NAKU播放器',
                              style: TextStyle(
                                fontSize: 12,
                                color: CinemaTheme.muted,
                              ),
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          if (wide)
                            SizedBox(
                              width: 216,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  10,
                                  14,
                                ),
                                child: CinemaGlass(child: _navigation()),
                              ),
                            ),

                          Expanded(
                            child: Column(
                              children: [
                                Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    wide ? 36 : 16,
                                    22,
                                    wide ? 36 : 16,
                                    18,
                                  ),
                                  child: Row(
                                    children: [
                                      if (!wide)
                                        Builder(
                                          builder: (context) => IconButton(
                                            onPressed: () => Scaffold.of(
                                              context,
                                            ).openDrawer(),
                                            icon: const Icon(
                                              Icons.menu_rounded,
                                            ),
                                          ),
                                        ),
                                      if (_section == _Section.settings &&
                                          _showSourceManager)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: IconButton(
                                            tooltip: '返回设置',
                                            onPressed: () => setState(
                                              () => _showSourceManager = false,
                                            ),
                                            icon: const Icon(
                                              Icons.arrow_back_rounded,
                                            ),
                                          ),
                                        ),
                                      Text(
                                        _heading,
                                        style: const TextStyle(
                                          fontSize: 27,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (_isCatalog)
                                        SizedBox(
                                          width: wide ? 330 : 190,
                                          child: TextField(
                                            controller: _search,
                                            onSubmitted: (_) => _runSearch(),
                                            decoration: InputDecoration(
                                              isDense: true,
                                              hintText: '中英文片名 / 演员',
                                              prefixIcon: const Icon(
                                                Icons.search_rounded,
                                                size: 20,
                                              ),
                                              suffixIcon: IconButton(
                                                tooltip: '搜索',
                                                onPressed: _runSearch,
                                                icon: const Icon(
                                                  Icons.arrow_forward_rounded,
                                                  size: 19,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: CinemaPaneTransition(
                                    destination: (_section, _showSourceManager),
                                    child: _content(wide),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _navigation({bool closeDrawer = false}) {
    const icons = [
      Icons.local_movies_outlined,
      Icons.tv_rounded,
      Icons.animation_rounded,
      Icons.bookmark_border_rounded,
      Icons.history_rounded,
      Icons.settings_outlined,
    ];
    const labels = ['电影', '剧集', '动漫', '我的收藏', '继续观看', '设置'];
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(26, 27, 24, 8),
          child: Row(
            children: [
              Icon(Icons.waves_rounded, color: CinemaTheme.copper, size: 28),
              SizedBox(width: 10),
              Text(
                'NAKU',
                style: TextStyle(
                  fontSize: 24,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        for (final section in _Section.values) ...[
          if (section == _Section.favorites)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              child: Divider(),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: ListTile(
              selected: _section == section,
              selectedTileColor: CinemaTheme.copper.withValues(alpha: .16),
              selectedColor: CinemaTheme.copper,
              textColor: CinemaTheme.muted,
              iconColor: CinemaTheme.muted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              dense: true,
              leading: Icon(icons[section.index], size: 20),
              title: Text(
                labels[section.index],
                style: const TextStyle(fontSize: 14),
              ),
              onTap: () {
                if (closeDrawer) Navigator.pop(context);
                _selectSection(section);
              },
            ),
          ),
          if (section == _Section.anime)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              child: ListTile(
                dense: true,
                textColor: CinemaTheme.muted,
                iconColor: CinemaTheme.muted,
                leading: const Icon(Icons.language_rounded, size: 20),
                title: const Text('网页影院', style: TextStyle(fontSize: 14)),
                onTap: () {
                  if (closeDrawer) Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CinemaWebsitesPage(),
                    ),
                  );
                },
              ),
            ),
        ],
        if (widget.enableWatchTogether)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: ListenableBuilder(
              listenable: _together,
              builder: (context, _) => ListTile(
                key: const ValueKey('watch-together-entry'),
                dense: true,
                leading: Icon(
                  Icons.people_outline_rounded,
                  size: 20,
                  color: _together.isPaired
                      ? CinemaTheme.copper
                      : CinemaTheme.muted,
                ),
                title: const Text('一起看', style: TextStyle(fontSize: 14)),
                subtitle: _together.isPaired
                    ? Text(
                        _together.session.connected
                            ? '已配对 · ${_together.peers.length} 人在线'
                            : '已配对 · 正在重连',
                        style: const TextStyle(
                          fontSize: 10,
                          color: CinemaTheme.muted,
                        ),
                      )
                    : null,
                onTap: () {
                  if (closeDrawer) Navigator.pop(this.context);
                  showCinemaSyncSheet(this.context, coordinator: _together);
                },
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.leaderboard_outlined, size: 20),
            title: const Text('豆瓣榜单'),
            onTap: () {
              if (closeDrawer) Navigator.pop(context);
              Navigator.of(context).push(
                PageRouteBuilder<void>(
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => DoubanPage(
                    onSelect: (title) {
                      Navigator.of(context).pop();
                      _selectSection(
                        title.kind == DoubanKind.movie
                            ? _Section.movies
                            : _Section.series,
                      ).then((_) {
                        if (!mounted) return;
                        _search.text = title.title;
                        _runSearch();
                      });
                    },
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextButton.icon(
            onPressed: () => context.pushNamed('/tab/popular/'),
            icon: const Icon(Icons.auto_awesome_outlined, size: 17),
            label: const Text('Bangumi 动漫目录', style: TextStyle(fontSize: 11)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 12, 20, 25),
          child: InkWell(
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'NAKU播放器',
              applicationVersion: '1.5.0',
              applicationLegalese:
                  '基于 Kazumi，GPL-3.0。\n个人电影、剧集与动漫客户端。\n片源及其内容由对应第三方提供。',
              children: [
                TextButton(
                  onPressed: () =>
                      launchUrl(Uri.parse(NakuUpdateService.repositoryUrl)),
                  child: const Text('NAKU播放器源代码'),
                ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://github.com/Predidit/Kazumi'),
                  ),
                  child: const Text('查看 Kazumi 开源项目'),
                ),
              ],
            ),
            child: const Text(
              'NAKU播放器  1.5.0',
              style: TextStyle(
                fontSize: 10,
                height: 1.8,
                letterSpacing: .8,
                color: CinemaTheme.muted,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _catalogSortControls() => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final sort in [
              CinemaCatalogSort.popular,
              CinemaCatalogSort.latest,
              CinemaCatalogSort.rating,
            ])
              ChoiceChip(
                key: ValueKey('catalog-sort-${sort.name}'),
                label: Text(switch (sort) {
                  CinemaCatalogSort.popular => '热门',
                  CinemaCatalogSort.latest => '最新',
                  CinemaCatalogSort.rating => '评分',
                }),
                selected: _currentCatalogSort == sort,
                selectedColor: CinemaTheme.copper.withValues(alpha: .18),
                side: BorderSide(
                  color: _currentCatalogSort == sort
                      ? CinemaTheme.copper
                      : CinemaTheme.border,
                ),
                onSelected: (_) {
                  if (_currentCatalogSort == sort) return;
                  setState(() => _catalogSort[_section] = sort);
                  if (_aggregates(_section) && !_searching) {
                    unawaited(_browse());
                  } else {
                    unawaited(_preloadRatings(_section));
                  }
                },
              ),
            if (_currentCatalogSort == CinemaCatalogSort.rating)
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('catalog-rating-provider'),
                  value: _scoreProvider,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 12,
                    color: CinemaTheme.copper,
                  ),
                  items: [
                    for (final provider in ['豆瓣', 'IMDb', '烂番茄'])
                      DropdownMenuItem(value: provider, child: Text(provider)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _scoreProviders[_section] = value);
                      unawaited(_preloadRatings(_section));
                    }
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                switch (_currentCatalogSort) {
                  CinemaCatalogSort.popular => '已加载作品 · 片源热度',
                  CinemaCatalogSort.latest => '已加载作品 · 片源更新时间',
                  CinemaCatalogSort.rating => '已加载作品 · 评分从高到低',
                },
                style: const TextStyle(fontSize: 11, color: CinemaTheme.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          _catalogSortExplanation,
          style: const TextStyle(
            fontSize: 11,
            height: 1.5,
            color: CinemaTheme.muted,
          ),
        ),
      ],
    ),
  );

  CinemaCatalogView get _catalogView => _catalog.viewCache.resolve(
    items: _items,
    filters: _catalog.filters,
    grouped: _searching || _aggregates(_section),
    sort: _showsCatalogSort ? _currentCatalogSort : null,
    provider: _scoreProvider,
    ratingRevision: _ratingRevision,
    scoreOf: (title) => _ratings.scoreFor(title, _scoreProvider),
  );

  Widget _content(bool wide) {
    if (_section == _Section.settings) {
      if (_showSourceManager) return _sourceManager(wide);
      return CinemaSettingsPage(
        enabledSourceCount: _store.enabledSources.length,
        sourceCount: _store.sources.length,
        onSources: () => setState(() => _showSourceManager = true),
        onAppearance: () => showCinemaAppearanceSheet(context),
        onUpdates: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const NakuUpdatePage())),
      );
    }
    if (_section == _Section.favorites) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: CinemaFilterBar(
              value: _catalog.filters,
              items: _store.favorites,
              scope: '全部收藏',
              onChanged: (v) => setState(() => _catalog.filters = v),
            ),
          ),
          Expanded(
            child: _library(
              _store.favorites.where(_catalog.filters.matches).toList(),
              wide,
              '没有符合条件的收藏。',
            ),
          ),
        ],
      );
    }
    if (_section == _Section.history) {
      if (_store.history.isEmpty) return _empty('暂无观看记录', '播放后会在这里保留剧集和进度。');
      final history = _store.history
          .where((h) => _catalog.filters.matches(h.title))
          .toList();
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: CinemaFilterBar(
              value: _catalog.filters,
              items: _store.history.map((h) => h.title).toList(),
              scope: '全部历史',
              onChanged: (v) => setState(() => _catalog.filters = v),
            ),
          ),
          Expanded(
            child: ListView.separated(
              key: const PageStorageKey('cinema-history-scroll'),
              padding: const EdgeInsets.all(28),
              itemCount: history.length,
              separatorBuilder: (_, _) => const Divider(height: 25),
              itemBuilder: (context, index) {
                final h = history[index];
                return CinemaLibraryActions(
                  key: ValueKey('history-actions:${h.title.key}'),
                  store: _store,
                  title: h.title,
                  history: true,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 48,
                      child: _poster(h.title, 48, 68),
                    ),
                    title: Text(h.title.title),
                    subtitle: Text(
                      '${_findSource(h.title.sourceId)?.name ?? '已移除的片源'}  ·  第 ${h.episodeIndex + 1} 集  ·  ${Duration(seconds: h.positionSeconds).inMinutes} 分钟',
                    ),
                    trailing: const Icon(
                      Icons.play_circle_outline_rounded,
                      color: CinemaTheme.copper,
                    ),
                    onTap: () => _openTitle(h.title, resume: h),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }
    final padding = wide ? 36.0 : 18.0;
    final searching = _searching;
    final aggregated = _aggregates(_section) && !searching;
    final snapshot = aggregated ? _aggregateFor(_section).snapshot : null;
    final view = _catalogView;
    final searchGroups = view.groups;
    final representatives = view.representatives;
    final visibleItems = view.visible;
    final variantsByKey = view.variants;
    return CustomScrollView(
      key: PageStorageKey(
        aggregated
            ? 'catalog-${_section.name}-unified-${_catalog.filters.year}-${_catalog.filters.region}-${_catalog.filters.genre}'
            : 'catalog-${_section.name}-${_source?.id}-${_searching ? _catalog.activeKeyword : _categoryId}-$_page',
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (aggregated) ...[
                  Row(
                    children: [
                      const Text(
                        '全部片源',
                        style: TextStyle(
                          color: CinemaTheme.muted,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${searchGroups.length} 部作品',
                        style: const TextStyle(
                          color: CinemaTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _loading
                            ? null
                            : () => _browse(refresh: true),
                        icon: const Icon(Icons.refresh_rounded, size: 19),
                      ),
                    ],
                  ),
                  Text(
                    snapshot!.message,
                    style: const TextStyle(
                      color: CinemaTheme.muted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 7,
                    runSpacing: 6,
                    children: [
                      for (final status in snapshot.sources)
                        Tooltip(
                          message:
                              status.error ??
                              (status.yearUnsupported
                                  ? '此源未按年份返回，已排除不匹配内容'
                                  : status.source.name),
                          child: Text(
                            '${status.source.name} · ${status.loading
                                ? '读取中'
                                : status.error != null
                                ? '暂不可用'
                                : status.yearUnsupported
                                ? '待匹配'
                                : status.loadedCount > 0
                                ? '${status.loadedCount}'
                                : snapshot.usesMetadataDiscovery
                                ? '按作品匹配'
                                : '暂无内容'}',
                            style: TextStyle(
                              fontSize: 10,
                              color: status.loading
                                  ? CinemaTheme.copper
                                  : CinemaTheme.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (!_searching && !aggregated)
                  Row(
                    children: [
                      Text(
                        '片源目录',
                        style: const TextStyle(
                          color: CinemaTheme.muted,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      if (_source != null)
                        DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _source!.id,
                            items: _store.enabledSources
                                .where((s) => s.kind == CinemaSourceKind.maccms)
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s.id,
                                    child: Text(
                                      s.name,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (id) {
                              _source = _findSource(id!);
                              _categories = [];
                              _categoryId = null;
                              _browse();
                            },
                          ),
                        ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _loading
                            ? null
                            : () => _browse(page: _page, refresh: true),
                        icon: const Icon(Icons.refresh_rounded, size: 19),
                      ),
                    ],
                  ),
                if (_searching)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _sourceStatus.entries
                        .map(
                          (e) => Tooltip(
                            message: e.value,
                            child: Chip(
                              label: Text(
                                '${e.key} · ${e.value.startsWith('连接失败') ? '连接失败' : e.value}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              avatar: Icon(
                                e.value.startsWith('连接失败')
                                    ? Icons.error_outline
                                    : Icons.hub_outlined,
                                size: 14,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                if (_searching && _items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '${searchGroups.length} 部作品 · ${_items.length} 个片源版本，进入详情切换片源',
                      style: const TextStyle(
                        fontSize: 12,
                        color: CinemaTheme.muted,
                      ),
                    ),
                  ),
                if (!_searching && !aggregated && _visibleCategories.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SizedBox(
                      height: 38,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: _visibleCategories
                            .map(
                              (c) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(
                                    c.name,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  selected: c.id == _categoryId,
                                  onSelected: (_) {
                                    _categoryId = c.id;
                                    _browse();
                                  },
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                CinemaFilterBar(
                  value: _catalog.filters,
                  items: aggregated ? representatives : _items,
                  onChanged: _changeCatalogueFilters,
                  scope: _searching
                      ? '当前搜索结果'
                      : aggregated
                      ? '聚合目录'
                      : '已加载片源目录',
                ),
                if (_showsCatalogSort) _catalogSortControls(),
                if (_searching) _discoveryResults(),
                if (_section == _Section.anime && !_searching)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '搜索同时查询动漫规则与影视接口；上方分类来自当前片源。',
                      style: TextStyle(
                        color: CinemaTheme.muted.withValues(alpha: .85),
                        fontSize: 11,
                      ),
                    ),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ),
        if (_error != null && _items.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    size: 18,
                    color: CinemaTheme.muted,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '暂时无法刷新，保留上次加载的内容。',
                      style: TextStyle(color: CinemaTheme.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _searching
                        ? _runSearch()
                        : _browse(page: _page, refresh: true),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        if (_error != null && _items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _empty(
              '暂时未能连接',
              _error!,
              action: FilledButton.tonal(
                onPressed: () =>
                    _searching ? _runSearch() : _browse(refresh: true),
                child: const Text('重新尝试'),
              ),
            ),
          )
        else if (visibleItems.isEmpty && !_loading)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _empty(
              '暂时没有结果',
              aggregated
                  ? '当前条件暂未返回作品，可调整筛选、继续加载或刷新重试。'
                  : !_catalog.filters.isEmpty
                  ? '已加载内容没有符合筛选的作品，可重置筛选或继续加载后续页。'
                  : _searching
                  ? '可从相关作品查找线路，或在片源管理启用其他来源。'
                  : '当前片源在这个分类暂未返回内容，可切换分类或片源。',
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(padding, 0, padding, 28),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.crossAxisExtent / 165)
                    .floor()
                    .clamp(2, 6);
                return SliverGrid(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _titleCard(
                      visibleItems[index],
                      variants:
                          variantsByKey[visibleItems[index].key] ?? const [],
                    ),
                    childCount: visibleItems.length,
                    findChildIndexCallback: (key) =>
                        key is ValueKey<String> &&
                            key.value.startsWith('title-card:')
                        ? view.indices[key.value.substring(
                            'title-card:'.length,
                          )]
                        : null,
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 24,
                    childAspectRatio: .51,
                  ),
                );
              },
            ),
          ),
        if (aggregated && snapshot!.hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _loading
                      ? null
                      : () => _aggregateFor(_section).loadMore(),
                  icon: const Icon(Icons.expand_more_rounded),
                  label: const Text('加载更多作品'),
                ),
              ),
            ),
          ),
        if (_searching && _searchMore.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Center(
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : () => _runSearch(loadMore: true),
                  icon: const Icon(Icons.expand_more),
                  label: const Text('加载更多搜索结果'),
                ),
              ),
            ),
          ),
        if (!aggregated &&
            !_searching &&
            !_catalog.filters.isEmpty &&
            _page < _pageCount)
          SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: OutlinedButton.icon(
                  onPressed: _loading
                      ? null
                      : () => _browse(page: _page + 1, append: true),
                  icon: const Icon(Icons.filter_alt_outlined),
                  label: const Text('继续筛选后续页'),
                ),
              ),
            ),
          ),
        if (!aggregated && !_searching && _items.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: _page > 1 && !_loading
                        ? () => _browse(page: _page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '$_page / $_pageCount',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CinemaTheme.muted,
                    ),
                  ),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: _page < _pageCount && !_loading
                        ? () => _browse(page: _page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _library(List<CinemaTitle> items, bool wide, String emptyMessage) {
    if (items.isEmpty) return _empty('暂无收藏', emptyMessage);
    return GridView.builder(
      key: const PageStorageKey('cinema-favorites-scroll'),
      padding: EdgeInsets.all(wide ? 36 : 18),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: .51,
      ),
      itemBuilder: (_, i) => CinemaLibraryActions(
        key: ValueKey('favorite-actions:${items[i].key}'),
        store: _store,
        title: items[i],
        child: _titleCard(items[i]),
      ),
    );
  }

  Widget _poster(CinemaTitle title, double? width, double? height) => ClipRRect(
    borderRadius: BorderRadius.circular(9),
    child: SizedBox(
      width: width,
      height: height,
      child: title.poster.isEmpty
          ? _posterFallback(title.title)
          : CachedNetworkImage(
              memCacheWidth: 480,
              imageUrl: title.poster,
              httpHeaders: title.sourceId == 'douban-discovery'
                  ? doubanImageHeaders
                  : null,
              fit: BoxFit.cover,
              placeholder: (_, _) => _posterFallback(title.title),
              errorWidget: (_, _, _) => _posterFallback(title.title),
            ),
    ),
  );

  Widget _posterFallback(String name) => Container(
    color: CinemaTheme.raised,
    padding: const EdgeInsets.all(18),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.local_movies_outlined,
          color: CinemaTheme.copper,
          size: 30,
        ),
        const SizedBox(height: 15),
        Text(
          name,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(color: CinemaTheme.muted, fontSize: 13),
        ),
      ],
    ),
  );

  Widget _titleCard(
    CinemaTitle title, {
    List<CinemaTitle> variants = const [],
  }) => InkWell(
    key: ValueKey('title-card:${title.key}'),
    onTap: () => _openTitle(title, variants: variants),
    borderRadius: BorderRadius.circular(10),
    child: CinemaGlass(
      blur: false,
      radius: 14,
      padding: const EdgeInsets.all(7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _poster(title, null, null),
                if (title.remarks.isNotEmpty)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    right: 8,
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .8),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          title.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            [
              title.year,
              title.sourceId == 'douban-discovery'
                  ? '查找全部片源'
                  : variants
                            .where((v) => v.sourceId != 'douban-discovery')
                            .length >
                        1
                  ? '${variants.where((v) => v.sourceId != 'douban-discovery').length} 个片源版本'
                  : _findSource(title.sourceId)?.name ?? title.category,
            ].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: CinemaTheme.muted),
          ),
          const SizedBox(height: 5),
          CinemaCardRatings(
            title: title,
            repository: _ratings,
            resolveTitle: _ratingTitles.resolve,
          ),
        ],
      ),
    ),
  );

  Widget _empty(String title, String description, {Widget? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(35),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.waves_rounded,
              color: CinemaTheme.copper,
              size: 45,
            ),
            const SizedBox(height: 22),
            Text(title, style: const TextStyle(fontSize: 21)),
            const SizedBox(height: 12),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                height: 1.8,
                fontSize: 12,
                color: CinemaTheme.muted,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 22), action],
          ],
        ),
      ),
    ),
  );

  Widget _sourceManager(bool wide) => ListView(
    padding: EdgeInsets.fromLTRB(wide ? 36 : 18, 8, wide ? 36 : 18, 36),
    children: [
      Row(
        children: [
          const Expanded(
            child: Text('你的片源，你来选择', style: TextStyle(fontSize: 21)),
          ),
          FilledButton.icon(
            onPressed: () => _editSource(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('添加接口'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        '影视接口提供电影和剧集目录；Kazumi 规则用于动漫搜索。来源标注的画质不代表实测分辨率。',
        style: TextStyle(fontSize: 12, height: 1.8, color: CinemaTheme.muted),
      ),
      const SizedBox(height: 8),
      Text(
        MacOSSystemProxy.description,
        style: const TextStyle(fontSize: 11, color: CinemaTheme.muted),
      ),
      const SizedBox(height: 22),
      for (final source in _store.sources)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: CinemaTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CinemaTheme.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  source.kind == CinemaSourceKind.maccms
                      ? Icons.movie_filter_outlined
                      : Icons.animation,
                  color: CinemaTheme.copper,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        source.kind == CinemaSourceKind.maccms
                            ? '影视接口 · ${source.url}'
                            : 'Kazumi 动漫规则 · ${source.url}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: CinemaTheme.muted,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: source.enabled,
                  onChanged: (enabled) async {
                    try {
                      await _store.saveSource(
                        source.copyWith(enabled: enabled),
                      );
                    } catch (e) {
                      _toast('$e');
                    }
                  },
                ),
                IconButton(
                  tooltip: '编辑',
                  onPressed: () => _editSource(source),
                  icon: const Icon(Icons.edit_outlined, size: 19),
                ),
                IconButton(
                  tooltip: '移除此片源',
                  onPressed: () async {
                    try {
                      await _store.removeSource(source.id);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已移除 ${source.name}'),
                          action: SnackBarAction(
                            label: '撤销',
                            onPressed: () => _store.saveSource(source),
                          ),
                        ),
                      );
                    } catch (e) {
                      _toast('$e');
                    }
                  },
                  icon: const Icon(Icons.remove_circle_outline, size: 19),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 12,
        runSpacing: 10,
        children: [
          OutlinedButton.icon(
            onPressed: _importRules,
            icon: const Icon(Icons.data_object, size: 18),
            label: const Text('导入 Kazumi 规则 JSON'),
          ),
          TextButton(
            onPressed: () => launchUrl(
              Uri.parse('https://www.xn--kivn76b41nnhi.com/'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('打开你提供的影视网站 ↗'),
          ),
        ],
      ),
      const SizedBox(height: 30),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: CinemaTheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Netflix 官方观看', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'Netflix 官方内容仍需在受支持的浏览器中使用你的订阅观看。NAKU播放器的第三方片源不等同于 Netflix 官方接口。',
              style: TextStyle(
                color: CinemaTheme.muted,
                fontSize: 12,
                height: 1.8,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://www.netflix.com/'),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('前往 Netflix ↗'),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> _editSource([CinemaSource? source]) async {
    if (source?.kind == CinemaSourceKind.kazumi) {
      await _importRules(existing: source);
      return;
    }
    final name = TextEditingController(text: source?.name ?? '');
    final url = TextEditingController(text: source?.url ?? '');
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(source == null ? '添加影视接口' : '编辑片源'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: url,
                  decoration: InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://example.com/api.php/provide/vod',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '支持标准 MacCMS V10 JSON 接口。请填写接口地址，而不是网站首页。',
                  style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final uri = Uri.tryParse(url.text.trim());
                if (name.text.trim().isEmpty ||
                    uri == null ||
                    !['http', 'https'].contains(uri.scheme) ||
                    uri.host.isEmpty) {
                  setDialogState(() {
                    error = '请填写名称及有效的 HTTP / HTTPS 接口地址';
                  });
                  return;
                }
                try {
                  await _store.saveSource(
                    source == null
                        ? CinemaSource(
                            id: 'custom-${DateTime.now().microsecondsSinceEpoch}',
                            name: name.text.trim(),
                            kind: CinemaSourceKind.maccms,
                            url: uri.toString(),
                          )
                        : source.copyWith(
                            name: name.text.trim(),
                            url: uri.toString(),
                          ),
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  setDialogState(() {
                    error = '$e';
                  });
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    url.dispose();
  }

  Future<void> _importRules({CinemaSource? existing}) async {
    final controller = TextEditingController(
      text: existing == null
          ? ''
          : const JsonEncoder.withIndent('  ').convert(existing.rule),
    );
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('导入 Kazumi 规则'),
          content: SizedBox(
            width: 600,
            child: TextField(
              controller: controller,
              maxLines: 12,
              decoration: InputDecoration(
                hintText: '粘贴规则 JSON 对象或数组',
                errorText: error,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final parsed = jsonDecode(controller.text);
                  final rules = parsed is List ? parsed : [parsed];
                  if (rules.isEmpty || rules.length > 100) {
                    throw const FormatException('一次导入 1–100 条规则');
                  }
                  if (existing != null && rules.length != 1) {
                    throw const FormatException('编辑片源时仅填写一条规则');
                  }
                  final sources = <CinemaSource>[];
                  for (final value in rules) {
                    if (value is! Map) {
                      throw const FormatException('规则需要 JSON 对象');
                    }
                    final rule = Map<String, dynamic>.from(value);
                    final ruleName = rule['name']?.toString() ?? '';
                    final base = Uri.tryParse(
                      rule['baseURL']?.toString() ?? '',
                    );
                    if (ruleName.isEmpty ||
                        base == null ||
                        !['http', 'https'].contains(base.scheme) ||
                        base.host.isEmpty ||
                        rule['deprecated'] == true) {
                      throw const FormatException('规则缺少名称/有效地址，或已被标记为停用');
                    }
                    sources.add(
                      CinemaSource(
                        id: existing?.id ?? 'kazumi-${ruleName.toLowerCase()}',
                        name: ruleName,
                        kind: CinemaSourceKind.kazumi,
                        url: base.toString(),
                        rule: rule,
                        enabled: existing?.enabled ?? true,
                      ),
                    );
                  }
                  for (final source in sources) {
                    source.validate();
                  }
                  for (final source in sources) {
                    await _store.saveSource(source);
                  }
                  if (context.mounted) Navigator.pop(context);
                  _toast('已导入 ${sources.length} 条规则，可在动漫栏目直接搜索');
                } catch (e) {
                  setDialogState(() {
                    error = '导入失败：$e';
                  });
                }
              },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }
}

class _TitleDetails extends StatefulWidget {
  const _TitleDetails({
    required this.title,
    required this.source,
    this.variants = const [],
    this.ratingsRepository,
    required this.repository,
    required this.store,
    required this.onPlay,
    required this.onRecommendationSelected,
    this.resume,
  });
  final CinemaTitle title;
  final CinemaSource source;
  final List<CinemaTitle> variants;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaRepository repository;
  final CinemaStore store;
  final CinemaHistory? resume;
  final ValueChanged<DoubanRecommendation> onRecommendationSelected;
  final void Function(CinemaTitle, CinemaSource, int, int, List<CinemaTitle>)
  onPlay;
  @override
  State<_TitleDetails> createState() => _TitleDetailsState();
}

class _TitleDetailsState extends State<_TitleDetails> {
  late CinemaTitle _selectedTitle = widget.title;
  late CinemaSource _selectedSource = widget.source;
  late Future<CinemaTitle> _detail = widget.repository.detail(
    _selectedSource,
    _selectedTitle,
  );
  int _road = 0;
  late List<CinemaTitle> _variants = [
    widget.title,
    ...widget.variants.where((v) => v.key != widget.title.key),
  ];
  bool _discovering = true;
  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    await for (final variants in discoverCinemaWorkSources(
      anchor: widget.title,
      known: _variants,
      sources: widget.store.enabledSources,
      repository: widget.repository,
      isCurrent: () => mounted,
    )) {
      if (!mounted) return;
      setState(() => _variants = variants);
    }
    if (mounted) setState(() => _discovering = false);
  }

  void _selectVariant(CinemaTitle variant) {
    if (variant.key == _selectedTitle.key) return;
    final source = widget.store.sources
        .where((s) => s.id == variant.sourceId)
        .firstOrNull;
    if (source == null) return;
    setState(() {
      _selectedTitle = variant;
      _selectedSource = source;
      _road = 0;
      _detail = widget.repository.detail(source, variant);
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .84,
      child: FutureBuilder<CinemaTitle>(
        key: ValueKey(_selectedTitle.key),
        future: _detail,
        initialData: _selectedTitle.routes.isNotEmpty ? _selectedTitle : null,
        builder: (context, snapshot) {
          final title = snapshot.data == null
              ? _selectedTitle
              : inheritCinemaRatingMetadata(
                  inheritCinemaRatingMetadata(snapshot.data!, _selectedTitle),
                  widget.title,
                );
          return CinemaCoverBackdrop(
            poster: title.poster,
            child: ListView(
              padding: const EdgeInsets.all(30),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.poster.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          memCacheWidth: 480,
                          imageUrl: title.poster,
                          httpHeaders: title.sourceId == 'douban-discovery'
                              ? doubanImageHeaders
                              : null,
                          width: MediaQuery.sizeOf(context).width < 600
                              ? 90
                              : 150,
                          height: MediaQuery.sizeOf(context).width < 600
                              ? 135
                              : 225,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              const Icon(Icons.movie_outlined, size: 50),
                        ),
                      ),
                      const SizedBox(width: 24),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.title,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            [
                              _selectedSource.name,
                              title.category,
                              title.year,
                              title.remarks,
                            ].where((s) => s.isNotEmpty).join('  ·  '),
                            style: const TextStyle(
                              color: CinemaTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 22),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              if (snapshot.hasData &&
                                  title.routes.any(
                                    (r) => r.episodes.isNotEmpty,
                                  ))
                                FilledButton.icon(
                                  onPressed: () {
                                    final r = title.routes.indexWhere(
                                      (r) => r.episodes.isNotEmpty,
                                    );
                                    widget.onPlay(
                                      title,
                                      _selectedSource,
                                      r,
                                      0,
                                      _variants,
                                    );
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('开始观看'),
                                ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  await widget.store.toggleFavorite(title);
                                  if (mounted) setState(() {});
                                },
                                icon: Icon(
                                  widget.store.isFavorite(title)
                                      ? Icons.bookmark
                                      : Icons.bookmark_border,
                                  size: 18,
                                ),
                                label: Text(
                                  widget.store.isFavorite(title) ? '已收藏' : '收藏',
                                ),
                              ),
                              if (widget.resume != null &&
                                  widget.resume!.title.key ==
                                      _selectedTitle.key &&
                                  snapshot.hasData &&
                                  title.routes.isNotEmpty) ...[
                                const SizedBox(width: 12),
                                FilledButton.icon(
                                  onPressed: () {
                                    final h = widget.resume!;
                                    final selection = cinemaResumeSelection(
                                      title,
                                      h,
                                    );
                                    if (selection == null) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            '片源的线路或集数已变化，请在下方重新选择。',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    widget.onPlay(
                                      title,
                                      _selectedSource,
                                      selection.routeIndex,
                                      selection.episodeIndex,
                                      _variants,
                                    );
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('继续观看'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                for (final entry in {
                  '导演': title.director,
                  '演员 / 配音': title.actors,
                  '地区': title.area,
                  '语言': title.language,
                  '类型': title.genres,
                  '上映（片源）': title.releaseDateText,
                  '片长（片源）': RegExp(r'^\d+$').hasMatch(title.durationText)
                      ? '${title.durationText} 分钟'
                      : title.durationText,
                  '又名（片源）': title.aliases,
                }.entries)
                  if (entry.value.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(
                        '${entry.key}  ${entry.value}',
                        style: const TextStyle(
                          color: CinemaTheme.muted,
                          height: 1.6,
                        ),
                      ),
                    ),
                if (title.director.isEmpty && title.actors.isEmpty)
                  const Text(
                    '此片源暂未提供演职员资料',
                    style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                  ),
                if (_discovering)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      '正在查找其他片源…',
                      style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                    ),
                  ),
                if (_variants.length > 1) ...[
                  const SizedBox(height: 20),
                  const Text(
                    '可用片源',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final variant in _variants)
                        ChoiceChip(
                          key: ValueKey('source-variant:${variant.key}'),
                          label: Text(
                            [
                              widget.store.sources
                                      .where((s) => s.id == variant.sourceId)
                                      .firstOrNull
                                      ?.name ??
                                  '已移除片源',
                              if (_variants
                                      .where(
                                        (v) => v.sourceId == variant.sourceId,
                                      )
                                      .length >
                                  1)
                                variant.title,
                              if (variant.remarks.isNotEmpty) variant.remarks,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: variant.key == _selectedTitle.key,
                          onSelected: (_) => _selectVariant(variant),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '播放页统一显示来源和线路，失败后自动尝试同集的其他线路。',
                    style: TextStyle(fontSize: 11, color: CinemaTheme.muted),
                  ),
                ],
                const SizedBox(height: 20),
                if (title.description.isNotEmpty)
                  Text(
                    title.description,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.85,
                      color: CinemaTheme.muted,
                    ),
                  ),
                const SizedBox(height: 20),
                if (snapshot.hasData) ...[
                  CinemaRatingsPanel(
                    title: title,
                    sourceName: _selectedSource.name,
                    repository: widget.ratingsRepository,
                    onRecommendationSelected: widget.onRecommendationSelected,
                  ),
                  const SizedBox(height: 20),
                ],
                const Divider(height: 40),
                if (snapshot.connectionState != ConnectionState.done)
                  const Center(child: CircularProgressIndicator()),
                if (snapshot.hasError)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '片源加载失败：${snapshot.error}',
                        style: const TextStyle(color: CinemaTheme.muted),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: () => setState(() {
                          _detail = widget.repository.detail(
                            _selectedSource,
                            _selectedTitle,
                          );
                        }),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                if (snapshot.hasData && title.routes.isEmpty)
                  const Text('这个结果暂未提供可播放线路，可返回后尝试其他片源。'),
                if (snapshot.hasData && title.routes.isNotEmpty) ...[
                  const Text('选择线路与集数', style: TextStyle(fontSize: 17)),
                  const SizedBox(height: 15),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var r = 0; r < title.routes.length; r++)
                        ChoiceChip(
                          label: Text(title.routes[r].name),
                          selected: _road == r,
                          onSelected: (_) => setState(() {
                            _road = r;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (
                        var e = 0;
                        e <
                            title
                                .routes[_road.clamp(0, title.routes.length - 1)]
                                .episodes
                                .length;
                        e++
                      )
                        OutlinedButton(
                          onPressed: () => widget.onPlay(
                            title,
                            _selectedSource,
                            _road,
                            e,
                            _variants,
                          ),
                          child: Text(title.routes[_road].episodes[e].name),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ),
  );
}
