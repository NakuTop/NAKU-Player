import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_models.dart';
import 'cinema_work_sources.dart';
import 'douban/douban_page.dart';
import 'douban/douban_models.dart';
import 'naku_update_page.dart';
import 'naku_update_service.dart';
import 'cinema_grouping.dart';
import 'cinema_card_ratings.dart';
import 'cinema_repository.dart';
import 'cinema_ratings_panel.dart';
import 'cinema_ratings.dart';
import 'cinema_store.dart';
import 'cinema_player_page.dart';
import 'cinema_theme.dart';
import 'cinema_websites_page.dart';

enum _Section { movies, series, anime, favorites, history, sources }

class CinemaHomePage extends StatefulWidget {
  const CinemaHomePage({
    super.key,
    this.store,
    this.repository,
    this.ratingsRepository,
  });
  final CinemaStore? store;
  final CinemaRepository? repository;
  final CinemaRatingsRepository? ratingsRepository;

  @override
  State<CinemaHomePage> createState() => _CinemaHomePageState();
}

class _CinemaHomePageState extends State<CinemaHomePage> {
  late final CinemaStore _store = widget.store ?? CinemaStore();
  late final CinemaRepository _repository =
      widget.repository ?? CinemaRepository();
  final _search = TextEditingController();
  _Section _section = _Section.movies;
  final Map<_Section, CinemaCatalogSort> _catalogSort = {
    _Section.movies: CinemaCatalogSort.latest,
    _Section.series: CinemaCatalogSort.latest,
  };
  List<CinemaTitle> _items = [];
  List<CinemaCategory> _categories = [];
  final Map<String, String> _sourceStatus = {};
  final Map<String, int> _searchPages = {};
  final Set<String> _searchMore = {};
  String _activeKeyword = '';
  CinemaSource? _source;
  String? _categoryId;
  String? _error;
  bool _loading = true;
  bool _searching = false;
  int _page = 1;
  int _pageCount = 1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    unawaited(_initialize());
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    try {
      await _store.load();
      if (!mounted) return;
      await _browse();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _store.removeListener(_onStoreChanged);
    unawaited(_store.flush());
    if (widget.store == null) _store.dispose();
    _search.dispose();
    super.dispose();
  }

  String get _heading => switch (_section) {
    _Section.movies => '电影',
    _Section.series => '剧集',
    _Section.anime => '动漫',
    _Section.favorites => '我的收藏',
    _Section.history => '继续观看',
    _Section.sources => '片源管理',
  };

  bool get _isCatalog => _section.index <= _Section.anime.index;

  bool get _showsCatalogSort =>
      !_searching &&
      (_section == _Section.movies || _section == _Section.series);

  CinemaCatalogSort get _currentCatalogSort =>
      _catalogSort[_section] ?? CinemaCatalogSort.latest;

  String get _catalogSortExplanation {
    if (_items.isEmpty) return _loading ? '正在读取当前页数据。' : '当前页暂无作品可排序。';
    final popular = _currentCatalogSort == CinemaCatalogSort.popular;
    final available = _items
        .where(
          (item) =>
              popular ? item.sourceHits != null : item.sourceUpdatedAt != null,
        )
        .length;
    final metric = popular ? '热度' : '更新时间';
    if (available == 0) return '片源未提供本页可用$metric，保留片源顺序。';
    final scope = available < _items.length
        ? '本页 $available/${_items.length} 项有$metric，缺失项排后。'
        : '';
    return popular
        ? '$scope按片源提供的数值排序，不代表真实播放量或外部榜单。'
        : '$scope按片源更新时间排序，不是影片上映时间。';
  }

