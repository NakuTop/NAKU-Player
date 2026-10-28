import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_idle.dart';

void main() {
  test('an action at nine minutes starts a complete new idle interval', () {
    final idle = CinemaTVIdleController();
    idle.activity(const Duration(minutes: 9));
    expect(idle.poll(const Duration(minutes: 10), watching: false), false);
    expect(
      idle.poll(const Duration(minutes: 18, seconds: 59), watching: false),
      false,
    );
    expect(idle.poll(const Duration(minutes: 19), watching: false), true);
  });
  test(
    'a long video ending starts ten fresh minutes instead of entering immediately',
    () {
      final idle = CinemaTVIdleController();
      idle.poll(Duration.zero, watching: true);
      expect(idle.poll(const Duration(hours: 2), watching: true), false);
      expect(idle.poll(const Duration(hours: 2), watching: false), false);
      expect(
        idle.poll(
          const Duration(hours: 2, minutes: 9, seconds: 59),
          watching: false,
        ),
        false,
      );
      expect(
        idle.poll(const Duration(hours: 2, minutes: 10), watching: false),
        true,
      );
    },
  );
  test(
    'manual wake resets the complete interval and does not retain background time',
    () {
      final idle = CinemaTVIdleController();
      idle.manual();
      expect(idle.active, true);
      idle.wake(const Duration(minutes: 1));
      idle.poll(const Duration(minutes: 5), watching: false, foreground: false);
      expect(idle.poll(const Duration(hours: 2), watching: false), false);
      expect(
        idle.poll(const Duration(hours: 2, minutes: 10), watching: false),
        true,
      );
    },
  );
}
