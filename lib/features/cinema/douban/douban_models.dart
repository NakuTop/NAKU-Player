enum DoubanKind {
  movie('movie', '电影', '选电影', 'https://movie.douban.com/explore'),
  tv('tv', '剧集', '选剧集', 'https://movie.douban.com/tv/');

  const DoubanKind(this.apiType, this.label, this.pageTitle, this.pageUrl);
  final String apiType;
  final String label;
  final String pageTitle;
  final String pageUrl;
}

class DoubanTitle {
  const DoubanTitle({
    required this.id,
    required this.title,
    required this.kind,
    this.year = '',
    this.poster = '',
    this.score,
    this.ratingCount,
  });

  final String id;
  final String title;
  final DoubanKind kind;
  final String year;
  final String poster;
  final double? score;
  final int? ratingCount;
  String get subjectUrl => 'https://movie.douban.com/subject/$id/';

  static DoubanTitle? fromJson(Map<String, dynamic> json, DoubanKind kind) {
    // The official feed also includes advertisements and user-created lists.
    if (json['type'] != kind.apiType || json['card'] != 'subject') return null;
    final id = _text(json['id']);
    final title = _text(json['title']);
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(id) || title.isEmpty) return null;
    final picture = json['pic'];
    final poster = picture is Map
        ? _text(picture['large']).isNotEmpty
              ? _text(picture['large'])
              : _text(picture['normal'])
        : '';
    final uri = Uri.tryParse(poster);
    final rating = json['rating'];
    final value = rating is Map
        ? double.tryParse(_text(rating['value']))
        : null;
    final scale = rating is Map ? double.tryParse(_text(rating['max'])) : null;
    final count = rating is Map ? int.tryParse(_text(rating['count'])) : null;
    return DoubanTitle(
      id: id,
      title: title,
      kind: kind,
      year: _text(json['year']),
      poster: uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
          ? uri.toString()
          : '',
      score:
          value != null &&
              value.isFinite &&
              value > 0 &&
              value <= 10 &&
              scale == 10
          ? value
          : null,
      ratingCount: count != null && count >= 0 ? count : null,
    );
  }
}

class DoubanSort {
  const DoubanSort({
    required this.name,
    required this.text,
    this.isDefault = false,
  });
  final String name;
  final String text;
  final bool isDefault;
}

class DoubanTagGroup {
  const DoubanTagGroup({required this.name, required this.tags});
  final String name;
  final List<String> tags;
}

class DoubanResultPage {
  const DoubanResultPage({
    required this.items,
    required this.start,
    required this.nextStart,
    required this.hasMore,
    this.sorts = const [],
    this.tags = const [],
    this.total,
  });
  final List<DoubanTitle> items;
  final int start;
  final int nextStart;
  final bool hasMore;
  final int? total;
  final List<DoubanSort> sorts;
  final List<String> tags;

  static DoubanResultPage fromJson(
    Map<String, dynamic> json,
    DoubanKind kind, {
    required int start,
    required int count,
  }) {
    final rawItems = json['items'];
    if (rawItems is! List) throw const FormatException('豆瓣未返回有效作品列表');
    final seen = <String>{};
    final items = <DoubanTitle>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final title = DoubanTitle.fromJson(Map<String, dynamic>.from(item), kind);
      if (title != null && seen.add(title.id)) items.add(title);
    }
    final total = int.tryParse(_text(json['total']));
    final sorts = <DoubanSort>[];
    final sortIds = <String>{};
    if (json['sorts'] is List) {
      for (final item in json['sorts'] as List) {
        if (item is! Map) continue;
        final name = _text(item['name']);
        final text = _text(item['text']);
        if (name.isNotEmpty && text.isNotEmpty && sortIds.add(name)) {
          sorts.add(
            DoubanSort(
              name: name,
              text: text,
              isDefault: item['checked'] == true,
            ),
          );
        }
      }
    }
    return DoubanResultPage(
      items: List.unmodifiable(items),
      start: start,
      nextStart: start + count,
      // Offset follows the raw server page, not the number left after filtering.
      hasMore:
          rawItems.isNotEmpty &&
          (total != null ? start + count < total : rawItems.length >= count),
      total: total != null && total >= 0 ? total : null,
      sorts: List.unmodifiable(sorts),
      tags: _strings(json['recommend_tags']),
    );
  }
}

List<DoubanTagGroup> parseDoubanTagGroups(Map<String, dynamic> json) {
  final raw = json['tags'];
  if (raw is! List) throw const FormatException('豆瓣未返回有效标签列表');
  return [
    for (final item in raw)
      if (item is Map &&
          _text(item['type']).isNotEmpty &&
          _strings(item['tags']).isNotEmpty)
        DoubanTagGroup(name: _text(item['type']), tags: _strings(item['tags'])),
  ];
}

String _text(Object? value) =>
    value is String || value is num ? '$value'.trim() : '';
List<String> _strings(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
    : const [];
