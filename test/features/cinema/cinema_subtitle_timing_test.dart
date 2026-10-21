import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_appearance.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state =>
      const PlayerState(position: Duration(milliseconds: 5600));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Duration _seconds(double value) =>
    Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

void main() {
  test('single dialogue anchor supports large early and late offsets', () {
    final late = const CinemaSubtitleTiming().align(
      subtitle: const Duration(minutes: 4),
      media: const Duration(minutes: 9),
    );
    expect(late.offsetSeconds, 300);
    expect(
      late.mediaTime(const Duration(minutes: 4)),
      const Duration(minutes: 9),
    );
    expect(
      late.subtitleTime(const Duration(minutes: 9)),
      const Duration(minutes: 4),
    );

    final early = const CinemaSubtitleTiming().align(
      subtitle: const Duration(minutes: 4),
      media: const Duration(seconds: 30),
    );
    expect(early.offsetSeconds, -210);
    expect(
      early.mediaTime(const Duration(minutes: 4)),
      const Duration(seconds: 30),
    );
    expect(early.mediaTime(Duration.zero), const Duration(seconds: -210));
  });

  test('two anchors correct 23.976 versus 25 FPS drift across an episode', () {
    const ratio = 23.976 / 25;
    const offset = 13.25;
    final timing = CinemaSubtitleTiming.fromAnchors(
      firstSubtitle: const Duration(seconds: 60),
      firstMedia: _seconds(60 * ratio + offset),
      secondSubtitle: const Duration(minutes: 30),
      secondMedia: _seconds(1800 * ratio + offset),
    );
    expect(timing.scale, closeTo(ratio, 1e-12));
    expect(timing.offsetSeconds, closeTo(offset, 1e-9));
    for (final seconds in [-30.25, 0.0, 60.0, 900.123456, 1800.0, 3600.0]) {
      final source = _seconds(seconds);
      final expectedMedia = _seconds(seconds * ratio + offset);
      expect(
        (timing.mediaTime(source) - expectedMedia).inMicroseconds.abs(),
        lessThanOrEqualTo(1),
      );
      expect(
        (timing.subtitleTime(timing.mediaTime(source)) - source).inMicroseconds
            .abs(),
        lessThanOrEqualTo(1),
      );
    }
    // A constant offset alone would be more than a minute out by 30 minutes.
    final offsetOnly = const CinemaSubtitleTiming().align(
      subtitle: const Duration(seconds: 60),
      media: _seconds(60 * ratio + offset),
    );
    expect(
      (offsetOnly.mediaTime(const Duration(minutes: 30)) -
              timing.mediaTime(const Duration(minutes: 30)))
          .inSeconds
          .abs(),
      greaterThan(60),
    );
  });

  test(
    'reanchoring and fine offset preserve an established rate correction',
    () {
      const original = CinemaSubtitleTiming(
        scale: 1.0427083333333333,
        offsetSeconds: -20,
      );
      final anchored = original.align(
        subtitle: const Duration(minutes: 10),
        media: const Duration(minutes: 11),
      );
      expect(anchored.scale, original.scale);
      expect(
        anchored.mediaTime(const Duration(minutes: 10)),
        const Duration(minutes: 11),
      );
      final adjusted = anchored.withOffset(anchored.offsetSeconds + .1);
      expect(adjusted.scale, original.scale);
      expect(
        adjusted.mediaTime(const Duration(minutes: 10)),
        const Duration(minutes: 11, milliseconds: 100),
      );
    },
  );

  test(
    'negative subtitle times remain negative before the first delayed cue',
    () {
      const timing = CinemaSubtitleTiming(scale: .96, offsetSeconds: 45);
      expect(timing.subtitleTime(Duration.zero), _seconds(-46.875));
      expect(timing.mediaTime(_seconds(-46.875)), Duration.zero);
    },
  );

  test(
    'offset limits include both six-hour endpoints and reject invalid values',
    () {
      for (final value in [-21600.0, 21600.0]) {
        expect(
          const CinemaSubtitleTiming().withOffset(value).offsetSeconds,
          value,
        );
      }
      for (final value in [
        -21600.1,
        21600.1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => const CinemaSubtitleTiming().withOffset(value),
          throwsFormatException,
        );
      }
    },
  );

  test('reversed, short and implausibly stretched anchors are rejected', () {
    for (final spans in [
      (0, 60),
      (29, 60),
      (60, 29),
      (-60, 60),
      (60, -60),
      (120, 59),
      (60, 121),
    ]) {
      expect(
        () => CinemaSubtitleTiming.fromAnchors(
          firstSubtitle: const Duration(minutes: 1),
          firstMedia: const Duration(minutes: 1),
          secondSubtitle: Duration(seconds: 60 + spans.$1),
          secondMedia: Duration(seconds: 60 + spans.$2),
        ),
        throwsFormatException,
        reason: 'Invalid source/media spans: $spans',
      );
    }
    expect(
      () => CinemaSubtitleTiming.fromAnchors(
        firstSubtitle: Duration.zero,
        firstMedia: const Duration(hours: 7),
        secondSubtitle: const Duration(minutes: 1),
        secondMedia: const Duration(hours: 7, minutes: 1),
      ),
      throwsFormatException,
    );
    final minimumSpan = CinemaSubtitleTiming.fromAnchors(
      firstSubtitle: Duration.zero,
      firstMedia: Duration.zero,
      secondSubtitle: const Duration(seconds: 30),
      secondMedia: const Duration(seconds: 30),
    );
    expect(minimumSpan.scale, 1);
  });

  testWidgets(
    'calibrated captions stay visible at both episode anchors and after seeking',
    (tester) async {
      final player = _Player();
      final state = cinemaExternalSubtitleState(player);
      state.select(
        '1\n00:01:00,000 --> 00:01:03,000\n开场对白\n'
            '\n2\n00:30:30,000 --> 00:30:33,000\n后段对白\n',
        'self-authored-fixture.srt',
        '1',
        0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaExternalSubtitleOverlay(
            player: player,
            appearance: const CinemaSubtitleAppearance(),
          ),
        ),
      );
      expect(find.text('开场对白'), findsNothing);
      final timing = CinemaSubtitleTiming.fromAnchors(
        firstSubtitle: const Duration(minutes: 1),
        firstMedia: _seconds(5.5),
        secondSubtitle: const Duration(minutes: 30, seconds: 30),
        secondMedia: _seconds(1704.7),
      );
      state.setTiming(timing);
      await tester.pump();
      expect(find.text('开场对白'), findsOneWidget);
      state.updatePosition(_seconds(1704.8));
      await tester.pump();
      expect(find.text('开场对白'), findsNothing);
      expect(find.text('后段对白'), findsOneWidget);
      state.updatePosition(const Duration(minutes: 10));
      await tester.pump();
      expect(find.text('后段对白'), findsNothing);
      state.updatePosition(_seconds(5.6));
      await tester.pump();
      expect(find.text('开场对白'), findsOneWidget);
      expect(
        () => state.setTiming(const CinemaSubtitleTiming(scale: 0)),
        throwsFormatException,
      );
      expect(state.timing.value, same(timing));
      state.setDelay(timing.offsetSeconds + .1);
      expect(state.timing.value.scale, timing.scale);
      await tester.pumpWidget(const SizedBox());
      await state.close();
    },
  );
}
