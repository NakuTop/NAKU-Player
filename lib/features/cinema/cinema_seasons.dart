import 'cinema_catalog_categories.dart';
import 'cinema_models.dart';
import 'cinema_media_identity.dart';

/// Chinese catalogue names often omit the spaces used by metadata providers.
/// Preserve English word boundaries and spaces around punctuation.
String cinemaSourceQuery(String title) => title.trim().replaceAll(
  RegExp(
    r'(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff0-9])|(?<=[0-9])\s+(?=[\u3400-\u9fff])',
  ),
  '',
);

final _seasonId = RegExp(r'^(\d+)~s([1-9][0-9]?)$');
final _episode = RegExp(
  r'^(?:第\s*([0-9一二两兩三四五六七八九十]{1,4})\s*季[\s._-]*第\s*([0-9一二两兩三四五六七八九十]{1,4})\s*[集话話]|s(\d{1,2})[\s._-]*e(\d{1,4}))$',
  caseSensitive: false,
);

String cinemaCatalogId(String id) => _seasonId.firstMatch(id)?[1] ?? id;

bool cinemaMatchesWorkQuery(CinemaTitle title, String query) {
  if (cinemaSameSearchTitle(title.title, query, title.year)) return true;
  if (RegExp(
    '解说|解說|影评|影評|预告|預告|花絮',
  ).hasMatch('${title.title} ${title.category}')) {
    return false;
  }
  return [
    if (title.doubanId.isNotEmpty) cinemaRegionalTitle(title.title, title.year),
    ...cinemaTitleAliases(title.aliases),
  ].any((name) => cinemaSameSearchTitle(name, query, title.year));
}

bool cinemaMatchesSeasonQuery(CinemaTitle title, CinemaSeasonName query) {
  if (cinemaMatchesSeason(title.title, query)) return true;
  if (!cinemaVarietyCategory(title.category)) return false;
  final primary = cinemaSeasonName(
    cinemaCleanWorkTitle(
      title.title.replaceFirst(cinemaVarietyEdition, ''),
      title.year,
    ),
  );
  if (primary == null &&
      query.number == 1 &&
      !cinemaVarietyEdition.hasMatch(title.title)) {
    return cinemaSameSearchTitle(title.title, query.work, title.year);
  }
  if (primary?.number != query.number) return false;
  if (cinemaSameSearchTitle(primary!.work, query.work, title.year)) return true;
  return cinemaTitleAliases(title.aliases).any((alias) {
    final alternate = cinemaSeasonName(alias);
    if (alternate != null && alternate.number != query.number) return false;
    return cinemaSameSearchTitle(
      alternate?.work ?? alias,
      query.work,
      title.year,
    );
  });
}

final cinemaVarietyEdition = RegExp(
  r'\s*[（(【\[]?\s*(?:加更版?|会员版|會員版|纯享版?|純享版?|精编版|精編版|完整版)\s*[）)】\]]?\s*$',
);
final _showCoordinate = RegExp(
  r'^(?:第\s*([0-9一二两兩三四五六七八九十]+)\s*季\s*第\s*(\d+)\s*[集期]|S(\d{1,2})\s*E(\d+))\s*(.*)$',
  caseSensitive: false,
);
final _specialSeason = RegExp(r'^第\s*([0-9一二两兩三四五六七八九十]+)\s*季\s*(.+)$');
final _datedShow = RegExp(
  r'(?<!\d)((?:19|20)\d{2})(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)',
);

