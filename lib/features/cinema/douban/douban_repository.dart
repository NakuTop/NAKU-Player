import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'douban_models.dart';
import '../cinema_douban_access.dart';

class DoubanException implements Exception {
  const DoubanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Public endpoints used by Douban's own /explore and /tv/ pages.
/// No account cookies, API keys, challenge bypasses or automatic retries.
class DoubanRepository {
  DoubanRepository({Dio? dio}) : _dio = dio ?? _defaultDio();
  final Dio _dio;
  static const baseUrl = 'https://m.douban.com/rexxar/api/v2';

  static Dio _defaultDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 12),
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (_) => true,
        headers: {
          'User-Agent':
              'NAKUPlayer/1.0.0 (https://github.com/NakuTop/NAKU-Player)',
          'Accept': 'application/json',
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

  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async {
    if (start < 0 || count < 1 || count > 50) {
      throw const DoubanException('榜单分页参数无效');
    }
    final selectedTags = {...filters.tags(kind), ...tags}.toList();
    _validateFilters(filters, selectedTags);
    final json = await _request(kind, '/recommend', {
      'start': start,
      'count': count,
      'selected_categories': jsonEncode(filters.categories(kind)),
      'uncollect': 'false',
      'score_range': '0,10',
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (selectedTags.isNotEmpty) 'tags': selectedTags.join(','),
    }, cancelToken);
    try {
      for (final row in (json['items'] as List? ?? []).whereType<Map>()) {
        final data = Map<String, dynamic>.from(row);
        if (DoubanTitle.fromJson(data, kind) != null) {
          CinemaDoubanAccess.rememberFeedSubject(data);
        }
      }
      return DoubanResultPage.fromJson(json, kind, start: start, count: count);
    } on FormatException catch (error) {
      throw DoubanException(error.message);
    }
  }

  Future<List<DoubanTagGroup>> tagGroups({
    required DoubanKind kind,
    DoubanFilters filters = const DoubanFilters(),
    CancelToken? cancelToken,
  }) async {
    _validateFilters(filters, filters.tags(kind));
    final json = await _request(kind, '/recommend/filter_tags', {
      'selected_categories': jsonEncode(filters.categories(kind)),
    }, cancelToken);
    try {
      return parseDoubanTagGroups(json);
    } on FormatException catch (error) {
      throw DoubanException(error.message);
    }
  }

  /// A bounded, independent exploration request; its cards never replace the
  /// active board. A discovered topic provides variety when the public API
  /// repeats the same top-level recommendations during a session.
  Future<List<String>> discoverThemes({
    required DoubanKind kind,
    String? seed,
    CancelToken? cancelToken,
  }) async {
    final page = await browse(
      kind: kind,
      tags: seed == null ? const [] : [seed],
      count: 20,
      cancelToken: cancelToken,
    );
    return page.tags;
  }

  Future<String> _web(
    String path,
    CancelToken token, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _dio.get<String>(
      'https://movie.douban.com$path',
      queryParameters: params,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        headers: {
          'Referer': 'https://movie.douban.com/chart',
          'Accept': path.startsWith('/j/') ? 'application/json' : 'text/html',
        },
      ),
    );
    final body = response.data;
    if (response.statusCode != 200 ||
        body == null ||
        body.length > 2 * 1024 * 1024) {
      throw const DoubanException('豆瓣排行榜暂时无法读取');
    }
    return body;
  }

