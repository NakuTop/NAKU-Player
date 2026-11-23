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
