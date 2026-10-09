import 'package:html/parser.dart' as html;

enum CinemaSourceKind { maccms, kazumi }

/// Sorting is limited to the supplied, already loaded catalogue items.
enum CinemaCatalogSort { latest, popular }

/// Independent source identity; it never shares Bangumi subject IDs.
class CinemaSource {
  const CinemaSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.url,
    this.enabled = true,
    this.rule,
    this.description = '',
    this.requestHeaders = const {},
  });

  final String id;
  final String name;
  final CinemaSourceKind kind;
  final String url;
  final bool enabled;
  final Map<String, dynamic>? rule;
  final String description;
  final Map<String, String> requestHeaders;

  Map<String, String> get headers => {
    ...requestHeaders,
    if ((rule?['userAgent']?.toString() ?? '').isNotEmpty)
      'User-Agent': rule!['userAgent'].toString(),
    if ((rule?['referer']?.toString() ?? '').isNotEmpty)
      'Referer': rule!['referer'].toString(),
  };

  CinemaSource copyWith({
    String? id,
    String? name,
    CinemaSourceKind? kind,
    String? url,
    bool? enabled,
    Map<String, dynamic>? rule,
    String? description,
    Map<String, String>? requestHeaders,
  }) => CinemaSource(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    url: url ?? this.url,
    enabled: enabled ?? this.enabled,
    rule: rule ?? this.rule,
    description: description ?? this.description,
    requestHeaders: requestHeaders ?? this.requestHeaders,
  );

  void validate() {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw const FormatException('片源名称和 ID 不能为空');
    }
    requireHttpUrl(url);
    for (final entry in headers.entries) {
      if (entry.key.contains(RegExp(r'[\r\n:]')) ||
          entry.value.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException('请求头格式无效');
      }
    }
    if (kind == CinemaSourceKind.kazumi) {
      final config = rule;
      if (config == null) throw const FormatException('动漫源缺少 Kazumi 规则');
      for (final field in ['searchMode', 'chapterMode']) {
        if (config[field] != null && config[field] != 'xpath') {
          throw const FormatException('个人影院目前仅支持 XPath 动漫规则');
        }
      }
      final anti = config['antiCrawlerConfig'];
      if (anti is Map &&
          (anti['enabled'] == true ||
              (anti['captchaScript']?.toString().isNotEmpty ?? false))) {
        throw const FormatException('个人影院不执行验证码脚本，请使用普通 XPath 规则');
      }
      requireHttpUrl(config['baseURL']?.toString() ?? url);
      requireHttpUrl(config['searchURL']?.toString() ?? '');
      for (final field in [
        'searchList',
        'searchName',
        'searchResult',
        'chapterRoads',
        'chapterResult',
      ]) {
        if ((config[field]?.toString() ?? '').isEmpty) {
          throw FormatException('动漫规则缺少 $field');
        }
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'url': url,
    'enabled': enabled,
    'description': description,
    if (rule != null) 'rule': rule,
    if (requestHeaders.isNotEmpty) 'headers': requestHeaders,
  };

  factory CinemaSource.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind']?.toString();
    final kind = CinemaSourceKind.values
        .where((item) => item.name == kindName)
        .firstOrNull;
    if (kind == null) throw FormatException('不支持的片源类型: $kindName');
    final source = CinemaSource(
      id: textValue(json['id']),
      name: textValue(json['name']),
      kind: kind,
      url: textValue(json['url']),
      enabled: json['enabled'] != false,
      description: textValue(json['description']),
      rule: json['rule'] is Map
          ? Map<String, dynamic>.from(json['rule'])
          : null,
      requestHeaders: json['headers'] is Map
          ? (json['headers'] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
    );
    source.validate();
    return source;
  }
}

class CinemaEpisode {
  const CinemaEpisode({required this.name, required this.url});
  final String name;
  final String url;
  bool get isDirect => RegExp(
    r'\.(m3u8|mp4|webm|mkv|mov|m4v|mpd)$',
    caseSensitive: false,
  ).hasMatch(Uri.tryParse(url)?.path ?? '');
  Map<String, dynamic> toJson() => {'name': name, 'url': url};
  factory CinemaEpisode.fromJson(Map<String, dynamic> json) => CinemaEpisode(
    name: textValue(json['name']),
    url: requireHttpUrl(textValue(json['url'])).toString(),
  );
}

class CinemaRoute {
  const CinemaRoute({required this.name, required this.episodes});
  final String name;
  final List<CinemaEpisode> episodes;
  Map<String, dynamic> toJson() => {
    'name': name,
    'episodes': episodes.map((e) => e.toJson()).toList(),
  };
  factory CinemaRoute.fromJson(Map<String, dynamic> json) => CinemaRoute(
    name: textValue(json['name']),
    episodes: jsonMaps(json['episodes']).map(CinemaEpisode.fromJson).toList(),
  );
}

