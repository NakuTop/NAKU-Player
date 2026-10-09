import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html;
import 'package:kazumi/services/network/macos_system_proxy.dart';

class CinemaDoubanReview {
  const CinemaDoubanReview({
    required this.id,
    required this.title,
    required this.author,
    required this.excerpt,
    required this.url,
    this.rating,
    this.spoiler = false,
  });
  final String id, title, author, excerpt, url;

  /// The review author's personal rating, on Douban's five-star scale.
  final double? rating;
  final bool spoiler;
}

enum CinemaDoubanReviewsStatus {
  available,
  empty,
  restricted,
  unavailable,
  invalidResponse,
}

class CinemaDoubanReviews {
  const CinemaDoubanReviews({
    required this.subjectId,
    this.items = const [],
    this.message = '',
    this.stale = false,
    this.fetchedAt,
    this.status = CinemaDoubanReviewsStatus.available,
  });
  final String subjectId, message;
  final List<CinemaDoubanReview> items;
  final bool stale;
  final DateTime? fetchedAt;
  final CinemaDoubanReviewsStatus status;
  String get url => 'https://movie.douban.com/subject/$subjectId/reviews';
}

typedef CinemaDoubanReviewsFetch =
    Future<List<int>> Function(Uri uri, int maxBytes);

class CinemaDoubanReviewsException implements Exception {
  const CinemaDoubanReviewsException(this.status, this.message);
  final CinemaDoubanReviewsStatus status;
  final String message;
  @override
  String toString() => message;
}

/// Public long-form reviews, separate from /interests short comments. The movie
/// endpoint accepts both film and TV subject IDs. No login, cookies or redirects.
class CinemaDoubanReviewsRepository {
  CinemaDoubanReviewsRepository({
    CinemaDoubanReviewsFetch? fetch,
    DateTime Function()? now,
  }) : _fetch = fetch ?? _networkFetch,
       _now = now ?? DateTime.now;

  static final instance = CinemaDoubanReviewsRepository();
  static const pageSize = 6;
  static const maxExcerptCharacters = 120;
  static const maxResponseBytes = 512 * 1024;
  final CinemaDoubanReviewsFetch _fetch;
  final DateTime Function() _now;
  final _cache = <String, _CacheEntry>{};
  final _pending = <String, Future<CinemaDoubanReviews>>{};
  final _waiters = <Completer<void>>[];
  int _active = 0;

  Future<CinemaDoubanReviews> load(String doubanId, {bool force = false}) {
    _validateId(doubanId);
    final pending = _pending[doubanId];
    if (pending != null) return pending;
    final cached = _cache.remove(doubanId);
    if (cached != null) {
      _cache[doubanId] = cached;
      final age = _now().difference(cached.attemptedAt);
      final ttl =
          cached.result.stale ||
              ![
                CinemaDoubanReviewsStatus.available,
                CinemaDoubanReviewsStatus.empty,
              ].contains(cached.result.status)
          ? const Duration(minutes: 5)
          : cached.result.items.isEmpty
          ? const Duration(minutes: 30)
          : const Duration(hours: 6);
      if (!force && !age.isNegative && age < ttl) {
        return Future.value(cached.result);
      }
    }
    final future = _load(doubanId, cached?.result);
    _pending[doubanId] = future;
    return future.whenComplete(() => _pending.remove(doubanId));
  }

