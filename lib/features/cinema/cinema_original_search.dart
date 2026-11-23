import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'cinema_media_identity.dart';
import 'cinema_models.dart';
import 'cinema_original_match.dart';
import 'cinema_search_discovery.dart';

// A catalogue-only identity can still be opened when the original is its only
// matching source. Its durable URL identifies the subject, never a local port.
const originalCatalogSource = CinemaSource(
  id: 'douban-discovery',
  name: '原画',
  kind: CinemaSourceKind.direct,
  url: 'https://movie.douban.com/',
);
Future<CinemaTitle?> originalCatalogDetail(
  CinemaTitle title, {
  CinemaOriginalSearch? search,
  String episode = '第1集',
}) async {
  if (title.sourceId != originalCatalogSource.id ||
      !RegExp(r'^\d+$').hasMatch(title.doubanId)) {
    return null;
  }
  final hasRoutes = title.routes.any((r) => r.episodes.isNotEmpty);
  if (hasRoutes && title.routes.first.episodes.length > 1) return title;
  final lookup = (search ?? CinemaOriginalSearch.instance).find(title, episode);
  await lookup.ready;
  final matches = lookup.matches;
  return matches == null
      ? (hasRoutes ? title : null)
      : originalCatalogAnchor(title, matches);
}

CinemaTitle? originalCatalogAnchor(CinemaTitle title, OriginalMatches matches) {
  final id = title.doubanId.isNotEmpty ? title.doubanId : matches.work.doubanId;
  if (parseCinemaDoubanId(id).isEmpty || matches.editions.isEmpty) return null;
  final series = matches.work.series;
  final listed = series
      ? (int.tryParse(
              RegExp(
                    r'(?:全|共)\s*(\d{1,3})\s*集',
                  ).firstMatch(title.remarks)?[1] ??
                  '',
            ) ??
            (matches.work.episodeCount > 0 ? matches.work.episodeCount : 1))
      : 1;
  final count = !series
      ? 1
      : [
          listed,
          matches.work.episodeCount,
          matches.work.episode ?? 1,
          title.routes.firstOrNull?.episodes.length ?? 0,
        ].reduce((a, b) => a > b ? a : b).clamp(1, 9999);
  return originalLibraryTitle(title, matches).copyWith(
    id: id,
    sourceId: originalCatalogSource.id,
    doubanId: id,
    routes: [
      CinemaRoute(
        name: '原画',
        episodes: [
          for (var i = 1; i <= count; i++)
            CinemaEpisode(
              name: series ? '第$i集' : '正片',
              url:
                  'https://movie.douban.com/subject/$id/#${series ? 'episode-$i' : 'film'}',
            ),
        ],
      ),
    ],
  );
}

/// Keep catalogue routes and keys stable for history, favorites and downloads.
CinemaTitle originalLibraryTitle(
  CinemaTitle title,
  OriginalMatches? matches, {
  OriginalEdition? edition,
  CinemaTitle? identity,
  bool keepEdition = true,
}) {
  if (matches == null && (identity == null || identical(identity, title))) {
    return title;
  }
  final work = matches?.work,
      previous = title.originalReference ?? identity?.originalReference;
  final aliases =
      {
          if (work != null && work.names.isNotEmpty)
            work.series
                ? '${work.names.first} Season ${work.season}'
                : work.names.first,
          ...cinemaTitleAliases(title.aliases),
          if (identity != null) ...[
            identity.title,
            ...cinemaTitleAliases(identity.aliases),
          ],
          if (work != null)
            for (final name in work.names)
              if (work.series) '$name Season ${work.season}' else name,
        }
        ..remove(title.title)
        ..remove('');
  return title.copyWith(
    doubanId: title.doubanId.isNotEmpty
        ? title.doubanId
        : (work?.doubanId.isNotEmpty == true
              ? work!.doubanId
              : identity?.doubanId),
    aliases: aliases.join(' / '),
    year: title.year.isNotEmpty ? title.year : identity?.year,
    category: title.category.isNotEmpty ? title.category : identity?.category,
    originalReference: work == null
        ? previous
        : CinemaOriginalReference(
            imdbId: work.imdbId.isNotEmpty
                ? work.imdbId
                : previous?.imdbId ?? '',
            premiere: (work.years.toList()..sort()).firstOrNull ?? '',
            season: work.season,
            episode: work.episode,
            hash:
                edition?.hash ??
                (keepEdition &&
                        previous?.season == work.season &&
                        previous?.episode == work.episode
                    ? previous?.hash ?? ''
                    : ''),
          ),
  );
}

