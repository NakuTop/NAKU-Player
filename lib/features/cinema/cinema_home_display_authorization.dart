import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

const cinemaHomeDisplayOrigin = 'https://between-us-home.pages.dev';
final cinemaHomeDisplayExchangeEndpoint = Uri.parse(
  '$cinemaHomeDisplayOrigin/api/auth/nas/exchange',
);
const _credentialName = '__Host-naku-display';
const _contextName = '__Host-naku-display-context';

/// The existing display service replays the registered desktop UGOS wire
/// profile. This identifier is transport metadata, not an authorization claim;
/// current-user and machine cryptographic proofs remain required by the server.
String cinemaHomeDisplayWireClientId(String randomHex) {
  if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(randomHex)) {
    throw const FormatException('Invalid Home Display client nonce');
  }
  return '${randomHex.substring(0, 8)}-${randomHex.substring(8, 12)}-'
      '${randomHex.substring(12, 16)}-${randomHex.substring(16, 20)}-'
      '${randomHex.substring(20)}PC-darwin';
}

/// The exchange stays in the NAS transport. Neither proof nor cookies are
/// returned through the public NAS call contract or injected into JavaScript.
class CinemaHomeDisplayExchangeResponse {
  const CinemaHomeDisplayExchangeResponse({
    required this.status,
    required this.bytes,
    required this.setCookies,
    required this.url,
  });
  final int status;
  final List<int> bytes;
  final List<String> setCookies;
  final Uri url;
}

class CinemaHomeDisplayAuthFailure implements Exception {
  const CinemaHomeDisplayAuthFailure(this.reason, this.stage, [this.status]);
  final String reason, stage;
  final int? status;
  Map<String, dynamic> get diagnostic => {
    'authenticated': false,
    'reason': reason,
    'stage': stage,
    if (status != null) 'httpStatus': status,
  };
}

class CinemaHomeDisplayGrant {
  const CinemaHomeDisplayGrant({
    required this.credential,
    required this.context,
    required this.expiresAt,
  });
  final io.Cookie credential, context;
  final int expiresAt;

