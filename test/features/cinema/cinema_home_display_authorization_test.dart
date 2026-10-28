import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_display_authorization.dart';

final _now = DateTime.utc(2030, 1, 2, 3, 4, 5);
const _clientId = '00000000-0000-4000-8000-000000000001PC-darwin';
const _credential =
    '__Host-naku-display=fixture-credential; Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Strict';
const _context =
    '__Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict';
CinemaHomeDisplayExchangeResponse _response({
  int status = 200,
  List<String> cookies = const [_credential, _context],
  Uri? url,
  Object? payload,
}) => CinemaHomeDisplayExchangeResponse(
  status: status,
  bytes: utf8.encode(
    jsonEncode(
      payload ??
          {
            'authenticated': true,
            'expiresAt': _now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          },
    ),
  ),
  setCookies: cookies,
  url: url ?? cinemaHomeDisplayExchangeEndpoint,
);

class _Cookies implements CinemaHomeDisplayCookieStore {
  CinemaHomeDisplayGrant? grant;
  bool succeed = true;
  int installations = 0, invalidations = 0;
  @override
  Future<bool> install(CinemaHomeDisplayGrant grant) async {
    ++installations;
    if (succeed) this.grant = grant;
    return succeed;
  }

  @override
  Future<void> invalidateCredential() async {
    ++invalidations;
    grant = null;
  }
}