/// Only send the identity of the selected film or episode. The TV opens its
/// own engine and independently resolves the edition from its catalogue.
({CinemaTitle title, CinemaSource source, int road, int episode})
originalCastTarget(
  CinemaTitle title,
  CinemaSource source,
  int road,
  int episode,
  OriginalSelection? selection,
) {
  if (selection == null) {
    return (title: title, source: source, road: road, episode: episode);
  }
  final work = selection.matches.work;
  final chosen = originalLibraryTitle(
    title,
    selection.matches,
    edition: selection.edition,
  );
  final anchor = originalCatalogAnchor(chosen, selection.matches);
  if (anchor != null) {
    return (
      title: anchor,
      source: originalCatalogSource,
      road: 0,
      episode: (work.episode ?? 1) - 1,
    );
  }
  // Some providers have an IMDb identity and no Douban subject. Retain their
  // work metadata and episode coordinate without transmitting the local URL.
  final identity = chosen.copyWith(
    sourceId: originalCatalogSource.id,
    id: chosen.key,
    routes: [
      CinemaRoute(
        name: '原画',
        episodes: [
          CinemaEpisode(
            name: work.series ? '第${work.episode}集' : '正片',
            url: originalCatalogSource.url,
          ),
        ],
      ),
    ],
  );
  return (title: identity, source: originalCatalogSource, road: 0, episode: 0);
}

class OriginalLookup extends ChangeNotifier {
  final _ready = Completer<void>();
  final _finished = Completer<void>();
  Future<void> get finished => _finished.future;
  DateTime? completedAt;
  OriginalMatches? matches;
  bool done = false;
  bool incomplete = false;
  Future<void> get ready => _ready.future;
  Future<void> waitForChinese({
    Duration budget = const Duration(milliseconds: 1400),
  }) async {
    if (done ||
        matches?.editions.any((edition) => edition.chineseSubtitles) == true) {
      return;
    }
    await nextAvailable(
      (matches) => matches?.editions
          .where((edition) => edition.chineseSubtitles)
          .firstOrNull,
      budget: budget,
    );
  }

  Future<void> waitForEdition(String hash) async {
    if (hash.isEmpty) return;
    await nextAvailable(
      (matches) => matches?.editions.where((v) => v.hash == hash).firstOrNull,
    );
  }

  Future<T?> nextAvailable<T>(
    T? Function(OriginalMatches?) select, {
    Duration? budget,
  }) async {
    final current = select(matches);
    if (current != null || done) return current;
    if (budget != null && budget <= Duration.zero) return null;
    final result = Completer<T?>();
    void changed() {
      final next = select(matches);
      if ((next != null || done) && !result.isCompleted) result.complete(next);
    }

    addListener(changed);
    try {
      return budget == null
          ? await result.future
          : await result.future.timeout(budget, onTimeout: () => null);
    } finally {
      removeListener(changed);
    }
  }

  void _update(OriginalMatches? value, {bool finished = false}) {
    matches = value;
    done = finished;
    if (finished) completedAt = DateTime.now();
    if (finished && !_finished.isCompleted) _finished.complete();
    if (!_ready.isCompleted &&
        (finished || value?.editions.isNotEmpty == true)) {
      _ready.complete();
    }
    notifyListeners();
  }
}

class CinemaOriginalSearch {
  CinemaOriginalSearch({
    Future<List<CinemaDiscoveryTitle>> Function(String)? identity,
    Future<Object?> Function(Uri)? get,
    this.lookupBudget = const Duration(seconds: 23),
  }) : _lookupIdentity = identity == null
           ? CinemaSearchDiscoveryRepository().originalNames
           : ((name, {CinemaTitle? subject}) => identity(name)),
       _get = get ?? _publicJson;
  static final instance = CinemaOriginalSearch();
  final Future<List<CinemaDiscoveryTitle>> Function(
    String, {
    CinemaTitle? subject,
  })
  _lookupIdentity;
  final Future<Object?> Function(Uri) _get;
  final Duration lookupBudget;
  final _queries = <String, OriginalLookup>{};

