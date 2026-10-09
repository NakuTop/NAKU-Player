import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'cinema_models.dart';
import 'cinema_douban_access.dart';
import 'cinema_filters.dart' show cinemaSearchKey;

class CinemaDiscoveryTitle {
  const CinemaDiscoveryTitle({
    required this.id,
    required this.title,
    this.originalTitle = '',
    this.aliases = '',
    this.year = '',
    this.poster = '',
    this.kind = 'movie',
    this.actors = '',
    this.genres = '',
    this.area = '',
    this.score,
    this.identityVerified = false,
  });
  final String id,
      title,
      originalTitle,
      aliases,
      year,
      poster,
      kind,
      actors,
      genres,
      area;
  final double? score;

  /// Exact ID, type and year were supplied by public subject metadata, or by
  /// one unambiguous Wikidata mapping with an explicit film/TV classification.
  final bool identityVerified;
  CinemaTitle get metadata => CinemaTitle(
    id: id,
    sourceId: 'douban-discovery',
    title: title,
    aliases: {originalTitle, aliases}.where((s) => s.isNotEmpty).join(' / '),
    year: year,
    poster: poster,
    actors: actors,
    genres: genres,
    area: area,
    doubanId: id,
    sourceDoubanScore: score,
    category: kind == 'tv' ? '电视剧' : (kind == 'movie' ? '电影' : ''),
  );
  static CinemaDiscoveryTitle? parse(
    Map<String, dynamic> json, {
    bool verifyIdentity = false,
  }) {
    final id = parseCinemaDoubanId(json['id']);
    final title = cleanCinemaText(json['title']);
    if (id.isEmpty || title.isEmpty) return null;
    final rating = json['rating'];
    final value = rating is Map ? double.tryParse('${rating['value']}') : null;
    final pic = json['pic'];
    final poster = textValue(
      json['img'] ?? json['cover_url'] ?? (pic is Map ? pic['normal'] : null),
    );
    final subtitle = textValue(json['card_subtitle']).split(' / ');
    final year = textValue(json['year']).isNotEmpty
        ? textValue(json['year'])
        : (subtitle.isNotEmpty && RegExp(r'^\d{4}$').hasMatch(subtitle.first)
              ? subtitle.first
              : '');
    final kind = textValue(json['subtype'] ?? json['type']);
    return CinemaDiscoveryTitle(
      id: id,
      title: title,
      originalTitle: textValue(json['sub_title'] ?? json['original_title']),
      aliases: json['aka'] is List
          ? (json['aka'] as List)
                .map(textValue)
                .where((s) => s.isNotEmpty)
                .join(' / ')
          : textValue(json['aliases']),
      year: year,
      identityVerified:
          verifyIdentity &&
          RegExp(r'^(?:18|19|20|21)[0-9]{2}$').hasMatch(year) &&
          ['movie', 'tv'].contains(kind),
      poster:
          Uri.tryParse(poster)?.hasScheme == true &&
              ['http', 'https'].contains(Uri.parse(poster).scheme)
          ? poster
          : '',
      kind: ['movie', 'tv'].contains(kind) ? kind : '',
      actors: jsonMaps(
        json['actors'],
      ).map((a) => textValue(a['name'])).join(' / '),
      genres: json['genres'] is List
          ? (json['genres'] as List).map(textValue).join(' / ')
          : '',
      area: subtitle.length >= 3 ? subtitle[1] : '',
      score:
          value != null &&
              value.isFinite &&
              value > 0 &&
              value <= 10 &&
              (rating['max'] == null ||
                  double.tryParse('${rating['max']}') == 10)
          ? value
          : null,
    );
  }
}

class CinemaDiscoveryPerson {
  const CinemaDiscoveryPerson({
    required this.id,
    required this.name,
    this.originalName = '',
    this.aliases = const [],
    this.wikidataId = '',
  });
  final String id, name, originalName, wikidataId;
  final List<String> aliases;
  bool matches(String keyword) => [
    name,
    originalName,
    ...aliases,
  ].any((name) => cinemaSearchKey(name) == cinemaSearchKey(keyword));
}

