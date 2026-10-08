import 'dart:async';

import 'cinema_grouping.dart';
import 'cinema_models.dart';
import 'cinema_repository.dart';

/// A concrete source, route and episode. Indexes only identify a selection
/// inside this title; they are never used to match episodes across sources.
class CinemaPlaybackCandidate {
  const CinemaPlaybackCandidate({
    required this.title,
    required this.source,
    required this.routeIndex,
    required this.episodeIndex,
  });

  final CinemaTitle title;
  final CinemaSource source;
  final int routeIndex;
  final int episodeIndex;
  CinemaRoute get route => title.routes[routeIndex];
  CinemaEpisode get episode => route.episodes[episodeIndex];
  String get key => '${title.key}::$routeIndex::$episodeIndex';
}

bool cinemaSamePlaybackWork(CinemaTitle first, CinemaTitle second) =>
    first.key == second.key || groupCinemaTitles([first, second]).length == 1;

/// Conservative episode matching, independent of provider ordering. Multiple
/// matches are ambiguous. Full-film label aliases only apply to single-episode
/// movie routes, never to a series' sole available episode.
int? cinemaMatchPlaybackEpisode({
  required CinemaPlaybackCandidate current,
  required CinemaTitle target,
  required int routeIndex,
}) {
  if (!cinemaSamePlaybackWork(current.title, target) ||
      routeIndex < 0 ||
      routeIndex >= target.routes.length) {
    return null;
  }
  final episodes = target.routes[routeIndex].episodes;
  int? unique(bool Function(CinemaEpisode) matches) {
    final indexes = [
      for (var i = 0; i < episodes.length; i++)
        if (matches(episodes[i])) i,
    ];
    return indexes.length == 1 ? indexes.single : null;
  }

  if (current.episode.url.isNotEmpty) {
    final urls = episodes.where((e) => e.url == current.episode.url).length;
    if (urls > 0) {
      return urls == 1 ? unique((e) => e.url == current.episode.url) : null;
    }
  }
  final name = _episodeName(current.episode.name);
  if (name.isNotEmpty) {
    final names = episodes.where((e) => _episodeName(e.name) == name).length;
    if (names > 0) {
      return names == 1 ? unique((e) => _episodeName(e.name) == name) : null;
    }
  }
  if (_movie(current.title) &&
      _movie(target) &&
      current.route.episodes.length == 1 &&
      episodes.length == 1 &&
      _fullFilm(current.episode.name) &&
      _fullFilm(episodes.single.name)) {
    return 0;
  }
  return null;
}

String _episodeName(String value) {
  final text = value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final number =
      RegExp(r'^(?:第)?([0-9]{1,4})(?:集|话)?$').firstMatch(text) ??
      RegExp(r'^(?:ep|episode)[._-]?([0-9]{1,4})$').firstMatch(text);
  if (number != null) return 'episode:${int.parse(number[1]!)}';
  return text;
}

bool _movie(CinemaTitle title) =>
    !RegExp('动漫|动画|剧|解说|影评|纪录|记录片').hasMatch(title.category) &&
    RegExp(
      '电影|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|悬疑片|犯罪片|奇幻片|冒险片|惊悚片',
    ).hasMatch(title.category);

bool _fullFilm(String name) => RegExp(
  r'^(?:正片|高清|蓝光|超清|hd|bd|hd中字|hd国语|hd英语|hd中英双字|720p|1080p|2160p|4k)$',
  caseSensitive: false,
).hasMatch(name.trim());

/// One episode selection has a finite attempt budget, even if every route
/// times out. Manual retry/episode selection creates a new ledger.
class CinemaFailoverAttempts {
  CinemaFailoverAttempts({this.limit = 8});
  final int limit;
  final Set<String> _attempted = {};
  int get count => _attempted.length;
  bool get exhausted => count >= limit;
  bool contains(CinemaPlaybackCandidate candidate) =>
      _attempted.contains(candidate.key);
  bool claim(CinemaPlaybackCandidate candidate) {
    if (exhausted || contains(candidate)) return false;
    _attempted.add(candidate.key);
    return true;
  }
}