  /// Mirrors the native macOS protocol: two exact host-only, Secure, HttpOnly,
  /// SameSite=Strict cookies, a short credential, and a session-only context
  /// marker that prevents the website from falling back to an owner session.
  static CinemaHomeDisplayGrant parse(
    CinemaHomeDisplayExchangeResponse response, {
    required DateTime now,
  }) {
    Never invalid(String stage) => throw CinemaHomeDisplayAuthFailure(
      'authorization_response_invalid',
      stage,
    );
    if (response.status == 503 && response.bytes.length <= 4096) {
      try {
        final body = jsonDecode(utf8.decode(response.bytes));
        if (body is Map && body['error'] == 'nas_display_unconfigured') {
          throw const CinemaHomeDisplayAuthFailure(
            'backend_unconfigured',
            'exchange_http',
            503,
          );
        }
      } on CinemaHomeDisplayAuthFailure {
        rethrow;
      } catch (_) {}
    }
    if (response.status != 200) {
      throw CinemaHomeDisplayAuthFailure(
        switch (response.status) {
          401 => 'nas_authentication_failed',
          403 => 'backend_access_rejected',
          429 => 'backend_rate_limited',
          _ => 'backend_http_error',
        },
        'exchange_http',
        response.status,
      );
    }
    if (response.url != cinemaHomeDisplayExchangeEndpoint ||
        response.bytes.length > 4096) {
      invalid('response_origin_or_size');
    }
    final raw = response.setCookies.join(',');
    if (raw.isEmpty || raw.length > 2048) invalid('response_cookie_header');
    // A comma in Expires is not followed by a cookie name and '='. Split other
    // boundaries as well so an unexpected or duplicate cookie cannot hide in
    // a coalesced Set-Cookie response.
    final fields = raw.split(
      RegExp(r',\s*(?=[!#$%&\x27*+.^_`|~A-Za-z0-9-]+=)'),
    );
    if (fields.length != 2) invalid('response_cookie_parse');
    final parsed = <String, io.Cookie>{};
    for (final field in fields) {
      if (RegExp(r';\s*domain\s*=', caseSensitive: false).hasMatch(field) ||
          !RegExp(
            r';\s*samesite=strict(?:;|$)',
            caseSensitive: false,
          ).hasMatch(field)) {
        invalid('response_cookie_header');
      }
      final io.Cookie cookie;
      try {
        cookie = io.Cookie.fromSetCookieValue(field.trim());
      } catch (_) {
        invalid('response_cookie_parse');
      }
      if (!{_credentialName, _contextName}.contains(cookie.name) ||
          parsed.containsKey(cookie.name)) {
        invalid('response_cookie_parse');
      }
      if (cookie.domain != null ||
          cookie.path != '/' ||
          !cookie.secure ||
          !cookie.httpOnly ||
          cookie.value.isEmpty ||
          cookie.value.length > 1024) {
        invalid('response_cookie_scope');
      }
      parsed[cookie.name] = cookie;
    }
    final credential = parsed[_credentialName], context = parsed[_contextName];
    if (credential == null || context == null) invalid('response_cookie_parse');
    if (context.value != '1') invalid('response_cookie_marker');
    if (context.maxAge != null || context.expires != null) {
      invalid('response_cookie_persistence');
    }
    final expires = credential.maxAge == null
        ? credential.expires
        : now.add(Duration(seconds: credential.maxAge!));
    if (expires == null ||
        !expires.isAfter(now) ||
        expires.difference(now) > const Duration(seconds: 301)) {
      invalid('response_cookie_expiry');
    }
    final dynamic payload;
    try {
      payload = jsonDecode(utf8.decode(response.bytes));
    } catch (_) {
      invalid('response_payload_body');
    }
    if (payload is! Map || payload['authenticated'] != true) {
      invalid('response_payload_authorized');
    }
    final expiry = payload['expiresAt'];
    if (expiry is! num ||
        !expiry.isFinite ||
        expiry <= now.millisecondsSinceEpoch ||
        expiry > now.add(const Duration(seconds: 301)).millisecondsSinceEpoch) {
      invalid('response_payload_expiry');
    }
    return CinemaHomeDisplayGrant(
      credential: credential,
      context: context,
      expiresAt: expiry.toInt(),
    );
  }
}

abstract interface class CinemaHomeDisplayCookieStore {
  Future<bool> install(CinemaHomeDisplayGrant grant);
  Future<void> invalidateCredential();
}

class CinemaHomeDisplayPlatformCookies implements CinemaHomeDisplayCookieStore {
  PlatformCookieManager get _manager =>
      PlatformCookieManager(const PlatformCookieManagerCreationParams());
  WebUri get _url => WebUri('$cinemaHomeDisplayOrigin/');

  @override
  Future<bool> install(CinemaHomeDisplayGrant grant) async {
    if (InAppWebViewPlatform.instance == null) return false;
    final manager = _manager;
    // Install the context marker first. A credential failure then still cannot
    // make this display inherit some unrelated website owner login.
    for (final cookie in [grant.context, grant.credential]) {
      if (!await manager.setCookie(
        url: _url,
        name: cookie.name,
        value: cookie.value,
        path: '/',
        maxAge: cookie.maxAge,
        expiresDate: cookie.expires?.millisecondsSinceEpoch,
        isSecure: true,
        isHttpOnly: true,
        sameSite: HTTPCookieSameSitePolicy.STRICT,
      )) {
        return false;
      }
    }
    final installed = await manager.getCookies(url: _url);
    return [grant.context, grant.credential].every(
      (expected) => installed.any(
        (actual) =>
            actual.name == expected.name &&
            actual.value == expected.value &&
            (actual.domain == null ||
                actual.domain == cinemaHomeDisplayExchangeEndpoint.host) &&
            (actual.path == null || actual.path == '/') &&
            actual.isSecure != false &&
            actual.isHttpOnly != false &&
            (actual.sameSite == null ||
                actual.sameSite == HTTPCookieSameSitePolicy.STRICT),
      ),
    );
  }

  @override
  Future<void> invalidateCredential() async {
    if (InAppWebViewPlatform.instance == null) return;
    await _manager.deleteCookie(url: _url, name: _credentialName, path: '/');
  }
}