List<CinemaTitle> _varietySeasons(CinemaTitle title) {
  final groups = <int, List<CinemaRoute>>{};
  var unlabelled = false;
  for (final route in title.routes) {
    final parts = <int, List<CinemaEpisode>>{};
    bool special(CinemaEpisode e) => RegExp(
      r'^(?:第\s*0+\s*季|s0+e)',
      caseSensitive: false,
    ).hasMatch(e.name.trim());
    for (final e in [
      ...route.episodes.where((e) => !special(e)),
      ...route.episodes.where(special),
    ]) {
      final m = _showCoordinate.firstMatch(
        cinemaIdentityTypography(e.name).trim(),
      );
      if (m == null) {
        unlabelled = true;
        continue;
      }
      var season = cinemaSeasonNumber(m[1] ?? m[3]!);
      var label = m[5]!.trim();
      if ((m[1] ?? m[3]) == '0' || (m[1] ?? m[3]) == '00') {
        final inner = _specialSeason.firstMatch(label);
        if (inner == null) continue;
        season = cinemaSeasonNumber(inner[1]!);
        label = inner[2]!;
      }
      if (season == null || season < 1 || season > 99) continue;
      (parts[season] ??= []).add(
        CinemaEpisode(
          name: label.isEmpty ? '第${m[2] ?? m[4]}集' : label,
          url: e.url,
        ),
      );
    }
    for (final part in parts.entries) {
      (groups[part.key] ??= []).add(
        CinemaRoute(name: route.name, episodes: part.value),
      );
    }
  }
  if (groups.isEmpty || (groups.length == 1 && unlabelled)) return [title];
  final base = title.title.replaceFirst(cinemaVarietyEdition, '').trim();
  final work = cinemaSeasonName(base)?.work ?? base;
  final edition = title.title.substring(base.length).trim();
  final seasons = groups.keys.toList()..sort();
  return [
    for (final season in seasons)
      CinemaTitle.fromJson({
        ...title.toJson(),
        'id': '${title.id}~s$season',
        'title': '$work 第$season季$edition',
        'routes': groups[season]!.map((r) => r.toJson()).toList(),
        'year':
            (groups[season]!
                    .expand((r) => r.episodes)
                    .expand((e) => _datedShow.allMatches(e.name))
                    .map((m) => m[1]!)
                    .toList()
                  ..sort())
                .firstOrNull ??
            '',
        'releaseDateText': '',
        'doubanId': '',
        'imdbId': '',
        'rottenTomatoesId': '',
        'sourceDoubanScore': null,
      }),
  ];
}

bool cinemaIsSeasonProjection(CinemaTitle title) =>
    _seasonId.hasMatch(title.id);

List<String> cinemaWorkQueries(CinemaTitle title) {
  final name = cinemaSourceQuery(cinemaCleanWorkTitle(title.title, title.year));
  return {
    ...cinemaWorkSearchQueries(name),
    for (final alias in cinemaTitleAliases(title.aliases).take(3))
      cinemaSourceQuery(alias),
  }.where((query) => query.isNotEmpty).take(6).toList();
}

/// The same bounded query set is used regardless of how the season was typed.
List<String> cinemaSeasonQueries(CinemaSeasonName season) {
  final work = cinemaSourceQuery(season.work);
  final number = season.number;
  return [
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(work)) ...[
      '$work第$number季',
      '$work第${cinemaChineseSeasonNumber(number)}季',
    ] else ...[
      '$work Season $number',
      '$work S${number.toString().padLeft(2, '0')}',
    ],
    work,
  ];
}

/// Split explicitly season-labelled bundles, never infer a season from order.
/// Virtual IDs retain the original API ID losslessly (including 64-bit IDs).
List<CinemaTitle> cinemaSplitSeasons(CinemaTitle title) {
  if (cinemaVarietyCategory(title.category) &&
      RegExp(r'^\d+$').hasMatch(title.id)) {
    return _varietySeasons(title);
  }
  if (!RegExp(r'^\d+$').hasMatch(title.id) ||
      !RegExp('剧|劇|动漫|動漫|動畫|动画').hasMatch(title.category) ||
      cinemaSeasonName(title.title) != null ||
      title.routes.isEmpty) {
    return [title];
  }
  final seasons = <int, List<CinemaRoute>>{};
  for (final route in title.routes) {
    final groups = <int, List<CinemaEpisode>>{};
    for (final episode in route.episodes) {
      final match = _episode.firstMatch(
        cinemaIdentityTypography(episode.name).trim(),
      );
      // Unknown specials or ambiguous labels keep the original bundle intact.
      if (match == null) return [title];
      final season = cinemaSeasonNumber(match[1] ?? match[3]!);
      final digits = match[2] ?? match[4]!;
      final number = int.tryParse(digits) ?? cinemaSeasonNumber(digits);
      if (season == null || season < 1 || number == null || number < 1) {
        return [title];
      }
      groups
          .putIfAbsent(season, () => [])
          .add(
            CinemaEpisode(
              name: '第${number.toString().padLeft(2, '0')}集',
              url: episode.url,
            ),
          );
    }
    for (final entry in groups.entries) {
      seasons
          .putIfAbsent(entry.key, () => [])
          .add(CinemaRoute(name: route.name, episodes: entry.value));
    }
  }
  if (seasons.isEmpty) return [title];
  final numbers = seasons.keys.toList()..sort();
  return [
    for (final season in numbers)
      CinemaTitle.fromJson({
        ...title.toJson(),
        'id': '${title.id}~s$season',
        'title': '${title.title} 第$season季',
        'routes': seasons[season]!.map((r) => r.toJson()).toList(),
        // Providers often attach the latest season's metadata to the whole box set.
        if (seasons.length > 1 || season != 1) ...{
          'year': '',
          'releaseDateText': '',
          'doubanId': '',
          'imdbId': '',
          'rottenTomatoesId': '',
          'sourceDoubanScore': null,
        },
      }),
  ];
}
