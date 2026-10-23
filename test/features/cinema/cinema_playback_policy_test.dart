import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_playback_buffer.dart';
import 'package:kazumi/features/cinema/cinema_playback_recovery.dart';

void main() {
  test(
    '20 seconds of media at double speed is 10 seconds of usable headroom',
    () {
      final policy = CinemaPlaybackBufferPolicy(2);
      expect(
        policy.remainingSeconds(
          const Duration(seconds: 10),
          const Duration(seconds: 30),
        ),
        10,
      );
      expect(
        policy.mayWarmNext(
          const Duration(seconds: 10),
          const Duration(seconds: 49),
        ),
        isFalse,
      );
      expect(
        policy.mayWarmNext(
          const Duration(seconds: 10),
          const Duration(seconds: 50),
        ),
        isTrue,
      );
      expect(
        CinemaPlaybackBufferPolicy(
          .5,
        ).remainingSeconds(Duration.zero, const Duration(seconds: 10)),
        20,
      );
    },
  );
  test(
    'cache fills the selected forward budget with a bounded rewind reserve',
    () {
      for (final rate in [.5, 1, 2, 3, 8, double.nan]) {
        final policy = CinemaPlaybackBufferPolicy(rate.toDouble());
        final properties = policy.nativeProperties(128 * 1024 * 1024);
        expect(int.parse(properties['demuxer-max-bytes']!), 128 * 1024 * 1024);
        expect(
          int.parse(properties['demuxer-readahead-secs']!),
          greaterThanOrEqualTo(3600),
        );
        expect(policy.prefetchSeconds(300), lessThanOrEqualTo(900));
      }
      expect(
        CinemaPlaybackBufferPolicy(
          2,
        ).nativeProperties(128 * 1024 * 1024)['cache-secs'],
        '86400',
      );
    },
  );
  test(
    'transient errors retry twice with backoff, access and format errors do not loop',
    () {
      final recovery = CinemaPlaybackRecovery();
      expect(
        recovery.retry(
          'episode1',
          cinemaPlaybackFailure('Connection reset by peer'),
        ),
        const Duration(milliseconds: 500),
      );
      expect(
        recovery.retry('episode1', cinemaPlaybackFailure('HTTP error 503')),
        const Duration(milliseconds: 1500),
      );
      expect(
        recovery.retry(
          'episode1',
          cinemaPlaybackFailure('Connection timed out'),
        ),
        isNull,
      );
      for (final error in [
        'HTTP error 403',
        'HTTP error 404',
        'certificate verify failed',
        'Failed to recognize file format',
        'decoder failed',
      ]) {
        expect(recovery.retry(error, cinemaPlaybackFailure(error)), isNull);
      }
      expect(
        recovery.retry('episode2', CinemaPlaybackFailure.transientNetwork),
        isNotNull,
      );
    },
  );
  test('a brief reopen or an idle seek cannot replenish the retry budget', () {
    var now = DateTime.utc(2026);
    final recovery = CinemaPlaybackRecovery(now: () => now);
    recovery.retry('media', CinemaPlaybackFailure.transientNetwork);
    recovery.retry('media', CinemaPlaybackFailure.transientNetwork);
    now = now.add(const Duration(seconds: 40));
    recovery.progress('media');
    expect(
      recovery.retry('media', CinemaPlaybackFailure.transientNetwork),
      isNull,
    );
    for (var i = 0; i < 30; i++) {
      now = now.add(const Duration(seconds: 1));
      recovery.progress('media');
    }
    expect(
      recovery.retry('media', CinemaPlaybackFailure.transientNetwork),
      const Duration(milliseconds: 500),
    );
    recovery.reset();
    expect(
      recovery.retry('media', CinemaPlaybackFailure.transientNetwork),
      const Duration(milliseconds: 500),
    );
  });
}