  String _key(CinemaTitle title, String episode) {
    final series = _seriesHint(title);
    final coordinate = originalEpisode(episode);
    return jsonEncode([
      MacOSSystemProxy.revision,
      title.doubanId.isEmpty ? title.key : title.doubanId,
      cinemaWorkTitleKey(title.title, title.year),
      cinemaTitleAliases(title.aliases).toList()..sort(),
      title.year,
      title.originalReference?.imdbId ?? '',
      series ? 'series' : title.category,
      if (series || coordinate.episode != null && coordinate.episode! > 1)
        [coordinate.season, coordinate.episode ?? episode],
    ]);
  }

  void invalidate(CinemaTitle title, String episode) =>
      _queries.remove(_key(title, episode));

  OriginalLookup find(CinemaTitle title, String episode) {
    final key = _key(title, episode);
    final previous = _queries[key];
    if (previous != null &&
        (!previous.done ||
            DateTime.now().difference(previous.completedAt!) <
                (previous.matches?.editions.isNotEmpty == true
                    ? const Duration(minutes: 12)
                    : const Duration(seconds: 30)))) {
      return previous;
    }
    if (_queries.length >= 48) {
      final finished = _queries.keys
          .where((k) => _queries[k]!.done)
          .firstOrNull;
      _queries.remove(finished ?? _queries.keys.first);
    }
    final lookup = _queries[key] = OriginalLookup();
    unawaited(_search(lookup, title, episode));
    return lookup;
  }

  static bool _seriesHint(CinemaTitle t) =>
      t.originalReference?.season != null ||
      cinemaSeasonName(t.title) != null ||
      !RegExp(r'电影|電影|片$').hasMatch(t.category) &&
          t.routes.any(
            (r) =>
                r.episodes
                    .take(8)
                    .map((e) => originalEpisode(e.name).episode)
                    .nonNulls
                    .toSet()
                    .length >=
                2,
          ) ||
      RegExp(
        '连续剧|連續劇|电视剧|電視劇|剧集|美剧|欧美剧|国产剧|韩剧|日剧|港台剧|海外剧|日本剧|香港剧|韩国剧|台湾剧|泰国剧',
      ).hasMatch(t.category);

