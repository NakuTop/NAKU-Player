import 'cinema_models.dart';

int cinemaVersionQuality(String label) {
  final text = label.toUpperCase();
  if (RegExp(
    r'(^|[^A-Z])(TC|TS|TD|CAM|HDCAM)([^A-Z]|$)|枪版|抢先',
  ).hasMatch(text)) {
    return -10;
  }
  if (RegExp(r'2160|4K|UHD|蓝光原盘').hasMatch(text)) return 4;
  if (RegExp(r'1080|FHD|蓝光|BLURAY').hasMatch(text)) return 3;
  if (RegExp(r'720|HD|BD|高清').hasMatch(text)) return 2;
  if (RegExp(r'480|DVD|SD').hasMatch(text)) return 1;
  return 0;
}

bool cinemaHasMovieVersions(CinemaTitle title, int route) {
  if (route < 0 || route >= title.routes.length) return false;
  if (RegExp(
    '连续剧|电视剧|国产剧|欧美剧|香港剧|韩国剧|日本剧|台湾剧|泰国剧|海外剧|动漫|综艺|解说|影评',
  ).hasMatch(title.category)) {
    return false;
  }
  final episodes = title.routes[route].episodes;
  // Only explicit full-film edition labels; never numbered episodes or parts.
  return episodes.isNotEmpty &&
      episodes.every(
        (episode) => RegExp(
          r'^(?:(?:TC|TS|TD|CAM|HDCAM|HD|BD|SD|DVD|FHD|UHD|4K|720P?|1080P?|2160P?)(?:中字|国语|英语|中英双字|高清|版)?|正片|高清|蓝光|超清|抢先版|枪版)$',
          caseSensitive: false,
        ).hasMatch(episode.name.trim()),
      );
}

int cinemaPreferredEpisode(CinemaTitle title, int route) {
  if (!cinemaHasMovieVersions(title, route)) return 0;
  final episodes = title.routes[route].episodes;
  var best = 0;
  for (var i = 1; i < episodes.length; i++) {
    if (cinemaVersionQuality(episodes[i].name) >
        cinemaVersionQuality(episodes[best].name)) {
      best = i;
    }
  }
  return best;
}

int cinemaPreferredRoute(CinemaTitle title) {
  var best = -1, bestScore = -100;
  for (var i = 0; i < title.routes.length; i++) {
    final route = title.routes[i];
    if (route.episodes.isEmpty) continue;
    final score = cinemaHasMovieVersions(title, i)
        ? cinemaVersionQuality(
            route.episodes[cinemaPreferredEpisode(title, i)].name,
          )
        : cinemaVersionQuality(route.name);
    if (best < 0 || score > bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return best;
}
