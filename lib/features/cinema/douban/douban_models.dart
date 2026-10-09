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
    this.originalTitle = '',
    this.cardSubtitle = '',
    this.actors = const [],
    this.genres = const [],
    this.regions = const [],
  });

  final String id;
  final String title;
  final DoubanKind kind;
  final String year;
  final String poster;
  final double? score;
  final int? ratingCount;
  final String originalTitle;
  final String cardSubtitle;
  final List<String> actors;
  final List<String> genres;
  final List<String> regions;
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
    final subtitle = _text(json['card_subtitle']);
    final parts = subtitle.split(RegExp(r'\s+/\s+'));
    // The public card format starts with year / region / genre. A four-part
    // card can omit either director or actors, so never guess that last field.
    final structuredSubtitle =
        parts.length >= 3 &&
        parts.first == _text(json['year']) &&
        RegExp(r'^\d{4}$').hasMatch(parts.first);
    List<String> metadata(String key, int subtitleIndex) {
      final direct = _names(json[key]);
      if (direct.isNotEmpty) return direct;
      if (!structuredSubtitle || subtitleIndex >= parts.length) return const [];
      if (key == 'actors' && parts.length != 5) return const [];
      // Keep the actor segment intact: spaces can belong to an English name.
      return key == 'actors'
          ? [parts[subtitleIndex]]
          : parts[subtitleIndex].split(RegExp(r'\s+'));
    }

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
      originalTitle: _text(json['original_title']),
      cardSubtitle: subtitle,
      actors: List.unmodifiable(metadata('actors', 4)),
      genres: List.unmodifiable(metadata('genres', 2)),
      regions: List.unmodifiable(metadata('countries', 1)),
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

/// Independent selections, serialized like the filters on Douban's own pages.
class DoubanFilters {
  const DoubanFilters({
    this.format = '',
    this.genre = '',
    this.region = '',
    this.year = '',
    this.platform = '',
  });

  final String format, genre, region, year, platform;
  bool get isEmpty =>
      [format, genre, region, year, platform].every((value) => value.isEmpty);

  DoubanFilters copyWith({
    String? format,
    String? genre,
    String? region,
    String? year,
    String? platform,
  }) => DoubanFilters(
    format: format ?? this.format,
    genre: genre ?? this.genre,
    region: region ?? this.region,
    year: year ?? this.year,
    platform: platform ?? this.platform,
  );

  Map<String, String> categories(DoubanKind kind) => {
    if (genre.isNotEmpty) '类型': genre,
    if (region.isNotEmpty) '地区': region,
    if (kind == DoubanKind.tv && format.isNotEmpty) '形式': format,
  };

  List<String> tags(DoubanKind kind) => [
    if (genre.isNotEmpty) genre,
    if (genre.isEmpty && kind == DoubanKind.tv && format.isNotEmpty) format,
    if (region.isNotEmpty) region,
    if (year.isNotEmpty) year,
    if (kind == DoubanKind.tv && platform.isNotEmpty) platform,
  ];
}

/// Stable taxonomy from recommend_categories, not personalized recommend_tags.
class DoubanCategoryGroup {
  const DoubanCategoryGroup({
    required this.name,
    this.tags = const [],
    this.groupName = '',
    this.groups = const {},
  });
  final String name, groupName;
  final List<String> tags;
  final Map<String, List<String>> groups;

  List<String> options({String format = ''}) {
    if (groups.isEmpty) return tags;
    if (format.isNotEmpty && groups.containsKey(format)) return groups[format]!;
    return {for (final values in groups.values) ...values}.toList();
  }
}

class DoubanResultPage {
  const DoubanResultPage({
    required this.items,
    required this.start,
    required this.nextStart,
    required this.hasMore,
    this.sorts = const [],
    this.tags = const [],
    this.categoryGroups = const [],
    this.total,
  });
  final List<DoubanTitle> items;
  final int start;
  final int nextStart;
  final bool hasMore;
  final int? total;
  final List<DoubanSort> sorts;
  final List<String> tags;
  final List<DoubanCategoryGroup> categoryGroups;

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
      categoryGroups: parseDoubanCategoryGroups(json['recommend_categories']),
    );
  }
}

List<DoubanCategoryGroup> parseDoubanCategoryGroups(Object? raw) {
  if (raw is! List) return const [];
  final parsed = <String, DoubanCategoryGroup>{};
  for (final item in raw) {
    if (item is! Map || item['data'] is! List) continue;
    final name = _text(item['type']);
    if (name.isEmpty) continue;
    final nested = _text(item['tag_groups']);
    final tags = <String>{};
    final groups = <String, List<String>>{};
    for (final entry in item['data'] as List) {
      if (entry is! Map) continue;
      final text = _text(entry['text']);
      if (text.isEmpty || _allValues.contains(text)) continue;
      if (nested.isEmpty) {
        tags.add(text);
      } else if (text != name) {
        final values = _strings(
          entry['tags'],
        ).where((value) => !_allValues.contains(value)).toList();
        if (values.isNotEmpty) groups[text] = List.unmodifiable(values);
      }
    }
    if (tags.isNotEmpty || groups.isNotEmpty) {
      parsed[name] = DoubanCategoryGroup(
        name: name,
        tags: List.unmodifiable(tags),
        groupName: nested,
        groups: Map.unmodifiable(groups),
      );
    }
  }
  return List.unmodifiable([
    for (final name in const ['类型', '地区'])
      if (parsed.containsKey(name)) parsed.remove(name)!,
    ...parsed.values,
  ]);
}

const _allValues = {'全部', '不限类型', '全部剧集', '全部综艺'};

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

List<String> _names(Object? value) => value is List
    ? value
          .map((entry) => entry is Map ? _text(entry['name']) : _text(entry))
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList()
    : const [];
