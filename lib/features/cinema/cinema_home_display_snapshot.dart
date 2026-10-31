import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cinema_home_display_authorization.dart';

typedef CinemaDisplayFetch =
    Future<({int status, List<int> bytes})> Function(
      Uri uri,
      Map<String, String> headers,
    );

/// Native TV projection of the same read-only display feed. The short-lived
/// credential stays here and never appears in widget data or diagnostics.
class CinemaHomeDisplaySnapshotSession implements CinemaHomeDisplayCookieStore {
  CinemaHomeDisplaySnapshotSession({
    this.webCookies,
    this.fetch,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final CinemaHomeDisplayCookieStore? webCookies;
  final CinemaDisplayFetch? fetch;
  final DateTime Function() _now;
  CinemaHomeDisplayGrant? _grant;
  int _revision = 0;
  bool get ready =>
      _grant != null &&
      _grant!.expiresAt >
          _now().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
  @override
  Future<bool> install(CinemaHomeDisplayGrant grant) async {
    if (webCookies != null && !await webCookies!.install(grant)) return false;
    _grant = grant;
    ++_revision;
    return true;
  }

  @override
  Future<void> invalidateCredential() async {
    _grant = null;
    ++_revision;
    await webCookies?.invalidateCredential();
  }

  Future<Map<String, dynamic>> snapshot() => _feed('/api/display');

  Future<Map<String, dynamic>> weather() =>
      _feed('/api/display/weather?scope=all', weather: true);

  Future<Map<String, dynamic>> _feed(
    String path, {
    bool weather = false,
  }) async {
    if (!ready) return {'ok': false, 'reason': 'nas_session_expired'};
    final grant = _grant!, revision = _revision;
    // The weather endpoint first verifies the itinerary, then reads two city
    // providers. Match its existing web client's 40-second read budget.
    final timeout = Duration(seconds: weather ? 40 : 15);
    try {
      final uri = Uri.parse('$cinemaHomeDisplayOrigin$path');
      final headers = {
        HttpHeaders.cookieHeader:
            '${grant.context.name}=${grant.context.value}; '
            '${grant.credential.name}=${grant.credential.value}',
        HttpHeaders.acceptHeader: 'application/json',
      };
      final response =
          await (fetch != null
                  ? fetch!(uri, headers)
                  : _request(uri, headers, timeout: timeout))
              .timeout(timeout);
      if (revision != _revision || !ready) {
        return {'ok': false, 'reason': 'nas_session_expired'};
      }
      if (response.status != 200 || response.bytes.length > 1024 * 1024) {
        if (response.status == 401 || response.status == 403) {
          await invalidateCredential();
        }
        return {'ok': false, 'reason': 'display_unavailable'};
      }
      final envelope = jsonDecode(utf8.decode(response.bytes));
      final raw = envelope is Map && envelope['ok'] == true
          ? envelope['data']
          : null;
      if (raw is! Map ||
          raw['demo'] == true ||
          (weather
              ? raw['routes'] is! List ||
                    raw['routes'].length > 12 ||
                    raw['checkedAt'] is! String ||
                    DateTime.tryParse(raw['checkedAt']) == null
              : raw['flights'] is! List ||
                    raw['flights'].length > 100 ||
                    (raw['parcels'] != null && raw['parcels'] is! List))) {
        return {'ok': false, 'reason': 'display_response_invalid'};
      }
      return {'ok': true, 'data': Map<String, dynamic>.from(raw)};
    } catch (_) {
      return {'ok': false, 'reason': 'display_unavailable'};
    }
  }

  static Future<({int status, List<int> bytes})> _request(
    Uri uri,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final deadline = Timer(timeout, () => client.close(force: true));
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const FormatException('Display response exceeds bound');
        }
        bytes.addAll(chunk);
      }
      return (status: response.statusCode, bytes: bytes);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
