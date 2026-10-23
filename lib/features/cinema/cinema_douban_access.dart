import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Shares the public subject API's IP-rate-limit cooldown across search and
/// ratings. Call only for subject details, never for actor or other host APIs.
class CinemaDoubanAccess {
  CinemaDoubanAccess._();
  static DateTime? _subjectRetryAt;
  static final _feedSubjects = <String, (DateTime, Map<String, dynamic>)>{};
  static const cooldown = Duration(minutes: 5);

  /// Douban redirects the generic movie endpoint to /tv for a series. This
  /// exact same-host, same-ID route is metadata, not an account challenge.
  /// Other redirects remain explicit failures; follow at most this one hop.
  static Uri? subjectRedirect(
    Uri from,
    String? location, {
    String resource = '',
  }) {
    if (!const {'', 'reviews', 'rating'}.contains(resource)) return null;
    final pagination =
        resource == 'reviews' &&
        from.queryParametersAll.entries.every(
          (entry) =>
              const {'start', 'count'}.contains(entry.key) &&
              entry.value.length == 1 &&
              RegExp(r'^\d{1,5}$').hasMatch(entry.value.single),
        );
    if (from.scheme != 'https' ||
        from.host != 'm.douban.com' ||
        from.hasQuery && !pagination ||
        from.hasFragment ||
        from.userInfo.isNotEmpty ||
        from.port != 443 ||
        location == null) {
      return null;
    }
    final id = RegExp(
      r'^/rexxar/api/v2/movie/([1-9][0-9]{1,11})' +
          (resource.isEmpty ? r'$' : '/$resource\$'),
    ).firstMatch(from.path)?.group(1);
    if (id == null) return null;
    final target = from.resolve(location);
    return target.scheme == 'https' &&
            target.host == from.host &&
            target.port == 443 &&
            target.userInfo.isEmpty &&
            target.query == from.query &&
            !target.hasFragment &&
            target.path ==
                '/rexxar/api/v2/tv/$id${resource.isEmpty ? '' : '/$resource'}'
        ? target
        : null;
  }

  static bool canRequestSubject({DateTime? now}) =>
      _subjectRetryAt?.isAfter(now ?? DateTime.now()) != true;

  /// Called only by the official feed parser after it accepts a subject card.
  /// Keep its timestamp and exact ID so a restricted detail endpoint does not
  /// discard the public score already delivered to the same homepage.
  static void rememberFeedSubject(Map<String, dynamic> data, {DateTime? now}) {
    final id = data['id']?.toString() ?? '';
    if (!RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(id) ||
        !['movie', 'tv'].contains(data['type'])) {
      return;
    }
    _feedSubjects.remove(id);
    _feedSubjects[id] = (
      now ?? DateTime.now(),
      Map<String, dynamic>.from(data),
    );
    while (_feedSubjects.length > 128) {
      _feedSubjects.remove(_feedSubjects.keys.first);
    }
  }

  static (DateTime, Map<String, dynamic>)? feedSubject(
    String id, {
    DateTime? now,
  }) {
    final cached = _feedSubjects[id];
    if (cached == null ||
        (now ?? DateTime.now()).difference(cached.$1) >
            const Duration(minutes: 15)) {
      return null;
    }
    return cached;
  }

  static void noteResponse(int? status, Object? data, {DateTime? now}) {
    Object? body = data;
    if (body is String) {
      if (body.length > 65536) return;
      try {
        body = jsonDecode(body);
      } on FormatException {
        return;
      }
    }
    if (body is Map &&
        (body['code'].toString() == '1309' ||
            body['msg'] == 'subject_ip_rate_limit')) {
      _subjectRetryAt = (now ?? DateTime.now()).add(cooldown);
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _subjectRetryAt = null;
    _feedSubjects.clear();
  }
}
