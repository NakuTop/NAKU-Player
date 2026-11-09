import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_lan_cast.dart';

void main() {
  test(
    'warm ticket avoids another NAS round trip and expires within five minutes',
    () async {
      var now = DateTime(2026, 11, 9), calls = 0;
      final cache = CinemaCastTicketCache(now: () => now);
      final account = 'a' * 64, id = '1' * 32, secret = 'b' * 32;
      Future<Map<String, dynamic>> load() async {
        calls++;
        return {
          'namespace': account,
          'secret': secret,
          'expires': now.add(const Duration(hours: 10)).millisecondsSinceEpoch,
        };
      }

      expect(await cache.get(account, id, load), secret);
      expect(await cache.get(account, id, load), secret);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 6));
      await cache.get(account, id, load);
      expect(calls, 2);
      cache.remove(id);
      await cache.get(account, id, load);
      expect(calls, 3);
    },
  );
  test(
    'concurrent requests share a ticket; logout prevents late authorization reuse',
    () async {
      final cache = CinemaCastTicketCache();
      final pending = Completer<Map<String, dynamic>>();
      var loads = 0;
      final account = 'a' * 64, id = '1' * 32;
      Future<Map<String, dynamic>> load() {
        loads++;
        return pending.future;
      }

      final first = cache.get(account, id, load),
          second = cache.get(account, id, load);
      final a = expectLater(first, throwsFormatException),
          b = expectLater(second, throwsFormatException);
      cache.clear();
      pending.complete({
        'namespace': account,
        'secret': 'b' * 32,
        'expires': DateTime.now()
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      await Future.wait([a, b]);
      expect(loads, 1);
      await expectLater(
        cache.get('c' * 64, id, () async => {'namespace': account}),
        throwsFormatException,
      );
    },
  );
}
