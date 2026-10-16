import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_lan_cast.dart';

void main() {
  test(
    'same-account fresh command accepted once; retries and stale commands rejected',
    () {
      final guard = CinemaCastReplayGuard();
      final valid = {
        'namespace': 'account-a',
        'nonce': 'a' * 32,
        'timestamp': 100000,
      };
      guard.accept(valid, 'account-a', now: 100100);
      expect(
        () => guard.accept(valid, 'account-a', now: 100101),
        throwsFormatException,
      );
      expect(
        () => guard.accept(
          {...valid, 'nonce': 'b' * 32},
          'account-b',
          now: 100101,
        ),
        throwsFormatException,
      );
      expect(
        () => guard.accept(
          {...valid, 'nonce': 'b' * 32},
          'account-a',
          now: 130001,
        ),
        throwsFormatException,
      );
      expect(
        () => guard.accept(
          {...valid, 'nonce': 'b' * 32},
          'account-a',
          now: 69999,
        ),
        throwsFormatException,
      );
      guard.accept({...valid, 'nonce': 'b' * 32}, 'account-a', now: 100100);
    },
  );
}
