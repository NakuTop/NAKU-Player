import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/download/download_sleep_guard.dart';

void main() {
  test(
    'queue keeps idle sleep blocked through work, releases on pause, obeys setting immediately',
    () async {
      final states = <bool>[];
      final guard = DownloadSleepGuard(
        supported: true,
        apply: (active) async {
          states.add(active);
        },
      );
      await guard.update(hasWork: true);
      await guard.update(hasWork: true);
      expect(states, [true]);
      await guard.update(enabled: false);
      expect(states, [true, false]);
      await guard.update(enabled: true);
      await guard.update(hasWork: false);
      expect(states, [true, false, true, false]);
      expect(guard.active, isFalse);
    },
  );
  test(
    'pause during acquisition cannot leak an idle-sleep assertion',
    () async {
      final gate = Completer<void>();
      final states = <bool>[];
      final guard = DownloadSleepGuard(
        supported: true,
        apply: (active) async {
          states.add(active);
          if (active) await gate.future;
        },
      );
      final start = guard.update(hasWork: true);
      await Future<void>.delayed(Duration.zero);
      final stop = guard.update(hasWork: false);
      gate.complete();
      await Future.wait([start, stop]);
      expect(states, [true, false]);
      expect(guard.active, isFalse);
    },
  );
}
