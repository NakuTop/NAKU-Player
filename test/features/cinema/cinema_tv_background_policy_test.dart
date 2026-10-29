import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_background_policy.dart';

void main() {
  test('startup with one buffered second never permits extra media reads', () {
    final gate = CinemaTVBackgroundPolicy();
    for (var second = 0; second < 120; second++) {
      expect(
        gate.update(
          now: Duration(seconds: second),
          position: Duration(seconds: second),
          bufferedUntil: Duration(seconds: second + 1),
          ready: true,
          playing: true,
          buffering: false,
          foreground: true,
          interacting: false,
        ),
        false,
      );
    }
  });

  test(
    'a sustained30-second wall-clock reserve unlocks optional work after8seconds progress',
    () {
      final gate = CinemaTVBackgroundPolicy();
      for (var second = 0; second <= 9; second++) {
        expect(
          gate.update(
            now: Duration(seconds: second),
            position: Duration(seconds: second),
            bufferedUntil: Duration(seconds: second + 30),
            ready: true,
            playing: true,
            buffering: false,
            foreground: true,
            interacting: false,
          ),
          second >= 9,
        );
      }
      expect(
        gate.update(
          now: const Duration(seconds: 10),
          position: const Duration(seconds: 10),
          bufferedUntil: const Duration(seconds: 39),
          ready: true,
          playing: true,
          buffering: false,
          foreground: true,
          interacting: false,
        ),
        false,
      );
    },
  );

  test(
    'rate uses wall-clock headroom and a stalled clock never counts as stable playback',
    () {
      final gate = CinemaTVBackgroundPolicy();
      for (var second = 0; second < 15; second++) {
        expect(
          gate.update(
            now: Duration(seconds: second),
            position: Duration(seconds: second * 2),
            bufferedUntil: Duration(seconds: second * 2 + 30),
            rate: 2,
            ready: true,
            playing: true,
            buffering: false,
            foreground: true,
            interacting: false,
          ),
          false,
        );
      }
      gate.reset();
      for (var second = 0; second < 20; second++) {
        expect(
          gate.update(
            now: Duration(seconds: second),
            position: Duration.zero,
            bufferedUntil: const Duration(minutes: 2),
            ready: true,
            playing: true,
            buffering: false,
            foreground: true,
            interacting: false,
          ),
          false,
        );
      }
    },
  );

  for (final disruption in [
    'buffering',
    'pause',
    'sheet',
    'background',
    'seek',
  ]) {
    test(
      '$disruption immediately suspends work and needs a new stable window',
      () {
        final gate = CinemaTVBackgroundPolicy();
        for (var second = 0; second <= 9; second++) {
          gate.update(
            now: Duration(seconds: second),
            position: Duration(seconds: second),
            bufferedUntil: Duration(seconds: second + 60),
            ready: true,
            playing: true,
            buffering: false,
            foreground: true,
            interacting: false,
          );
        }
        expect(gate.allowed, true);
        final base = disruption == 'seek' ? 90 : 10;
        expect(
          gate.update(
            now: const Duration(seconds: 10),
            position: Duration(seconds: base),
            bufferedUntil: Duration(seconds: base + 60),
            ready: true,
            playing: disruption != 'pause',
            buffering: disruption == 'buffering',
            foreground: disruption != 'background',
            interacting: disruption == 'sheet',
          ),
          false,
        );
        for (var offset = 1; offset <= 9; offset++) {
          expect(
            gate.update(
              now: Duration(seconds: 10 + offset),
              position: Duration(seconds: base + offset),
              bufferedUntil: Duration(seconds: base + offset + 60),
              ready: true,
              playing: true,
              buffering: false,
              foreground: true,
              interacting: false,
            ),
            offset >= 9,
          );
        }
      },
    );
  }
}