class CinemaTitle {
  const CinemaTitle({
    required this.id,
    required this.sourceId,
    required this.title,
    this.poster = '',
    this.description = '',
    this.category = '',
    this.categoryId = '',
    this.year = '',
    this.remarks = '',
    this.actors = '',
    this.director = '',
    this.area = '',
    this.language = '',
    this.genres = '',
    this.durationText = '',
    this.aliases = '',
    this.sourceHits,
    this.sourceUpdatedAt,
    this.releaseDateText = '',
    this.doubanId = '',
    this.sourceDoubanScore,
    this.imdbId = '',
    this.rottenTomatoesId = '',
    this.routes = const [],
  });
  final String id;
  final String sourceId;
  final String title;
  final String poster;
  final String description;
  final String category;
  final String categoryId;
  final String year;
  final String remarks;
  final String actors;
  final String director;
  final String area;
  final String language;
  final String genres;
  final String durationText;
  final String aliases;

  /// Provider-supplied metadata, not independently verified viewing or ratings.
  final int? sourceHits;
  final DateTime? sourceUpdatedAt;
  final String releaseDateText;
  final String doubanId;

  /// The source's transcription of a Douban score, never the source's own score.
  final double? sourceDoubanScore;
  final String imdbId;
  final String rottenTomatoesId;
  final List<CinemaRoute> routes;
  String get key => '$sourceId::$id';
  CinemaTitle copyWith({List<CinemaRoute>? routes}) => CinemaTitle(
    id: id,
    sourceId: sourceId,
    title: title,
    poster: poster,
    description: description,
    category: category,
    categoryId: categoryId,
    year: year,
    remarks: remarks,
    actors: actors,
    director: director,
    area: area,
    language: language,
    genres: genres,
    durationText: durationText,
    aliases: aliases,
    sourceHits: sourceHits,
    sourceUpdatedAt: sourceUpdatedAt,
    releaseDateText: releaseDateText,
    doubanId: doubanId,
    sourceDoubanScore: sourceDoubanScore,
    imdbId: imdbId,
    rottenTomatoesId: rottenTomatoesId,
    routes: routes ?? this.routes,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'title': title,
    'poster': poster,
    'description': description,
    'category': category,
    'categoryId': categoryId,
    'year': year,
    'remarks': remarks,
    'actors': actors,
    'director': director,
    'area': area,
    'language': language,
    'genres': genres,
    'durationText': durationText,
    'aliases': aliases,
    'sourceHits': sourceHits,
    'sourceUpdatedAt': sourceUpdatedAt?.toIso8601String(),
    'releaseDateText': releaseDateText,
    'doubanId': doubanId,
    'sourceDoubanScore': sourceDoubanScore,
    'imdbId': imdbId,
    'rottenTomatoesId': rottenTomatoesId,
    'routes': routes.map((route) => route.toJson()).toList(),
  };
  factory CinemaTitle.fromJson(Map<String, dynamic> json) => CinemaTitle(
    id: textValue(json['id']),
    sourceId: textValue(json['sourceId']),
    title: textValue(json['title']),
    poster: textValue(json['poster']),
    description: textValue(json['description']),
    category: textValue(json['category']),
    categoryId: textValue(json['categoryId']),
    year: textValue(json['year']),
    remarks: textValue(json['remarks']),
    actors: textValue(json['actors']),
    director: textValue(json['director']),
    area: textValue(json['area']),
    language: textValue(json['language']),
    genres: textValue(json['genres']),
    durationText: textValue(json['durationText']),
    aliases: textValue(json['aliases']),
    sourceHits: parseCinemaSourceHits(json['sourceHits']),
    sourceUpdatedAt: parseCinemaSourceUpdatedAt(json['sourceUpdatedAt']),
    releaseDateText: textValue(json['releaseDateText']),
    doubanId: parseCinemaDoubanId(json['doubanId']),
    sourceDoubanScore: parseCinemaSourceDoubanScore(json['sourceDoubanScore']),
    imdbId: parseCinemaImdbId(json['imdbId']),
    rottenTomatoesId: parseCinemaRottenTomatoesId(json['rottenTomatoesId']),
    routes: jsonMaps(json['routes']).map(CinemaRoute.fromJson).toList(),
  );
}

/// A stable copy: missing values go last and equal values retain source order.
/// This does not create a source-wide chart or compare external rating ranks.
List<CinemaTitle> sortCinemaTitles(
  Iterable<CinemaTitle> items,
  CinemaCatalogSort sort,
) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final comparison = switch (sort) {
      CinemaCatalogSort.latest => _compareNullableDescending(
        a.$2.sourceUpdatedAt,
        b.$2.sourceUpdatedAt,
        (a, b) => b.compareTo(a),
      ),
      CinemaCatalogSort.popular => _compareNullableDescending(
        a.$2.sourceHits,
        b.$2.sourceHits,
        (a, b) => b.compareTo(a),
      ),
    };
    return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
  });
  return indexed.map((entry) => entry.$2).toList();
}

int _compareNullableDescending<T>(T? a, T? b, int Function(T, T) compare) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return compare(a, b);
}

