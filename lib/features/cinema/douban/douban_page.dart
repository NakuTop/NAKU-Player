import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../cinema_theme.dart';
import 'douban_models.dart';
import 'douban_repository.dart';
import 'douban_image_headers.dart';
import 'douban_themes.dart';

class DoubanPage extends StatefulWidget {
  const DoubanPage({
    super.key,
    required this.onSelect,
    this.repository,
    this.themeCatalog,
    this.session,
  });
  final ValueChanged<DoubanTitle> onSelect;
  final DoubanRepository? repository;
  final DoubanThemeCatalog? themeCatalog;
  final DoubanBrowseSession? session;
  @override
  State<DoubanPage> createState() => _DoubanPageState();
}

/// One home-window browsing session. Only data and offsets survive closing the
/// board; scroll controllers and in-flight requests belong to each route.
class DoubanBrowseSession {
  DoubanKind _kind = DoubanKind.movie;
  final _states = <DoubanKind, _KindSnapshot>{};
}

class _KindSnapshot {
  _KindSnapshot(_KindState state)
    : filters = state.filters,
      sort = state.sort,
      error = state.error,
      filterError = state.filterError,
      items = List.of(state.items),
      sorts = List.of(state.sorts),
      categories = Map.of(state.categories),
      tagGroups = {
        for (final entry in state.tagGroups.entries)
          entry.key: List.of(entry.value),
      },
      themes = List.of(state.themes),
      selectedThemes = Set.of(state.selectedThemes),
      themesInitialized = state.themesInitialized,
      showAllThemes = state.showAllThemes,
      themesExpanded = state.themesExpanded,
      themeMessage = state.themeMessage,
      more = state.more,
      initialized = state.initialized,
      failedAppend = state.failedAppend,
      next = state.next,
      scrollOffset = state.scrollOffset,
      themeScrollOffset = state.themeScrollOffset,
      resumePage = state.loading || state.resumePage,
      resumeFilters = state.filtersLoading || state.resumeFilters,
      resumeThemes = state.themesLoading || state.resumeThemes;

  final DoubanFilters filters;
  final String? sort, error, filterError, themeMessage;
  final List<DoubanTitle> items;
  final List<DoubanSort> sorts;
  final Map<String, DoubanCategoryGroup> categories;
  final Map<String, List<String>> tagGroups;
  final List<String> themes;
  final Set<String> selectedThemes;
  final bool themesInitialized, showAllThemes, themesExpanded;
  final bool more, initialized, failedAppend;
  final bool resumePage, resumeFilters, resumeThemes;
  final int next;
  final double scrollOffset, themeScrollOffset;
}

class _KindState {
  _KindState(_KindSnapshot? saved) {
    if (saved != null) {
      filters = saved.filters;
      sort = saved.sort;
      error = saved.error;
      filterError = saved.filterError;
      items = List.of(saved.items);
      sorts = List.of(saved.sorts);
      categories.addAll(saved.categories);
      tagGroups.addAll(saved.tagGroups);
      themes = List.of(saved.themes);
      selectedThemes.addAll(saved.selectedThemes);
      themesInitialized = saved.themesInitialized && !saved.resumeThemes;
      showAllThemes = saved.showAllThemes;
      themesExpanded = saved.themesExpanded;
      themeMessage = saved.themeMessage;
      more = saved.more;
      initialized = saved.initialized;
      failedAppend = saved.failedAppend;
      next = saved.next;
      scrollOffset = saved.scrollOffset;
      themeScrollOffset = saved.themeScrollOffset;
      resumePage = saved.resumePage;
      resumeFilters = saved.resumeFilters;
      resumeThemes = saved.resumeThemes;
    }
    scroll = ScrollController(initialScrollOffset: scrollOffset)
      ..addListener(() => scrollOffset = scroll.offset);
    themeScroll = ScrollController(initialScrollOffset: themeScrollOffset)
      ..addListener(() => themeScrollOffset = themeScroll.offset);
  }

