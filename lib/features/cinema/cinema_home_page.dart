import 'cinema_neon_decode.dart';
import 'cinema_detail_artwork.dart';
import 'cinema_poster_atmosphere.dart';
import 'cinema_poster_palette.dart';
import 'cinema_featured_wall.dart';
import 'cinema_navigation_island.dart';
import 'cinema_navigation_preferences.dart';
import 'cinema_tv_focus.dart';
import 'cinema_lan_cast.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'cinema_download_sheet.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'cinema_downloads.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:dio/dio.dart';
import 'cinema_appearance_settings.dart';
import 'cinema_pane_transition.dart';
import 'cinema_scroll_activity.dart';
import 'cinema_catalog_view.dart';
import 'cinema_settings_page.dart';
import 'cinema_settings_host_binding.dart';
import 'cinema_startup_preferences.dart';
import 'anime/cinema_anime_page.dart';
import 'anime/cinema_anime_library.dart';
import 'anime/cinema_anime_invitation.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'cinema_unified_library.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'cinema_filters.dart';
import 'cinema_media_identity.dart';
import 'cinema_aggregate_catalog.dart';
import 'cinema_home_cache.dart';
import 'cinema_discovery_resolver.dart';
import 'cinema_search_discovery.dart';

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

import 'cinema_models.dart';
import 'cinema_follow_resolver.dart';
import 'cinema_sync_session.dart';
import 'cinema_sync_sheet.dart';
import 'cinema_watch_together.dart';
import 'cinema_work_sources.dart';
import 'cinema_resource_availability.dart';
import 'cinema_resource_badge.dart';
import 'douban/douban_page.dart';
import 'douban/douban_themes.dart';
import 'douban/douban_repository.dart';
import 'douban/douban_image_headers.dart';
import 'naku_update_page.dart';
import 'naku_update_service.dart';
import 'cinema_grouping.dart';
import 'cinema_card_ratings.dart';
import 'cinema_nas_page.dart';
import 'cinema_nas_sync.dart';
import 'cinema_nas_media.dart';
import 'cinema_nas_peer.dart';
import 'cinema_repository.dart';
import 'cinema_ratings_panel.dart';
import 'cinema_ratings.dart';
import 'cinema_rating_title_resolver.dart';
import 'cinema_rating_identity_search.dart';
import 'cinema_store.dart';
import 'cinema_source_health.dart';
import 'cinema_source_subscriptions.dart';
import 'cinema_media_cache.dart';
import 'cinema_tools_settings.dart';
import 'cinema_player_page.dart';
import 'cinema_theme.dart';
import 'cinema_header_frost.dart';
import 'cinema_artwork_backdrop.dart';
import 'cinema_route_motion.dart';
import 'cinema_websites_page.dart';
import 'cinema_home_display_page.dart';

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
  bool yearWasChosen = false;
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
    this.artworkRepository,
    this.homeCache,
    this.watchTogether,
    this.enableWatchTogether = true,
    this.enableSearchDiscovery = true,
    this.searchDiscovery,
    this.catalogDiscovery,
    this.doubanThemeCatalog,
    this.animePageBuilder,
    this.navigationPreferences,
    this.windowControls,
    this.playerPageBuilder,
    this.initialStartup = const CinemaStartupTarget(),
  });
  final CinemaStartupTarget initialStartup;

  /// Allows embedding the player or inspecting navigation without an engine.
  final Widget Function(CinemaPlayerPage)? playerPageBuilder;
  final CinemaStore? store;
  final CinemaRepository? repository;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaDetailArtworkRepository? artworkRepository;
  final CinemaHomeCache? homeCache;
  final CinemaWatchTogether? watchTogether;
  final bool enableWatchTogether;
  final bool enableSearchDiscovery;
  final CinemaSearchDiscoveryRepository? searchDiscovery;
  final DoubanRepository? catalogDiscovery;
  final DoubanThemeCatalog? doubanThemeCatalog;
  final Widget Function(BuildContext context, bool active)? animePageBuilder;
  final CinemaNavigationPreferences? navigationPreferences;
  final DesktopWindowControls? windowControls;

  @override
  State<CinemaHomePage> createState() => _CinemaHomePageState();
}