typedef CinemaHomeDisplayProof =
    Future<Map<String, String>> Function(Map<String, String> parameters);
typedef CinemaHomeDisplayExchange =
    Future<CinemaHomeDisplayExchangeResponse> Function(
      Map<String, dynamic> body,
    );

/// Serialized cookie mutations prevent stale authorization failures from
/// deleting a newer account's credential. No untrusted URL is accepted here.
class CinemaHomeDisplayAuthorizer {
  CinemaHomeDisplayAuthorizer({
    required this.proof,
    required this.exchange,
    required this.hasSession,
    required this.revision,
    required this.cookies,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final CinemaHomeDisplayProof proof;
  final CinemaHomeDisplayExchange exchange;
  final bool Function() hasSession;
  final int Function() revision;
  final CinemaHomeDisplayCookieStore cookies;
  final DateTime Function() now;
  Future<void> _cookieTail = Future.value();
  Future<Map<String, dynamic>>? _flight;
  int? _flightRevision;

  Future<T> _mutate<T>(Future<T> Function() work) {
    final done = Completer<T>();
    _cookieTail = _cookieTail.then((_) async {
      try {
        done.complete(await work());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> invalidate() => _mutate(cookies.invalidateCredential);

  Future<Map<String, dynamic>> authorize(String clientId) {
    if (!RegExp(r'^[a-fA-F0-9-]{36}PC-darwin$').hasMatch(clientId)) {
      return Future.value(
        const CinemaHomeDisplayAuthFailure(
          'nas_proof_unavailable',
          'proof_prepare',
        ).diagnostic,
      );
    }
    final attempt = revision();
    if (_flight != null && _flightRevision == attempt) return _flight!;
    _flightRevision = attempt;
    final work = _perform(clientId, attempt);
    _flight = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_flight, work)) {
          _flight = null;
          _flightRevision = null;
        }
      }),
    );
    return work;
  }

  bool _current(int attempt) => hasSession() && revision() == attempt;

  Future<Map<String, dynamic>> _perform(String clientId, int attempt) async {
    if (!_current(attempt)) {
      return const {'authenticated': false, 'reason': 'nas_login_required'};
    }
    try {
      final List<Map<String, String>> proofs;
      try {
        proofs = await Future.wait([
          proof({}),
          proof({'basic': '1'}),
        ]);
      } catch (_) {
        throw const CinemaHomeDisplayAuthFailure(
          'nas_proof_unavailable',
          'proof_prepare',
        );
      }
      if (!_current(attempt)) {
        throw const CinemaHomeDisplayAuthFailure(
          'nas_session_expired',
          'session_generation',
        );
      }
      final response = await exchange({
        'version': 1,
        'clientId': clientId,
        'currentUser': proofs[0],
        'machine': proofs[1],
      });
      if (!_current(attempt)) {
        throw const CinemaHomeDisplayAuthFailure(
          'nas_session_expired',
          'session_generation',
        );
      }
      final grant = CinemaHomeDisplayGrant.parse(response, now: now());
      final installed = await _mutate(
        () async => _current(attempt) && await cookies.install(grant),
      );
      if (!_current(attempt)) {
        throw const CinemaHomeDisplayAuthFailure(
          'nas_session_expired',
          'session_generation',
        );
      }
      if (!installed) {
        throw const CinemaHomeDisplayAuthFailure(
          'authorization_cookie_install_failed',
          'cookie_install',
        );
      }
      return {'authenticated': true, 'expiresAt': grant.expiresAt};
    } catch (error) {
      if (_current(attempt)) {
        try {
          await _mutate(() async {
            if (_current(attempt)) await cookies.invalidateCredential();
          });
        } catch (_) {
          /* Keep the failure opaque and do not expose cookie data. */
        }
      }
      if (error is CinemaHomeDisplayAuthFailure) return error.diagnostic;
      return CinemaHomeDisplayAuthFailure(
        error is TimeoutException ? 'backend_timeout' : 'backend_network_error',
        'exchange_transport',
      ).diagnostic;
    }
  }
}
