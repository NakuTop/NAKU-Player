import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_replay.dart';
import 'package:media_kit/media_kit.dart';

class _ReplayPlayer implements Player {
  Duration position = const Duration(seconds: 30);
  double rate = 1.5;
  bool playing = false;
  bool delaySeekPosition = false;
  bool failSeek = false;
  Completer<void>? pendingSeek;
  final rates = <double>[];
  final seeks = <Duration>[];
  int playCalls = 0, pauseCalls = 0;

  @override
  PlatformPlayer? get platform => null;

  @override
  PlayerState get state =>
      PlayerState(position: position, rate: rate, playing: playing);

  @override
  Future<void> setRate(double value) async {
    rates.add(value);
    rate = value;
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    if (failSeek) throw StateError('test seek failure');
    if (pendingSeek != null) await pendingSeek!.future;
    if (!delaySeekPosition) position = value;
  }

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('replays preceding three seconds slowly then pauses at the end', (
    tester,
  ) async {
    final player = _ReplayPlayer();
    final replay = CinemaSubtitleReplay(player);
    await replay.capture();
    expect(replay.start, const Duration(seconds: 27));
    expect(replay.end, const Duration(seconds: 30));
    expect(player.pauseCalls, 0);
    expect(player.rates, isEmpty);

    await replay.play();
    expect(player.seeks, [const Duration(seconds: 27)]);
    expect(player.rate, .75);
    expect(player.playing, isTrue);
    expect(replay.listening, isTrue);
    expect(replay.busy, isFalse);
    await tester.pump(const Duration(milliseconds: 60));
    player.position = const Duration(milliseconds: 29990);
    await tester.pump(const Duration(milliseconds: 60));
    expect(replay.listening, isTrue);
    player.position = const Duration(seconds: 30);
    await tester.pump(const Duration(milliseconds: 60));
    expect(player.pauseCalls, 1);
    expect(player.playing, isFalse);
    expect(player.rate, 1.5);
    expect(player.rates, [.75, 1.5]);
    expect(replay.listening, isFalse);
    await tester.pump(const Duration(seconds: 15));
    expect(player.pauseCalls, 1);
    replay.dispose();
    await tester.pump();
  });