class CinemaSearchDiscovery {
  const CinemaSearchDiscovery({
    this.titles = const [],
    this.people = const [],
    this.queries = const [],
    this.celebrityId = '',
    this.celebrityName = '',
    this.nextStart = 0,
    this.hasMore = false,
    this.message = '',
  });
  final List<CinemaDiscoveryTitle> titles;
  final List<CinemaDiscoveryPerson> people;
  final List<String> queries;
  final String celebrityId, celebrityName, message;
  final int nextStart;
  final bool hasMore;
}

/// Public metadata resolves original names and cast. Media URLs still come only
/// from the user's configured sources. Failures never block ordinary search.
class CinemaSearchDiscoveryRepository {
  CinemaSearchDiscoveryRepository({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? _defaultDio(),
      _now = now ?? DateTime.now;
  final Dio _dio;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, CinemaSearchDiscovery)>{};
  final _workCache = <String, (DateTime, CinemaSearchDiscovery)>{};
  final _people = <String, CinemaDiscoveryPerson>{};
  // Actor failures share a short cooldown by verified identity, independently
  // of punctuation-sensitive movie query caching. An explicit actor retry may
  // still call actorWorks directly.
  final _actorFailures = <String, DateTime>{};
  DateTime? _suggestRestrictedUntil;
  static const _wikidataApi = 'https://www.wikidata.org/w/api.php';

  static Dio _defaultDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 6),
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (_) => true,
        headers: {
          'User-Agent':
              'NAKUPlayer/1.5.0 (https://github.com/NakuTop/NAKU-Player)',
        },
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = Platform.isMacOS
            ? MacOSSystemProxy.findProxy
            : HttpClient.findProxyFromEnvironment;
        return client;
      },
    );
    return dio;
  }

  void _checkCancellation(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
  }

  Future<dynamic> _get(
    String url,
    Map<String, dynamic> query,
    CancelToken? cancel,
  ) async {
    _checkCancellation(cancel);
    final uri = Uri.parse(url);
    final response = await _dio.get<Object?>(
      url,
      queryParameters: query,
      cancelToken: cancel,
      options: Options(
        followRedirects: false,
        validateStatus: (_) => true,
        headers: {
          'Accept': 'application/json',
          if (uri.host.endsWith('douban.com'))
            'Referer':
                uri.path.contains('/movie/') && uri.pathSegments.length >= 5
                ? 'https://m.douban.com/movie/subject/${uri.pathSegments[4]}/'
                : 'https://m.douban.com/movie/',
        },
      ),
    );
    final status = response.statusCode ?? 0;
    final isSubject =
        uri.host == 'm.douban.com' && uri.path.contains('/movie/');
    if (isSubject) {
      CinemaDoubanAccess.noteResponse(status, response.data, now: _now());
    }
    if (status != 200) {
      final subjectRateLimited =
          isSubject && !CinemaDoubanAccess.canRequestSubject(now: _now());
      final restricted =
          status >= 300 && status < 400 ||
          [401, 403, 418, 429].contains(status) ||
          subjectRateLimited;
      throw _DiscoveryFailure(
        restricted ? '公开检索暂受限' : '检索服务暂不可用',
        restricted: restricted,
      );
    }
    _checkCancellation(cancel);
    final body = response.data;
    if (body is String && body.length > 2 * 1024 * 1024) {
      throw const FormatException('检索响应超过大小限制');
    }
    try {
      return body is String ? jsonDecode(body) : body;
    } on FormatException {
      throw const FormatException('检索服务未返回有效资料');
    }
  }

  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    _checkCancellation(cancelToken);
    final input = keyword.trim();
    if (input.isEmpty) return const CinemaSearchDiscovery();
    if (input.length > 120) throw const FormatException('检索关键词过长');
    // Actor aliases normalize punctuation through person.matches below. Keep
    // punctuation in query cache keys: distinct movie names must not alias.
    final key = input.toLowerCase();
    final cached = _cache[key];
    if (cached != null) {
      final ttl = cached.$2.message.contains('暂受限')
          ? const Duration(minutes: 5)
          : cached.$2.message.contains('暂时无法') ||
                (cached.$2.titles.isEmpty && cached.$2.people.isEmpty)
          ? const Duration(seconds: 30)
          : const Duration(minutes: 15);
      if (_now().difference(cached.$1) < ttl) return cached.$2;
    }
    final knownPeople = _people.values.where((p) => p.matches(input)).toList();
    if (knownPeople.length == 1) {
      final result = await _finish(input, const [], knownPeople, cancelToken);
      _checkCancellation(cancelToken);
      return _remember(key, result);
    }
    final titles = <CinemaDiscoveryTitle>[];
    final people = <CinemaDiscoveryPerson>[];
    var useFallback = _suggestRestrictedUntil?.isAfter(_now()) == true;
    if (!useFallback) {
      try {
        final raw = await _get('https://movie.douban.com/j/subject_suggest', {
          'q': input,
        }, cancelToken);
        if (raw is! List) throw const FormatException('作品检索暂时不可用');
        for (final item in jsonMaps(raw)) {
          if (item['type'] == 'movie' || item['type'] == 'tv') {
            final title = CinemaDiscoveryTitle.parse(item);
            if (title != null) titles.add(title);
          } else if (item['type'] == 'celebrity' &&
              RegExp(r'^[1-9][0-9]*$').hasMatch(textValue(item['id']))) {
            people.add(
              CinemaDiscoveryPerson(
                id: textValue(item['id']),
                name: textValue(item['title']),
                originalName: textValue(item['sub_title']),
              ),
            );
          }
        }
        useFallback = titles.isEmpty && people.isEmpty;
      } catch (error) {
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        if (error is _DiscoveryFailure && error.restricted) {
          _suggestRestrictedUntil = _now().add(const Duration(minutes: 5));
        }
        useFallback = true;
      }
    }
    if (useFallback) {
      final fallback = await _wikidataSearch(input, cancelToken);
      titles.addAll(fallback.$1);
      people.addAll(fallback.$2);
    }
    final result = await _finish(input, titles, people, cancelToken);
    _checkCancellation(cancelToken);
    return _remember(key, result);
  }

  CinemaSearchDiscovery _remember(String key, CinemaSearchDiscovery result) {
    _cache.remove(key);
    _cache[key] = (_now(), result);
    while (_cache.length > 40) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  Future<CinemaSearchDiscovery> _finish(
    String keyword,
    List<CinemaDiscoveryTitle> titles,
    List<CinemaDiscoveryPerson> candidates,
    CancelToken? cancel,
  ) async {
    final people = {
      for (final person in candidates) person.id: person,
    }.values.toList();
    for (final person in people) {
      _people[person.id] = person;
    }
    while (_people.length > 80) {
      _people.remove(_people.keys.first);
    }
    final exact = people.where((person) => person.matches(keyword)).toList();
    final queries = titles
        .map((t) => t.title)
        .where((title) => cinemaSearchKey(title) != cinemaSearchKey(keyword))
        .toSet()
        .take(2)
        .toList();
    // A partial or ambiguous name must not silently select the first person.
    if (exact.length != 1) {
      return CinemaSearchDiscovery(
        titles: titles,
        queries: queries,
        people: people,
        message: people.isEmpty
            ? _subjectRestrictionMessage
            : '找到多个或不完全匹配的演员，请选择对应人名。',
      );
    }
    final person = exact.single;
    CinemaSearchDiscovery unavailable() => CinemaSearchDiscovery(
      titles: titles,
      queries: queries,
      people: people,
      message: '演员已找到，但作品暂时无法读取；可选择演员重试。',
    );
    final failedAt = _actorFailures[person.id];
    if (failedAt != null &&
        _now().difference(failedAt) < const Duration(seconds: 30)) {
      return unavailable();
    }
    _actorFailures.remove(person.id);
    try {
      final works = await actorWorks(
        person.id,
        person.name,
        cancelToken: cancel,
      );
      _actorFailures.remove(person.id);
      final seen = <String>{};
      return CinemaSearchDiscovery(
        titles: [
          ...titles,
          ...works.titles,
        ].where((title) => seen.add(title.id)).toList(),
        people: people,
        queries: queries,
        celebrityId: works.celebrityId,
        celebrityName: works.celebrityName,
        nextStart: works.nextStart,
        hasMore: works.hasMore,
        message: works.message,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      _actorFailures[person.id] = _now();
      while (_actorFailures.length > 80) {
        _actorFailures.remove(_actorFailures.keys.first);
      }
      return unavailable();
    }
  }

  Future<(List<CinemaDiscoveryTitle>, List<CinemaDiscoveryPerson>)>
  _wikidataSearch(String keyword, CancelToken? cancel) async {
    final result = await _get(_wikidataApi, {
      'action': 'wbsearchentities',
      'search': keyword,
      'language': RegExp(r'[\u4e00-\u9fff]').hasMatch(keyword) ? 'zh' : 'en',
      'uselang': 'zh',
      'format': 'json',
      'limit': 5,
    }, cancel);
    if (result is! Map || result['search'] is! List) {
      throw const FormatException('公开资料检索暂时不可用');
    }
    final ids = jsonMaps(result['search'])
        .map((r) => textValue(r['id']))
        .where((id) => RegExp(r'^Q[1-9][0-9]*$').hasMatch(id))
        .take(5)
        .toList();
    if (ids.isEmpty) {
      return (<CinemaDiscoveryTitle>[], <CinemaDiscoveryPerson>[]);
    }
    final data = await _get(_wikidataApi, {
      'action': 'wbgetentities',
      'ids': ids.join('|'),
      'props': 'labels|aliases|claims',
      'languages': 'zh-hans|zh-cn|zh|en',
      'format': 'json',
    }, cancel);
    if (data is! Map || data['entities'] is! Map) {
      throw const FormatException('公开资料详情暂时不可用');
    }
    final titles = <CinemaDiscoveryTitle>[];
    final people = <CinemaDiscoveryPerson>[];
    for (final id in ids) {
      final entity = data['entities'][id];
      if (entity is! Map) continue;
      final labels = entity['labels'] is Map
          ? entity['labels'] as Map
          : const {};
      String label(String language) =>
          labels[language] is Map ? textValue(labels[language]['value']) : '';
      final aliases = <String>{
        for (final value in labels.values.whereType<Map>())
          textValue(value['value']),
      };
      if (entity['aliases'] is Map) {
        for (final list in (entity['aliases'] as Map).values) {
          aliases.addAll(
            jsonMaps(list).map((alias) => textValue(alias['value'])),
          );
        }
      }
      aliases.remove('');
      final name = [
        label('zh-hans'),
        label('zh-cn'),
        label('zh'),
        label('en'),
      ].firstWhere((s) => s.isNotEmpty, orElse: () => '');
      final instances = _claims(
        entity,
        'P31',
      ).whereType<Map>().map((value) => textValue(value['id'])).toSet();
      final personIds = _claims(entity, 'P5284')
          .map(textValue)
          .where((v) => RegExp(r'^[1-9][0-9]*$').hasMatch(v))
          .toSet();
      if (instances.contains('Q5') && name.isNotEmpty) {
        people.add(
          CinemaDiscoveryPerson(
            id: personIds.length == 1 ? personIds.single : 'wikidata:$id',
            name: label('zh').isNotEmpty ? label('zh') : name,
            originalName: label('en'),
            aliases: aliases.toList(),
            wikidataId: id,
          ),
        );
        continue;
      }
      final subjectIds = _claims(
        entity,
        'P4529',
      ).map(parseCinemaDoubanId).where((s) => s.isNotEmpty).toSet();
      // Conflicting mappings must never assign the first subject's rating.
      if (subjectIds.length != 1 || name.isEmpty) continue;
      final subjectId = subjectIds.single;
      final dates =
          _claims(entity, 'P577')
              .whereType<Map>()
              .map(
                (d) =>
                    RegExp(
                      r'^\+?(\d{4})-',
                    ).firstMatch(textValue(d['time']))?.group(1) ??
                    '',
              )
              .where((d) => RegExp(r'^(?:18|19|20|21)[0-9]{2}$').hasMatch(d))
              .toList()
            ..sort();
      titles.add(
        CinemaDiscoveryTitle(
          id: subjectId,
          title: name,
          originalTitle: label('en'),
          aliases: aliases.join(' / '),
          year: dates.firstOrNull ?? '',
          kind: _kindFromInstances(instances),
          identityVerified:
              dates.isNotEmpty && _kindFromInstances(instances).isNotEmpty,
        ),
      );
    }
    return (await _hydrate(titles, cancel, limit: 2), people);
  }

  static String _kindFromInstances(Iterable<String> instances) {
    final ids = instances.toSet();
    final movie = ids.contains('Q11424');
    final tv = ids.any({'Q5398426', 'Q15416', 'Q3464665'}.contains);
    return movie == tv ? '' : (tv ? 'tv' : 'movie');
  }

  static List<dynamic> _claims(Map entity, String property) {
    final claims = entity['claims'];
    if (claims is! Map) return const [];
    return jsonMaps(claims[property])
        .where((entry) => entry['rank'] != 'deprecated')
        .map((entry) => entry['mainsnak'])
        .whereType<Map>()
        .map((snak) => snak['datavalue'])
        .whereType<Map>()
        .map((value) => value['value'])
        .where((value) => value != null)
        .toList();
  }

  String get _subjectRestrictionMessage =>
      !CinemaDoubanAccess.canRequestSubject(now: _now())
      ? '豆瓣详情暂受限，已保留公开名称资料；评分将在稍后重试。'
      : '';

  Future<List<CinemaDiscoveryTitle>> _hydrate(
    List<CinemaDiscoveryTitle> titles,
    CancelToken? cancel, {
    int limit = 12,
  }) async {
    final output = List<CinemaDiscoveryTitle>.of(titles);
    var next = 0;
    Future<void> worker() async {
      while (next < output.length && next < limit) {
        _checkCancellation(cancel);
        if (!CinemaDoubanAccess.canRequestSubject(now: _now())) break;
        final index = next++, original = output[index];
        try {
          final data = await _get(
            'https://m.douban.com/rexxar/api/v2/movie/${original.id}',
            {},
            cancel,
          );
          if (data is! Map || parseCinemaDoubanId(data['id']) != original.id) {
            continue;
          }
          final found = CinemaDiscoveryTitle.parse(
            Map<String, dynamic>.from(data),
            verifyIdentity: true,
          );
          if (found == null) continue;
          output[index] = CinemaDiscoveryTitle(
            id: found.id,
            title: found.title,
            originalTitle: found.originalTitle.isEmpty
                ? original.originalTitle
                : found.originalTitle,
            aliases: {
              original.title,
              original.aliases,
              found.aliases,
            }.where((s) => s.isNotEmpty).join(' / '),
            year: found.year.isEmpty ? original.year : found.year,
            poster: found.poster.isEmpty ? original.poster : found.poster,
            kind: found.kind.isEmpty ? original.kind : found.kind,
            actors: found.actors.isEmpty ? original.actors : found.actors,
            genres: found.genres,
            area: found.area,
            score: found.score ?? original.score,
            identityVerified:
                found.identityVerified ||
                (found.kind.isEmpty && original.identityVerified),
          );
        } catch (error) {
          if (error is DioException && CancelToken.isCancel(error)) rethrow;
        }
      }
    }

    await Future.wait([worker(), worker()]);
    return output;
  }

  Future<CinemaSearchDiscovery> actorWorks(
    String id,
    String name, {
    int start = 0,
    CancelToken? cancelToken,
  }) async {
    _checkCancellation(cancelToken);
    if (start < 0 ||
        start > 10000 ||
        !RegExp(r'^(?:[1-9][0-9]*|wikidata:Q[1-9][0-9]*)$').hasMatch(id)) {
      throw const FormatException('演员或分页参数无效');
    }
    final cacheKey = '$id:$start';
    final cached = _workCache[cacheKey];
    if (cached != null &&
        _now().difference(cached.$1) <
            (cached.$2.message.contains('暂受限')
                ? const Duration(minutes: 5)
                : const Duration(minutes: 15))) {
      return cached.$2;
    }
    CinemaSearchDiscovery result;
    if (id.startsWith('wikidata:')) {
      result = await _wikidataWorks(id.substring(9), name, start, cancelToken);
    } else {
      var needsFallback = false;
      try {
        final data = await _get(
          'https://m.douban.com/rexxar/api/v2/celebrity/$id/works',
          {'start': start, 'count': 12},
          cancelToken,
        );
        if (data is! Map || data['works'] is! List) {
          throw const FormatException('演员作品列表无效');
        }
        final raw = data['works'] as List;
        final titles = <CinemaDiscoveryTitle>[];
        final seen = <String>{};
        for (final item in jsonMaps(raw)) {
          final roles = item['roles'];
          if (roles is! List ||
              !roles.any((r) => r.toString().contains('演员'))) {
            continue;
          }
          if (item['work'] is! Map) continue;
          final title = CinemaDiscoveryTitle.parse(
            Map<String, dynamic>.from(item['work']),
            verifyIdentity: true,
          );
          if (title != null && seen.add(title.id)) titles.add(title);
        }
        final next = start + raw.length;
        result = CinemaSearchDiscovery(
          titles: titles,
          celebrityId: id,
          celebrityName: name,
          nextStart: next,
          hasMore:
              raw.isNotEmpty &&
              (data['total'] == null
                  ? raw.length >= 12
                  : next < intValue(data['total'])),
        );
        if (raw.isEmpty &&
            start == 0 &&
            _people[id]?.wikidataId.isNotEmpty == true) {
          needsFallback = true;
        }
      } catch (error) {
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        final entityId = _people[id]?.wikidataId ?? '';
        if (entityId.isEmpty || start != 0) rethrow;
        needsFallback = true;
        result = const CinemaSearchDiscovery();
      }
      if (needsFallback) {
        result = await _wikidataWorks(
          _people[id]!.wikidataId,
          name,
          0,
          cancelToken,
        );
      }
    }
    _checkCancellation(cancelToken);
    _actorFailures.remove(id);
    _workCache[cacheKey] = (_now(), result);
    while (_workCache.length > 60) {
      _workCache.remove(_workCache.keys.first);
    }
    return result;
  }

  Future<CinemaSearchDiscovery> _wikidataWorks(
    String entityId,
    String name,
    int start,
    CancelToken? cancel,
  ) async {
    if (!RegExp(r'^Q[1-9][0-9]*$').hasMatch(entityId)) {
      throw const FormatException('演员关联资料无效');
    }
    // Group before paginating: multiple release dates or original-title claims
    // must not duplicate a work or consume the entire next page.
    final query =
        '''SELECT ?work ?douban ?date ?original ?types ?workLabel WHERE {
 { SELECT ?work (SAMPLE(?subject) AS ?douban) (MIN(?released) AS ?date) (SAMPLE(?originalTitle) AS ?original) (GROUP_CONCAT(DISTINCT ?instance; separator="|") AS ?types) WHERE {
   ?work wdt:P161 wd:$entityId; wdt:P4529 ?subject.
   OPTIONAL { ?work wdt:P577 ?released } OPTIONAL { ?work wdt:P1476 ?originalTitle } OPTIONAL { ?work wdt:P31 ?instance }
 } GROUP BY ?work HAVING(COUNT(DISTINCT ?subject) = 1) ORDER BY DESC(?date) ?work LIMIT 13 OFFSET $start }
 SERVICE wikibase:label { bd:serviceParam wikibase:language "zh-hans,zh-cn,zh,en". }
} ORDER BY DESC(?date) ?work''';
    final data = await _get('https://query.wikidata.org/sparql', {
      'query': query,
      'format': 'json',
    }, cancel);
    if (data is! Map ||
        data['results'] is! Map ||
        data['results']['bindings'] is! List) {
      throw const FormatException('演员公开作品资料暂时不可用');
    }
    final rows = jsonMaps(data['results']['bindings']);
    String value(Map row, String key) =>
        row[key] is Map ? textValue(row[key]['value']) : '';
    final titles = <CinemaDiscoveryTitle>[];
    final seen = <String>{};
    for (final row in rows.take(12)) {
      final id = parseCinemaDoubanId(value(row, 'douban')),
          title = value(row, 'workLabel');
      if (id.isEmpty ||
          title.isEmpty ||
          RegExp(r'^Q[0-9]+$').hasMatch(title) ||
          !seen.add(id)) {
        continue;
      }
      titles.add(
        CinemaDiscoveryTitle(
          id: id,
          title: title,
          originalTitle: value(row, 'original'),
          year:
              RegExp(
                r'^([0-9]{4})-',
              ).firstMatch(value(row, 'date'))?.group(1) ??
              '',
          actors: name,
          kind: _kindFromInstances(
            value(row, 'types').split('|').map((v) => v.split('/').last),
          ),
        ),
      );
    }
    return CinemaSearchDiscovery(
      titles: await _hydrate(titles, cancel),
      celebrityId: 'wikidata:$entityId',
      celebrityName: name,
      nextStart: start + rows.take(12).length,
      hasMore: rows.length > 12,
      message: '豆瓣演员目录暂未提供作品，已显示 Wikidata 公开参演资料。$_subjectRestrictionMessage',
    );
  }
}

class _DiscoveryFailure implements Exception {
  const _DiscoveryFailure(this.message, {this.restricted = false});
  final String message;
  final bool restricted;
  @override
  String toString() => message;
}
