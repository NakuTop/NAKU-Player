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
    this.persistent = false,
  });
  final io.Cookie credential, context;
  final int expiresAt;
  final bool persistent;

  Map<String, dynamic> toStored() => {
    'credential': credential.value,
    'expiresAt': expiresAt,
    'persistent': persistent,
  };
  static CinemaHomeDisplayGrant? fromStored(
    Map<String, dynamic>? value,
    DateTime now,
  ) {
    if (value == null ||
        value['persistent'] != true ||
        value['credential'] is! String ||
        value['expiresAt'] is! int) {
      return null;
    }
    final expiry = value['expiresAt'] as int;
    final token = value['credential'] as String;
    if (expiry <= now.millisecondsSinceEpoch ||
        expiry > now.add(const Duration(days: 30)).millisecondsSinceEpoch ||
        !RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$').hasMatch(token) ||
        token.length > 1024) {
      return null;
    }
    return parse(
      CinemaHomeDisplayExchangeResponse(
        status: 200,
        bytes: utf8.encode(
          jsonEncode({
            'authenticated': true,
            'persistent': true,
            'expiresAt': expiry,
          }),
        ),
        setCookies: [
          '$_credentialName=$token; Path=/; Secure; HttpOnly; SameSite=Strict; Expires=${io.HttpDate.format(DateTime.fromMillisecondsSinceEpoch(expiry, isUtc: true))}',
          '$_contextName=1; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=34560000',
        ],
        url: cinemaHomeDisplayExchangeEndpoint,
      ),
      now: now,
    );
  }

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
    final dynamic payload;
    try {
      payload = jsonDecode(utf8.decode(response.bytes));
    } catch (_) {
      invalid('response_payload_body');
    }
    if (payload is! Map || payload['authenticated'] != true) {
      invalid('response_payload_authorized');
    }
    final persistent = payload['persistent'] == true;
    final maximum = persistent
        ? const Duration(days: 30, seconds: 1)
        : const Duration(seconds: 301);
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
    if (!persistent && (context.maxAge != null || context.expires != null)) {
      invalid('response_cookie_persistence');
    }
    final expires = credential.maxAge == null
        ? credential.expires
        : now.add(Duration(seconds: credential.maxAge!));
    if (expires == null ||
        !expires.isAfter(now) ||
        expires.difference(now) > maximum) {
      invalid('response_cookie_expiry');
    }
    final expiry = payload['expiresAt'];
    if (expiry is! num ||
        !expiry.isFinite ||
        expiry <= now.millisecondsSinceEpoch ||
        expiry > now.add(maximum).millisecondsSinceEpoch) {
      invalid('response_payload_expiry');
    }
    return CinemaHomeDisplayGrant(
      credential: credential,
      context: context,
      expiresAt: expiry.toInt(),
      persistent: persistent,
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
    this.loadGrant,
    this.saveGrant,
    this.forgetGrant,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final CinemaHomeDisplayProof proof;
  final CinemaHomeDisplayExchange exchange;
  final bool Function() hasSession;
  final int Function() revision;
  final CinemaHomeDisplayCookieStore cookies;
  final Future<Map<String, dynamic>?> Function()? loadGrant;
  final Future<void> Function(Map<String, dynamic>)? saveGrant;
  final Future<void> Function()? forgetGrant;
  CinemaHomeDisplayGrant? _cached;
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

  Future<void> invalidate() {
    _cached = null;
    return _mutate(cookies.invalidateCredential);
  }

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

  Future<CinemaHomeDisplayExchangeResponse> _requestGrant(
    String clientId,
    CinemaHomeDisplayGrant? cached,
  ) async {
    if (cached != null) {
      return exchange({'version': 2, 'credential': cached.credential.value});
    }
    final proofs = await Future.wait([
      proof({}),
      proof({'basic': '1'}),
    ]);
    return exchange({
      'version': 2,
      'clientId': clientId,
      'currentUser': proofs[0],
      'machine': proofs[1],
    });
  }

  bool _current(int attempt) => hasSession() && revision() == attempt;

  Future<Map<String, dynamic>> _perform(String clientId, int attempt) async {
    if (!_current(attempt)) {
      return const {'authenticated': false, 'reason': 'nas_login_required'};
    }
    try {
      var cached = _cached;
      if (cached == null && loadGrant != null) {
        try {
          cached = CinemaHomeDisplayGrant.fromStored(await loadGrant!(), now());
        } catch (_) {
          /* A malformed saved grant is never used. */
        }
      }
      if (!_current(attempt)) {
        throw const CinemaHomeDisplayAuthFailure(
          'nas_session_expired',
          'session_generation',
        );
      }
      if (cached != null && cached.expiresAt <= now().millisecondsSinceEpoch) {
        cached = null;
      }
      CinemaHomeDisplayGrant grant;
      if (cached != null &&
          cached.expiresAt >
              now().add(const Duration(days: 1)).millisecondsSinceEpoch) {
        if (identical(cached, _cached)) {
          return {
            'authenticated': true,
            'expiresAt': cached.expiresAt,
            'persistent': true,
          };
        }
        grant = cached;
      } else {
        try {
          final response = await _requestGrant(clientId, cached);
          if (!_current(attempt)) {
            throw const CinemaHomeDisplayAuthFailure(
              'nas_session_expired',
              'session_generation',
            );
          }
          grant = CinemaHomeDisplayGrant.parse(response, now: now());
        } catch (error) {
          if (!_current(attempt)) rethrow;
          if (cached != null &&
              error is CinemaHomeDisplayAuthFailure &&
              {401, 403}.contains(error.status)) {
            _cached = null;
            await forgetGrant?.call();
            grant = CinemaHomeDisplayGrant.parse(
              await _requestGrant(clientId, null),
              now: now(),
            );
          } else if (cached != null &&
              (error is! CinemaHomeDisplayAuthFailure ||
                  error.status == 429 ||
                  (error.status ?? 0) >= 500)) {
            grant = cached;
          } else {
            rethrow;
          }
        }
      }
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
      if (grant.persistent) {
        final changed =
            _cached?.credential.value != grant.credential.value ||
            _cached?.expiresAt != grant.expiresAt;
        _cached = grant;
        if (changed && saveGrant != null) {
          try {
            await saveGrant!(grant.toStored());
          } catch (_) {
            /* Keep the valid in-memory session if secure storage is unavailable. */
          }
        }
      }
      if (!_current(attempt)) {
        return const {'authenticated': false, 'reason': 'nas_session_expired'};
      }
      return {
        'authenticated': true,
        'expiresAt': grant.expiresAt,
        'persistent': grant.persistent,
      };
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