  testWidgets('waits for seek position before treating old end as completion', (
    tester,
  ) async {
    final player = _ReplayPlayer()..delaySeekPosition = true;
    final replay = CinemaSubtitleReplay(player);
    await replay.capture();
    await replay.play();
    expect(player.position, const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 180));
    expect(replay.listening, isTrue);
    expect(player.pauseCalls, 0);
    player.position = const Duration(seconds: 27);
    await tester.pump(const Duration(milliseconds: 60));
    player.position = const Duration(seconds: 30);
    await tester.pump(const Duration(milliseconds: 60));
    expect(replay.listening, isFalse);
    expect(player.pauseCalls, 1);
    expect(player.rate, 1.5);
    replay.dispose();
    await tester.pump();
  });

  testWidgets('capture and negative shifts respect the beginning of the film', (
    tester,
  ) async {
    final player = _ReplayPlayer()..position = Duration.zero;
    final replay = CinemaSubtitleReplay(player);
    await replay.capture();
    expect(replay.start, Duration.zero);
    expect(replay.end, const Duration(seconds: 3));
    await replay.shift(const Duration(seconds: -1));
    expect(replay.start, Duration.zero);
    expect(player.seeks, [Duration.zero]);
    replay.dispose();
    await tester.pump();

    final earlyPlayer = _ReplayPlayer()..position = const Duration(seconds: 2);
    final earlyReplay = CinemaSubtitleReplay(earlyPlayer);
    await earlyReplay.capture();
    expect(earlyReplay.start, Duration.zero);
    expect(earlyReplay.end, const Duration(seconds: 2));
    earlyReplay.dispose();
    await tester.pump();
  });

  testWidgets(
    'shifting the anchor replays from the new start at the same rate',
    (tester) async {
      final player = _ReplayPlayer();
      final replay = CinemaSubtitleReplay(player);
      await replay.capture();
      await replay.play();
      await replay.shift(const Duration(milliseconds: -250));
      expect(replay.start, const Duration(milliseconds: 26750));
      expect(replay.end, const Duration(seconds: 30));
      expect(player.seeks.last, replay.start);
      expect(player.playCalls, 2);
      expect(player.rate, .75);
      expect(replay.listening, isTrue);
      await replay.shift(const Duration(seconds: 20));
      expect(replay.start, const Duration(milliseconds: 29850));
      expect(player.seeks.last, replay.start);
      expect(player.rate, .75);
      await replay.stop();
      expect(player.rate, 1.5);
      expect(player.playing, isFalse);
      replay.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'disposing an active replay restores rate and cancels callbacks',
    (tester) async {
      final player = _ReplayPlayer();
      final replay = CinemaSubtitleReplay(player);
      var notifications = 0;
      replay.addListener(() => notifications++);
      await replay.capture();
      await replay.play();
      final beforeDispose = notifications;
      replay.dispose();
      await tester.pump();
      expect(player.rate, 1.5);
      expect(player.playing, isFalse);
      expect(player.pauseCalls, 1);
      expect(notifications, beforeDispose);
      await tester.pump(const Duration(seconds: 15));
      expect(player.pauseCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed seek restores original speed and leaves no active timer',
    (tester) async {
      final player = _ReplayPlayer()..failSeek = true;
      final replay = CinemaSubtitleReplay(player);
      await replay.capture();
      await replay.play();
      expect(replay.error, isNotNull);
      expect(replay.listening, isFalse);
      expect(replay.busy, isFalse);
      expect(player.rate, 1.5);
      expect(player.playCalls, 0);
      expect(player.playing, isFalse);
      await tester.pump(const Duration(seconds: 15));
      expect(player.pauseCalls, 1);
      replay.dispose();
      await tester.pump();
    },
  );

  testWidgets('stop and dispose leave ordinary playback alone when not owned', (
    tester,
  ) async {
    final player = _ReplayPlayer()..playing = true;
    final replay = CinemaSubtitleReplay(player);
    await replay.capture();
    await replay.stop();
    replay.dispose();
    await tester.pump();
    expect(player.playing, isTrue);
    expect(player.rate, 1.5);
    expect(player.pauseCalls, 0);
    expect(player.playCalls, 0);
    expect(player.seeks, isEmpty);
    expect(player.rates, isEmpty);
  });

  testWidgets('stopping while seek is pending does not start playback later', (
    tester,
  ) async {
    final pendingSeek = Completer<void>();
    final player = _ReplayPlayer()..pendingSeek = pendingSeek;
    final replay = CinemaSubtitleReplay(player);
    await replay.capture();
    final starting = replay.play();
    await tester.pump();
    expect(replay.busy, isTrue);
    expect(player.seeks, hasLength(1));
    expect(player.rate, .75);
    await replay.stop();
    expect(player.rate, 1.5);
    pendingSeek.complete();
    await starting;
    expect(player.playCalls, 0);
    expect(player.playing, isFalse);
    expect(replay.listening, isFalse);
    expect(replay.busy, isFalse);
    await tester.pump(const Duration(seconds: 15));
    expect(player.pauseCalls, 1);
    replay.dispose();
    await tester.pump();
  });

  testWidgets('stalled playback ends at the bounded audition timeout', (
    tester,
  ) async {
    final player = _ReplayPlayer();
    final replay = CinemaSubtitleReplay(player);
    await replay.play();
    await tester.pump(const Duration(seconds: 12));
    expect(replay.listening, isFalse);
    expect(player.pauseCalls, 1);
    expect(player.playing, isFalse);
    expect(player.rate, 1.5);
    replay.dispose();
    await tester.pump();
  });
}