  Future<OriginalWork?> _work(
    CinemaTitle t,
    String label,
    List<CinemaDiscoveryTitle> found,
  ) async {
    if (RegExp(
      '解说|解說|影评|影評|预告|預告|花絮|综艺',
    ).hasMatch('${t.category} ${t.title}')) {
      return null;
    }
    final local = cinemaCleanWorkTitle(
      t.doubanId.isEmpty ? t.title : cinemaRegionalTitle(t.title, t.year),
      t.year,
    );
    final localSeason = cinemaSeasonName(local);
    final coordinate = originalEpisode(label);
    final aliases = {local, ...cinemaTitleAliases(t.aliases)};
    String key(String name) => cinemaWorkTitleKey(name, t.year);
    final known = aliases.map(key).toSet();
    final exact = {
      for (final c in found)
        if (c.identityVerified &&
            (t.doubanId.isEmpty ||
                t.doubanId == c.id ||
                c.id.startsWith('wikidata:') && t.year == c.year) &&
            (t.year.isEmpty ||
                c.year == t.year ||
                (t.doubanId == c.id &&
                    c.kind == 'movie' &&
                    ((int.tryParse(t.year) ?? 0) -
                                (int.tryParse(c.year) ?? -100))
                            .abs() ==
                        1)) &&
            [
              c.title,
              c.originalTitle,
              ...cinemaTitleAliases(c.aliases),
            ].any((n) => known.contains(key(n))))
          c.id: c,
    };
    if (exact.length > 1) return null;
    final entry = exact.values.firstOrNull;
    var season =
        localSeason?.number ??
        cinemaSeasonName(entry?.originalTitle ?? '')?.number ??
        coordinate.season ??
        t.originalReference?.season;
    if (coordinate.season != null && season != coordinate.season) return null;
    final series = season != null || entry?.kind == 'tv' || _seriesHint(t);
    if (series &&
        season == null &&
        (entry?.kind == 'tv' || _seriesHint(t)) &&
        coordinate.episode != null) {
      season = 1;
    }
    if (series &&
        (season == null ||
            coordinate.episode == null ||
            coordinate.episode! < 1)) {
      return null;
    }
    if (!series &&
        (RegExp('综艺|解说|影评').hasMatch(t.category) ||
            coordinate.episode != null && coordinate.episode! > 1)) {
      return null;
    }
    if (entry != null &&
        ((series && entry.kind == 'movie') ||
            (!series && entry.kind == 'tv'))) {
      return null;
    }
    final names = <String>{};
    for (final n in [
      if (entry != null) entry.originalTitle,
      ...aliases,
      if (entry != null) ...cinemaTitleAliases(entry.aliases),
    ]) {
      final clean = (cinemaSeasonName(n)?.work ?? n)
          .replaceFirst(RegExp(r'\s*[(（](?:台|臺|港|大陆|中国大陆)[）)]$'), '')
          .trim();
      if (clean.isNotEmpty && clean.length <= 150) names.add(clean);
    }
    final years = {
      for (final y in [
        entry?.year,
        entry?.seriesPremiere,
        t.year,
        t.originalReference?.premiere,
      ])
        if (y != null && RegExp(r'^(?:19|20)\d{2}$').hasMatch(y)) y,
    };
    if (names.isEmpty || (!series && years.isEmpty)) return null;
    if (series &&
        season! > 1 &&
        localSeason != null &&
        entry != null &&
        entry.seriesPremiere.isEmpty) {
      try {
        final first = await _lookupIdentity(
          '${localSeason.work} 第一季',
        ).timeout(const Duration(seconds: 3));
        final parent = first
            .where(
              (c) =>
                  c.identityVerified &&
                  c.kind == 'tv' &&
                  cinemaSeasonName(c.title)?.number == 1 &&
                  cinemaSeasonName(c.originalTitle)?.number == 1 &&
                  originalNameKey(cinemaSeasonName(c.title)!.work) ==
                      originalNameKey(localSeason.work) &&
                  names.any(
                    (n) =>
                        originalNameKey(n) ==
                        originalNameKey(
                          cinemaSeasonName(c.originalTitle)!.work,
                        ),
                  ),
            )
            .toList();
        if (parent.length == 1) years.add(parent.single.year);
      } catch (_) {}
    }
    final sorted = [
      ...names.where((name) => _latin(name) > 0),
      ...names.where((name) => _latin(name) == 0),
    ];
    return OriginalWork(
      names: sorted,
      years: years,
      imdbId: parseCinemaImdbId(
        entry?.imdbId.isNotEmpty == true
            ? entry!.imdbId
            : t.originalReference?.imdbId,
      ),
      episodeCount: entry?.episodeCount ?? 0,
      doubanId: t.doubanId.isNotEmpty
          ? t.doubanId
          : parseCinemaDoubanId(entry?.id),
      season: season,
      episode: series ? coordinate.episode : null,
    );
  }