  late final ScrollController scroll, themeScroll;
  double scrollOffset = 0, themeScrollOffset = 0;
  bool resumePage = false, resumeFilters = false, resumeThemes = false;
  DoubanFilters filters = const DoubanFilters();
  String? sort, error, filterError;
  List<DoubanTitle> items = [];
  List<DoubanSort> sorts = [];
  final categories = <String, DoubanCategoryGroup>{};
  final tagGroups = <String, List<String>>{};
  List<String> themes = [];
  final selectedThemes = <String>{};
  bool themesLoading = false, themesInitialized = false;
  int themeGeneration = 0;
  bool showAllThemes = false, themesExpanded = true;
  String? themeMessage;
  CancelToken? themeToken;
  bool loading = false, filtersLoading = false, more = false;
  bool initialized = false, failedAppend = false;
  int next = 0, generation = 0, filterGeneration = 0;
  CancelToken? pageToken, filterToken;
}

class _DoubanPageState extends State<DoubanPage> {
  late final _repository = widget.repository ?? DoubanRepository();
  late final _themeCatalog = widget.themeCatalog ?? DoubanThemeCatalog.shared;
  late final _session = widget.session ?? DoubanBrowseSession();
  late DoubanKind _kind = _session._kind;
  late final _states = {
    for (final kind in DoubanKind.values)
      kind: _KindState(_session._states[kind]),
  };
  _KindState get _state => _states[_kind]!;

  @override
  void initState() {
    super.initState();
    for (final kind in DoubanKind.values) {
      _states[kind]!.themes = {
        ..._states[kind]!.themes,
        ..._themeCatalog.topics(kind),
      }.toList();
    }
    _themeCatalog.addListener(_restoreThemes);
    unawaited(_themeCatalog.initialize());
    _resumeKind(_kind);
  }

  void _restoreThemes() {
    if (!mounted) return;
    setState(() {
      for (final kind in DoubanKind.values) {
        _states[kind]!.themes = {
          ..._states[kind]!.themes,
          ..._themeCatalog.topics(kind),
        }.toList();
      }
    });
  }

  @override
  void dispose() {
    _themeCatalog.removeListener(_restoreThemes);
    _session._kind = _kind;
    for (final entry in _states.entries) {
      _session._states[entry.key] = _KindSnapshot(entry.value);
    }
    for (final state in _states.values) {
      state.generation++;
      state.filterGeneration++;
      state.themeGeneration++;
      state.pageToken?.cancel();
      state.filterToken?.cancel();
      state.themeToken?.cancel();
      state.scroll.dispose();
      state.themeScroll.dispose();
    }
    super.dispose();
  }

  void _change(_KindState state, VoidCallback change) {
    if (!mounted) return;
    if (identical(state, _state)) {
      setState(change);
    } else {
      change();
    }
  }

  void _loadKind(DoubanKind kind) {
    unawaited(_loadPage(kind));
    unawaited(_loadFilters(kind));
  }

  void _resumeKind(DoubanKind kind) {
    final state = _states[kind]!;
    if (!state.initialized) {
      _loadKind(kind);
      return;
    }
    final page = state.resumePage;
    if (page) {
      unawaited(_loadPage(kind, append: state.failedAppend, preserve: true));
    }
    if (state.resumeFilters) unawaited(_loadFilters(kind));
    if (state.resumeThemes) {
      state.themesInitialized = true;
      unawaited(_loadThemes(kind));
    }
    state.resumePage = state.resumeFilters = state.resumeThemes = false;
  }

  void _selectKind(DoubanKind kind) {
    if (kind == _kind) return;
    setState(() => _kind = kind);
    _resumeKind(kind);
  }

