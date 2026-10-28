import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_display_authorization.dart';
import 'package:kazumi/features/cinema/cinema_home_display_snapshot.dart';

void main() {
  final now = DateTime.utc(2030, 1, 2);
  CinemaHomeDisplayGrant grant() => CinemaHomeDisplayGrant(
    credential: Cookie('__Host-naku-display', 'private-fixture'),
    context: Cookie('__Host-naku-display-context', '1'),
    expiresAt: now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
  );
  List<int> data({bool demo = false}) => utf8.encode(
    jsonEncode({
      'ok': true,
      'data': {
        'flights': [],
        'destination': null,
        'syncedAt': now.toIso8601String(),
        'demo': demo,
      },
    }),
  );

  test(
    'native display reads only the fixed feed with the existing short grant',
    () async {
      final session = CinemaHomeDisplaySnapshotSession(
        now: () => now,
        fetch: (uri, headers) async {
          expect(uri.toString(), '$cinemaHomeDisplayOrigin/api/display');
          expect(
            headers[HttpHeaders.cookieHeader],
            '__Host-naku-display-context=1; __Host-naku-display=private-fixture',
          );
          return (status: 200, bytes: data());
        },
      );
      expect(await session.install(grant()), isTrue);
      final result = await session.snapshot();
      expect(result['ok'], isTrue);
      expect((result['data'] as Map)['flights'], isEmpty);
      expect(jsonEncode(result), isNot(contains('private-fixture')));
    },
  );

  test('no session or expiring grant never sends a feed request', () async {
    var calls = 0, clock = now;
    final session = CinemaHomeDisplaySnapshotSession(
      now: () => clock,
      fetch: (_, _) async {
        calls++;
        return (status: 200, bytes: data());
      },
    );
    expect((await session.snapshot())['ok'], isFalse);
    await session.install(grant());
    clock = clock.add(const Duration(minutes: 4, seconds: 40));
    expect((await session.snapshot())['ok'], isFalse);
    expect(calls, 0);
  });

  test(
    'logout invalidates an in-flight snapshot and discards private data',
    () async {
      final response = Completer<({int status, List<int> bytes})>();
      final session = CinemaHomeDisplaySnapshotSession(
        now: () => now,
        fetch: (_, _) => response.future,
      );
      await session.install(grant());
      final pending = session.snapshot();
      await session.invalidateCredential();
      response.complete((status: 200, bytes: data()));
      expect(await pending, {'ok': false, 'reason': 'nas_session_expired'});
    },
  );

  test(
    'unauthorized response clears grant without exposing response body',
    () async {
      final session = CinemaHomeDisplaySnapshotSession(
        now: () => now,
        fetch: (_, _) async =>
            (status: 401, bytes: utf8.encode('private response')),
      );
      await session.install(grant());
      expect((await session.snapshot())['ok'], isFalse);
      expect(session.ready, isFalse);
    },
  );

  test(
    'demo malformed and oversized responses are not presented as real data',
    () async {
      for (final bytes in [
        data(demo: true),
        utf8.encode('{"flights":[]}'),
        List.filled(1024 * 1024 + 1, 32),
      ]) {
        final session = CinemaHomeDisplaySnapshotSession(
          now: () => now,
          fetch: (_, _) async => (status: 200, bytes: bytes),
        );
        await session.install(grant());
        expect((await session.snapshot())['ok'], isFalse);
      }
    },
  );
}