  static int _latin(String n) => RegExp(r'[a-zA-Z]').hasMatch(n) ? 1 : 0;
  Future<void> _search(
    OriginalLookup lookup,
    CinemaTitle t,
    String label,
  ) async {
    final requests = <Uri, Future<Object?>>{};
    final rows = <String, OriginalEdition>{};
    bool interrupted = false, answeredIndex = false, accepting = true;
    OriginalWork? resolvedWork;
    Future<void> searchWork(OriginalWork work, {bool verified = false}) async {
      if (!accepting) return;
      if (verified || resolvedWork == null) resolvedWork = work;
      Future<void> collect(
        Uri uri,
        String field,
        OriginalEdition? Function(Map) parse,
      ) async {
        if (!accepting) return;
        try {
          final data = await requests.putIfAbsent(
            uri,
            () => _readWithRetry(() => accepting ? _get(uri) : Future.value()),
          );
          if (!accepting) return;
          final list = data is Map ? data[field] : null;
          if (list is! List) {
            interrupted = true;
            return;
          }
          answeredIndex = true;
          var changed = false;
          for (final v in list.whereType<Map>()) {
            final e = parse(v);
            if (e == null) continue;
            final prior = rows[e.hash];
            final merged = prior?.mergeIndexEvidence(e) ?? e;
            if (!identical(prior, merged)) {
              rows[e.hash] = merged;
              changed = true;
            }
          }
          if (rows.isNotEmpty &&
              (changed || !identical(lookup.matches?.work, resolvedWork))) {
            final sorted = rows.values.toList()
              ..sort((a, b) {
                final availability = a.compareAvailability(b);
                if (availability != 0) return availability;
                final pack = (a.pack ? 1 : 0).compareTo(b.pack ? 1 : 0);
                return pack != 0 ? pack : a.hash.compareTo(b.hash);
              });
            lookup._update(
              OriginalMatches(resolvedWork!, List.unmodifiable(sorted)),
            );
          }
        } on Exception {
          interrupted = true;
        }
      }

      // Knaben category IDs are exact. Some movie and TV subcategories omit
      // the parent ID, so classify each returned record by type and identity.
      Future<void> byName(String query, bool knaben) {
        // Search backends interpret punctuation such as "!" and "|" as
        // operators. Use words for retrieval and the complete name for identity.
        final words = query
            .replaceAll(RegExp(r'[!！?？:：&|()*"“”]+'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return collect(
          knaben
              ? Uri.https('api.knaben.org', '/v2/search', {
                  'q': words,
                  's': '35',
                })
              : Uri.https('torrents-csv.com', '/service/search', {'q': words}),
          knaben ? 'hits' : 'torrents',
          (row) => parseOriginalIndexRow(work, row, knaben: knaben),
        );
      }

      final s = work.season.toString().padLeft(2, '0'),
          e = work.episode.toString().padLeft(2, '0');
      Future<void> batch(String n) => Future.wait([
        if (work.series) ...[
          byName('$n S${s}E$e 2160p', true),
          byName('$n S$s 2160p', true),
          byName('$n Season ${work.season}', false),
          byName('$n S${s}E$e', false),
        ] else ...[
          byName('$n 2160p', true),
          byName('$n 2160p', false),
        ],
      ]);
      final primary = work.names.first;
      final chineseName = work.names
          .where((n) => RegExp(r'[\u3400-\u9fff]').hasMatch(n))
          .firstOrNull;
      final internationalName = work.names.firstWhere(
        (n) => RegExp(r'[A-Za-z]').hasMatch(n),
        orElse: () => primary,
      );
      final coordinate = work.series ? 'S${s}E$e' : '2160p';
      await Future.wait([
        if (chineseName != null) byName('$chineseName $coordinate 中字', true),
        byName('$internationalName $coordinate CHS', false),
        if (work.series) ...[
          byName('$internationalName S$s CHS', true),
          // Subtitle groups index individual episodes by number without an SxxExx tag.
          byName('$internationalName CHS', false),
        ],
        batch(primary),
        if (work.imdbId.isNotEmpty)
          collect(
            Uri.https(
              'torrentio.strem.fun',
              work.series
                  ? '/stream/series/${work.imdbId}:${work.season}:${work.episode}.json'
                  : '/stream/movie/${work.imdbId}.json',
            ),
            'streams',
            (row) => parseOriginalStream(work, row),
          ),
      ]);
      if (accepting && rows.isEmpty) {
        await Future.wait([
          for (final alias in work.names.skip(1).take(2)) batch(alias),
          for (final knaben in [true, false])
            byName(
              work.series
                  ? '${work.names.first} S$s'
                  : '${work.names.first} ${work.years.first}',
              knaben,
            ),
        ]);
      }
    }

    try {
      final knownKind =
          t.originalReference != null ||
          _seriesHint(t) ||
          RegExp(r'电影|電影|片$').hasMatch(t.category);
      final local = knownKind ? await _work(t, label, const []) : null;
      // An index can already match a provider alias while the official title
      // is still resolving. Keep listening for both on this open detail page.
      Future<void> enrich() async {
        final name = t.doubanId.isEmpty
            ? t.title
            : cinemaRegionalTitle(t.title, t.year);
        final identity = await _readWithRetry(
          () => _lookupIdentity(cinemaCleanWorkTitle(name, t.year), subject: t),
        ).timeout(const Duration(seconds: 30));
        if (!accepting || identity.isEmpty) return;
        final verified = await _work(t, label, identity);
        if (verified != null &&
            (verified.key != local?.key ||
                verified.names.first != local?.names.first ||
                verified.imdbId != local?.imdbId)) {
          await searchWork(verified, verified: true);
        }
      }

      await Future.wait([
        if (local != null) searchWork(local),
        enrich(),
      ]).timeout(lookupBudget);
    } on Exception {
      interrupted = true;
    } finally {
      accepting = false;
      lookup.incomplete = interrupted && !answeredIndex && rows.isEmpty;
      lookup._update(lookup.matches, finished: true);
    }
  }

  static Future<T> _readWithRetry<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Exception catch (error) {
      final temporary =
          error is SocketException ||
          error is TimeoutException ||
          error is HttpException ||
          error is DioException &&
              const {
                DioExceptionType.connectionError,
                DioExceptionType.connectionTimeout,
                DioExceptionType.receiveTimeout,
                DioExceptionType.sendTimeout,
              }.contains(error.type);
      if (!temporary) rethrow;
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return read();
  }

  static Future<Object?> _publicJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = MacOSSystemProxy.findProxy;
    final timer = Timer(
      const Duration(seconds: 7),
      () => client.close(force: true),
    );
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'NakuPlayer/Originals');
      final resp = await request.close();
      if (const {408, 502, 503, 504}.contains(resp.statusCode)) {
        throw HttpException('原画索引连接中断', uri: uri);
      }
      if (resp.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in resp) {
        if (bytes.length + chunk.length > 1024 * 1024) return null;
        bytes.addAll(chunk);
      }
      return jsonDecode(utf8.decode(bytes));
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }
}

