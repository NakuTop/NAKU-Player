import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Shares the public subject API's IP-rate-limit cooldown across search and
/// ratings. Call only for subject details, never for actor or other host APIs.
class CinemaDoubanAccess {
  CinemaDoubanAccess._();
  static DateTime? _subjectRetryAt;
  static const cooldown = Duration(minutes: 5);

  static bool canRequestSubject({DateTime? now}) =>
      _subjectRetryAt?.isAfter(now ?? DateTime.now()) != true;

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
  static void resetForTesting() => _subjectRetryAt = null;
}