  Future<String> chartPoster(String id) async {
    if (!RegExp(r'^[1-9]\d{0,15}$').hasMatch(id)) return '';
    final token = CancelToken();
    try {
      final doc = html.parse(
        await _web('/subject/$id/', token).timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            token.cancel();
            throw const DoubanException('封面加载超时');
          },
        ),
      );
      final url =
          doc.querySelector('#mainpic img')?.attributes['src'] ??
          doc.querySelector('meta[property="og:image"]')?.attributes['content'];
      final uri = Uri.tryParse(url ?? '');
      return uri != null &&
              uri.scheme == 'https' &&
              uri.host.endsWith('.doubanio.com')
          ? uri.toString()
          : '';
    } catch (_) {
      return '';
    }
  }

  Future<DoubanCharts> charts({required CancelToken cancelToken}) async {
    final doc = html.parse(await _web('/chart', cancelToken));
    final items = <String, DoubanTitle>{};
    List<DoubanTitle> read(String selector) {
      final seen = <String>{};
      return [
        for (final row in doc.querySelectorAll(selector))
          if (row.querySelector('a[href*="/subject/"]') case final link?)
            if (RegExp(
                  r'/subject/([1-9]\d*)/',
                ).firstMatch(link.attributes['href'] ?? '')
                case final id?)
              if (seen.add(id[1]!))
                items.putIfAbsent(id[1]!, () {
                  final label = row.querySelector('.pl2 a, dd a') ?? link;
                  final titles = label.text.trim().split(RegExp(r'\s+/\s+'));
                  final title =
                      link.attributes['title']?.trim().isNotEmpty == true
                      ? link.attributes['title']!.trim()
                      : titles.first;
                  return DoubanTitle(
                    id: id[1]!,
                    title: title,
                    kind: DoubanKind.movie,
                    aliases: titles.skip(1).join(' / '),
                    year:
                        RegExp(r'^\d{4}').stringMatch(
                          row.querySelector('.pl2 p')?.text.trim() ?? '',
                        ) ??
                        '',
                    score: double.tryParse(
                      row.querySelector('.rating_nums')?.text ?? '',
                    ),
                    poster:
                        row
                            .querySelector('img[src*="/view/photo/"]')
                            ?.attributes['src'] ??
                        '',
                  );
                }),
      ];
    }

    final sections = [
      DoubanChartSection('豆瓣新片榜', read('.article tr.item')),
      DoubanChartSection('一周口碑榜', read('#listCont2 li')),
      DoubanChartSection('北美票房榜', read('#listCont1 li')),
      DoubanChartSection('豆瓣电影TOP250', read('#douban-top250 dl')),
    ].where((section) => section.items.isNotEmpty).toList();
    if (sections.isEmpty) throw const DoubanException('豆瓣未返回排行榜，请稍后刷新');
    final genres = <String, String>{};
    for (final link in doc.querySelectorAll('.types a')) {
      final type = Uri.tryParse(
        link.attributes['href'] ?? '',
      )?.queryParameters['type'];
      if (type != null && RegExp(r'^\d+$').hasMatch(type))
        genres[link.text.trim()] = type;
    }
    return DoubanCharts(sections, genres);
  }

  Future<List<DoubanTitle>> genreChart(
    String type, {
    required CancelToken cancelToken,
    int start = 0,
  }) async {
    if (!RegExp(r'^\d{1,3}$').hasMatch(type) || start < 0) {
      throw const DoubanException('无效的排行榜分类');
    }
    final rows = jsonDecode(
      await _web(
        '/j/chart/top_list',
        cancelToken,
        params: {
          'type': type,
          'interval_id': '100:90',
          'action': '',
          'start': start,
          'limit': 20,
        },
      ),
    );
    if (rows is! List) throw const DoubanException('豆瓣未返回分类排行榜');
    return [
      for (final row in rows.whereType<Map>())
        if (DoubanTitle.fromJson({
              'id': row['id'],
              'title': row['title'],
              'type': 'movie',
              'card': 'subject',
              'pic': {'large': row['cover_url']},
              'rating': {'value': row['score'], 'max': 10},
              'genres': row['types'],
              'countries': row['regions'],
            }, DoubanKind.movie)
            case final item?)
          item,
    ];
  }

  static void _validateFilters(DoubanFilters filters, List<String> tags) {
    final values = [...tags, filters.format, filters.genre, filters.region];
    if (tags.length > 20 ||
        values.any(
          (value) =>
              value.length > 120 || RegExp(r'[,\x00-\x1f\x7f]').hasMatch(value),
        )) {
      throw const DoubanException('豆瓣筛选条件无效');
    }
  }

  Future<Map<String, dynamic>> _request(
    DoubanKind kind,
    String path,
    Map<String, dynamic> query,
    CancelToken? callerToken,
  ) async {
    final token = callerToken ?? CancelToken();
    try {
      final response = await _dio
          .get<Object>(
            '$baseUrl/${kind.apiType}$path',
            queryParameters: query,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: false,
              validateStatus: (_) => true,
              headers: {'Referer': kind.pageUrl},
            ),
          )
          .timeout(
            const Duration(seconds: 22),
            onTimeout: () {
              token.cancel('豆瓣请求超时');
              throw const DoubanException('豆瓣请求超时，请稍后刷新');
            },
          );
      final status = response.statusCode ?? 0;
      if (status == 403 ||
          status == 401 ||
          status == 429 ||
          (status >= 300 && status < 400)) {
        throw const DoubanException('豆瓣暂时限制访问或要求验证，请在官网查看后稍后刷新');
      }
      if (status != 200) throw DoubanException('豆瓣返回 HTTP $status，请稍后刷新');
      final body = response.data;
      final text = body is String ? body : jsonEncode(body);
      if (text.length > 2 * 1024 * 1024) {
        throw const DoubanException('豆瓣返回内容过大');
      }
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const DoubanException('豆瓣未返回榜单数据，可能要求网页验证，请稍后刷新');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const DoubanException('豆瓣榜单格式已变化');
      }
      if (decoded.containsKey('msg') &&
          !decoded.containsKey('items') &&
          !decoded.containsKey('tags')) {
        throw const DoubanException('豆瓣暂未提供榜单数据，请在官网查看后稍后刷新');
      }
      return decoded;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      if (error.type == DioExceptionType.badCertificate) {
        throw const DoubanException('豆瓣证书验证失败，已停止连接');
      }
      throw const DoubanException('无法连接豆瓣，请检查网络或稍后刷新');
    }
  }
}