/// The selected detail is available immediately. Other details are fetched
/// lazily, de-duplicated, and bounded; a failure is cached until manual retry.
class CinemaPlaybackCatalogue {
  CinemaPlaybackCatalogue({
    required CinemaTitle title,
    required CinemaSource source,
    required Iterable<CinemaTitle> variants,
    required Iterable<CinemaSource> sources,
    required this.repository,
    this.detailTimeout = const Duration(seconds: 18),
  }) : _anchor = title,
       _sources = {
         for (final item in sources)
           if (item.enabled) item.id: item,
         source.id: source,
       } {
    this.variants = List.unmodifiable(
      groupCinemaTitles([title, ...variants])
          .firstWhere(
            (group) => group.variants.any((item) => item.key == title.key),
          )
          .variants
          .where((item) => _sources.containsKey(item.sourceId)),
    );
    _loaded[title.key] = title;
    for (final item in this.variants) {
      if (item.routes.isNotEmpty) _loaded[item.key] = item;
    }
  }

  final CinemaTitle _anchor;
  final Map<String, CinemaSource> _sources;
  final CinemaRepository repository;
  final Duration detailTimeout;
  late List<CinemaTitle> variants;
  void addVariants(Iterable<CinemaTitle> values) {
    variants = List.unmodifiable(
      groupCinemaTitles([
        _anchor,
        ...variants,
        ...values,
      ]).first.variants.where((v) => _sources.containsKey(v.sourceId)),
    );
    for (final item in variants) {
      if (item.routes.isNotEmpty) _loaded.putIfAbsent(item.key, () => item);
    }
  }

  final Map<String, CinemaTitle> _loaded = {};
  final Map<String, Future<CinemaTitle>> _pending = {};
  final Map<String, String> errors = {};

  CinemaSource sourceFor(CinemaTitle title) => _sources[title.sourceId]!;
  CinemaTitle? loaded(CinemaTitle title) => _loaded[title.key];
  bool isLoading(CinemaTitle title) => _pending.containsKey(title.key);
  Iterable<CinemaTitle> get unread => variants.where(
    (title) =>
        !_loaded.containsKey(title.key) && !errors.containsKey(title.key),
  );

  Future<CinemaTitle> load(CinemaTitle title, {bool retry = false}) {
    final current = _loaded[title.key];
    if (current != null) return Future.value(current);
    if (!retry && errors.containsKey(title.key)) {
      return Future.error(CinemaSourceException(errors[title.key]!));
    }
    errors.remove(title.key);
    return _pending.putIfAbsent(title.key, () {
      return repository
          .detail(sourceFor(title), title)
          .timeout(detailTimeout)
          .then((detail) {
            if (detail.key != title.key ||
                !cinemaSamePlaybackWork(_anchor, detail)) {
              throw const CinemaSourceException('返回的作品与当前影片不一致，请手动核对。');
            }
            _loaded[title.key] = detail;
            return detail;
          })
          .catchError((Object error) {
            final message = error is TimeoutException
                ? '读取线路超时，可手动重试'
                : '暂未读到线路，可手动重试';
            errors[title.key] = message;
            throw CinemaSourceException(message);
          })
          .whenComplete(() {
            _pending.remove(title.key);
          });
    });
  }

  Iterable<CinemaPlaybackCandidate> matching(
    CinemaPlaybackCandidate current,
  ) sync* {
    for (final variant in variants) {
      final title = loaded(variant);
      if (title == null) continue;
      for (var route = 0; route < title.routes.length; route++) {
        final episode = cinemaMatchPlaybackEpisode(
          current: current,
          target: title,
          routeIndex: route,
        );
        if (episode != null) {
          yield CinemaPlaybackCandidate(
            title: title,
            source: sourceFor(title),
            routeIndex: route,
            episodeIndex: episode,
          );
        }
      }
    }
  }
}