  bool _matchesCategory(String name) {
    return switch (_section) {
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

  bool _ordinaryCategory(String name) =>
      !RegExp('伦理|福利|情色|成人|里番|写真|三级').hasMatch(name);

  List<CinemaCategory> get _visibleCategories {
    final roots = _categories
        .where((c) => _matchesCategory(c.name))
        .map((c) => c.id)
        .toSet();
    final matches = _categories
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
    if (value == _section) return;
    _generation++;
    setState(() {
      _section = value;
      _categoryId = null;
      _searching = false;
      _search.clear();
      _error = null;
      _items = [];
      _page = 1;
      _sourceStatus.clear();
      _loading = false;
    });
    if (_isCatalog) await _browse();
  }

  Future<void> _browse({int page = 1}) async {
    final generation = ++_generation;
    final choices = _store.enabledSources
        .where((s) => s.kind == CinemaSourceKind.maccms)
        .toList();
    if (choices.isEmpty) {
      setState(() {
        _loading = false;
        _items = [];
        _source = null;
        _error = '还没有启用的影视接口。请到片源管理添加或启用一个接口。';
      });
      return;
    }
    final source =
        choices.where((s) => s.id == _source?.id).firstOrNull ??
        choices.where((s) => s.id == 'maccms-modu').firstOrNull ??
        choices.first;
    setState(() {
      _source = source;
      _loading = true;
      _error = null;
      _searching = false;
    });
    try {
      var result = await _repository.browse(
        source,
        categoryId: _categoryId,
        page: page,
      );
      if (!mounted || generation != _generation) return;
      if (result.categories.isNotEmpty) _categories = result.categories;
      // Category identifiers belong to each source; never assume 1/2/4.
      if (_categoryId == null) {
        final names = switch (_section) {
          _Section.movies => ['剧情片', '科幻片', '动作片'],
          _Section.series => ['欧美剧', '美国剧', '国产剧', '大陆剧', '日剧'],
          _ => ['日韩动漫', '日本动漫', '国产动漫'],
        };
        CinemaCategory? match;
        for (final name in names) {
          match = _categories.where((c) => c.name == name).firstOrNull;
          if (match != null) break;
        }
        match ??= _visibleCategories.firstOrNull;
        if (match != null) {
          _categoryId = match.id;
          result = await _repository.browse(
            source,
            categoryId: _categoryId,
            page: page,
          );
          if (!mounted || generation != _generation) return;
        }
      }
      setState(() {
        _items = result.items
            .where((t) => _ordinaryCategory(t.category))
            .toList();
        _page = result.page;
        _pageCount = result.pageCount;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '$e';
          _loading = false;
          _items = [];
        });
      }
    }
  }

  Future<void> _runSearch({bool loadMore = false}) async {
    final keyword = loadMore ? _activeKeyword : _search.text.trim();
    if (keyword.isEmpty) {
      await _browse();
      return;
    }
    final generation = ++_generation;
    final sources = _store.enabledSources
        .where(
          (s) =>
              (_section == _Section.anime ||
                  s.kind == CinemaSourceKind.maccms) &&
              (!loadMore || _searchMore.contains(s.id)),
        )
        .toList();
    setState(() {
      _loading = true;
      _error = null;
      _searching = true;
      if (!loadMore) {
        _items = [];
        _sourceStatus.clear();
        _searchPages.clear();
        _searchMore.clear();
        _activeKeyword = keyword;
      }
      for (final source in sources) {
        _sourceStatus[source.name] = '搜索中';
      }
    });
    if (sources.isEmpty) {
      setState(() {
        _error = '没有启用的片源，请先添加或启用。';
        _loading = false;
      });
      return;
    }
    // Bounded batches avoid flooding user-configured sources.
    for (var offset = 0; offset < sources.length; offset += 3) {
      await Future.wait(
        sources.skip(offset).take(3).map((source) async {
          try {
            final page = loadMore ? (_searchPages[source.id] ?? 1) + 1 : 1;
            final result = await _repository.search(
              source,
              keyword,
              page: page,
            );
            if (!mounted || generation != _generation) return;
            setState(() {
              final items = result.items
                  .where(
                    (t) =>
                        _ordinaryCategory(t.category) &&
                        (t.category.isEmpty || _matchesCategory(t.category)),
                  )
                  .toList();
              final existing = _items.map((item) => item.key).toSet();
              _items.addAll(
                items.where((item) => !existing.contains(item.key)),
              );
              _searchPages[source.id] = result.page;
              if (result.hasMore) {
                _searchMore.add(source.id);
              } else {
                _searchMore.remove(source.id);
              }
              _sourceStatus[source.name] = '${items.length} 个结果';
            });
          } catch (e) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _sourceStatus[source.name] = '连接失败：$e';
            });
          }
        }),
      );
      if (!mounted || generation != _generation) return;
    }
    setState(() {
      _loading = false;
    });
  }

  Future<void> _openTitle(
    CinemaTitle title, {
    CinemaHistory? resume,
    List<CinemaTitle> variants = const [],
  }) async {
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
        variants: variants,
        ratingsRepository: widget.ratingsRepository,
        repository: _repository,
        store: _store,
        resume: resume,
        onPlay: (detail, selectedSource, road, episode, allVariants) {
          Navigator.pop(context);
          Navigator.of(this.context).push(
            MaterialPageRoute<void>(
              builder: (_) => Theme(
                data: CinemaTheme.data,
                child: CinemaPlayerPage(
                  title: detail,
                  source: selectedSource,
                  store: _store,
                  variants: allVariants,
                  repository: _repository,
                  routeIndex: road,
                  episodeIndex: episode,
                ),
              ),
            ),
          );
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
      data: CinemaTheme.data,
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
                                              hintText: '搜索电影、剧集或动漫',
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
                                Expanded(child: _content(wide)),
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
      Icons.tune_rounded,
    ];
    const labels = ['电影', '剧集', '动漫', '我的收藏', '继续观看', '片源管理'];
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
              selectedTileColor: CinemaTheme.raised,
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
            leading: const Icon(Icons.leaderboard_outlined, size: 20),
            title: const Text('豆瓣榜单'),
            onTap: () {
              if (closeDrawer) Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DoubanPage(
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.system_update_alt, size: 20),
            title: const Text('软件更新'),
            onTap: () {
              if (closeDrawer) Navigator.pop(context);
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const NakuUpdatePage()),
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
              applicationVersion: '1.0.0',
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
              'NAKU播放器  1.0.0',
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
            ])
              ChoiceChip(
                key: ValueKey('catalog-sort-${sort.name}'),
                label: Text(sort == CinemaCatalogSort.popular ? '热门' : '最新'),
                selected: _currentCatalogSort == sort,
                selectedColor: CinemaTheme.copper.withValues(alpha: .18),
                side: BorderSide(
                  color: _currentCatalogSort == sort
                      ? CinemaTheme.copper
                      : CinemaTheme.border,
                ),
                onSelected: (_) =>
                    setState(() => _catalogSort[_section] = sort),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                _currentCatalogSort == CinemaCatalogSort.popular
                    ? '当前页·片源热度'
                    : '当前页·片源更新时间',
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

  Widget _content(bool wide) {
    if (_section == _Section.sources) return _sourceManager(wide);
    if (_section == _Section.favorites) {
      return _library(_store.favorites, wide, '还没有收藏。打开任意影片，点击收藏即可保存在这里。');
    }
    if (_section == _Section.history) {
      if (_store.history.isEmpty) return _empty('暂无观看记录', '播放后会在这里保留剧集和进度。');
      return ListView.separated(
        padding: const EdgeInsets.all(28),
        itemCount: _store.history.length,
        separatorBuilder: (_, _) => const Divider(height: 25),
        itemBuilder: (context, index) {
          final h = _store.history[index];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(width: 48, child: _poster(h.title, 48, 68)),
            title: Text(h.title.title),
            subtitle: Text(
              '${_findSource(h.title.sourceId)?.name ?? '已移除的片源'}  ·  第 ${h.episodeIndex + 1} 集  ·  ${Duration(seconds: h.positionSeconds).inMinutes} 分钟',
            ),
            trailing: const Icon(
              Icons.play_circle_outline_rounded,
              color: CinemaTheme.copper,
            ),
            onTap: () => _openTitle(h.title, resume: h),
          );
        },
      );
    }
    final padding = wide ? 36.0 : 18.0;
    final searchGroups = _searching
        ? groupCinemaTitles(_items)
        : <CinemaTitleGroup>[];
    final visibleItems = _searching
        ? searchGroups.map((g) => g.representative).toList()
        : _showsCatalogSort
        ? sortCinemaTitles(_items, _currentCatalogSort)
        : _items;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_searching)
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
                        onPressed: _loading ? null : () => _browse(),
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
                if (!_searching && _visibleCategories.isNotEmpty)
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
                if (_showsCatalogSort) _catalogSortControls(),
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
        if (_error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _empty(
              '暂时未能连接',
              _error!,
              action: FilledButton.tonal(
                onPressed: () => _searching ? _runSearch() : _browse(),
                child: const Text('重新尝试'),
              ),
            ),
          )
        else if (_items.isEmpty && !_loading)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _empty(
              '暂时没有结果',
              _searching ? '试试作品别名，或在片源管理启用其他来源。' : '当前片源在这个分类暂未返回内容，可切换分类或片源。',
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
                      variants: _searching
                          ? searchGroups[index].variants
                          : const [],
                    ),
                    childCount: visibleItems.length,
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
        if (!_searching && _items.isNotEmpty)
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
      padding: EdgeInsets.all(wide ? 36 : 18),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: .51,
      ),
      itemBuilder: (_, i) => _titleCard(items[i]),
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
              variants.length > 1
                  ? '${variants.length} 个片源版本'
                  : _findSource(title.sourceId)?.name ?? title.category,
            ].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: CinemaTheme.muted),
          ),
          const SizedBox(height: 5),
          CinemaCardRatings(title: title, repository: widget.ratingsRepository),
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
    this.resume,
  });
  final CinemaTitle title;
  final CinemaSource source;
  final List<CinemaTitle> variants;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaRepository repository;
  final CinemaStore store;
  final CinemaHistory? resume;
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
    data: CinemaTheme.data,
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .84,
      child: FutureBuilder<CinemaTitle>(
        key: ValueKey(_selectedTitle.key),
        future: _detail,
        builder: (context, snapshot) {
          final title = snapshot.data ?? _selectedTitle;
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
