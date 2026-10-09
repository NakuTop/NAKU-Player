import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_models.dart';

class CinemaSourceException implements Exception {
  const CinemaSourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// MacCMS is a catalogue of its own. No Bangumi title matching is involved.
class CinemaRepository {
  CinemaRepository({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? _createDefaultDio(),
      _categories = _CatalogueCache(
        lifetime: const Duration(minutes: 30),
        capacity: 24,
        now: now ?? DateTime.now,
      ),
      _pages = _CatalogueCache(
        lifetime: const Duration(minutes: 5),
        capacity: 48,
        now: now ?? DateTime.now,
      ),
      _searches = _CatalogueCache(
        lifetime: const Duration(minutes: 3),
        capacity: 96,
        now: now ?? DateTime.now,
      );

  static Dio _createDefaultDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 12),
        responseType: ResponseType.plain,
        headers: {
          'User-Agent': 'NAKUPlayer/1.5.0',
          'Accept': 'application/json',
        },
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        if (Platform.isMacOS) {
          client.findProxy = MacOSSystemProxy.findProxy;
        } else {
          client.findProxy = HttpClient.findProxyFromEnvironment;
        }
        return client;
      },
    );
    return dio;
  }

  final Dio _dio;
  final _CatalogueCache<(String, String), List<CinemaCategory>> _categories;
  final _CatalogueCache<(String, String, String, int), CinemaPage> _pages;
  final _CatalogueCache<(String, String, String, int), CinemaPage> _searches;

  /// A manual refresh also detaches earlier requests, so a response that was
  /// already loading cannot overwrite the refreshed catalogue in the cache.
  void invalidateBrowseCache({CinemaSource? source}) {
    _categories.invalidate((key) => source == null || key.$1 == source.id);
    _pages.invalidate((key) => source == null || key.$1 == source.id);
    invalidateSearchCache(source: source);
  }

  /// Shared by card lookup, source discovery and explicit searches. Source
  /// settings also form part of each key, including headers and nested rules.
  void invalidateSearchCache({CinemaSource? source}) =>
      _searches.invalidate((key) => source == null || key.$1 == source.id);

  static String _sourceIdentity(CinemaSource source) =>
      jsonEncode(_canonicalConfig(source.toJson()));

  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    source.validate();
    if (source.kind == CinemaSourceKind.kazumi) {
      return const CinemaPage(items: []);
    }
    final key = (source.id, _sourceIdentity(source), categoryId ?? '', page);
    return _pages.load(key, () async {
      final categoriesFuture = categories(source);
      final bodyFuture = _request(source, {
        'ac': 'detail',
        'pg': '$page',
        if (categoryId != null && categoryId.isNotEmpty) 't': categoryId,
      });
      // Register both futures immediately so either error remains observable.
      final responses = await Future.wait<Object>([
        categoriesFuture,
        bodyFuture,
      ]);
      return parseMacCmsPage(
        source,
        responses[1] as Map<String, dynamic>,
        categories: responses[0] as List<CinemaCategory>,
      );
    });
  }

  Future<List<CinemaCategory>> categories(CinemaSource source) async {
    source.validate();
    if (source.kind == CinemaSourceKind.kazumi) return [];
    final key = (source.id, _sourceIdentity(source));
    return _categories.load(key, () async {
      final body = await _request(source, {'ac': 'list', 'pg': '1'});
      return jsonMaps(body['class'])
          .map(
            (entry) => CinemaCategory(
              id: textValue(entry['type_id']),
              name: cleanCinemaText(entry['type_name']),
              parentId: textValue(entry['type_pid']),
            ),
          )
          .where((entry) => entry.id.isNotEmpty && entry.name.isNotEmpty)
          .toList();
    });
  }

  /// Some MacCMS providers support [year], while others silently ignore it.
  /// Callers must validate returned metadata before presenting a filtered page.
  /// Kept separate from browse so existing ordinary catalogue adapters retain
  /// their interface and the filtered cache never aliases an unfiltered page.
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) async {
    if (year.isEmpty) return browse(source, categoryId: categoryId, page: page);
    if (!RegExp(r'^\d{4}$').hasMatch(year)) {
      throw const CinemaSourceException('片源年份筛选参数无效');
    }
    source.validate();
    if (source.kind != CinemaSourceKind.maccms) {
      return const CinemaPage(items: []);
    }
    final key = (
      source.id,
      _sourceIdentity(source),
      jsonEncode({'category': categoryId, 'year': year}),
      page,
    );
    return _pages.load(key, () async {
      final results = await Future.wait<Object>([
        categories(source),
        _request(source, {
          'ac': 'detail',
          'pg': '$page',
          'year': year,
          if (categoryId != null && categoryId.isNotEmpty) 't': categoryId,
        }),
      ]);
      return parseMacCmsPage(
        source,
        results[1] as Map<String, dynamic>,
        categories: results[0] as List<CinemaCategory>,
      );
    });
  }

  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    source.validate();
    final query = keyword.trim();
    if (query.isEmpty || (source.kind == CinemaSourceKind.kazumi && page > 1)) {
      return const CinemaPage(items: []);
    }
    // Keep case and interior whitespace: those can affect remote semantics.
    final key = (source.id, _sourceIdentity(source), query, page);
    return _searches.load(key, () => _search(source, query, page));
  }

  Future<CinemaPage> _search(
    CinemaSource source,
    String keyword,
    int page,
  ) async {
    if (source.kind == CinemaSourceKind.maccms) {
      final body = await _request(source, {
        'ac': 'detail',
        'wd': keyword,
        'pg': '$page',
      });
      return parseMacCmsPage(
        source,
        body,
        categories:
            _categories.peek((source.id, _sourceIdentity(source))) ?? [],
      );
    }
    final plugin = Plugin.fromJson(source.rule!);
    final cancelToken = CancelToken();
    try {
      final response = await plugin
          .queryBangumi(keyword, shouldRethrow: true, cancelToken: cancelToken)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              cancelToken.cancel('动漫源搜索超时');
              throw CinemaSourceException('${source.name}搜索超时，请重试或换源');
            },
          );
      final items = response.data
          .map(
            (item) => CinemaTitle(
              id: requireHttpUrl(plugin.buildFullUrl(item.src)).toString(),
              sourceId: source.id,
              title: cleanCinemaText(item.name),
              category: '动漫',
            ),
          )
          .toList();
      return CinemaPage(items: items, total: items.length);
    } on NoResultException {
      return const CinemaPage(items: []);
    } on CaptchaRequiredException {
      throw CinemaSourceException('${source.name}需要网页验证码，请换源或在原动漫页面验证');
    } on SearchErrorException catch (error) {
      throw CinemaSourceException('${source.name}搜索失败：${error.cause ?? error}');
    }
  }

  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    source.validate();
    if (title.sourceId != source.id) {
      throw const CinemaSourceException('影片与当前片源不匹配');
    }
    if (source.kind == CinemaSourceKind.maccms) {
      final body = await _request(source, {'ac': 'detail', 'ids': title.id});
      final items = parseMacCmsPage(source, body).items;
      final match = items.where((item) => item.id == title.id).firstOrNull;
      if (match == null) throw const CinemaSourceException('片源未返回此影片详情，可能已下架');
      return match;
    }
    final plugin = Plugin.fromJson(source.rule!);
    requireHttpUrl(title.id);
    final cancelToken = CancelToken();
    try {
      final roads = await plugin
          .queryChapterRoads(title.id, cancelToken: cancelToken)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              cancelToken.cancel('动漫源详情超时');
              throw CinemaSourceException('${source.name}详情超时，请重试或换源');
            },
          );
      return title.copyWith(
        routes: roads
            .map(
              (road) => CinemaRoute(
                name: cleanCinemaText(road.name),
                episodes: List.generate(
                  road.data.length,
                  (index) => CinemaEpisode(
                    name:
                        index < road.identifier.length &&
                            road.identifier[index].isNotEmpty
                        ? cleanCinemaText(road.identifier[index])
                        : '第 ${index + 1} 集',
                    url: requireHttpUrl(
                      plugin.buildFullUrl(road.data[index]),
                    ).toString(),
                  ),
                ),
              ),
            )
            .where((road) => road.episodes.isNotEmpty)
            .toList(),
      );
    } on ChapterErrorException catch (error) {
      throw CinemaSourceException(
        '${source.name}详情加载失败：${error.cause ?? error}',
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    CinemaSource source,
    Map<String, String> query,
  ) async {
    final uri = requireHttpUrl(source.url);
    final target = uri.replace(
      queryParameters: {...uri.queryParameters, ...query},
    );
    final token = CancelToken();
    try {
      final response = await _dio
          .get<Object?>(
            target.toString(),
            options: Options(
              responseType: ResponseType.plain,
              headers: source.headers,
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 12),
            ),
            cancelToken: token,
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              token.cancel('片源请求超时');
              throw CinemaSourceException('${source.name}请求超时，请重试或换源');
            },
          );
      Object? decoded = response.data;
      if (decoded is String) {
        decoded = jsonDecode(decoded.replaceFirst('\uFEFF', ''));
      }
      if (decoded is! Map) throw const FormatException('顶层数据不是 JSON 对象');
      final data = Map<String, dynamic>.from(decoded);
      if (data['code'] != null && textValue(data['code']) != '1') {
        throw CinemaSourceException(
          '${source.name}返回错误：${cleanCinemaText(data['msg'])}',
        );
      }
      if (data['list'] is! List) {
        throw const FormatException('缺少 MacCMS list 数组');
      }
      return data;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw CinemaSourceException(
        status == null
            ? '${source.name}连接失败：${error.type.name}'
            : '${source.name}返回 HTTP $status',
      );
    } on FormatException catch (error) {
      throw CinemaSourceException('${source.name}接口格式不兼容：${error.message}');
    }
  }

  static CinemaPage parseMacCmsPage(
    CinemaSource source,
    Map<String, dynamic> data, {
    List<CinemaCategory> categories = const [],
  }) {
    if (data['list'] is! List) throw const FormatException('缺少 MacCMS list 数组');
    if ((data['list'] as List).any((entry) => entry is! Map)) {
      throw const FormatException('MacCMS 影片条目不是 JSON 对象');
    }
    final items = jsonMaps(data['list']).map((entry) {
      if (textValue(entry['vod_id']).isEmpty ||
          cleanCinemaText(entry['vod_name']).isEmpty) {
        throw const FormatException('MacCMS 影片缺少 vod_id 或 vod_name');
      }
      final poster = textValue(entry['vod_pic']).trim();
      final posterUri = Uri.tryParse(poster);
      final resolvedPoster = poster.isEmpty
          ? ''
          : requireHttpUrl(
              source.url,
            ).resolveUri(posterUri ?? Uri()).toString();
      return CinemaTitle(
        id: textValue(entry['vod_id']),
        sourceId: source.id,
        title: cleanCinemaText(entry['vod_name']),
        poster:
            Uri.tryParse(resolvedPoster)?.isScheme('https') == true ||
                Uri.tryParse(resolvedPoster)?.isScheme('http') == true
            ? resolvedPoster
            : '',
        description: cleanCinemaText(
          entry['vod_content'] ?? entry['vod_blurb'],
        ),
        category: cleanCinemaText(entry['type_name']),
        categoryId: textValue(entry['type_id']),
        year: cleanCinemaText(entry['vod_year']),
        remarks: cleanCinemaText(entry['vod_remarks']),
        actors: cleanCinemaText(entry['vod_actor']),
        director: cleanCinemaText(entry['vod_director']),
        area: cleanCinemaText(entry['vod_area']),
        language: cleanCinemaText(entry['vod_lang']),
        aliases: cleanCinemaText(entry['vod_sub']),
        durationText: cleanCinemaText(entry['vod_duration']),
        genres: cleanCinemaText(entry['vod_class']),
        sourceHits: parseCinemaSourceHits(entry['vod_hits']),
        sourceUpdatedAt: parseCinemaSourceUpdatedAt(entry['vod_time']),
        releaseDateText: textValue(entry['vod_pubdate']),
        doubanId: parseCinemaDoubanId(entry['vod_douban_id']),
        sourceDoubanScore: parseCinemaSourceDoubanScore(
          entry['vod_douban_score'],
        ),
        // These optional IDs require an explicitly named provider field.
        // Never infer them from a title, description, score or arbitrary URL.
        imdbId: parseCinemaImdbId(entry['vod_imdb_id'] ?? entry['imdb_id']),
        rottenTomatoesId: parseCinemaRottenTomatoesId(
          entry['vod_rotten_tomatoes_id'] ?? entry['rotten_tomatoes_id'],
        ),
        routes: parseMacCmsRoutes(
          textValue(entry['vod_play_from']),
          textValue(entry['vod_play_url']),
        ),
      );
    }).toList();
    return CinemaPage(
      items: items,
      categories: categories,
      page: intValue(data['page'], 1),
      pageCount: intValue(data['pagecount'], 1),
      total: intValue(data['total'], items.length),
    );
  }

  static List<CinemaRoute> parseMacCmsRoutes(String names, String playUrls) {
    if (playUrls.trim().isEmpty) return [];
    final routeNames = names.split(r'$$$');
    final routeUrls = playUrls.split(r'$$$');
    final routes = <CinemaRoute>[];
    for (var routeIndex = 0; routeIndex < routeUrls.length; routeIndex++) {
      final episodes = <CinemaEpisode>[];
      for (final entry in routeUrls[routeIndex].split('#')) {
        final separator = entry.indexOf(r'$');
        final rawUrl = separator < 0
            ? entry.trim()
            : entry.substring(separator + 1).trim();
        // Decode HTML entities but do not turn a non-web scheme into a request.
        final url = cleanCinemaText(rawUrl);
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          continue;
        }
        final name = separator < 0
            ? ''
            : cleanCinemaText(entry.substring(0, separator));
        episodes.add(
          CinemaEpisode(
            name: name.isEmpty ? '正片 ${episodes.length + 1}' : name,
            url: uri.toString(),
          ),
        );
      }
      if (episodes.isNotEmpty) {
        routes.add(
          CinemaRoute(
            name:
                routeIndex < routeNames.length &&
                    routeNames[routeIndex].isNotEmpty
                ? cleanCinemaText(routeNames[routeIndex])
                : '线路 ${routeIndex + 1}',
            episodes: episodes,
          ),
        );
      }
    }
    // Prefer directly playable links while retaining each original route label.
    return [
      ...routes.where((route) => route.episodes.first.isDirect),
      ...routes.where((route) => !route.episodes.first.isDirect),
    ];
  }
}

