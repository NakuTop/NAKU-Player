import 'package:dio/dio.dart';

enum CinemaPlaybackFailure {
  transientNetwork,
  accessDenied,
  unavailable,
  format,
  decoder,
  unknown,
}

CinemaPlaybackFailure cinemaPlaybackFailure(String message) {
  if (RegExp(
    r'\b(?:HTTP(?: error)?|server returned|status(?: code)?)[: ]+(?:401|403)\b|unauthorized|forbidden|certificate|SSL peer',
    caseSensitive: false,
  ).hasMatch(message)) {
    return CinemaPlaybackFailure.accessDenied;
  }
  if (RegExp(
    r'HTTP (?:error )?(?:404|410)|server returned (?:404|410)',
    caseSensitive: false,
  ).hasMatch(message)) {
    return CinemaPlaybackFailure.unavailable;
  }
  if (RegExp(
    r'connection (?:reset|refused|timed out)|timed? ?out|timeout|temporarily unavailable|network is unreachable|HTTP (?:error )?5\d\d|server returned 5\d\d|failed to open (?:segment|key)|unable to open resource',
    caseSensitive: false,
  ).hasMatch(message)) {
    return CinemaPlaybackFailure.transientNetwork;
  }
  if (RegExp(
    r'failed to recognize file format|nothing to play|no video or audio streams|invalid data',
    caseSensitive: false,
  ).hasMatch(message)) {
    return CinemaPlaybackFailure.format;
  }
  if (RegExp(
    r'failed to decode|could not open codec|decoder.*failed',
    caseSensitive: false,
  ).hasMatch(message)) {
    return CinemaPlaybackFailure.decoder;
  }
  return CinemaPlaybackFailure.unknown;
}

CinemaPlaybackFailure cinemaPlaybackException(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    if ([401, 403].contains(status) ||
        error.type == DioExceptionType.badCertificate) {
      return CinemaPlaybackFailure.accessDenied;
    }
    if ([404, 410].contains(status)) return CinemaPlaybackFailure.unavailable;
    if (status != null && status >= 500 ||
        [
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout,
          DioExceptionType.connectionError,
        ].contains(error.type)) {
      return CinemaPlaybackFailure.transientNetwork;
    }
  }
  return cinemaPlaybackFailure(error.toString());
}

/// A retry budget belongs to one concrete media selection. A short successful
/// reopen does not replenish it; sustained forward progress does.
class CinemaPlaybackRecovery {
  CinemaPlaybackRecovery({DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _healthy = <String, ({DateTime since, DateTime last})>{};
  final _attempts = <String, ({int count, DateTime at})>{};
  Duration? retry(String key, CinemaPlaybackFailure failure) {
    if (failure != CinemaPlaybackFailure.transientNetwork) return null;
    final previous = _attempts[key];
    final count = previous?.count ?? 0;
    if (count >= 2) return null;
    _healthy.remove(key);
    _attempts[key] = (count: count + 1, at: _now());
    while (_attempts.length > 64) {
      _attempts.remove(_attempts.keys.first);
    }
    return Duration(milliseconds: count == 0 ? 500 : 1500);
  }

  void progress(String key) {
    if (!_attempts.containsKey(key)) return;
    final now = _now(), previous = _healthy[key];
    final since =
        previous != null &&
            now.difference(previous.last) <= const Duration(seconds: 3)
        ? previous.since
        : now;
    _healthy[key] = (since: since, last: now);
    if (now.difference(since) >= const Duration(seconds: 30)) {
      _attempts.remove(key);
      _healthy.remove(key);
    }
  }

  void reset() {
    _attempts.clear();
    _healthy.clear();
  }
}
