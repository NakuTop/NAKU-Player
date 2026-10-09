import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'cinema_models.dart';

class CinemaDiscoveryTitle {
  const CinemaDiscoveryTitle({
    required this.id,
    required this.title,
    this.originalTitle = '',
    this.year = '',
    this.poster = '',
    this.kind = 'movie',
    this.actors = '',
    this.genres = '',
    this.area = '',
    this.score,
  });
  final String id,
      title,
      originalTitle,
      year,
      poster,
      kind,
      actors,
      genres,
      area;
  final double? score;
  CinemaTitle get metadata => CinemaTitle(
    id: id,
    sourceId: 'douban-discovery',
    title: title,
    aliases: originalTitle,
    year: year,
    poster: poster,
    actors: actors,
    genres: genres,
    area: area,
    doubanId: id,
    category: kind == 'tv' ? '电视剧' : '电影',
  );
  static CinemaDiscoveryTitle? parse(Map<String, dynamic> json) {
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
    return CinemaDiscoveryTitle(
      id: id,
      title: title,
      originalTitle: textValue(json['sub_title'] ?? json['original_title']),
      year: textValue(json['year']),
      poster:
          Uri.tryParse(poster)?.hasScheme == true &&
              ['http', 'https'].contains(Uri.parse(poster).scheme)
          ? poster
          : '',
      kind: textValue(json['subtype'] ?? json['type']),
      actors: jsonMaps(
        json['actors'],
      ).map((a) => textValue(a['name'])).join(' / '),
      genres: json['genres'] is List
          ? (json['genres'] as List).map(textValue).join(' / ')
          : '',
      area: subtitle.length >= 3 ? subtitle[1] : '',
      score: value != null && value > 0 && value <= 10 ? value : null,
    );
  }
}

class CinemaSearchDiscovery {
  const CinemaSearchDiscovery({
    this.titles = const [],
    this.queries = const [],
    this.celebrityId = '',
    this.celebrityName = '',
    this.nextStart = 0,
    this.hasMore = false,
    this.message = '',
  });
  final List<CinemaDiscoveryTitle> titles;
  final List<String> queries;
  final String celebrityId, celebrityName, message;
  final int nextStart;
  final bool hasMore;
}

/// Public metadata resolves original names and cast. Media URLs still come only
/// from the user's configured sources. Failures never block ordinary search.
class CinemaSearchDiscoveryRepository {
  CinemaSearchDiscoveryRepository({Dio? dio}) : _dio = dio ?? _defaultDio();
  final Dio _dio;
  final _cache = <String, (DateTime, CinemaSearchDiscovery)>{};
  static Dio _defaultDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': 'NAKUPlayer/1.2.0',
          'Referer': 'https://m.douban.com/movie/',
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

  Future<dynamic> _get(
    String url,
    Map<String, dynamic> query,
    CancelToken? cancel,
  ) async {
    final response = await _dio.get<Object?>(
      url,
      queryParameters: query,
      cancelToken: cancel,
    );
    return response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
  }

  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    final key = keyword.trim().toLowerCase();
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 15)) {
      return cached.$2;
    }
    final raw = await _get('https://movie.douban.com/j/subject_suggest', {
      'q': keyword.trim(),
    }, cancelToken);
    if (raw is! List) throw const FormatException('作品检索暂时不可用');
    final suggestions = jsonMaps(raw);
    final titles = <CinemaDiscoveryTitle>[];
    for (final item in suggestions.where(
      (s) => s['type'] == 'movie' || s['type'] == 'tv',
    )) {
      final title = CinemaDiscoveryTitle.parse(item);
      if (title != null) titles.add(title);
    }
    final people = suggestions
        .where(
          (s) =>
              s['type'] == 'celebrity' &&
              RegExp(r'^\d+$').hasMatch(textValue(s['id'])),
        )
        .toList();
    CinemaSearchDiscovery result;
    if (people.isNotEmpty) {
      final person = people.first;
      try {
        final works = await actorWorks(
          textValue(person['id']),
          textValue(person['title']),
          cancelToken: cancelToken,
        );
        final seen = <String>{};
        result = CinemaSearchDiscovery(
          titles: [
            ...titles,
            ...works.titles,
          ].where((t) => seen.add(t.id)).toList(),
          celebrityId: works.celebrityId,
          celebrityName: works.celebrityName,
          nextStart: works.nextStart,
          hasMore: works.hasMore,
        );
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        result = CinemaSearchDiscovery(
          titles: titles,
          message: '演员作品暂时无法读取，可稍后重试。',
        );
      }
    } else {
      result = CinemaSearchDiscovery(
        titles: titles,
        queries: titles
            .map((t) => t.title)
            .where((s) => s.toLowerCase() != key)
            .toSet()
            .take(2)
            .toList(),
      );
    }
    _cache[key] = (DateTime.now(), result);
    while (_cache.length > 40) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  Future<CinemaSearchDiscovery> actorWorks(
    String id,
    String name, {
    int start = 0,
    CancelToken? cancelToken,
  }) async {
    if (!RegExp(r'^\d+$').hasMatch(id)) throw const FormatException('演员ID无效');
    final data = await _get(
      'https://m.douban.com/rexxar/api/v2/celebrity/$id/works',
      {'start': start, 'count': 12},
      cancelToken,
    );
    if (data is! Map || data['works'] is! List) {
      throw const FormatException('演员作品列表无效');
    }
    final works = jsonMaps(data['works']);
    final titles = <CinemaDiscoveryTitle>[];
    for (final item in works) {
      // Do not label directing/producing credits as an acting credit.
      final roles = item['roles'];
      if (roles is! List || !roles.any((r) => r.toString().contains('演员'))) {
        continue;
      }
      if (item['work'] is! Map) continue;
      final title = CinemaDiscoveryTitle.parse(
        Map<String, dynamic>.from(item['work']),
      );
      if (title != null) titles.add(title);
    }
    final next = start + works.length;
    return CinemaSearchDiscovery(
      titles: titles,
      celebrityId: id,
      celebrityName: name,
      nextStart: next,
      hasMore: works.isNotEmpty && next < intValue(data['total']),
    );
  }
}