/// Map ordering must not turn equivalent source settings into different keys.
Object? _canonicalConfig(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalConfig(value[key])};
  }
  if (value is List) return value.map(_canonicalConfig).toList();
  return value;
}

class _CatalogueCache<K, V> {
  _CatalogueCache({
    required this.lifetime,
    required this.capacity,
    required this.now,
  });

  final Duration lifetime;
  final int capacity;
  final DateTime Function() now;
  final _values = <K, ({V value, DateTime expires})>{};
  final _pending = <K, Future<V>>{};

  V? peek(K key) {
    final entry = _values.remove(key);
    if (entry == null || !entry.expires.isAfter(now())) return null;
    _values[key] = entry;
    return entry.value;
  }

  Future<V> load(K key, Future<V> Function() request) {
    final cached = peek(key);
    if (cached != null) return Future.value(cached);
    final pending = _pending[key];
    if (pending != null) return pending;
    late final Future<V> future;
    future = Future<V>.sync(request).then(
      (value) {
        if (identical(_pending[key], future)) {
          _pending.remove(key);
          _values[key] = (value: value, expires: now().add(lifetime));
          while (_values.length > capacity) {
            _values.remove(_values.keys.first);
          }
        }
        return value;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[key], future)) _pending.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _pending[key] = future;
    return future;
  }

  void invalidate(bool Function(K) matches) {
    _values.removeWhere((key, _) => matches(key));
    _pending.removeWhere((key, _) => matches(key));
  }
}