OriginalEdition? parseOriginalIndexRow(
  OriginalWork work,
  Map row, {
  required bool knaben,
}) {
  if (knaben) {
    final category = row['category']?.toString().toLowerCase() ?? '';
    if (!category.startsWith(work.series ? 'tv' : 'movies') &&
        !category.startsWith('anime')) {
      return null;
    }
  }
  return _originalEdition(
    work,
    name: row[knaben ? 'title' : 'name'],
    infoHash: row[knaben ? 'hash' : 'infohash'],
    size: row[knaben ? 'bytes' : 'size_bytes'],
    seeds: row['seeders'],
    magnet: row['magnetUrl'],
  );
}

final _streamSize = RegExp(
  r'💾\s*(\d+(?:\.\d+)?)\s*([KMGT])i?B\b',
  caseSensitive: false,
);
final _streamSeeds = RegExp(r'👤\s*(\d+)');

OriginalEdition? parseOriginalStream(OriginalWork work, Map row) {
  if (['url', 'externalUrl', 'ytId'].any(row.containsKey)) return null;
  final hints = row['behaviorHints'];
  if (hints is! Map || hints['filename'] is! String) return null;
  final path = hints['filename'] as String;
  final description = row['description'] ?? row['title'];
  final details = description is String ? description : '';
  if (path.length > 1400 ||
      details.length > 4096 ||
      originalExcludedRelease(path) ||
      originalExcludedRelease(details.split('\n').first)) {
    return null;
  }
  final filename = path.replaceAll('\\', '/').split('/').last;
  if (!originalVideoFilename(filename)) return null;
  int? size = hints['videoSize'] is int ? hints['videoSize'] as int : null;
  if (size == null || size <= 0) {
    final match = _streamSize.firstMatch(details);
    if (match == null) return null;
    final amount = double.tryParse(match[1]!);
    if (amount == null || !amount.isFinite || amount <= 0 || amount > 1048576) {
      return null;
    }
    final unit = 'KMGT'.indexOf(match[2]!.toUpperCase()) + 1;
    size = (amount * (1 << (10 * unit))).round();
  }
  var release = filename;
  if (work.series && work.matchRelease(filename) == null) {
    if (originalLowerResolution(path)) return null;
    final stem = filename.substring(0, filename.lastIndexOf('.'));
    final marker = originalEpisode(stem);
    final generic = RegExp(
      r'^(?:s\d|e(?:p(?:isode)?)?[ ._-]*\d|第|\d{1,4}(?:$|x\d))',
      caseSensitive: false,
    );
    if (marker.episode != work.episode ||
        marker.season != null && marker.season != work.season ||
        (!generic.hasMatch(stem) && work.matchRelease('$stem 2160p') == null)) {
      return null;
    }
    final contexts = [
      ...path.replaceAll('\\', '/').split('/').reversed.skip(1),
      details.split('\n').first,
    ];
    final parent = contexts
        .where((n) => work.matchRelease(n) != null)
        .firstOrNull;
    if (parent == null) return null;
    final candidate = OriginalEdition(
      hash: '',
      name: parent,
      size: size,
      seeds: 0,
      pack: true,
      magnet: '',
    );
    if (originalMainFile(work, candidate, [OriginalFile(0, path, size)]) ==
        null) {
      return null;
    }
    release = parent;
  }
  return _originalEdition(
    work,
    name: release,
    infoHash: row['infoHash'],
    trackerSources: row['sources'],
    subtitleHint:
        originalChineseSubtitles(path) ||
        originalChineseSubtitles(details.split('\n').first) ||
        details
            .split('\n')
            .where(
              (line) => RegExp(
                r'字幕|subtitles?\s*[:=]',
                caseSensitive: false,
              ).hasMatch(line),
            )
            .any(originalChineseSubtitles),
    size: size,
    seeds: int.tryParse(_streamSeeds.firstMatch(details)?[1] ?? ''),
  );
}

