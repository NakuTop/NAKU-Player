import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';

void main() {
  setUp(CinemaDoubanAccess.resetForTesting);
  tearDown(CinemaDoubanAccess.resetForTesting);

  test('1309 is shared across callers for exactly five minutes', () {
    final now = DateTime(2026, 10, 9);
    expect(CinemaDoubanAccess.canRequestSubject(now: now), isTrue);
    CinemaDoubanAccess.noteResponse(400, {'code': 1309}, now: now);
    expect(
      CinemaDoubanAccess.canRequestSubject(
        now: now.add(const Duration(minutes: 4, seconds: 59)),
      ),
      isFalse,
    );
    expect(
      CinemaDoubanAccess.canRequestSubject(
        now: now.add(const Duration(minutes: 5)),
      ),
      isTrue,
    );
  });

  test(
    'JSON bodies and string codes are recognized without clearing on concurrent success',
    () {
      final now = DateTime(2026, 10, 9);
      CinemaDoubanAccess.noteResponse(400, '{"code":"1309"}', now: now);
      CinemaDoubanAccess.noteResponse(200, {'id': '12345'}, now: now);
      expect(CinemaDoubanAccess.canRequestSubject(now: now), isFalse);
    },
  );

  test(
    'ordinary bad requests and malformed bodies do not set a rate limit',
    () {
      final now = DateTime(2026, 10, 9);
      for (final body in [
        '<html>error</html>',
        {'code': 1000},
        {},
        'x' * 65537,
      ]) {
        CinemaDoubanAccess.noteResponse(400, body, now: now);
        expect(CinemaDoubanAccess.canRequestSubject(now: now), isTrue);
      }
      CinemaDoubanAccess.noteResponse(400, {
        'msg': 'subject_ip_rate_limit',
      }, now: now);
      expect(CinemaDoubanAccess.canRequestSubject(now: now), isFalse);
    },
  );
  test(
    'a JSON-level rate-limit error also applies when HTTP reports success',
    () {
      final now = DateTime(2026, 10, 9);
      CinemaDoubanAccess.noteResponse(200, {'code': 1309}, now: now);
      expect(CinemaDoubanAccess.canRequestSubject(now: now), isFalse);
    },
  );
}