class _CinemaHomePageState extends State<CinemaHomePage>
    with KazumiDialogOwner {
  CinemaAnimeLibrary? _animeLibrary;
  final _health = CinemaSourceHealth.instance;
  List<CinemaSource> get _activeSources =>
      _health.available(_store.enabledSources);
  late final CinemaStore _store = widget.store ?? CinemaStore();
  late final _navigationPreferences =
      widget.navigationPreferences ?? CinemaNavigationPreferences.instance;
  CinemaNASSync? _nasSync;
  final _nasPageCache = CinemaNASPageCache();
  late final CinemaRepository _repository =
      widget.repository ?? CinemaRepository(health: _health);
  late final _homeCache =
      widget.homeCache ??
      (widget.store == null ? CinemaHomeCache.instance : null);
  late final _resources = CinemaResourceAvailabilityService(
    _repository,
    cache: _homeCache,
  );
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
  String? _displayedRatingFingerprint;
  final _scrollActivity = CinemaScrollActivity();
  bool _ratingsChangedWhileScrolling = false;
  late final _together = widget.watchTogether ?? CinemaWatchTogether.instance;
  StreamSubscription<String>? _togetherNotices;
  _Section _section = _Section.movies;
  int _sectionRevision = 0, _desktopSearchRevision = 0;
  bool _showSourceManager = false;
  bool _animeOpened = false;
  String _applicationVersion = '正在读取版本';
  final _catalogs = {
    for (final section in _Section.values) section: _CatalogState(),
  };
  final _doubanSession = DoubanBrowseSession();
  final _knownCategories = <String, List<CinemaCategory>>{};
  final _aggregateControllers = <_Section, CinemaAggregateCatalogController>{};
  String _sourceConfiguration = '';
  final Map<_Section, CinemaCatalogSort> _catalogSort = {
    _Section.movies: CinemaCatalogSort.popular,
    _Section.series: CinemaCatalogSort.popular,
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

  String get _catalogViewportKey => _aggregates(_section) && !_searching
      ? 'catalog-${_section.name}-unified-${_catalog.filters.year}-${_catalog.filters.region}-${_catalog.filters.genre}'
      : 'catalog-${_section.name}-${_source?.id}-${_searching ? _catalog.activeKeyword : _categoryId}-$_page';

  String _sourceKey(CinemaSource source) => jsonEncode(source.toJson());

  bool _aggregates(_Section section) =>
      section == _Section.movies || section == _Section.series;

  CinemaAggregateCatalogController _aggregateFor(_Section section) =>
      _aggregateControllers.putIfAbsent(section, () {
        final controller = CinemaAggregateCatalogController(
          repository: _repository,
          discoveryRepository: widget.catalogDiscovery,
          cache: _homeCache,
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
      final previousViewport = _catalogViewportKey;
      setState(change);
      if (previousViewport != _catalogViewportKey) {
        // Disposing a moving ScrollPosition need not send ScrollEnd. Reset at
        // the data change that replaces its key, including async page results,
        // so enrichment cannot remain waiting on a viewport that no longer exists.
        _scrollActivity.reset();
      }
    } else {
      change();
    }
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      final cast = CinemaLanCast.instance;
      cast.onPlay = (title, source, road, episode, position) async {
        if (!mounted) return;
        final homeRoute = ModalRoute.of(context);
        final accepted = homeRoute?.isCurrent == true
            ? true
            : await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('手机发送了「${title.title}」'),
                  content: const Text('在电视上开始播放？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('播放'),
                    ),
                  ],
                ),
              );
        if (!mounted || accepted != true) return;
        if (homeRoute != null) {
          Navigator.of(
            context,
          ).popUntil((route) => identical(route, homeRoute));
        }
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(
              name: CinemaPageTransitionsBuilder.playerRouteName,
            ),
            builder: (_) => Theme(
              data: CinemaTheme.of(context),
              child: CinemaPlayerPage(
                title: title,
                source: source,
                store: _store,
                routeIndex: road,
                episodeIndex: episode,
                initialPositionSeconds: position,
              ),
            ),
          ),
        );
      };
      cast.start();
    }

    if (NakuDevice.hasNAS && widget.store == null) {
      _nasSync = CinemaNASSync(_store);
    }
    try {
      if (!Platform.isAndroid) _animeLibrary = CinemaAnimeLibrary();
    } catch (_) {
      // A standalone widget test may have no anime storage initialized.
    }
    _section = switch (widget.initialStartup.section) {
      CinemaStartupSection.series => _Section.series,
      CinemaStartupSection.anime => _Section.anime,
      CinemaStartupSection.favorites => _Section.favorites,
      CinemaStartupSection.history => _Section.history,
      CinemaStartupSection.settings => _Section.settings,
      _ => _Section.movies,
    };
    if (_section == _Section.anime &&
        widget.initialStartup.animeTab == CinemaAnimeStartupTab.collect) {
      _section = _Section.favorites;
    }
    _animeOpened = _section == _Section.anime;
    if (widget.initialStartup.section == CinemaStartupSection.douban) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openDouban();
      });
    }
    CinemaSettingsHostBinding.instance.bind(
      this,
      onSources: _openSourceSettings,
      onFavorites: () => _openLibrary(false),
      onHistory: () => _openLibrary(true),
      onNASAccount: _openNAS,
      onLibraryBackup: () => _openTools(2),
      accountSync: () => _nasSync,
      onOfflinePlayback: _playOffline,
      enabledSourceCount: () => _store.enabledSources
          .where((source) => source.kind == CinemaSourceKind.maccms)
          .length,
      sourceCount: () => _store.sources
          .where((source) => source.kind == CinemaSourceKind.maccms)
          .length,
    );
    _store.addListener(_onStoreChanged);
    _navigationPreferences.addListener(_onNavigationChanged);
    _health.addListener(_onHealthChanged);

    _ratings.changes.addListener(_onRatingsChanged);
    _scrollActivity.addListener(_onScrollActivityChanged);
    if (widget.enableWatchTogether) {
      _together.onFollowRequested = _followPeer;
      _togetherNotices = _together.notices.listen((message) {
        if (mounted) _toast(message);
      });
      unawaited(_initializeTogether());
    }
    unawaited(_readApplicationVersion());
    unawaited(_initialize());
  }

  Future<void> _openDouban() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DoubanPage(
          repository: widget.catalogDiscovery,
          session: _doubanSession,
          themeCatalog: widget.doubanThemeCatalog,
          onSelect: (title) => _openTitle(
            CinemaDiscoveryTitle(
              id: title.id,
              title: title.title,
              originalTitle: title.originalTitle,
              year: title.year,
              poster: title.poster,
              kind: title.kind.apiType,
              actors: title.actors.join(' / '),
              genres: title.genres.join(' / '),
              area: title.regions.join(' / '),
              score: title.score,
              identityVerified: true,
            ).metadata,
            keepBrowseRoute: true,
          ),
        ),
      ),
    );
    if (mounted && _isCatalog && !_catalog.initialized && !_catalog.loading) {
      await _browse();
    }
  }

  void _openLibrary(bool history) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      Navigator.of(context).popUntil((candidate) => candidate == route);
    }
    unawaited(_selectSection(history ? _Section.history : _Section.favorites));
  }

  void _openSourceSettings() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      Navigator.of(context).popUntil((candidate) => candidate == route);
    }
    setState(() {
      _section = _Section.settings;
      _showSourceManager = true;
    });
  }

  Future<void> _readApplicationVersion() async {
    var display = '版本信息暂不可用';
    try {
      final package = await PackageInfo.fromPlatform();
      final version = package.version.trim();
      final build = package.buildNumber.trim();
      if (version.isNotEmpty) {
        display = build.isEmpty ? version : '$version+$build';
      }
    } catch (_) {
      // Display an unavailable state rather than a stale hard-coded release.
    }
    if (mounted) setState(() => _applicationVersion = display);
  }

  String get _scoreProvider => _scoreProviders[_section] ?? '豆瓣';

  String _ratingSortFingerprint() {
    final view = _catalogView;
    return jsonEncode([
      _section.name,
      _scoreProvider,
      _catalogViewportKey,
      _catalog.filters.year,
      _catalog.filters.region,
      _catalog.filters.genre,
      // Use the filtered, grouped representatives that the wall actually sorts.
      // Keep all scores, including changes that preserve the current order.
      for (final title in view.representatives)
        [title.key, _ratings.scoreFor(title, _scoreProvider)],
      if (_searching)
        [
          for (final title in _visibleDiscoveryTitles(_catalog, _section))
            [
              title.metadata.key,
              _ratings.scoreFor(title.metadata, _scoreProvider),
            ],
        ],
    ]);
  }

  void _onRatingsChanged() {
    if (_scrollActivity.value) {
      _ratingsChangedWhileScrolling = true;
      return;
    }
    if (!mounted ||
        !_showsCatalogSort ||
        _currentCatalogSort != CinemaCatalogSort.rating) {
      _ratingRevision++;
      return;
    }
    _ratingRefresh ??= Timer(const Duration(milliseconds: 350), () {
      _ratingRefresh = null;
      if (mounted &&
          _showsCatalogSort &&
          _currentCatalogSort == CinemaCatalogSort.rating) {
        final fingerprint = _ratingSortFingerprint();
        if (fingerprint == _displayedRatingFingerprint) return;
        _displayedRatingFingerprint = fingerprint;
        setState(() => _ratingRevision++);
      } else {
        // Another destination/provider can reuse its view later. Preserve cache
        // invalidation without rebuilding the inactive rating catalogue.
        _ratingRevision++;
      }
    });
  }

  void _onScrollActivityChanged() {
    if (_scrollActivity.value) {
      if (_ratingRefresh != null) {
        _ratingsChangedWhileScrolling = true;
        _ratingRefresh?.cancel();
        _ratingRefresh = null;
      }
    } else if (_ratingsChangedWhileScrolling) {
      _ratingsChangedWhileScrolling = false;
      _onRatingsChanged();
    }
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
        await _scrollActivity.whenIdle;
        // Another worker can claim the final item while both await idle.
        if (!current() || next >= titles.length) return;
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
      if (mounted) _toast('NAS 配对设置暂时无法读取，请稍后重试。');
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
    if (media.animeId != null) {
      final args = await resolveCinemaAnimeInvitation(
        media: media,
        plugins: inject<PluginsController>().pluginList,
        isCurrent: current,
      );
      if (!mounted || !current()) return false;
      if (args == null) {
        _toast('动漫规则未找到对应作品和集数，请在动漫中检查规则');
        return false;
      }
      context.pushNamed('/video/', arguments: args);
      return true;
    }
    final nasCandidate = _together.isNASPaired
        ? await resolveCinemaNASPeerPlayback(
            media: media,
            namespace: _together.nasNamespace,
            isCurrent: current,
          )
        : null;
    if (!current()) return false;
    final candidate =
        nasCandidate ??
        await resolveCinemaPeerPlayback(
          media: media,
          sources: _activeSources,
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

  void _playOffline(DownloadRecord record, DownloadEpisode episode) {
    try {
      final downloads = inject<DownloadController>();
      final playback = CinemaOfflinePlayback.fromRecord(
        record,
        episode,
        (entry) => downloads.getLocalVideoPath(
          record.bangumiId,
          record.pluginName,
          entry.episodeNumber,
        ),
      );
      if (playback == null) {
        _toast('本地文件不存在，请重新下载');
        return;
      }
      _playTitle(
        playback.title,
        playback.source,
        0,
        playback.episodeIndex,
        [],
        offlinePaths: playback.paths,
      );
    } catch (_) {
      _toast('下载记录暂时无法打开，请重新下载');
    }
  }

  void _playTitle(
    CinemaTitle detail,
    CinemaSource source,
    int road,
    int episode,
    List<CinemaTitle> variants, {
    bool keepBrowseRoute = false,
    Map<String, String>? offlinePaths,
    int? initialPositionSeconds,
  }) {
    unawaited(
      Navigator.of(context)
          .push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(
                name: CinemaPageTransitionsBuilder.playerRouteName,
              ),
              builder: (context) => Theme(
                data: CinemaTheme.of(context),
                child: _buildPlayerPage(
                  CinemaPlayerPage(
                    title: detail,
                    source: source,
                    offlinePaths: offlinePaths,
                    initialPositionSeconds: initialPositionSeconds,
                    watchTogether: widget.enableWatchTogether
                        ? _together
                        : null,
                    store: _store,
                    variants: variants,
                    repository: _repository,
                    ratingsRepository: _ratings,
                    onRecommendationSelected: (recommendation) async {
                      if (!mounted) return;
                      if (keepBrowseRoute) {
                        await _openDoubanRecommendation(recommendation);
                        return;
                      }
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
            ),
          )
          .then((_) {
            if (mounted) setState(() {});
          }),
    );
  }

  Widget _buildPlayerPage(CinemaPlayerPage page) =>
      widget.playerPageBuilder?.call(page) ?? page;

  void _onHealthChanged() {
    if (mounted && _section == _Section.settings && _showSourceManager) {
      setState(() {});
    }
  }

  Future<void> _openNAS() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Theme(
          data: CinemaTheme.of(context),
          child: CinemaNASPage(
            cache: _nasPageCache,
            store: _store,
            sync: _nasSync,
            onSyncSettings: () => context.pushNamed('/settings/sync'),
            onRecommendationSelected: (recommendation) =>
                unawaited(_openDoubanRecommendation(recommendation)),
          ),
        ),
      ),
    );
  }

  void _openHomeDisplay() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CinemaHomeDisplayPage(
          client: _nasPageCache.client,
          onOpenNAS: _openNAS,
        ),
      ),
    );
  }

  void _openTools([int tab = 0]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Theme(
          data: CinemaTheme.of(context),
          child: CinemaToolsSettingsPage(store: _store, initialTab: tab),
        ),
      ),
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

  void _onNavigationChanged() {
    if (mounted) setState(() {});
  }

  // Explicit anime startup/deep links keep a selected destination while that
  // page is open, without changing the device's saved navigation preference.
  bool get _showAnimeDestination =>
      !(Platform.isAndroid || NakuDevice.isTV) &&
      (_navigationPreferences.showAnime || _section == _Section.anime);

  Future<void> _initialize() async {
    try {
      await _store.load();
      await Future.wait([
        if (_homeCache != null) _homeCache.load(),
        if (_homeCache != null) _ratings.restore(),
      ]);
      if (widget.store == null) {
        if (NakuDevice.hasNAS) {
          _nasSync ??= CinemaNASSync(_store);
          unawaited(_nasSync!.start());
        }
        await _health.load();
        final prefs = _store.extras['mediaCache'];
        if (prefs is Map) {
          await CinemaMediaCache.instance.configure(
            CinemaCachePreferences.parse(prefs),
          );
        }
        unawaited(CinemaSourceSubscriptions(_store).refresh(automatic: true));
      }

      _sourceConfiguration = jsonEncode(
        _store.sources.map((s) => s.toJson()).toList(),
      );
      if (!mounted) return;
      setState(() {});
      if (widget.initialStartup.section != CinemaStartupSection.douban) {
        await _browse();
      }
    } catch (e) {
      if (mounted) {
        if (_isCatalog) {
          setState(() {
            _catalog.error = '$e';
            _catalog.loading = false;
          });
        } else {
          _toast('资料加载失败，请重试');
        }
      }
    }
  }

  @override
  void dispose() {
    _resources.dispose();
    if (Platform.isAndroid) unawaited(CinemaLanCast.instance.stop());
    _nasSync?.dispose();
    _animeLibrary?.dispose();
    CinemaSettingsHostBinding.instance.unbind(this);
    _ratings.changes.removeListener(_onRatingsChanged);
    _ratingRefresh?.cancel();
    _scrollActivity.removeListener(_onScrollActivityChanged);
    _scrollActivity.dispose();
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
    _navigationPreferences.removeListener(_onNavigationChanged);
    _health.removeListener(_onHealthChanged);

    unawaited(_health.flush());
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

  bool get _isCatalog =>
      _section == _Section.movies || _section == _Section.series;

  bool get _showsCatalogSort =>
      _section == _Section.movies || _section == _Section.series;

  CinemaCatalogSort get _currentCatalogSort =>
      _catalogSort[_section] ?? CinemaCatalogSort.latest;

  String get _catalogSortExplanation {
    if (_currentCatalogSort == CinemaCatalogSort.popular && !_searching) {
      return '按豆瓣近期热门顺序展示，卡片会自动检查片源；同片优先选择标记为 4K 的版本。';
    }
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

  bool _unifiedSearchSection(_Section section) =>
      Platform.isMacOS &&
      !NakuDevice.isTV &&
      (section == _Section.movies || section == _Section.series);

  bool _searchCategoryMatches(String name, _Section section) =>
      _unifiedSearchSection(section)
      ? _matchesCategory(name, _Section.movies) ||
            _matchesCategory(name, _Section.series)
      : _matchesCategory(name, section);

  bool _sameDiscoveryKind(CinemaTitle item, CinemaDiscoveryTitle title) {
    if (title.kind.isEmpty) return true;
    return title.kind == 'tv'
        ? _matchesCategory(item.category, _Section.series)
        : _matchesCategory(item.category, _Section.movies);
  }

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
    if (id == cinemaNASSource.id) return cinemaNASSource;
    if (id == cinemaDirectSource.id) return cinemaDirectSource;
    for (final source in _store.sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<void> _selectSection(_Section value) async {
    if (value == _section && !_showSourceManager) return;
    ++_sectionRevision;
    _scrollActivity.reset();
    setState(() {
      _section = value;
      if (value == _Section.anime) _animeOpened = true;
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
    if (!_isCatalog) return;
    final state = _catalog;
    final section = _section;
    final generation = ++state.generation;
    state.discoveryCancel?.cancel();
    if (_aggregates(section)) {
      _changed(state, () {
        state.searching = false;
        state.source = null;
        state.categories = [];
        state.categoryId = null;
      });
      await _aggregateFor(section).load(
        sources: _activeSources,
        kind: switch (section) {
          _Section.movies => CinemaAggregateKind.movies,
          _ => CinemaAggregateKind.series,
        },
        filters: state.filters,
        sort: _catalogSort[section] ?? CinemaCatalogSort.latest,
        refresh: refresh,
      );
      return;
    }
    final choices = _activeSources
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
        _changed(
          state,
          () => state.categoryId = _preferredCategory(state, section),
        );
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
    if (!_isCatalog) return;
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
    final sources = _activeSources
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
                          _searchCategoryMatches(t.category, section)),
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
                          _searchCategoryMatches(t.category, section)),
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
                          _searchCategoryMatches(t.category, section)) &&
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
    if (value.year != _catalog.filters.year) _catalog.yearWasChosen = true;
    if (_aggregates(_section) && !_searching) {
      _changed(_catalog, () => _catalog.filters = value);
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
    _changed(_catalog, () => _catalog.filters = value);
    if (_searching) unawaited(_preloadRatings(_section));
    if (category != null && category.id != _categoryId) {
      _changed(_catalog, () => _categoryId = category.id);
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
            (_unifiedSearchSection(section) ||
                section == _Section.anime ||
                title.kind.isEmpty ||
                (section == _Section.series
                    ? title.kind == 'tv'
                    : title.kind != 'tv')) &&
            !state.items.any(
              (item) =>
                  (title.id.isNotEmpty && item.doubanId == title.id) ||
                  (_sameDiscoveryKind(item, title) &&
                      cinemaSearchKey(item.title) ==
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

  Future<void> _openDoubanRecommendation(
    DoubanRecommendation recommendation,
  ) => _openTitle(
    CinemaDiscoveryTitle(
      id: recommendation.doubanId,
      title: recommendation.title,
      year: recommendation.year,
      poster: recommendation.poster,
      // The recommendation metadata does not declare film versus television.
      kind: '',
    ).metadata,
    keepBrowseRoute: true,
  );

  Future<void> _openTitle(
    CinemaTitle title, {
    CinemaHistory? resume,
    List<CinemaTitle> variants = const [],
    bool keepBrowseRoute = false,
  }) async {
    // Continue Watching should work immediately without catalogue access when
    // this exact episode has already been saved.
    if (resume != null) {
      try {
        final downloads = inject<DownloadController>();
        final route = resume.title.routes.elementAtOrNull(resume.routeIndex);
        final url = route?.episodes.elementAtOrNull(resume.episodeIndex)?.url;
        if (url != null) {
          for (final record in downloads.records.where((r) => r.isCinema)) {
            for (final episode in record.episodes.values) {
              if (episode.episodePageUrl != url ||
                  downloads.getLocalVideoPath(
                        record.bangumiId,
                        record.pluginName,
                        episode.episodeNumber,
                      ) ==
                      null) {
                continue;
              }
              final offline = CinemaOfflinePlayback.fromRecord(
                record,
                episode,
                (e) => downloads.getLocalVideoPath(
                  record.bangumiId,
                  record.pluginName,
                  e.episodeNumber,
                ),
              );
              if (offline?.title.key != resume.title.key) continue;
              _playOffline(record, episode);
              return;
            }
          }
        }
      } catch (_) {
        /* Invalid or unavailable downloads fall back to online. */
      }
    }
    if (title.sourceId == cinemaNASSource.id) {
      final saved = resume ?? _store.historyFor(title);
      _playTitle(
        title,
        cinemaNASSource,
        saved?.routeIndex ?? 0,
        saved?.episodeIndex ?? 0,
        const [],
      );
      return;
    }
    if (title.isDirectMedia) {
      final saved = resume ?? _store.historyFor(title);
      _playTitle(
        title,
        cinemaDirectSource,
        saved?.routeIndex ?? 0,
        saved?.episodeIndex ?? 0,
        const [],
      );
      return;
    }
    if (title.sourceId == 'douban-discovery' ||
        _findSource(title.sourceId) == null) {
      final cached = _resources.peek(title, _activeSources);
      final found = cached?.variants.isNotEmpty == true
          ? cached!.variants
          : await resolveCinemaDiscoverySources(
              context,
              anchor: title,
              sources: _activeSources,
              repository: _repository,
            );
      if (!mounted || found == null || found.isEmpty) return;
      final available = found
          .where((t) => _findSource(t.sourceId)?.enabled == true)
          .toList();
      if (available.isEmpty) return;
      final representative = groupCinemaTitles(
        [...available, title],
        sourcePriority: _store.enabledSources.map((s) => s.id).toList(),
      ).first.catalogTitle;
      await _openTitle(
        representative,
        variants: available,
        keepBrowseRoute: keepBrowseRoute,
      );
      return;
    }
    final source = _findSource(title.sourceId);
    if (source == null) {
      _toast('此片源已移除，请重新添加后播放。');
      return;
    }
    if (resume != null) {
      // A history click resumes saved media, not the details page's first item.
      try {
        final detail = await _repository.detail(source, title);
        if (!mounted) return;
        final selection = cinemaResumeSelection(detail, resume);
        if (selection != null) {
          _playTitle(
            detail,
            source,
            selection.routeIndex,
            selection.episodeIndex,
            variants,
            keepBrowseRoute: keepBrowseRoute,
            initialPositionSeconds: cinemaResumePosition(
              detail,
              resume,
              selection.routeIndex,
              selection.episodeIndex,
            ),
          );
          return;
        }
        _toast('历史集数无法与当前片源对应，请选择集数。');
      } catch (_) {
        if (!mounted) return;
        _toast('暂时无法刷新片源，请在详情中重试继续观看。');
      }
    }
    Widget buildDetails(BuildContext context) => _TitleDetails(
      title: title,
      source: source,
      variants: variants
          .where((v) => v.sourceId != 'douban-discovery')
          .toList(),
      ratingsRepository: widget.ratingsRepository,
      artworkRepository: widget.artworkRepository,
      repository: _repository,
      store: _store,
      resume: resume,
      onRecommendationSelected: (recommendation) {
        Navigator.pop(context);
        if (keepBrowseRoute) {
          unawaited(_openDoubanRecommendation(recommendation));
          return;
        }
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
        _playTitle(
          detail,
          selectedSource,
          road,
          episode,
          allVariants,
          keepBrowseRoute: keepBrowseRoute,
        );
      },
    );
    if (Platform.isMacOS && MediaQuery.sizeOf(context).width >= 900) {
      await showDialog<void>(
        context: context,
        barrierColor: const Color(0x22000000),
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 1320, child: buildDetails(context)),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(maxWidth: 1320),
        showDragHandle: false,
        builder: buildDetails,
      );
    }
    if (mounted) {
      setState(() {}); // Refresh poster summaries after rating edits.
    }
  }

  Future<void> _openAnimeHistory(History history) async {
    if (dialogs.isRunning) return;
    await dialogs.run((task) async {
      final token = RuleCancelToken();
      final result = await task.loading(
        message: '正在恢复动漫进度',
        barrierDismissible: true,
        onCancel: token.cancel,
        action: () =>
            inject<HistoryPlaybackService>().open(history, cancelToken: token),
      );
      switch (result) {
        case HistoryPlaybackReady(:final args):
          task.withContext(
            (context) => context.pushNamed('/video/', arguments: args),
          );
        case HistoryPlaybackUnavailable(:final reason):
          task.withContext(
            (context) =>
                context.pushNamed('/info/', arguments: history.bangumiItem),
          );
          _toast(reason);
      }
    }, errorMessage: '暂时无法继续播放，请重试');
  }

  void _toast(String message) {
    KazumiDialog.showToast(context: context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    if (_showsCatalogSort &&
        _currentCatalogSort == CinemaCatalogSort.rating &&
        !_scrollActivity.value &&
        _ratingRefresh == null &&
        !_ratingsChangedWhileScrolling) {
      // A regular tab/query/provider/data change establishes a fresh baseline.
      // Do not absorb pending score changes during an unrelated rebuild: the
      // scheduled refresh still owns their eventual re-sort after scrolling.
      _displayedRatingFingerprint = _ratingSortFingerprint();
    }
    return Theme(
      data: CinemaTheme.of(context),
      child: Builder(
        builder: (context) {
          final wide =
              NakuDevice.isTV || MediaQuery.sizeOf(context).width >= 860;
          if (wide && Platform.isMacOS && !NakuDevice.isTV) {
            return _desktopCinemaScaffold();
          }
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
                        padding: EdgeInsets.only(
                          left: Platform.isMacOS ? 96 : 24,
                          right: 24,
                        ),
                        child: Row(
                          children: [
                            Text(
                              NakuDevice.isTV ? 'NAKU · TV' : 'NAKU播放器',
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
                                  child: IndexedStack(
                                    index: _section == _Section.anime ? 1 : 0,
                                    children: [
                                      TickerMode(
                                        enabled: _section != _Section.anime,
                                        child: CinemaPaneTransition(
                                          destination: (
                                            _section,
                                            _showSourceManager,
                                          ),
                                          child: CinemaScrollNotifications(
                                            activity: _scrollActivity,
                                            child: _section == _Section.anime
                                                ? const SizedBox.shrink()
                                                : _content(wide),
                                          ),
                                        ),
                                      ),
                                      if (_animeOpened)
                                        TickerMode(
                                          enabled: _section == _Section.anime,
                                          child:
                                              widget.animePageBuilder?.call(
                                                context,
                                                _section == _Section.anime,
                                              ) ??
                                              CinemaAnimePage(
                                                initialTab: widget
                                                    .initialStartup
                                                    .animeTab
                                                    .index,
                                                active:
                                                    _section == _Section.anime,
                                              ),
                                        )
                                      else
                                        const SizedBox.shrink(),
                                    ],
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

  Widget _desktopCinemaScaffold() {
    final media = MediaQuery.of(context);
    return Scaffold(
      key: const ValueKey('cinema-mac-home-scaffold'),
      backgroundColor: CinemaTheme.background,
      body: CinemaCanvas(
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: IndexedStack(
                  index: _section == _Section.anime ? 1 : 0,
                  children: [
                    TickerMode(
                      enabled: _section != _Section.anime,
                      child: CinemaPaneTransition(
                        destination: (_section, _showSourceManager),
                        child: CinemaScrollNotifications(
                          activity: _scrollActivity,
                          child: _section == _Section.anime
                              ? const SizedBox.shrink()
                              : _content(true, topInset: 68),
                        ),
                      ),
                    ),
                    if (_animeOpened)
                      TickerMode(
                        enabled: _section == _Section.anime,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 68),
                          child:
                              widget.animePageBuilder?.call(
                                context,
                                _section == _Section.anime,
                              ) ??
                              CinemaAnimePage(
                                initialTab:
                                    widget.initialStartup.animeTab.index,
                                active: _section == _Section.anime,
                              ),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: CinemaHeaderFrost(),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 68,
                  child: Row(
                    children: [
                      if (_section == _Section.settings && _showSourceManager)
                        Padding(
                          padding: const EdgeInsets.only(left: 80),
                          child: IconButton(
                            tooltip: '返回设置',
                            onPressed: () =>
                                setState(() => _showSourceManager = false),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                        ),
                      Expanded(
                        child: Stack(
                          children: [
                            const Positioned.fill(
                              child: DragToMoveArea(child: SizedBox.expand()),
                            ),
                            Padding(
                              padding: EdgeInsets.only(
                                left:
                                    _section == _Section.settings &&
                                        _showSourceManager
                                    ? 12
                                    : 96,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: InkWell(
                                  onTap: _toggleWindowTranslucency,
                                  borderRadius: BorderRadius.circular(6),
                                  child: Text(
                                    'NAKU播放器  $_applicationVersion',
                                    key: const ValueKey('cinema-app-version'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: CinemaTheme.muted,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: (media.size.width * .28).clamp(220, 340),
                        child: TextField(
                          key: const ValueKey('cinema-unified-search'),
                          controller: _search,
                          onSubmitted: (_) => _submitDesktopSearch(),
                          decoration: InputDecoration(
                            isDense: true,
                            filled: false,
                            hintText: '搜索电影、剧集或演员',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 18,
                            ),
                            suffixIcon: IconButton(
                              tooltip: '搜索',
                              onPressed: _submitDesktopSearch,
                              icon: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 17,
                              ),
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0x50FFFFFF)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton.icon(
                        onPressed: _openNAS,
                        icon: const Icon(Icons.dns_outlined, size: 16),
                        label: const Text('NAS 影视'),
                      ),
                      if (Theme.of(context).platform == TargetPlatform.macOS)
                        IconButton(
                          key: const ValueKey('cinema-home-display-entry'),
                          tooltip: 'Home Display',
                          onPressed: _openHomeDisplay,
                          icon: const Icon(Icons.public_rounded, size: 19),
                        ),
                      if (NakuDevice.canDownload)
                        IconButton(
                          tooltip: '下载管理',
                          onPressed: () =>
                              context.pushNamed(DownloadPage.routePath),
                          icon: const Icon(
                            Icons.download_for_offline_outlined,
                            size: 19,
                          ),
                        ),
                      IconButton(
                        tooltip: '网页影院',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CinemaWebsitesPage(),
                          ),
                        ),
                        icon: const Icon(Icons.language_rounded, size: 19),
                      ),
                      IconButton(
                        tooltip: '豆瓣榜单',
                        onPressed: _openDouban,
                        icon: const Icon(Icons.leaderboard_outlined, size: 19),
                      ),
                      if (widget.enableWatchTogether)
                        ListenableBuilder(
                          listenable: _together,
                          builder: (context, _) => IconButton(
                            key: const ValueKey('watch-together-entry'),
                            tooltip: 'NAS 用户配对',
                            onPressed: () => showCinemaSyncSheet(
                              context,
                              coordinator: _together,
                            ),
                            icon: Icon(
                              Icons.people_outline_rounded,
                              size: 19,
                              color: _together.isPaired
                                  ? CinemaTheme.copper
                                  : CinemaTheme.muted,
                            ),
                          ),
                        ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_horiz_rounded, size: 20),
                        onSelected: (value) {
                          switch (value) {
                            case 'sources':
                              _openSourceSettings();
                            case 'tools':
                              _openTools();
                            case 'appearance':
                              showCinemaAppearanceSheet(context);
                            case 'update':
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const NakuUpdatePage(),
                                ),
                              );
                            case 'about':
                              showAboutDialog(
                                context: context,
                                applicationName: 'NAKU播放器',
                                applicationVersion: _applicationVersion,
                                applicationLegalese: '基于 Kazumi · GPL-3.0',
                                children: [
                                  TextButton(
                                    onPressed: () => launchUrl(
                                      Uri.parse(
                                        NakuUpdateService.repositoryUrl,
                                      ),
                                    ),
                                    child: const Text('NAKU播放器源代码'),
                                  ),
                                  TextButton(
                                    onPressed: () => launchUrl(
                                      Uri.parse(
                                        'https://github.com/Predidit/Kazumi',
                                      ),
                                    ),
                                    child: const Text('查看 Kazumi 开源项目'),
                                  ),
                                ],
                              );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'sources', child: Text('片源管理')),
                          PopupMenuItem(value: 'tools', child: Text('影视工具')),
                          PopupMenuItem(value: 'appearance', child: Text('外观')),
                          PopupMenuItem(value: 'update', child: Text('检查更新')),
                          PopupMenuItem(value: 'about', child: Text('关于 NAKU')),
                        ],
                      ),
                      const SizedBox(width: 18),
                    ],
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 100,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xA6080B10)],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 16,
                child: Center(
                  child: CinemaNavigationIsland<_Section>(
                    key: const ValueKey('cinema-floating-island'),
                    value: _section,
                    onChanged: _selectSection,
                    keyFor: (section) =>
                        ValueKey('cinema-destination-${section.name}'),
                    destinations: [
                      (_Section.movies, Icons.local_movies_outlined, '电影'),
                      (_Section.series, Icons.tv_rounded, '剧集'),
                      if (_showAnimeDestination)
                        (_Section.anime, Icons.animation_rounded, '动漫'),
                      (
                        _Section.favorites,
                        Icons.bookmark_border_rounded,
                        '我的收藏',
                      ),
                      (_Section.history, Icons.history_rounded, '继续观看'),
                      (_Section.settings, Icons.settings_outlined, '设置'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleWindowTranslucency() async {
    final controls = widget.windowControls ?? DesktopWindowControls.instance;
    await controls.initialize();
    if (!mounted || controls.saving) return;
    final updated = await controls.update(
      controls.preferences.copyWith(
        translucent: !controls.preferences.translucent,
      ),
    );
    if (!updated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controls.error ?? '窗口透明度未生效，请重试。')),
      );
    }
  }

  void _showDesktopAbout() => showAboutDialog(
    context: context,
    applicationName: 'NAKU播放器',
    applicationVersion: _applicationVersion,
    applicationLegalese: '基于 Kazumi · GPL-3.0',
    children: [
      TextButton(
        onPressed: () => launchUrl(Uri.parse(NakuUpdateService.repositoryUrl)),
        child: const Text('NAKU播放器源代码'),
      ),
      TextButton(
        onPressed: () =>
            launchUrl(Uri.parse('https://github.com/Predidit/Kazumi')),
        child: const Text('查看 Kazumi 开源项目'),
      ),
    ],
  );

  Future<void> _submitDesktopSearch() async {
    final submission = ++_desktopSearchRevision;
    final query = _search.text;
    if (!_isCatalog) {
      final target = _catalogs[_Section.movies]!;
      final opening = _selectSection(_Section.movies);
      final navigation = _sectionRevision;
      final generation = target.generation;
      // Show the submitted query on its destination immediately. A later
      // catalogue reply must never write through the current-page getter.
      target.search.text = query;
      await opening;
      if (!mounted ||
          submission != _desktopSearchRevision ||
          navigation != _sectionRevision ||
          !identical(target, _catalog) ||
          generation != target.generation ||
          target.search.text != query) {
        return;
      }
    }
    await _runSearch();
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
        if (NakuDevice.isTV)
          ListenableBuilder(
            listenable: CinemaLanCast.instance,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                CinemaLanCast.instance.status,
                style: const TextStyle(fontSize: 12, color: CinemaTheme.muted),
              ),
            ),
          ),
        const SizedBox(height: 28),
        for (final section in _Section.values.where(
          (s) => s != _Section.anime || _showAnimeDestination,
        )) ...[
          if (section == _Section.favorites)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              child: Divider(),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: ListTile(
              key: ValueKey('cinema-destination-${section.name}'),
              autofocus: NakuDevice.isTV && _section == section,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.dns_outlined, size: 20),
            title: const Text('NAS 影视', style: TextStyle(fontSize: 14)),
            onTap: () {
              if (closeDrawer) Navigator.pop(context);
              _openNAS();
            },
          ),
        ),
        if (Theme.of(context).platform == TargetPlatform.macOS)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.public_rounded, size: 20),
              title: const Text('Home Display', style: TextStyle(fontSize: 14)),
              onTap: () {
                if (closeDrawer) Navigator.pop(context);
                _openHomeDisplay();
              },
            ),
          ),
        if (NakuDevice.canDownload)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            child: ListTile(
              dense: true,
              leading: const Icon(
                Icons.download_for_offline_outlined,
                size: 20,
              ),
              title: const Text('下载管理', style: TextStyle(fontSize: 14)),
              onTap: () {
                if (closeDrawer) Navigator.pop(context);
                context.pushNamed(DownloadPage.routePath);
              },
            ),
          ),
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
                title: const Text('NAS 用户配对', style: TextStyle(fontSize: 14)),
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
              _openDouban();
            },
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 12, 20, 25),
          child: InkWell(
            onTap: Platform.isMacOS
                ? _toggleWindowTranslucency
                : _showDesktopAbout,
            child: Text(
              'NAKU播放器  $_applicationVersion',
              key: const ValueKey('cinema-app-version'),
              style: const TextStyle(
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

  Widget _catalogSortControls({bool compact = false}) => Padding(
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
                  CinemaCatalogSort.popular => _searching ? '热度' : '近期热门',
                  CinemaCatalogSort.latest => '最新',
                  CinemaCatalogSort.rating => '评分',
                }),
                selected: _currentCatalogSort == sort,
                showCheckmark: !compact,
                backgroundColor: compact ? Colors.transparent : null,
                selectedColor: compact
                    ? const Color(0x14FFFFFF)
                    : CinemaTheme.copper.withValues(alpha: .18),
                labelStyle: compact
                    ? TextStyle(
                        color: _currentCatalogSort == sort
                            ? CinemaTheme.text
                            : CinemaTheme.muted,
                        fontWeight: _currentCatalogSort == sort
                            ? FontWeight.w600
                            : FontWeight.w400,
                      )
                    : null,
                side: BorderSide.none,
                onSelected: (_) {
                  if (_currentCatalogSort == sort) return;
                  setState(() {
                    _catalogSort[_section] = sort;
                    if (sort == CinemaCatalogSort.popular &&
                        !_catalog.yearWasChosen) {
                      _catalog.filters = _catalog.filters.copyWith(year: '');
                    }
                  });
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
            if (compact)
              Tooltip(
                message: _catalogSortExplanation,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: CinemaTheme.muted,
                  ),
                ),
              ),
            if (!compact)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  switch (_currentCatalogSort) {
                    CinemaCatalogSort.popular =>
                      _searching ? '已加载资源 · 片源热度' : '豆瓣 · 近期热门',
                    CinemaCatalogSort.latest => '已加载作品 · 片源更新时间',
                    CinemaCatalogSort.rating => '已加载作品 · 评分从高到低',
                  },
                  style: const TextStyle(
                    fontSize: 11,
                    color: CinemaTheme.muted,
                  ),
                ),
              ),
          ],
        ),
        if (!compact) const SizedBox(height: 7),
        if (!compact)
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
    sourcePriority: _store.enabledSources.map((s) => s.id).toList(),
    sort:
        _showsCatalogSort &&
            !(!_searching && _currentCatalogSort == CinemaCatalogSort.popular)
        ? _currentCatalogSort
        : null,
    provider: _scoreProvider,
    ratingRevision: _ratingRevision,
    scoreOf: (title) => _ratings.scoreFor(title, _scoreProvider),
  );

  Widget _content(bool wide, {double topInset = 0}) {
    if (topInset > 0 && !_isCatalog) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: _content(wide),
      );
    }
    if (_section == _Section.settings) {
      if (_showSourceManager) return _sourceManager(wide);
      return CinemaSettingsPage(
        navigationPreferences: _navigationPreferences,
        platform: Platform.isAndroid
            ? TargetPlatform.android
            : Platform.isMacOS
            ? TargetPlatform.macOS
            : TargetPlatform.windows,
        enabledSourceCount: _store.enabledSources
            .where((source) => source.kind == CinemaSourceKind.maccms)
            .length,
        sourceCount: _store.sources
            .where((source) => source.kind == CinemaSourceKind.maccms)
            .length,
        onSources: () => setState(() => _showSourceManager = true),
        onTools: _openTools,
        onAppearance: () => showCinemaAppearanceSheet(context),
        onUpdates: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const NakuUpdatePage())),
      );
    }
    if (_section == _Section.favorites || _section == _Section.history) {
      return CinemaUnifiedLibrary(
        key: ValueKey(_section),
        store: _store,
        anime: _animeLibrary,
        history: _section == _Section.history,
        filters: _catalog.filters,
        onFilters: (value) => setState(() => _catalog.filters = value),
        titleCard: _titleCard,
        poster: _poster,
        onCinemaPlay: (record) => _openTitle(record.title, resume: record),
        onAnimePlay: _openAnimeHistory,
        sourceName: (id) => _findSource(id)?.name ?? '已移除的片源',
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
    final immersive = wide && Platform.isMacOS && !NakuDevice.isTV;
    final featured = immersive && aggregated && visibleItems.length >= 8
        ? visibleItems.take(4).toList()
        : <CinemaTitle>[];
    final featuredKeys = featured.map((title) => title.key).toSet();
    final wallItems = featured.isEmpty
        ? visibleItems
        : visibleItems
              .where((title) => !featuredKeys.contains(title.key))
              .toList();
    final wallIndices = {
      for (var index = 0; index < wallItems.length; index++)
        wallItems[index].key: index,
    };
    // SliverLayoutBuilder receives new scrollOffset/cache constraints on every
    // scroll frame. Keep the child delegate stable within this catalogue build
    // so those geometry updates do not rebuild every mounted poster, rating and
    // resource badge. Data, sorting and filtering create a fresh delegate here.
    final wallChildren = SliverChildBuilderDelegate(
      (context, index) => _titleCard(
        wallItems[index],
        variants: variantsByKey[wallItems[index].key] ?? const [],
      ),
      childCount: wallItems.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> && key.value.startsWith('title-card:')
          ? wallIndices[key.value.substring('title-card:'.length)]
          : null,
    );
    // Keep this widget stable across scroll-only sliver constraint updates.
    final featuredWall = featured.isEmpty
        ? null
        : CinemaFeaturedWall(
            key: ValueKey('cinema-featured-${_section.name}'),
            topInset: topInset,
            titles: featured,
            artworkRepository: widget.artworkRepository,
            artworkChanges: _ratings.changes,
            artworkIdentity: (title) =>
                _ratings.peek(title)?.identity ?? const RatingIdentity(),
            onOpen: (title) => _openTitle(
              title,
              variants: variantsByKey[title.key] ?? const [],
            ),
            statusBuilder: (title) => Align(
              alignment: Alignment.centerLeft,
              child: CinemaResourceBadge(
                title: title,
                sources: _activeSources,
                service: _resources,
              ),
            ),
          );
    return CustomScrollView(
      key: PageStorageKey(_catalogViewportKey),
      slivers: [
        if (featured.isEmpty && topInset > 0)
          SliverToBoxAdapter(child: SizedBox(height: topInset)),
        if (featuredWall != null)
          SliverLayoutBuilder(
            builder: (context, constraints) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: ConstrainedBox(
                  // The 60px floating navigation sits 16px from the bottom.
                  // Leave another 20px so the hero action stays clear of it.
                  constraints: BoxConstraints(
                    maxHeight: (constraints.viewportMainAxisExtent - 96).clamp(
                      0.0,
                      double.infinity,
                    ),
                  ),
                  child: featuredWall,
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (aggregated) ...[
                  Row(
                    children: [
                      Text(
                        immersive ? _heading : '全部片源',
                        style: TextStyle(
                          color: CinemaTheme.muted,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      if (immersive) _catalogStatusMenu(snapshot!),
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
                  if (!immersive) ...[
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
                            items: _activeSources
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
                              _changed(_catalog, () {
                                _source = _findSource(id!);
                                _categories = [];
                                _categoryId = null;
                              });
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
                                    _changed(
                                      _catalog,
                                      () => _categoryId = c.id,
                                    );
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
                  compact: immersive,
                  value: _catalog.filters,
                  items: aggregated ? representatives : _items,
                  onChanged: _changeCatalogueFilters,
                  scope: _searching
                      ? '当前搜索结果'
                      : aggregated
                      ? '聚合目录'
                      : '已加载片源目录',
                ),
                if (_showsCatalogSort) _catalogSortControls(compact: immersive),
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
                final columns =
                    (constraints.crossAxisExtent / (immersive ? 205 : 165))
                        .floor()
                        .clamp(2, immersive ? 7 : 6);
                return SliverGrid(
                  delegate: wallChildren,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 24,
                    childAspectRatio: immersive ? .57 : .51,
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
        if (immersive) const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _poster(CinemaTitle title, double? width, double? height) =>
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          boxShadow: Platform.isMacOS && !NakuDevice.isTV
              ? const [
                  BoxShadow(
                    color: Color(0x50000000),
                    blurRadius: 22,
                    spreadRadius: -3,
                    offset: Offset(0, 9),
                  ),
                ]
              : const [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: SizedBox(
            width: width,
            height: height,
            child: title.poster.isEmpty
                ? _posterFallback(title.title)
                : CachedNetworkImage(
                    cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
                    memCacheWidth: 480,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    imageUrl: title.poster,
                    httpHeaders: title.sourceId == 'douban-discovery'
                        ? doubanImageHeaders
                        : null,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _posterFallback(title.title),
                    errorWidget: (_, _, _) => _posterFallback(title.title),
                  ),
          ),
        ),
      );

  Widget _posterFallback(String name) => LayoutBuilder(
    builder: (context, bounds) => bounds.maxWidth < 96 || bounds.maxHeight < 100
        ? ColoredBox(
            color: CinemaTheme.raised,
            child: const Center(
              child: Icon(
                Icons.local_movies_outlined,
                size: 24,
                color: CinemaTheme.copper,
              ),
            ),
          )
        : Container(
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
                  style: const TextStyle(
                    color: CinemaTheme.muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
  );

  Widget _posterCardSurface({required Widget child}) =>
      Platform.isMacOS && !NakuDevice.isTV
      ? child
      : CinemaGlass(
          blur: false,
          radius: 14,
          padding: const EdgeInsets.all(7),
          child: child,
        );

  Widget _catalogStatusMenu(CinemaAggregateSnapshot snapshot) =>
      PopupMenuButton<void>(
        tooltip: '片源状态',
        icon: const Icon(
          Icons.info_outline_rounded,
          size: 17,
          color: CinemaTheme.muted,
        ),
        itemBuilder: (_) => [
          PopupMenuItem<void>(
            enabled: false,
            child: SizedBox(
              width: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    snapshot.message,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CinemaTheme.text,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final status in snapshot.sources)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Tooltip(
                        message: status.error ?? status.source.name,
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: CinemaTheme.muted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _titleCard(
    CinemaTitle title, {
    List<CinemaTitle> variants = const [],
  }) => CinemaTVFocus(
    child: InkWell(
      key: ValueKey('title-card:${title.key}'),
      onTap: () => _openTitle(title, variants: variants),
      borderRadius: BorderRadius.circular(10),
      child: _posterCardSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _poster(title, null, null),
                  if (title.sourceId == 'douban-discovery' ||
                      (_isCatalog && !_searching))
                    Positioned(
                      top: 8,
                      left: 8,
                      right: 8,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: CinemaResourceBadge(
                          title: title,
                          sources: _activeSources,
                          service: _resources,
                        ),
                      ),
                    ),
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
              cinemaMediaBaseTitle(title.title),
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
            if (!title.isDirectMedia)
              CinemaCardRatings(
                title: title,
                repository: _ratings,
                resolveTitle: _ratingTitles.resolve,
              ),
          ],
        ),
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

  Widget _sourceManager(bool wide) {
    final sources = _store.sources
        .where((s) => s.kind == CinemaSourceKind.maccms)
        .toList();
    return ReorderableListView(
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) async {
        final ids = sources.map((s) => s.id).toList();
        ids.insert(newIndex, ids.removeAt(oldIndex));
        try {
          await _store.reorderMovieSources(ids);
        } catch (error) {
          if (mounted) _toast('保存顺序失败：$error');
        }
      },
      padding: EdgeInsets.fromLTRB(wide ? 36 : 18, 8, wide ? 36 : 18, 36),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('片源管理', style: TextStyle(fontSize: 21)),
              ),
              FilledButton.icon(
                onPressed: () => _editSource(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加接口'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _health.probing
                    ? _health.cancelProbes
                    : () {
                        unawaited(
                          _health.probeAll(sources, (source) async {
                            final probe = CinemaRepository();
                            await probe.categories(source);
                          }),
                        );
                      },
                icon: Icon(
                  _health.probing
                      ? Icons.stop_circle_outlined
                      : Icons.monitor_heart_outlined,
                ),
                label: Text(
                  _health.probing
                      ? '停止探活 ${_health.completed}/${_health.total}'
                      : '检测全部片源',
                ),
              ),
              OutlinedButton.icon(
                onPressed: _openTools,
                icon: const Icon(Icons.rss_feed),
                label: const Text('订阅与批量导入'),
              ),
            ],
          ),
          if (_health.probing) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          const Text(
            '拖动左侧手柄调整优先级，越靠前越优先播放，失效时依次换源。动漫规则在动漫 → 更多 → 规则管理中维护。',
            style: TextStyle(
              fontSize: 12,
              height: 1.8,
              color: CinemaTheme.muted,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            MacOSSystemProxy.description,
            style: const TextStyle(fontSize: 11, color: CinemaTheme.muted),
          ),
          const SizedBox(height: 22),
        ],
      ),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => context.pushNamed('/settings/plugin/'),
                icon: const Icon(Icons.data_object, size: 18),
                label: const Text('动漫规则管理'),
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
      ),
      children: [
        for (final (index, source) in sources.indexed)
          Container(
            key: ValueKey('source-order:${source.id}'),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: CinemaTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Platform.isMacOS
                  ? null
                  : Border.all(color: CinemaTheme.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: Tooltip(
                      message: '拖动调整播放优先级',
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_handle_rounded,
                          color: CinemaTheme.copper,
                        ),
                      ),
                    ),
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
                          '接口：${_health.record(source)?.label ?? '未检测'}${_health.cooling(source) ? ' · 临时冷却' : ''}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: CinemaTheme.muted,
                          ),
                        ),
                        if (_health.record(source, media: true)
                            case final media?)
                          Text(
                            '视频：${media.label}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: CinemaTheme.muted,
                            ),
                          ),

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
                  IconButton(
                    tooltip: '健康记录',
                    icon: const Icon(Icons.monitor_heart_outlined, size: 19),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('${source.name} · 健康记录'),
                        content: SizedBox(
                          width: 520,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final media in [false, true]) ...[
                                  Text(media ? '实际视频' : '目录接口'),
                                  if (_health
                                      .history(source, media: media)
                                      .isEmpty)
                                    const Text('尚无记录'),
                                  for (final event in _health.history(
                                    source,
                                    media: media,
                                  ))
                                    ListTile(
                                      dense: true,
                                      leading: Icon(
                                        event.ok
                                            ? Icons.check_circle_outline
                                            : Icons.error_outline,
                                        color: event.ok
                                            ? CinemaTheme.copper
                                            : CinemaTheme.muted,
                                      ),
                                      title: Text(event.label),
                                      subtitle: Text(
                                        '${event.checkedAt.toLocal()}',
                                      ),
                                    ),
                                  const Divider(),
                                ],
                              ],
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_health.cooling(source))
                    IconButton(
                      tooltip: '解除临时冷却并重试',
                      onPressed: () => _health.restore(source),
                      icon: const Icon(Icons.restart_alt),
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
                        KazumiDialog.showToast(
                          context: context,
                          message: '已移除 ${source.name}',
                          showActionButton: true,
                          actionLabel: '撤销',
                          onActionPressed: () async {
                            try {
                              await _store.saveSource(source);
                            } catch (error) {
                              if (mounted) _toast('恢复片源失败：$error');
                            }
                          },
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
      ],
    );
  }

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
                  _toast('已导入 ${sources.length} 条规则；动漫规则请在动漫的规则管理中导入');
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
    this.artworkRepository,
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
  final CinemaDetailArtworkRepository? artworkRepository;
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
  int _informationTab = 0;
  CinemaTitle? _resolvedInput, _resolvedTitle;
  late List<CinemaTitle> _variants = [
    widget.title,
    ...widget.variants.where((v) => v.key != widget.title.key),
  ];
  bool _discovering = true, _discoveryFailed = false;
  bool _variantChosen = false;
  bool _routeChosen = false;
  StreamSubscription<List<CinemaTitle>>? _discoverySubscription;
  ImageStream? _posterStream;
  ImageStreamListener? _posterListener;
  ImageProvider<Object>? _posterProvider;
  List<Color> _posterPalette = const [];
  String? _posterIdentity;
  CancelToken? _artworkCancel;
  bool _posterTerminal = false, _posterFailed = false, _attachingPoster = false;
  bool _posterLimited = false;
  bool _ratingsTerminal = false, _presentationReady = false, _disposing = false;
  bool _scoresTerminal = false, _informationTerminal = false;
  CinemaTitle? _ratingsTitle;
  int _detailGeneration = 0, _ratingTicket = 0, _posterTicket = 0;
  @override
  void initState() {
    super.initState();
    _artworkRatings.changes.addListener(_onArtworkIdentityChanged);
    _variants = orderCinemaVariants(
      _variants,
      widget.store.enabledSources.map((source) => source.id),
    );
    if (widget.resume == null && _variants.isNotEmpty) {
      _selectVariant(_variants.first, automatic: true);
    }
    _discover();
  }

  void _discover() {
    _discoverySubscription =
        discoverCinemaWorkSources(
          anchor: widget.title,
          known: _variants,
          sources: widget.store.enabledSources,
          repository: widget.repository,
          isCurrent: () => mounted && !_disposing,
          onSourceError: (source, error) {
            if (mounted && !_disposing) setState(() => _discoveryFailed = true);
          },
        ).listen(
          (variants) {
            if (!mounted || _disposing) return;
            final priority = widget.store.enabledSources
                .map((s) => s.id)
                .toList();
            setState(() => _variants = orderCinemaVariants(variants, priority));
            if (!_variantChosen &&
                widget.resume == null &&
                _variants.isNotEmpty) {
              final preferred = _variants.first;
              if (preferred.key != _selectedTitle.key &&
                  orderCinemaVariants([
                        preferred,
                        _selectedTitle,
                      ], priority).first.key ==
                      preferred.key) {
                _selectVariant(preferred, automatic: true);
              }
            }
          },
          onDone: () {
            if (mounted && !_disposing) setState(() => _discovering = false);
          },
          onError: (Object error, StackTrace stack) {
            if (mounted && !_disposing) {
              setState(() {
                _discovering = false;
                _discoveryFailed = true;
              });
            }
          },
        );
  }

  void _detachPoster() {
    final listener = _posterListener;
    if (listener != null) _posterStream?.removeListener(listener);
    _posterListener = null;
    _posterStream = null;
  }

  CinemaRatingsRepository get _artworkRatings =>
      widget.ratingsRepository ?? CinemaRatingsRepository.instance;

  void _onArtworkIdentityChanged() {
    if (!mounted || _disposing) return;
    final title = _ratingsTitle ?? _selectedTitle;
    final identity =
        _artworkRatings.peek(title)?.identity ?? const RatingIdentity();
    if (CinemaDetailArtworkRepository.identityKey(title, identity) !=
        _posterIdentity) {
      setState(() {});
    }
  }

  void _watchPoster(CinemaTitle title, {bool force = false}) {
    final identity =
        (widget.ratingsRepository ?? CinemaRatingsRepository.instance)
            .peek(title)
            ?.identity ??
        const RatingIdentity();
    final key = CinemaDetailArtworkRepository.identityKey(title, identity);
    if (!force && _posterIdentity == key) return;
    _artworkCancel?.cancel('Selected artwork changed');
    _detachPoster();
    _posterIdentity = key;
    final ticket = ++_posterTicket;
    _posterTerminal = false;
    _posterFailed = false;
    _posterLimited = false;
    _presentationReady = false;
    _posterProvider = null;
    _posterPalette = const [];
    final cancel = _artworkCancel = CancelToken();
    bool current() => mounted && !_disposing && ticket == _posterTicket;
    (widget.artworkRepository ?? CinemaDetailArtworkRepository.instance)
        .resolveLandscape(
          title,
          identity: identity,
          cancelToken: cancel,
          isCurrent: current,
          force: force,
        )
        .then(
          (artwork) {
            if (!current()) return;
            _attachPoster(title, artwork, ticket);
            if (current()) setState(() {});
          },
          onError: (Object error, StackTrace stack) {
            if (!current()) return;
            _attachPoster(title, const CinemaDetailArtwork(url: ''), ticket);
            if (current()) setState(() {});
          },
        );
  }

  void _attachPoster(
    CinemaTitle title,
    CinemaDetailArtwork artwork,
    int ticket, {
    bool fallback = false,
  }) {
    _detachPoster();
    final existingPoster = [
      title.poster,
      _selectedTitle.poster,
      widget.title.poster,
    ].where((url) => url.isNotEmpty).firstOrNull;
    if (!fallback && !artwork.usableLandscape) {
      final url = artwork.url.isNotEmpty ? artwork.url : existingPoster;
      if (url != null && url.isNotEmpty) {
        _attachPoster(
          title,
          CinemaDetailArtwork(url: url),
          ticket,
          fallback: true,
        );
        return;
      }
    }
    if (artwork.url.isEmpty) {
      _posterProvider = null;
      _posterTerminal = true;
      _posterLimited = true;
      return;
    }
    // The file's original dimensions were checked before selecting HD. Fit
    // preserves them and caps decode memory; it never manufactures pixels.
    _posterProvider = ResizeImage(
      CachedNetworkImageProvider(
        artwork.url,
        cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
        headers: artwork.headers.isEmpty ? null : artwork.headers,
      ),
      width: 3200,
      height: 2400,
      policy: ResizeImagePolicy.fit,
    );
    final stream = _posterStream = _posterProvider!.resolve(
      createLocalImageConfiguration(context),
    );
    void terminal({required bool failed}) {
      if (!mounted || _disposing || ticket != _posterTicket) return;
      if (failed &&
          !fallback &&
          existingPoster != null &&
          existingPoster != artwork.url) {
        _attachPoster(
          title,
          CinemaDetailArtwork(url: existingPoster),
          ticket,
          fallback: true,
        );
        if (!_attachingPoster) setState(() {});
        return;
      }
      _posterTerminal = true;
      _posterFailed = failed;
      _posterLimited = !failed && (fallback || !artwork.highResolution);
      _detachPoster();
      if (!_attachingPoster) setState(() {});
    }

    final listener = _posterListener = ImageStreamListener((
      frame,
      synchronousCall,
    ) {
      // This clones the frame before the listener releases it, and only reads
      // back a 36x24 thumbnail once. Motion never samples artwork pixels.
      unawaited(_samplePosterPalette(frame.image, ticket));
      frame.dispose();
      terminal(failed: false);
    }, onError: (Object error, StackTrace? stack) => terminal(failed: true));
    _attachingPoster = true;
    stream.addListener(listener);
    _attachingPoster = false;
  }

  Future<void> _samplePosterPalette(ui.Image image, int ticket) async {
    try {
      final palette = await cinemaPosterPalette(image);
      if (!mounted || _disposing || ticket != _posterTicket) return;
      setState(() => _posterPalette = palette);
    } catch (_) {
      // Artwork remains usable even if a platform cannot read back colors.
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _artworkRatings.changes.removeListener(_onArtworkIdentityChanged);
    _ratingTicket++;
    _posterTicket++;
    _artworkCancel?.cancel('Detail disposed');
    _detachPoster();
    unawaited(_discoverySubscription?.cancel());
    super.dispose();
  }

  void _selectVariant(CinemaTitle variant, {bool automatic = false}) {
    if (!automatic) _variantChosen = true;
    if (variant.key == _selectedTitle.key) return;
    final source = widget.store.sources
        .where((s) => s.id == variant.sourceId)
        .firstOrNull;
    if (source == null) return;
    setState(() {
      _detailGeneration++;
      _ratingTicket++;
      _ratingsTitle = null;
      _ratingsTerminal = false;
      _scoresTerminal = false;
      _informationTerminal = false;
      _presentationReady = false;
      _posterTicket++;
      _artworkCancel?.cancel('Selected source changed');
      _posterIdentity = null;
      _posterProvider = null;
      _posterPalette = const [];
      _detachPoster();
      _selectedTitle = variant;
      _selectedSource = source;
      _road = 0;
      _routeChosen = false;
      _detail = automatic && variant.routes.isNotEmpty
          ? Future.value(variant)
          : widget.repository.detail(source, variant);
    });
  }

  /// Catalogue quality labels choose a starting route; the existing player
  /// probes the stream and handles source failover after playback begins.
  int _preferredRoad(CinemaTitle title) {
    if (_routeChosen &&
        _road < title.routes.length &&
        title.routes[_road].episodes.isNotEmpty) {
      return _road;
    }
    int quality(String name) {
      if (RegExp(r'4k|2160|uhd|蓝光原盘', caseSensitive: false).hasMatch(name)) {
        return 3;
      }
      if (RegExp(r'1080|fhd|蓝光', caseSensitive: false).hasMatch(name)) return 2;
      if (RegExp(r'720|高清', caseSensitive: false).hasMatch(name)) return 1;
      return 0;
    }

    var best = -1;
    for (var index = 0; index < title.routes.length; index++) {
      if (title.routes[index].episodes.isEmpty) continue;
      if (best < 0 ||
          quality(title.routes[index].name) >
              quality(title.routes[best].name)) {
        best = index;
      }
    }
    return best;
  }

  Widget _actions(CinemaTitle title, AsyncSnapshot<CinemaTitle> snapshot) {
    final playable = snapshot.hasData && _preferredRoad(title) >= 0;
    final route = title.routes.isEmpty
        ? 0
        : (_routeChosen ? _road : _preferredRoad(title)).clamp(
            0,
            title.routes.length - 1,
          );
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const ValueKey('cinema-detail-primary-play'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF111114),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          ),
          onPressed: playable
              ? () => widget.onPlay(
                  title,
                  _selectedSource,
                  _preferredRoad(title),
                  0,
                  _variants,
                )
              : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 25),
          label: const Text('开始观看'),
        ),
        if (NakuDevice.canDownload && playable)
          IconButton(
            tooltip: '下载',
            onPressed: () => showCinemaDownloadSheet(
              context,
              title: title,
              source: _selectedSource,
              routeIndex: route,
            ),
            icon: const Icon(Icons.download_rounded, size: 21),
          ),
        IconButton(
          tooltip: widget.store.isFavorite(title) ? '取消收藏' : '收藏',
          onPressed: () async {
            await widget.store.toggleFavorite(title);
            if (mounted) setState(() {});
          },
          icon: Icon(
            widget.store.isFavorite(title)
                ? Icons.bookmark_rounded
                : Icons.bookmark_border_rounded,
            size: 20,
          ),
        ),
        if (Platform.isAndroid && !NakuDevice.isTV && playable)
          IconButton(
            tooltip: '发送到电视',
            onPressed: () => showCinemaCast(
              context,
              title: title,
              source: _selectedSource,
              road: route,
            ),
            icon: const Icon(Icons.cast, size: 20),
          ),
        if (widget.resume != null &&
            widget.resume!.title.key == _selectedTitle.key &&
            snapshot.hasData &&
            title.routes.isNotEmpty)
          TextButton.icon(
            onPressed: () {
              final selection = cinemaResumeSelection(title, widget.resume!);
              if (selection == null) {
                KazumiDialog.showToast(
                  context: context,
                  message: '片源的线路或集数已变化，请在下方重新选择。',
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
            icon: const Icon(Icons.history_rounded, size: 18),
            label: const Text('继续观看'),
          ),
      ],
    );
  }

  Widget _sourceControls(
    CinemaTitle title,
    AsyncSnapshot<CinemaTitle> snapshot,
  ) {
    final road = title.routes.isEmpty
        ? 0
        : (_routeChosen ? _road : _preferredRoad(title)).clamp(
            0,
            title.routes.length - 1,
          );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectedSource.name,
                  style: const TextStyle(
                    color: CinemaTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_discovering)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
            ],
          ),
          if (_variants.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final variant in _variants)
                  ChoiceChip(
                    key: ValueKey('source-variant:${variant.key}'),
                    showCheckmark: false,
                    side: BorderSide.none,
                    backgroundColor: Colors.transparent,
                    selectedColor: Colors.white.withValues(alpha: .08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    label: Text(
                      [
                        widget.store.sources
                                .where((s) => s.id == variant.sourceId)
                                .firstOrNull
                                ?.name ??
                            '已移除片源',
                        if (_variants
                                .where((v) => v.sourceId == variant.sourceId)
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
          ],
          if (_discoveryFailed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '部分片源暂未返回，可继续使用已加载线路',
                style: TextStyle(color: CinemaTheme.muted, fontSize: 11),
              ),
            ),
          if (snapshot.connectionState != ConnectionState.done) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (snapshot.hasError) ...[
            const SizedBox(height: 12),
            Text(
              '片源加载失败：${snapshot.error}',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
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
          if (snapshot.hasData && title.routes.isEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              '这个结果暂未提供可播放线路，可尝试其他片源。',
              style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
            ),
          ],
          if (snapshot.hasData && title.routes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var r = 0; r < title.routes.length; r++)
                  ChoiceChip(
                    showCheckmark: false,
                    side: BorderSide.none,
                    backgroundColor: Colors.transparent,
                    selectedColor: Colors.white.withValues(alpha: .08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    label: Text(title.routes[r].name),
                    selected: road == r,
                    onSelected: (_) => setState(() {
                      _variantChosen = true;
                      _routeChosen = true;
                      _road = r;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var e = 0; e < title.routes[road].episodes.length; e++)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: CinemaTheme.text,
                    ),
                    onPressed: () => widget.onPlay(
                      title,
                      _selectedSource,
                      road,
                      e,
                      _variants,
                    ),
                    child: Text(title.routes[road].episodes[e].name),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _metadata(CinemaTitle title, {required bool cast}) {
    final values = cast
        ? {'导演': title.director, '演员 / 配音': title.actors}
        : {
            '地区': title.area,
            '语言': title.language,
            '类型': title.genres,
            '上映': title.releaseDateText,
            '片长': RegExp(r'^\d+$').hasMatch(title.durationText)
                ? '${title.durationText} 分钟'
                : title.durationText,
            '又名': title.aliases,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cast && values.values.every((value) => value.isEmpty))
          const Text(
            '此片源暂未提供演职员资料',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 13),
          ),
        for (final entry in values.entries)
          if (entry.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: cast ? 76 : 48,
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        color: CinemaTheme.muted,
                        fontSize: 11,
                        height: 1.9,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      entry.value,
                      style: const TextStyle(fontSize: 13, height: 1.7),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _information(
    CinemaTitle title,
    Widget details,
    Widget reviews,
  ) => Padding(
    key: const ValueKey('cinema-detail-information'),
    padding: const EdgeInsets.only(top: 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 6,
          children: [
            for (final (index, label) in ['简介', '演员', '相似推荐', '影评'].indexed)
              TextButton(
                key: ValueKey('cinema-detail-tab-$index'),
                style: TextButton.styleFrom(
                  foregroundColor: _informationTab == index
                      ? CinemaTheme.text
                      : CinemaTheme.muted,
                  backgroundColor: Colors.transparent,
                  padding: const EdgeInsets.fromLTRB(0, 6, 20, 8),
                  textStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: _informationTab == index
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                onPressed: () => setState(() => _informationTab = index),
                child: Text(label),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_informationTab == 0) ...[
          if (title.description.isNotEmpty)
            SelectableText(
              title.description,
              style: const TextStyle(fontSize: 14, height: 1.9),
            ),
          const SizedBox(height: 20),
          _metadata(title, cast: false),
        ],
        if (_informationTab == 1) _metadata(title, cast: true),
        // Keep both independently loaded views mounted when changing tabs;
        // their existing caches, identity edits and retry flows stay intact.
        Offstage(
          key: const ValueKey('cinema-detail-recommendations-pane'),
          offstage: _informationTab != 2,
          child: details,
        ),
        Offstage(
          key: const ValueKey('cinema-detail-reviews-pane'),
          offstage: _informationTab != 3,
          child: reviews,
        ),
      ],
    ),
  );

  Widget _layout(
    BuildContext context,
    CinemaTitle title,
    AsyncSnapshot<CinemaTitle> snapshot,
    Widget ratings,
    Widget details,
    Widget reviews,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 820;
      final height = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : MediaQuery.sizeOf(context).height * .88;
      final hasArtwork = _posterProvider != null && !_posterFailed;
      // Leave the composition quiet above the information, while reserving a
      // title and playback action on short windows rather than an empty screen.
      final latestStart = (height - 220).clamp(60.0, 440.0);
      final informationTop = hasArtwork
          ? (height * (wide ? .48 : .40))
                .clamp(wide ? 228.0 : 172.0, wide ? 440.0 : 320.0)
                .clamp(60.0, latestStart)
          : 60.0;
      final feather = hasArtwork
          ? (informationTop * .22).clamp(48.0, 88.0)
          : 40.0;
      final left = Column(
        key: const ValueKey('cinema-detail-left'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.title,
            style: TextStyle(
              fontSize: wide ? 42 : 30,
              height: 1.14,
              fontWeight: FontWeight.w600,
              letterSpacing: -.8,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            [
              title.year,
              title.category,
              title.remarks,
            ].where((value) => value.isNotEmpty).join(' · '),
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 26),
          CinemaNeonRegion(
            key: const ValueKey('cinema-detail-actions-region'),
            ready: snapshot.connectionState == ConnectionState.done,
            child: _actions(title, snapshot),
          ),
          const SizedBox(height: 20),
          CinemaNeonRegion(
            key: const ValueKey('cinema-detail-ratings-region'),
            ready: _scoresTerminal,
            child: ratings,
          ),
          const SizedBox(height: 24),
          CinemaNeonRegion(
            key: const ValueKey('cinema-detail-sources-region'),
            ready:
                snapshot.connectionState == ConnectionState.done &&
                !_discovering,
            child: _sourceControls(title, snapshot),
          ),
        ],
      );
      final right = CinemaNeonRegion(
        key: const ValueKey('cinema-detail-information-region'),
        ready:
            snapshot.connectionState == ConnectionState.done &&
            (_informationTab < 2 || _informationTerminal),
        child: _information(title, details, reviews),
      );
      return SingleChildScrollView(
        key: const ValueKey('cinema-title-detail-layout'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: informationTop - feather),
            Stack(
              children: [
                Positioned.fill(
                  child: _DetailInformationFrost(
                    feather: feather,
                    palette: _posterPalette,
                  ),
                ),
                Padding(
                  key: const ValueKey('cinema-detail-information-surface'),
                  padding: EdgeInsets.fromLTRB(
                    wide ? 38 : 20,
                    feather,
                    wide ? 38 : 20,
                    32,
                  ),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: left),
                            const SizedBox(width: 28),
                            Expanded(flex: 6, child: right),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [left, const SizedBox(height: 24), right],
                        ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .88,
      child: FutureBuilder<CinemaTitle>(
        key: ValueKey(_selectedTitle.key),
        future: _detail,
        initialData: _selectedTitle.routes.isNotEmpty ? _selectedTitle : null,
        builder: (context, snapshot) {
          // Keep rating identity widgets stable across tab, hover and source
          // discovery updates; merging metadata otherwise makes a new object
          // on every build and restarts independent ratings requests.
          if (snapshot.data != null &&
              (!identical(_resolvedInput, snapshot.data) ||
                  _resolvedTitle?.key != _selectedTitle.key)) {
            _resolvedInput = snapshot.data;
            _resolvedTitle = inheritCinemaRatingMetadata(
              inheritCinemaRatingMetadata(snapshot.data!, _selectedTitle),
              widget.title,
            );
          }
          final title = snapshot.data == null
              ? _selectedTitle
              : _resolvedTitle!;
          if (!identical(_ratingsTitle, title)) {
            _ratingsTitle = title;
            _ratingTicket++;
            _ratingsTerminal = false;
            _scoresTerminal = false;
            _informationTerminal = false;
          }
          _watchPoster(title);
          final generation = _detailGeneration;
          final ratingTicket = _ratingTicket;
          final sourceTerminal =
              snapshot.connectionState == ConnectionState.done;
          final completed = [
            sourceTerminal,
            !_discovering,
            _ratingsTerminal,
            _posterTerminal,
          ].where((value) => value).length;
          // Readiness belongs to the current requests and decoded frame. A
          // prior source/identity finishing cannot latch later work as ready.
          _presentationReady = completed == 4;
          return CinemaNeonDecode(
            loading: !_presentationReady,
            progress: completed / 4,
            regional: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: CinemaDetailFrost(
                        key: ValueKey('cinema-detail-frost'),
                      ),
                    ),
                  ),
                  if (_posterProvider != null)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: MediaQuery.sizeOf(context).height * .66,
                      child: CinemaNeonRegion(
                        key: const ValueKey('cinema-detail-poster-region'),
                        ready: _posterTerminal,
                        child: CinemaArtworkBackdrop(
                          image: _posterProvider!,
                          alignment: const Alignment(0, -.55),
                          shadeLeading: true,
                        ),
                      ),
                    ),
                  CinemaRatingsPanel(
                    title: title,
                    sourceName: _selectedSource.name,
                    repository: widget.ratingsRepository,
                    onRecommendationSelected: widget.onRecommendationSelected,
                    compact: true,
                    onLoadState: (state) {
                      if (!mounted ||
                          _disposing ||
                          generation != _detailGeneration ||
                          ratingTicket != _ratingTicket ||
                          state.titleKey != _selectedTitle.key ||
                          (_ratingsTerminal == state.terminal &&
                              _scoresTerminal == !state.ratingsLoading &&
                              _informationTerminal == !state.detailsLoading)) {
                        return;
                      }
                      setState(() {
                        _ratingsTerminal = state.terminal;
                        _scoresTerminal = !state.ratingsLoading;
                        _informationTerminal = !state.detailsLoading;
                      });
                    },
                    layoutBuilder: (context, ratings, details, reviews) =>
                        _layout(
                          context,
                          title,
                          snapshot,
                          ratings,
                          details,
                          reviews,
                        ),
                  ),
                  Positioned(
                    top: 12,
                    right: 14,
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  if (_posterTerminal &&
                      (_posterFailed || _posterLimited) &&
                      _ratingsTerminal)
                    Positioned(
                      top: 12,
                      left: 18,
                      child: TextButton.icon(
                        key: const ValueKey('cinema-detail-artwork-retry'),
                        onPressed: () =>
                            setState(() => _watchPoster(title, force: true)),
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label: Text(
                          _posterFailed ? '海报暂未加载' : '高清海报暂不可用',
                          style: const TextStyle(
                            color: CinemaTheme.muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// The veil belongs to the scrolling information, not to the artwork. Its
/// feather finishes before text starts, so the image keeps its full composition.
class _DetailInformationFrost extends StatelessWidget {
  const _DetailInformationFrost({required this.feather, required this.palette});
  final double feather;
  final List<Color> palette;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CinemaAppearanceScope.of(context),
    builder: (context, _) {
      final appearance = CinemaAppearanceScope.of(context);
      final solid = appearance.reduceTransparency;
      final atmosphere = CinemaPosterAtmosphere(
        palette: palette,
        active: palette.isNotEmpty && !appearance.reduceMotion,
      );
      final veil = CustomPaint(
        painter: _DetailInformationFrostPainter(feather, solid: solid),
        foregroundPainter: solid ? null : _DetailInformationFeather(feather),
        child: solid
            // Reducing transparency removes backdrop blur, not color motion.
            // Mask only the isolated color layer so the poster is never erased.
            ? ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => ui.Gradient.linear(
                  bounds.topLeft,
                  bounds.topLeft + Offset(0, feather),
                  const [Colors.transparent, Colors.white],
                ),
                child: atmosphere,
              )
            : atmosphere,
      );
      return IgnorePointer(
        child: ClipRect(
          key: const ValueKey('cinema-detail-information-frost'),
          child: solid
              ? veil
              : BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: veil,
                ),
        ),
      );
    },
  );
}

class _DetailInformationFrostPainter extends CustomPainter {
  const _DetailInformationFrostPainter(this.feather, {required this.solid});
  final double feather;
  final bool solid;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    if (solid) {
      // Without a backdrop layer, dstIn would also erase the artwork already
      // beneath us. Source-over alpha leaves that composition intact at the lip.
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(0, feather),
            const [
              Color(0x001B1B1F),
              Color(0x301B1B1F),
              Color(0xB81B1B1F),
              Color(0xFF1B1B1F),
            ],
            const [0, .32, .72, 1],
          ),
      );
      return;
    }
    canvas.drawRect(
      bounds,
      Paint()..color = const Color(0xFF1B1B1F).withValues(alpha: .86),
    );
  }

  @override
  bool shouldRepaint(_DetailInformationFrostPainter oldDelegate) =>
      oldDelegate.feather != feather || oldDelegate.solid != solid;
}

class _DetailInformationFeather extends CustomPainter {
  const _DetailInformationFeather(this.feather);
  final double feather;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Mask inside the backdrop layer so both tint and actual blur disappear
    // together above the information, without a rectangular filter boundary.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, feather),
          const [
            Colors.transparent,
            Color(0x30FFFFFF),
            Color(0xB8FFFFFF),
            Colors.white,
          ],
          const [0, .32, .72, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_DetailInformationFeather oldDelegate) =>
      oldDelegate.feather != feather;
}
