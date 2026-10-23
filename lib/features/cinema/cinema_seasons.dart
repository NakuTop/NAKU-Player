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

final _seasonSuffix = RegExp(
  r'(?:第[一二三四五六七八九十0-9]{1,3}季|\s+season\s+\d{1,2}|\s+s\d{1,2})$',
  caseSensitive: false,
);
final _seasonId = RegExp(r'^(\d+)~s([1-9][0-9]?)$');
final _episode = RegExp(
  r'^(?:第\s*(\d{1,2})\s*季\s*第\s*(\d{1,4})\s*集|s(\d{1,2})\s*e(\d{1,4}))$',
  caseSensitive: false,
);

String cinemaCatalogId(String id) => _seasonId.firstMatch(id)?[1] ?? id;
bool cinemaIsSeasonProjection(CinemaTitle title) =>
    _seasonId.hasMatch(title.id);

List<String> cinemaWorkQueries(CinemaTitle title) {
  final name = cinemaSourceQuery(cinemaMediaBaseTitle(title.title));
  return {
    name,
    name.replaceFirst(_seasonSuffix, '').trim(),
    for (final alias in title.aliases.split(RegExp(r'[/／]')).take(1))
      cinemaSourceQuery(alias),
  }.where((query) => query.isNotEmpty).take(3).toList();
}

/// Split explicitly season-labelled bundles, never infer a season from order.
/// Virtual IDs retain the original API ID losslessly (including 64-bit IDs).
List<CinemaTitle> cinemaSplitSeasons(CinemaTitle title) {
  if (!RegExp(r'^\d+$').hasMatch(title.id) ||
      !title.category.contains('剧') ||
      _seasonSuffix.hasMatch(cinemaSourceQuery(title.title)) ||
      title.routes.isEmpty) {
    return [title];
  }
  final seasons = <int, List<CinemaRoute>>{};
  for (final route in title.routes) {
    final groups = <int, List<CinemaEpisode>>{};
    for (final episode in route.episodes) {
      final match = _episode.firstMatch(episode.name.trim());
      // Unknown specials or ambiguous labels keep the original bundle intact.
      if (match == null) return [title];
      final season = int.parse(match[1] ?? match[3]!);
      final number = int.parse(match[2] ?? match[4]!);
      if (season < 1 || number < 1) return [title];
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
        // A bundle's premiere year and ratings cannot describe later seasons.
        if (season != 1) ...{
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