void main() {
  test(
    'uses the existing desktop wire ID shape without a platform auth claim',
    () {
      expect(
        cinemaHomeDisplayWireClientId('0123456789abcdef0123456789abcdef'),
        '01234567-89ab-cdef-0123-456789abcdefPC-darwin',
      );
      expect(
        () => cinemaHomeDisplayWireClientId('not-a-nonce'),
        throwsFormatException,
      );
    },
  );

  test(
    'accepts two host-only short lived cookies without returning values',
    () {
      final grant = CinemaHomeDisplayGrant.parse(_response(), now: _now);
      expect(grant.credential.name, '__Host-naku-display');
      expect(grant.context.value, '1');
      expect(grant.context.maxAge, isNull);
      expect(grant.context.expires, isNull);
    },
  );

  test('coalesced Set-Cookie keeps Expires date commas intact', () {
    final expires = 'Wed, 02 Jan 2030 03:09:05 GMT';
    final credential = _credential.replaceFirst(
      'Max-Age=300',
      'Expires=$expires',
    );
    final grant = CinemaHomeDisplayGrant.parse(
      _response(cookies: ['$credential,$_context']),
      now: _now,
    );
    expect(grant.credential.expires, _now.add(const Duration(minutes: 5)));
  });

  for (final pair in <String, List<String>>{
    'duplicate credential': [_credential, _credential],
    'missing context': [_credential],
    'unexpected cookie': [_credential, _context, 'owner=fixture; Secure'],
    'domain attribute': [
      _credential.replaceFirst(
        'Path=/',
        'Path=/; Domain=between-us-home.pages.dev',
      ),
      _context,
    ],
    'insecure credential': [_credential.replaceFirst('Secure; ', ''), _context],
    'script-readable cookie': [
      _credential.replaceFirst('HttpOnly; ', ''),
      _context,
    ],
    'non-root path': [
      _credential.replaceFirst('Path=/', 'Path=/display'),
      _context,
    ],
    'wrong same-site': [
      _credential.replaceFirst('SameSite=Strict', 'SameSite=Lax'),
      _context,
    ],
    'wrong context marker': [_credential, _context.replaceFirst('=1;', '=2;')],
    'persistent context': [_credential, '$_context; Max-Age=300'],
    'long credential expiry': [
      _credential.replaceFirst('Max-Age=300', 'Max-Age=3600'),
      _context,
    ],
  }.entries) {
    test('rejects ${pair.key}', () {
      expect(
        () => CinemaHomeDisplayGrant.parse(
          _response(cookies: pair.value),
          now: _now,
        ),
        throwsA(isA<CinemaHomeDisplayAuthFailure>()),
      );
    });
  }

  test('rejects redirected response and a long or unauthorized payload', () {
    for (final response in [
      _response(
        url: Uri.parse('https://example.invalid/api/auth/nas/exchange'),
      ),
      _response(payload: {'authenticated': false}),
      _response(
        payload: {
          'authenticated': true,
          'expiresAt': _now
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        },
      ),
    ]) {
      expect(
        () => CinemaHomeDisplayGrant.parse(response, now: _now),
        throwsA(isA<CinemaHomeDisplayAuthFailure>()),
      );
    }
  });

  test(
    'authorization exchanges both proofs and only returns safe metadata',
    () async {
      final cookies = _Cookies(), parameters = <Map<String, String>>[];
      final authorizer = CinemaHomeDisplayAuthorizer(
        proof: (p) async {
          parameters.add(p);
          return {
            'query': 'encrypted-fixture',
            'responseKey': 'opaque-fixture',
          };
        },
        exchange: (body) async {
          expect(body.keys.toSet(), {
            'version',
            'clientId',
            'currentUser',
            'machine',
          });
          expect(body['version'], 1);
          return _response();
        },
        hasSession: () => true,
        revision: () => 1,
        cookies: cookies,
        now: () => _now,
      );
      final result = await authorizer.authorize(_clientId);
      expect(parameters, [
        {},
        {'basic': '1'},
      ]);
      expect(result.keys.toSet(), {'authenticated', 'expiresAt'});
      expect(result['authenticated'], true);
      expect(jsonEncode(result), isNot(contains('fixture-credential')));
      expect(jsonEncode(result), isNot(contains('encrypted-fixture')));
      expect(cookies.installations, 1);
    },
  );

  test('same session authorization is single flight', () async {
    final response = Completer<CinemaHomeDisplayExchangeResponse>();
    var requests = 0;
    final authorizer = CinemaHomeDisplayAuthorizer(
      proof: (_) async => {'query': 'fixture'},
      exchange: (_) {
        ++requests;
        return response.future;
      },
      hasSession: () => true,
      revision: () => 1,
      cookies: _Cookies(),
      now: () => _now,
    );
    final first = authorizer.authorize(_clientId),
        second = authorizer.authorize(_clientId);
    expect(identical(first, second), true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    response.complete(_response());
    expect((await first)['authenticated'], true);
  });

  test('logout during exchange cannot install an old account cookie', () async {
    var revision = 1, session = true;
    final response = Completer<CinemaHomeDisplayExchangeResponse>(),
        cookies = _Cookies();
    final authorizer = CinemaHomeDisplayAuthorizer(
      proof: (_) async => {'query': 'fixture'},
      exchange: (_) => response.future,
      hasSession: () => session,
      revision: () => revision,
      cookies: cookies,
      now: () => _now,
    );
    final pending = authorizer.authorize(_clientId);
    await Future<void>.delayed(Duration.zero);
    ++revision;
    session = false;
    await authorizer.invalidate();
    response.complete(_response());
    final result = await pending;
    expect(result['reason'], 'nas_session_expired');
    expect(cookies.installations, 0);
    expect(cookies.grant, isNull);
  });

  test('a stale failure never deletes the newer session cookie', () async {
    var revision = 1, requests = 0;
    final old = Completer<CinemaHomeDisplayExchangeResponse>(),
        cookies = _Cookies();
    final authorizer = CinemaHomeDisplayAuthorizer(
      proof: (_) async => {'query': 'fixture'},
      exchange: (_) => ++requests == 1 ? old.future : Future.value(_response()),
      hasSession: () => true,
      revision: () => revision,
      cookies: cookies,
      now: () => _now,
    );
    final stale = authorizer.authorize(_clientId);
    await Future<void>.delayed(Duration.zero);
    ++revision;
    await authorizer.invalidate();
    expect((await authorizer.authorize(_clientId))['authenticated'], true);
    final before = cookies.invalidations;
    old.complete(_response(status: 401));
    expect((await stale)['reason'], 'nas_session_expired');
    expect(cookies.invalidations, before);
    expect(cookies.grant, isNotNull);
  });

  test(
    'cookie install failure is opaque and clears only display credential',
    () async {
      final cookies = _Cookies()..succeed = false;
      final authorizer = CinemaHomeDisplayAuthorizer(
        proof: (_) async => {'query': 'private-fixture'},
        exchange: (_) async => _response(),
        hasSession: () => true,
        revision: () => 1,
        cookies: cookies,
        now: () => _now,
      );
      expect(await authorizer.authorize(_clientId), {
        'authenticated': false,
        'reason': 'authorization_cookie_install_failed',
        'stage': 'cookie_install',
      });
      expect(cookies.invalidations, 1);
    },
  );

  test('missing NAS session never prepares proof or opens exchange', () async {
    final authorizer = CinemaHomeDisplayAuthorizer(
      proof: (_) async => throw StateError('must not prepare'),
      exchange: (_) async => throw StateError('must not send'),
      hasSession: () => false,
      revision: () => 1,
      cookies: _Cookies(),
      now: () => _now,
    );
    expect(
      (await authorizer.authorize(_clientId))['reason'],
      'nas_login_required',
    );
  });
}