  Future<void> _loadPage(
    DoubanKind kind, {
    bool append = false,
    bool preserve = false,
  }) async {
    final state = _states[kind]!;
    state.pageToken?.cancel();
    final token = state.pageToken = CancelToken();
    final generation = ++state.generation;
    final filters = state.filters, sort = state.sort;
    final themes = state.selectedThemes.toList();
    final start = append ? state.next : 0;
    _change(state, () {
      state.initialized = true;
      state.loading = true;
      state.error = null;
      state.failedAppend = append;
      if (!append && !preserve) {
        state.items = [];
        state.next = 0;
        state.more = false;
      }
    });
    try {
      final page = await _repository.browse(
        kind: kind,
        sort: sort,
        filters: filters,
        tags: themes,
        start: start,
        cancelToken: token,
      );
      if (!mounted || generation != state.generation) return;
      _change(state, () {
        final items = append
            ? List<DoubanTitle>.of(state.items)
            : <DoubanTitle>[];
        final seen = items.map((item) => item.id).toSet();
        items.addAll(page.items.where((item) => seen.add(item.id)));
        state.items = items;
        state.next = page.nextStart;
        state.more = page.hasMore;
        // Recommendation topics are a separate exploration surface. Preserve
        // the visible order and chosen topics across personalized responses.
        state.themes = _themeCatalog.remember(
          kind,
          page.tags,
          selected: state.selectedThemes,
        );
        // Pagination cannot reshuffle controls. A partial response cannot remove
        // previously available taxonomy or a selected filter.
        if (!append || state.sorts.isEmpty) {
          if (page.sorts.isNotEmpty) state.sorts = page.sorts;
        }
        for (final group in page.categoryGroups) {
          final previous = state.categories[group.name];
          state.categories[group.name] = previous == null
              ? group
              : DoubanCategoryGroup(
                  name: group.name,
                  groupName: group.groupName.isNotEmpty
                      ? group.groupName
                      : previous.groupName,
                  tags: {...previous.tags, ...group.tags}.toList(),
                  groups: {
                    for (final key in {
                      ...previous.groups.keys,
                      ...group.groups.keys,
                    })
                      key: {
                        ...?previous.groups[key],
                        ...?group.groups[key],
                      }.toList(),
                  },
                );
        }
        state.loading = false;
      });
      if (!state.themesInitialized) {
        state.themesInitialized = true;
        unawaited(_loadThemes(kind, rounds: 2));
      }
    } catch (error) {
      if (!mounted ||
          generation != state.generation ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      _change(state, () {
        state.loading = false;
        state.error = '$error';
      });
    }
  }

  Future<void> _loadThemes(DoubanKind kind, {int rounds = 1}) async {
    final state = _states[kind]!;
    if (state.themesLoading) return;
    final generation = ++state.themeGeneration;
    final token = state.themeToken = CancelToken();
    final before = state.themes.toSet();
    _change(state, () {
      state.themesLoading = true;
      state.themeMessage = null;
    });
    try {
      // Warm up at most two contexts, then one request per explicit click.
      for (var round = 0; round < rounds.clamp(1, 2); round++) {
        await _themeCatalog.initialize();
        if (!mounted || generation != state.themeGeneration) return;
        final seed = _themeCatalog.nextSeed(kind);
        final topics = await _repository.discoverThemes(
          kind: kind,
          seed: seed,
          cancelToken: token,
        );
        if (!mounted || generation != state.themeGeneration) return;
        _change(state, () {
          state.themes = _themeCatalog.remember(
            kind,
            topics,
            selected: state.selectedThemes,
          );
        });
      }
      _change(state, () {
        final added = state.themes
            .where((topic) => !before.contains(topic))
            .length;
        state.themeMessage = added == 0
            ? '当前暂无更多主题，已保留之前发现的主题。'
            : '新增 $added 个主题，已保留之前发现的主题。';
      });
    } catch (error) {
      if (!mounted ||
          generation != state.themeGeneration ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      _change(state, () {
        state.themeMessage = '主题暂时无法更新，现有主题和作品仍可使用。';
      });
    } finally {
      if (mounted && generation == state.themeGeneration) {
        _change(state, () => state.themesLoading = false);
      }
    }
  }

  Future<void> _loadFilters(DoubanKind kind) async {
    final state = _states[kind]!;
    state.filterToken?.cancel();
    final token = state.filterToken = CancelToken();
    final generation = ++state.filterGeneration;
    _change(state, () {
      state.filtersLoading = true;
      state.filterError = null;
    });
    try {
      final groups = await _repository.tagGroups(
        kind: kind,
        filters: state.filters,
        cancelToken: token,
      );
      if (!mounted || generation != state.filterGeneration) return;
      _change(state, () {
        for (final group in groups) {
          state.tagGroups[group.name] = {
            ...?state.tagGroups[group.name],
            ...group.tags,
          }.toList();
        }
        state.filtersLoading = false;
      });
    } catch (error) {
      if (!mounted ||
          generation != state.filterGeneration ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      _change(state, () {
        state.filtersLoading = false;
        state.filterError = '$error';
      });
    }
  }

  void _selectFilters(DoubanFilters filters, {bool categoriesChanged = false}) {
    setState(() => _state.filters = filters);
    if (_state.scroll.hasClients) _state.scroll.jumpTo(0);
    unawaited(_loadPage(_kind));
    if (categoriesChanged) unawaited(_loadFilters(_kind));
  }

  void _refresh() {
    unawaited(_loadPage(_kind, preserve: true));
    unawaited(_loadFilters(_kind));
  }

  void _reset() {
    setState(() {
      _state.filters = const DoubanFilters();
      _state.sort = null;
      _state.selectedThemes.clear();
    });
    if (_state.scroll.hasClients) _state.scroll.jumpTo(0);
    _loadKind(_kind);
  }

  Widget _filter({
    required String id,
    required String label,
    required String selected,
    required List<String> options,
    required ValueChanged<String> onChanged,
  }) {
    final values = <String>{
      '',
      ...options.where(
        (value) => value.isNotEmpty && value != '全部' && value != '不限类型',
      ),
      if (selected.isNotEmpty) selected,
    };
    return InputDecorator(
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('douban-filter-$id'),
          value: selected,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(12),
          menuMaxHeight: 380,
          style: TextStyle(
            color: selected.isEmpty ? CinemaTheme.muted : CinemaTheme.copper,
            fontSize: 13,
          ),
          items: [
            for (final value in values)
              DropdownMenuItem(
                value: value,
                child: Text(
                  value.isEmpty ? '全部$label' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: values.length == 1
              ? null
              : (value) {
                  if (value != null && value != selected) onChanged(value);
                },
        ),
      ),
    );
  }

  Widget _themeChips(_KindState state) => Align(
    alignment: Alignment.centerLeft,
    child: Wrap(
      spacing: 7,
      runSpacing: 6,
      children: [
        for (final theme in state.themes)
          FilterChip(
            key: ValueKey('douban-theme-$theme'),
            label: Text(theme, style: const TextStyle(fontSize: 12)),
            selected: state.selectedThemes.contains(theme),
            onSelected:
                state.selectedThemes.length >= 6 &&
                    !state.selectedThemes.contains(theme)
                ? null
                : (selected) {
                    setState(() {
                      if (selected) {
                        state.selectedThemes.add(theme);
                      } else {
                        state.selectedThemes.remove(theme);
                      }
                    });
                    if (state.scroll.hasClients) state.scroll.jumpTo(0);
                    unawaited(_loadPage(_kind));
                  },
          ),
      ],
    ),
  );

  Widget _filters() {
    final state = _state, filters = state.filters;
    final genre = state.categories['类型'];
    final formats = genre?.groups.keys.toList() ?? const <String>[];
    final fields = <Widget>[
      if (_kind == DoubanKind.tv)
        _filter(
          id: 'format',
          label: '形式',
          selected: filters.format,
          options: formats,
          onChanged: (value) {
            final genres = genre?.options(format: value) ?? const <String>[];
            _selectFilters(
              filters.copyWith(
                format: value,
                genre: genres.contains(filters.genre) ? filters.genre : '',
              ),
              categoriesChanged: true,
            );
          },
        ),
      _filter(
        id: 'genre',
        label: '类型',
        selected: filters.genre,
        options: genre?.options(format: filters.format) ?? const [],
        onChanged: (value) => _selectFilters(
          filters.copyWith(genre: value),
          categoriesChanged: true,
        ),
      ),
      _filter(
        id: 'region',
        label: '地区',
        selected: filters.region,
        options: state.categories['地区']?.tags ?? const [],
        onChanged: (value) => _selectFilters(
          filters.copyWith(region: value),
          categoriesChanged: true,
        ),
      ),
      _filter(
        id: 'year',
        label: '年代',
        selected: filters.year,
        options: state.tagGroups['年代'] ?? const [],
        onChanged: (value) => _selectFilters(filters.copyWith(year: value)),
      ),
      if (_kind == DoubanKind.tv && state.tagGroups.containsKey('平台'))
        _filter(
          id: 'platform',
          label: '平台',
          selected: filters.platform,
          options: state.tagGroups['平台'] ?? const [],
          onChanged: (value) =>
              _selectFilters(filters.copyWith(platform: value)),
        ),
    ];
    return CinemaGlass(
      blur: false,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 170).floor().clamp(1, 5);
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 14,
                children: [
                  for (final field in fields)
                    SizedBox(width: width, child: field),
                ],
              );
            },
          ),
          if (state.sorts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 6,
              children: [
                for (final sort in state.sorts)
                  ChoiceChip(
                    key: ValueKey('douban-sort-${sort.name}'),
                    label: Text(
                      sort.text,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected:
                        state.sort == sort.name ||
                        (state.sort == null && sort.isDefault),
                    onSelected: (_) {
                      if (state.sort == sort.name ||
                          (state.sort == null && sort.isDefault)) {
                        return;
                      }
                      setState(
                        () => state.sort = sort.isDefault ? null : sort.name,
                      );
                      if (state.scroll.hasClients) state.scroll.jumpTo(0);
                      unawaited(_loadPage(_kind));
                    },
                  ),
              ],
            ),
          ],
          ...[
            const SizedBox(height: 8),
            Theme(
              data: CinemaTheme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey('douban-${_kind.name}-themes'),
                initiallyExpanded: state.themesExpanded,
                onExpansionChanged: (expanded) =>
                    state.themesExpanded = expanded,
                expansionAnimationStyle: AnimationStyle.noAnimation,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text('风格与主题', style: TextStyle(fontSize: 13)),
                subtitle: state.selectedThemes.isEmpty
                    ? null
                    : Text(
                        state.selectedThemes.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: CinemaTheme.copper,
                        ),
                      ),
                children: [
                  Row(
                    children: [
                      Text(
                        '已发现 ${state.themes.length} 个主题',
                        style: const TextStyle(
                          fontSize: 11,
                          color: CinemaTheme.muted,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        key: const ValueKey('douban-more-themes'),
                        onPressed: state.themesLoading
                            ? null
                            : () => _loadThemes(_kind),
                        icon: state.themesLoading
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : const Icon(Icons.add, size: 16),
                        label: Text(state.themesLoading ? '正在发现' : '更多主题'),
                      ),
                    ],
                  ),
                  if (state.selectedThemes.length >= 6)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        '已选 6 个主题，取消一项可继续选择。',
                        style: TextStyle(
                          fontSize: 11,
                          color: CinemaTheme.muted,
                        ),
                      ),
                    ),
                  if (state.showAllThemes)
                    _themeChips(state)
                  else
                    SizedBox(
                      height: 144,
                      child: Scrollbar(
                        controller: state.themeScroll,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          // ExpansionTile stores a bool in PageStorage. This
                          // nested scroller needs its own key for a double offset.
                          key: PageStorageKey(
                            'douban-${_kind.name}-theme-scroll',
                          ),
                          controller: state.themeScroll,
                          padding: const EdgeInsets.only(right: 12),
                          child: _themeChips(state),
                        ),
                      ),
                    ),
                  if (state.themes.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('douban-show-all-themes'),
                        onPressed: () => setState(
                          () => state.showAllThemes = !state.showAllThemes,
                        ),
                        icon: Icon(
                          state.showAllThemes
                              ? Icons.unfold_less
                              : Icons.unfold_more,
                          size: 16,
                        ),
                        label: Text(
                          state.showAllThemes
                              ? '收起为滚动列表'
                              : '展开全部 ${state.themes.length} 个主题',
                        ),
                      ),
                    ),
                  if (_themeCatalog.storageError != null)
                    TextButton.icon(
                      onPressed: _themeCatalog.retryPersistence,
                      icon: const Icon(Icons.info_outline, size: 14),
                      label: Text(
                        _themeCatalog.storageError!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  SizedBox(
                    height: 32,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        state.themeMessage ?? '豆瓣推荐中的真实主题，可与上方筛选组合。',
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 11,
                          color: CinemaTheme.muted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (state.filtersLoading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 1),
          ],
          if (state.filterError != null) ...[
            const SizedBox(height: 8),
            Text(
              '部分筛选项暂时无法更新。${state.filterError}',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
            ),
            TextButton(
              onPressed: () => _loadFilters(_kind),
              child: const Text('重试筛选项'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: Scaffold(
      backgroundColor: CinemaTheme.background,
      appBar: AppBar(
        title: const Text('豆瓣榜单'),
        actions: [
          IconButton(
            tooltip: '豆瓣官网',
            onPressed: () => launchUrl(Uri.parse(_kind.pageUrl)),
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _state.loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: CinemaCanvas(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
              child: Row(
                children: [
                  SegmentedButton<DoubanKind>(
                    segments: [
                      for (final kind in DoubanKind.values)
                        ButtonSegment(value: kind, label: Text(kind.label)),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (values) => _selectKind(values.single),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('douban-reset-filters'),
                    onPressed:
                        _state.filters.isEmpty &&
                            _state.sort == null &&
                            _state.selectedThemes.isEmpty
                        ? null
                        : _reset,
                    icon: const Icon(Icons.filter_alt_off_outlined, size: 17),
                    label: const Text('重置筛选'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CustomScrollView(
                key: PageStorageKey('douban-${_kind.name}-scroll'),
                controller: _state.scroll,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _filters(),
                          const SizedBox(height: 14),
                          const Text(
                            '按豆瓣公开分类筛选，点击作品搜索可用片源。',
                            style: TextStyle(
                              color: CinemaTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                          if (_state.error != null) ...[
                            const SizedBox(height: 14),
                            Text(
                              _state.items.isEmpty
                                  ? _state.error!
                                  : '本次加载未完成，已保留现有作品。${_state.error}',
                              style: const TextStyle(
                                color: CinemaTheme.copper,
                                fontSize: 12,
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('douban-retry'),
                              onPressed: () => _loadPage(
                                _kind,
                                append: _state.failedAppend,
                                preserve: true,
                              ),
                              child: const Text('重试'),
                            ),
                          ],
                          if (_state.loading) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(minHeight: 2),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final columns = (constraints.crossAxisExtent / 175)
                            .floor()
                            .clamp(2, 7);
                        return SliverGrid.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: math.min(
                                  18,
                                  constraints.crossAxisExtent / 25,
                                ),
                                mainAxisSpacing: 20,
                                childAspectRatio: .54,
                              ),
                          itemCount: _state.items.length,
                          itemBuilder: (context, index) =>
                              _card(_state.items[index]),
                        );
                      },
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: _state.loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : _state.more
                            ? OutlinedButton(
                                onPressed: () => _loadPage(_kind, append: true),
                                child: const Text('加载更多'),
                              )
                            : Text(
                                _state.error != null
                                    ? ''
                                    : _state.items.isEmpty
                                    ? '当前筛选暂无可显示的作品'
                                    : '已显示当前公开列表',
                                style: const TextStyle(
                                  color: CinemaTheme.muted,
                                ),
                              ),
                      ),
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

  Widget _card(DoubanTitle item) => InkWell(
    key: ValueKey('douban-${item.id}'),
    onTap: () => widget.onSelect(item),
    borderRadius: BorderRadius.circular(10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox.expand(
              child: item.poster.isEmpty
                  ? _posterFallback()
                  : CachedNetworkImage(
                      memCacheWidth: 480,
                      imageUrl: item.poster,
                      httpHeaders: doubanImageHeaders,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _posterFallback(),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          '${item.year}  ·  豆瓣 ${item.score?.toStringAsFixed(1) ?? '暂无评分'}',
          style: const TextStyle(color: CinemaTheme.copper, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _posterFallback() => ColoredBox(
    color: CinemaTheme.raised,
    child: const Center(
      child: Icon(Icons.movie_outlined, color: CinemaTheme.muted),
    ),
  );
}