  Future<CinemaDoubanReviews> _load(
    String id,
    CinemaDoubanReviews? previous,
  ) async {
    if (_active >= 2) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    CinemaDoubanReviews result;
    try {
      final uri = Uri.https(
        'm.douban.com',
        '/rexxar/api/v2/movie/$id/reviews',
        {'start': '0', 'count': '$pageSize'},
      );
      final bytes = await _fetch(
        uri,
        maxResponseBytes,
      ).timeout(const Duration(seconds: 15));
      if (bytes.length > maxResponseBytes) {
        throw const CinemaDoubanReviewsException(
          CinemaDoubanReviewsStatus.invalidResponse,
          '豆瓣影评响应超过大小限制。',
        );
      }
      result = parse(id, utf8.decode(bytes), fetchedAt: _now());
    } catch (error) {
      final status = error is CinemaDoubanReviewsException
          ? error.status
          : error is FormatException
          ? CinemaDoubanReviewsStatus.invalidResponse
          : CinemaDoubanReviewsStatus.unavailable;
      final message = error is CinemaDoubanReviewsException
          ? error.message
          : error is TimeoutException
          ? '影评读取超时，可稍后重试或前往豆瓣查看。'
          : error is FormatException
          ? '豆瓣暂未返回可读取的影评数据。'
          : '暂时无法连接豆瓣影评，可稍后重试或前往官网查看。';
      final retained = previous?.items.isNotEmpty == true;
      result = CinemaDoubanReviews(
        subjectId: id,
        items: retained ? previous!.items : const [],
        fetchedAt: retained ? previous!.fetchedAt : null,
        stale: retained,
        status: status,
        message: retained ? '更新未完成，保留上次影评。$message' : message,
      );
    } finally {
      if (_waiters.isNotEmpty) {
        // Transfer the occupied slot directly to the next waiter.
        _waiters.removeAt(0).complete();
      } else {
        _active--;
      }
    }
    _cache.remove(id);
    _cache[id] = _CacheEntry(result, _now());
    while (_cache.length > 80) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  static CinemaDoubanReviews parse(
    String subjectId,
    String body, {
    DateTime? fetchedAt,
  }) {
    _validateId(subjectId);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw CinemaDoubanReviewsException(
        RegExp(
              r'验证码|访问异常|登录后|sec\.douban\.com|captcha',
              caseSensitive: false,
            ).hasMatch(body)
            ? CinemaDoubanReviewsStatus.restricted
            : CinemaDoubanReviewsStatus.invalidResponse,
        '豆瓣暂未提供公开影评数据，可前往官网查看。',
      );
    }
    if (decoded is! Map || decoded['reviews'] is! List) {
      throw CinemaDoubanReviewsException(
        decoded is Map &&
                RegExp(
                  r'验证码|访问异常|登录|login|forbidden|captcha',
                  caseSensitive: false,
                ).hasMatch('${decoded['msg'] ?? decoded['message'] ?? ''}')
            ? CinemaDoubanReviewsStatus.restricted
            : CinemaDoubanReviewsStatus.invalidResponse,
        '豆瓣影评格式已变化，可前往官网查看。',
      );
    }
    final raw = decoded['reviews'] as List;
    final seen = <String>{};
    final reviews = <CinemaDoubanReview>[];
    for (final value in raw.whereType<Map>()) {
      final id = '${value['id'] ?? ''}';
      final subject = value['subject'];
      if (value['type'] != 'review' ||
          subject is! Map ||
          '${subject['id'] ?? ''}' != subjectId ||
          !['movie', 'tv'].contains(subject['type']) ||
          !RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(id)) {
        continue;
      }
      final title = _plain(value['title'], 160);
      if (title.isEmpty || !seen.add(id)) continue;
      final user = value['user'];
      final rating = value['rating'];
      final number = rating is Map
          ? double.tryParse('${rating['value']}')
          : null;
      final scale = rating is Map ? double.tryParse('${rating['max']}') : null;
      reviews.add(
        CinemaDoubanReview(
          id: id,
          title: title,
          author: user is Map ? _plain(user['name'], 80) : '',
          excerpt: _plain(value['abstract'], maxExcerptCharacters),
          // Derive the only permitted destination from the verified review ID;
          // response links, tracking redirects and embedded HTML are never opened.
          url: 'https://movie.douban.com/review/$id/',
          rating:
              number != null &&
                  number.isFinite &&
                  number > 0 &&
                  number <= 5 &&
                  scale == 5
              ? number
              : null,
          spoiler: value['is_spoiler'] == true || value['spoiler'] == true,
        ),
      );
      if (reviews.length == pageSize) break;
    }
    if (raw.isNotEmpty && reviews.isEmpty) {
      throw const CinemaDoubanReviewsException(
        CinemaDoubanReviewsStatus.invalidResponse,
        '豆瓣暂未返回与该作品对应的长影评。',
      );
    }
    return CinemaDoubanReviews(
      subjectId: subjectId,
      items: List.unmodifiable(reviews),
      fetchedAt: fetchedAt,
      status: reviews.isEmpty
          ? CinemaDoubanReviewsStatus.empty
          : CinemaDoubanReviewsStatus.available,
      message: reviews.isEmpty ? '豆瓣当前没有公开长影评。' : '豆瓣公开长影评 · 摘要',
    );
  }

  static String _plain(Object? value, int limit) {
    if (value is! String) return '';
    final fragment = html.parseFragment(value);
    for (final element in fragment.querySelectorAll('script,style')) {
      element.remove();
    }
    final text = (fragment.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final points = text.runes;
    return points.length > limit
        ? '${String.fromCharCodes(points.take(limit - 1))}…'
        : text;
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(id)) {
      throw const FormatException('影评需要有效的豆瓣作品 ID');
    }
  }

  static Future<List<int>> _networkFetch(Uri uri, int maxBytes) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    client.findProxy = Platform.isMacOS
        ? MacOSSystemProxy.findProxy
        : HttpClient.findProxyFromEnvironment;
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          'User-Agent',
          'NAKUPlayer/1.4.0 (https://github.com/NakuTop/NAKU-Player)',
        );
        request.headers.set('Accept', 'application/json');
        request.headers.set(
          'Referer',
          'https://m.douban.com/movie/subject/${uri.pathSegments[4]}/',
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          final restricted =
              response.statusCode >= 300 && response.statusCode < 400 ||
              [401, 403, 418, 429].contains(response.statusCode);
          throw CinemaDoubanReviewsException(
            restricted
                ? CinemaDoubanReviewsStatus.restricted
                : CinemaDoubanReviewsStatus.unavailable,
            response.statusCode == 429
                ? '豆瓣影评请求暂受限，请稍后重试。'
                : restricted
                ? '豆瓣限制了公开访问或要求验证，请前往官网查看影评。'
                : '豆瓣影评暂不可用（HTTP ${response.statusCode}）。',
          );
        }
        if (response.contentLength > maxBytes) {
          throw const CinemaDoubanReviewsException(
            CinemaDoubanReviewsStatus.invalidResponse,
            '豆瓣影评响应超过大小限制。',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const CinemaDoubanReviewsException(
              CinemaDoubanReviewsStatus.invalidResponse,
              '豆瓣影评响应超过大小限制。',
            );
          }
          bytes.addAll(chunk);
        }
        return bytes;
      })().timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }
}

class _CacheEntry {
  const _CacheEntry(this.result, this.attemptedAt);
  final CinemaDoubanReviews result;
  final DateTime attemptedAt;
}
