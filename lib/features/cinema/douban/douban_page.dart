import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../cinema_theme.dart';
import 'douban_models.dart';
import 'douban_repository.dart';

class DoubanPage extends StatefulWidget {
  const DoubanPage({super.key, required this.onSelect, this.repository});
  final ValueChanged<DoubanTitle> onSelect;
  final DoubanRepository? repository;
  @override
  State<DoubanPage> createState() => _DoubanPageState();
}

class _DoubanPageState extends State<DoubanPage> {
  late final _repository = widget.repository ?? DoubanRepository();
  DoubanKind _kind = DoubanKind.movie;
  String? _sort;
  String? _tag;
  List<DoubanTitle> _items = [];
  List<DoubanSort> _sorts = [];
  List<String> _tags = [];
  bool _loading = true, _more = false;
  int _next = 0, _generation = 0;
  String? _error;
  CancelToken? _token;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    _token?.cancel();
    final token = _token = CancelToken();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _items = [];
    });
    try {
      final page = await _repository.browse(
        kind: _kind,
        sort: _sort,
        tags: _tag == null ? [] : [_tag!],
        start: append ? _next : 0,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final seen = _items.map((e) => e.id).toSet();
        _items.addAll(page.items.where((e) => seen.add(e.id)));
        _next = page.nextStart;
        _more = page.hasMore;
        if (page.sorts.isNotEmpty) _sorts = page.sorts;
        if (page.tags.isNotEmpty) _tags = page.tags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.data,
    child: Scaffold(
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
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 18),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<DoubanKind>(
                    segments: [
                      for (final kind in DoubanKind.values)
                        ButtonSegment(value: kind, label: Text(kind.label)),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (values) {
                      setState(() {
                        _kind = values.single;
                        _sort = null;
                        _tag = null;
                        _sorts = [];
                        _tags = [];
                      });
                      _load();
                    },
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sort in _sorts)
                        ChoiceChip(
                          label: Text(sort.text),
                          selected:
                              _sort == sort.name ||
                              (_sort == null && sort.isDefault),
                          onSelected: (_) {
                            setState(() => _sort = sort.name);
                            _load();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (_tags.isNotEmpty)
                        FilterChip(
                          label: const Text('全部'),
                          selected: _tag == null,
                          onSelected: (_) {
                            setState(() => _tag = null);
                            _load();
                          },
                        ),
                      for (final tag in _tags)
                        FilterChip(
                          label: Text(tag),
                          selected: _tag == tag,
                          onSelected: (_) {
                            setState(() => _tag = _tag == tag ? null : tag);
                            _load();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '数据来自豆瓣选电影 / 选剧集。点击作品后搜索已启用片源；列表范围以豆瓣当前公开返回为准。',
                    style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: CinemaTheme.copper),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.crossAxisExtent / 185)
                    .floor()
                    .clamp(2, 7);
                return SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 20,
                    childAspectRatio: .54,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return InkWell(
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
                                child: CachedNetworkImage(
                                  memCacheWidth: 480,
                                  imageUrl: item.poster,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => const ColoredBox(
                                    color: CinemaTheme.raised,
                                    child: Center(
                                      child: Icon(Icons.movie_outlined),
                                    ),
                                  ),
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
                            style: const TextStyle(
                              color: CinemaTheme.copper,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : _more
                    ? OutlinedButton(
                        onPressed: () => _load(append: true),
                        child: const Text('加载更多'),
                      )
                    : Text(
                        _items.isEmpty ? '暂无可显示的作品' : '已显示当前公开列表',
                        style: const TextStyle(color: CinemaTheme.muted),
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