int? parseCinemaSourceHits(Object? value) {
  if (value is int) return value >= 0 ? value : null;
  // Do not truncate fractional counts or silently clamp large floating values.
  if (value is double) {
    return value.isFinite &&
            value >= 0 &&
            value <= 9007199254740991 &&
            value == value.roundToDouble()
        ? value.toInt()
        : null;
  }
  if (value is! String || !RegExp(r'^[0-9]+$').hasMatch(value.trim())) {
    return null;
  }
  return int.tryParse(value.trim());
}

DateTime? parseCinemaSourceUpdatedAt(Object? value) {
  final seconds = parseCinemaSourceHits(value);
  if (seconds != null) {
    // Only Unix seconds; do not interpret millisecond inputs as far-future dates.
    if (seconds > 253402300799) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }
  if (value is! String) return null;
  final text = value.trim();
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d{1,6})?)?(?: ?[zZ]| ?[+-]\d{2}(?::?\d{2})?)?)?$',
  ).firstMatch(text);
  if (parts == null) return null;
  final year = int.parse(parts[1]!);
  final month = int.parse(parts[2]!);
  final day = int.parse(parts[3]!);
  final calendarDate = DateTime.utc(year, month, day);
  if (year < 1 ||
      calendarDate.year != year ||
      calendarDate.month != month ||
      calendarDate.day != day ||
      int.parse(parts[4] ?? '0') > 23 ||
      int.parse(parts[5] ?? '0') > 59 ||
      int.parse(parts[6] ?? '0') > 59) {
    return null;
  }
  return DateTime.tryParse(text);
}

String parseCinemaDoubanId(Object? value) {
  final id = value is String || value is int ? value.toString().trim() : '';
  return RegExp(r'^[1-9][0-9]*$').hasMatch(id) ? id : '';
}

double? parseCinemaSourceDoubanScore(Object? value) {
  final score = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return score != null && score.isFinite && score > 0 && score <= 10
      ? score
      : null;
}

String parseCinemaImdbId(Object? value) {
  final id = value is String ? value.trim() : '';
  return RegExp(r'^tt[0-9]{7,10}$').hasMatch(id) ? id : '';
}

String parseCinemaRottenTomatoesId(Object? value) {
  final id = value is String ? value.trim() : '';
  return RegExp(
        r'^(?:m/[a-z0-9][a-z0-9_-]*|tv/[a-z0-9][a-z0-9_-]*(?:/s[0-9]{2})?)$',
      ).hasMatch(id)
      ? id
      : '';
}

class CinemaCategory {
  const CinemaCategory({
    required this.id,
    required this.name,
    this.parentId = '',
  });
  final String id;
  final String name;
  final String parentId;
}

class CinemaPage {
  const CinemaPage({
    required this.items,
    this.categories = const [],
    this.page = 1,
    this.pageCount = 1,
    this.total = 0,
  });
  final List<CinemaTitle> items;
  final List<CinemaCategory> categories;
  final int page;
  final int pageCount;
  final int total;
  bool get hasMore => page < pageCount;
}

class CinemaHistory {
  const CinemaHistory({
    required this.title,
    required this.routeIndex,
    required this.episodeIndex,
    required this.positionSeconds,
    this.durationSeconds = 0,
    required this.updatedAt,
  });
  final CinemaTitle title;
  final int routeIndex;
  final int episodeIndex;
  final int positionSeconds;
  final int durationSeconds;
  final DateTime updatedAt;
  Map<String, dynamic> toJson() => {
    'title': title.toJson(),
    'routeIndex': routeIndex,
    'episodeIndex': episodeIndex,
    'positionSeconds': positionSeconds,
    'durationSeconds': durationSeconds,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory CinemaHistory.fromJson(Map<String, dynamic> json) => CinemaHistory(
    title: CinemaTitle.fromJson(
      Map<String, dynamic>.from(json['title'] as Map),
    ),
    routeIndex: intValue(json['routeIndex']),
    episodeIndex: intValue(json['episodeIndex']),
    positionSeconds: intValue(json['positionSeconds']),
    durationSeconds: intValue(json['durationSeconds']),
    updatedAt:
        DateTime.tryParse(textValue(json['updatedAt'])) ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

Uri requireHttpUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('地址必须是完整的 HTTP 或 HTTPS URL，不能包含账号密码');
  }
  return uri;
}

String textValue(Object? value) => value?.toString() ?? '';
int intValue(Object? value, [int fallback = 0]) =>
    int.tryParse(textValue(value)) ?? fallback;
List<Map<String, dynamic>> jsonMaps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : [];
String cleanCinemaText(Object? value) {
  final fragment = html.parseFragment(
    textValue(value).replaceAll(
      RegExp(
        r'</?(p|div|br|li|h[1-6]|tr|td)(\s[^>]*)?/?>',
        caseSensitive: false,
      ),
      ' ',
    ),
  );
  for (final node in fragment.querySelectorAll('script,style')) {
    node.remove();
  }
  return (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}