OriginalEdition? _originalEdition(
  OriginalWork work, {
  required Object? name,
  required Object? infoHash,
  required Object? size,
  required Object? seeds,
  Object? magnet,
  Object? trackerSources,
  bool subtitleHint = false,
}) {
  final hash = infoHash is String ? infoHash.toLowerCase() : '';
  if (name is! String ||
      name.length > 1400 ||
      size is! int ||
      size <= 0 ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) {
    return null;
  }
  final pack = work.matchRelease(name);
  if (pack == null) return null;
  final raw = magnet;
  final trackers = <String>{};
  final provided = <String>[
    if (trackerSources is List)
      for (final value in trackerSources.whereType<String>().take(40))
        if (value.startsWith('tracker:') && value.length <= 512)
          value.substring(8),
  ];
  if (raw is String && raw.isNotEmpty) {
    if (raw.length > 16384) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'magnet' ||
        uri.queryParameters['xt']?.toLowerCase() != 'urn:btih:$hash') {
      return null;
    }
    provided.addAll(uri.queryParametersAll['tr'] ?? const <String>[]);
  }
  for (final v in provided) {
    final tr = Uri.tryParse(v);
    if (tr != null &&
        {'http', 'https', 'udp'}.contains(tr.scheme) &&
        tr.userInfo.isEmpty &&
        tr.query.isEmpty &&
        const {
          'tracker.opentrackr.org',
          'open.stealth.si',
          'tracker.torrent.eu.org',
          'open.demonii.com',
          'exodus.desync.com',
          'tracker.openbittorrent.com',
          'tracker.internetwarriors.net',
          'tracker.moeking.me',
          'tracker.theoks.net',
        }.contains(tr.host)) {
      trackers.add(v);
    }
  }
  trackers.addAll(const [
    'udp://tracker.opentrackr.org:1337/announce',
    'http://tracker.dler.com:6969/announce',
    'http://tracker.renfei.net:8080/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://open.demonii.com:1337/announce',
  ]);
  final magnetUri = Uri(
    scheme: 'magnet',
    queryParameters: {
      'xt': 'urn:btih:$hash',
      'dn': name,
      'tr': trackers.take(14).toList(),
    },
  ).toString();
  final seedCount = int.tryParse('$seeds') ?? 0;
  return OriginalEdition(
    hash: hash,
    name: name,
    size: size,
    seeds: seedCount > 0 ? seedCount : 0,
    pack: pack,
    subtitleHint: subtitleHint,
    magnet: magnetUri,
  );
}
