import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_pause_cache_policy.dart';
import 'package:kazumi/features/cinema/cinema_playback_buffer.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';

void main() {
  testWidgets('short pause keeps cache; long pause conserves; play restores', (
    tester,
  ) async {
    final changes = <bool>[];
    final policy = CinemaPauseCachePolicy(
      onChanged: (v) async {
        changes.add(v);
      },
    );
    addTearDown(policy.close);
    policy.update(
      playing: false,
      buffering: false,
      ready: true,
      backgrounded: false,
      enabled: true,
    );
    await tester.pump(const Duration(seconds: 29));
    expect(changes, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(changes, [true]);
    policy.update(
      playing: true,
      buffering: false,
      ready: true,
      backgrounded: false,
      enabled: true,
    );
    await tester.pump();
    expect(changes, [true, false]);
  });
  testWidgets('startup and buffering cannot be throttled even while hidden', (
    tester,
  ) async {
    final changes = <bool>[];
    final policy = CinemaPauseCachePolicy(
      onChanged: (v) async {
        changes.add(v);
      },
    );
    addTearDown(policy.close);
    for (final ready in [false, true]) {
      policy.update(
        playing: false,
        buffering: !ready,
        ready: ready,
        backgrounded: true,
        enabled: true,
      );
      if (ready) {
        // The initially paused, ready player is allowed to conserve.
        await tester.pump();
        expect(changes, [true]);
        policy.update(
          playing: false,
          buffering: true,
          ready: true,
          backgrounded: true,
          enabled: true,
        );
        await tester.pump();
        expect(changes, [true, false]);
      } else {
        await tester.pump(const Duration(minutes: 1));
        expect(changes, isEmpty);
      }
    }
  });
  testWidgets(
    'hide paused player conserves immediately; hide playing does not',
    (tester) async {
      final changes = <bool>[];
      final policy = CinemaPauseCachePolicy(
        onChanged: (v) async {
          changes.add(v);
        },
      );
      addTearDown(policy.close);
      policy.update(
        playing: true,
        buffering: false,
        ready: true,
        backgrounded: true,
        enabled: true,
      );
      await tester.pump(const Duration(minutes: 1));
      expect(changes, isEmpty);
      policy.update(
        playing: false,
        buffering: false,
        ready: true,
        backgrounded: true,
        enabled: true,
      );
      await tester.pump();
      expect(changes, [true]);
      policy.update(
        playing: false,
        buffering: false,
        ready: true,
        backgrounded: true,
        enabled: false,
      );
      await tester.pump();
      expect(changes, [true, false]);
    },
  );
  testWidgets('resume cancels pending timer; closing cancels deferred tuning', (
    tester,
  ) async {
    final changes = <bool>[];
    final policy = CinemaPauseCachePolicy(
      onChanged: (v) async {
        changes.add(v);
      },
    );
    policy.update(
      playing: false,
      buffering: false,
      ready: true,
      backgrounded: false,
      enabled: true,
    );
    await tester.pump(const Duration(seconds: 15));
    policy.update(
      playing: true,
      buffering: false,
      ready: true,
      backgrounded: false,
      enabled: true,
    );
    await tester.pump(const Duration(minutes: 1));
    expect(changes, isEmpty);
    policy.update(
      playing: false,
      buffering: false,
      ready: true,
      backgrounded: true,
      enabled: true,
    );
    policy.close();
    await tester.pump(const Duration(minutes: 1));
    expect(changes, isEmpty);
  });
  test(
    'native tuning serializes slow changes and always restores latest state',
    () async {
      final gate = Completer<void>();
      final changes = <bool>[];
      final policy = CinemaPauseCachePolicy(
        onChanged: (v) async {
          changes.add(v);
          if (v) await gate.future;
        },
      );
      policy.update(
        playing: false,
        buffering: false,
        ready: true,
        backgrounded: true,
        enabled: true,
      );
      await Future<void>.delayed(Duration.zero);
      policy.update(
        playing: true,
        buffering: false,
        ready: true,
        backgrounded: false,
        enabled: true,
      );
      expect(changes, [true]);
      gate.complete();
      await policy.settled;
      expect(changes, [true, false]);
      policy.close();
    },
  );
  testWidgets(
    'system low power mode conserves paused video, never active playback',
    (tester) async {
      final changes = <bool>[];
      final policy = CinemaPauseCachePolicy(
        onChanged: (v) async {
          changes.add(v);
        },
      );
      addTearDown(policy.close);
      policy.update(
        playing: false,
        buffering: false,
        ready: true,
        backgrounded: false,
        enabled: true,
        lowPowerMode: true,
      );
      await tester.pump();
      expect(changes, [true]);
      policy.update(
        playing: true,
        buffering: false,
        ready: true,
        backgrounded: false,
        enabled: true,
        lowPowerMode: true,
      );
      await tester.pump();
      expect(changes, [true, false]);
    },
  );
  test('rate changes never overwrite a newer pause or resume horizon', () {
    for (final rate in [.5, 1.0, 2.0, 3.0]) {
      final properties = CinemaPlaybackBufferPolicy(
        rate,
      ).rateProperties(128 * 1048576);
      expect(properties.containsKey('cache-secs'), false);
      expect(properties.containsKey('demuxer-readahead-secs'), false);
      expect(
        properties['cache-pause-wait'],
        (5 * rate).ceil().clamp(3, 20).toString(),
      );
    }
  });
  test('economy preserves byte budget and opt-out is persisted', () {
    final policy = CinemaPlaybackBufferPolicy(2);
    final normal = policy.nativeProperties(128 * 1048576);
    final paused = policy.nativeProperties(128 * 1048576, conserving: true);
    expect(paused['cache-secs'], '1');
    expect(paused['demuxer-readahead-secs'], '1');
    expect(paused['demuxer-max-bytes'], normal['demuxer-max-bytes']);
    expect(paused['demuxer-max-back-bytes'], normal['demuxer-max-back-bytes']);
    expect(CinemaCachePreferences.parse({}).pauseEconomy, true);
    expect(
      CinemaCachePreferences.parse(
        const CinemaCachePreferences(pauseEconomy: false).toJson(),
      ).pauseEconomy,
      false,
    );
  });
}
