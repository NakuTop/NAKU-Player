import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'douban_models.dart';

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
