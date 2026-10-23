import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_keyboard_transport.dart';

class _Player implements Player {
  PlayerState value = PlayerState(
    position: const Duration(seconds: 20),
    duration: const Duration(seconds: 60),
    rate: 1.5,
    playing: true,
  );
  final seeks = <Duration>[];
  final rates = <double>[];
  Completer<void>? rateGate;
  @override
  PlayerState get state => value;
  @override
  Future<void> seek(Duration at) async {
    seeks.add(at);
    value = value.copyWith(position: at);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    await rateGate?.future;
    value = value.copyWith(rate: rate);
  }

  @override
  Future<void> play() async {
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(playing: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  CinemaKeyboardTransport transport(_Player player) => CinemaKeyboardTransport(
    player: player,
    setTemporaryRate: player.setRate,
    skipSeconds: 5,
  );

  test(
    'short taps seek once in either direction with no speed change',
    () async {
      final player = _Player(), controls = transport(_Player());
      await controls.close();
      final keys = transport(player);
      await keys.press(1);
      await keys.release();
      expect(player.state.position.inSeconds, 25);
      await keys.press(-1);
      await keys.release();
      expect(player.state.position.inSeconds, 20);
      expect(player.seeks, hasLength(2));
      expect(player.rates, isEmpty);
      await keys.close();
    },
  );

  for (final playing in [true, false]) {
    test(
      'forward hold temporarily plays 2x and restores rate and playing=$playing',
      () async {
        final player = _Player();
        player.value = player.value.copyWith(playing: playing);
        final keys = transport(player);
        await keys.press(1);
        await keys.hold(1);
        await keys.hold(1);
        expect(player.state.rate, 2);
        expect(player.state.playing, true);
        expect(keys.label, contains('快进'));
        expect(player.rates, [2]);
        await keys.release();
        expect(player.state.rate, 1.5);
        expect(player.state.playing, playing);
        expect(player.seeks, isEmpty);
        expect(keys.label, isEmpty);
        await keys.close();
      },
    );

    test(
      'reverse hold moves about two seconds per second and restores playing=$playing',
      () async {
        final player = _Player();
        player.value = player.value.copyWith(playing: playing);
        final keys = transport(player);
        await keys.press(-1);
        await keys.hold(-1);
        expect(player.state.playing, false);
        await Future<void>.delayed(const Duration(milliseconds: 550));
        await keys.release();
        expect(player.seeks.length, greaterThanOrEqualTo(3));
        expect(
          player.state.position.inMilliseconds,
          inInclusiveRange(18000, 19500),
        );
        expect(player.state.playing, playing);
        expect(player.state.rate, 1.5);
        final count = player.seeks.length;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.seeks.length, count);
        await keys.close();
      },
    );
  }

  test(
    'late asynchronous rate change cannot leave 2x active after key release',
    () async {
      final player = _Player()..rateGate = Completer<void>();
      final keys = transport(player);
      await keys.press(1);
      final held = keys.hold(1);
      await Future<void>.delayed(Duration.zero);
      final released = keys.release();
      player.rateGate!.complete();
      await held;
      await released;
      expect(player.rates, [2, 1.5]);
      expect(player.state.rate, 1.5);
      await keys.close();
    },
  );

  test(
    'cancelled short tap never seeks and closing a hold restores rate',
    () async {
      final player = _Player(), keys = transport(_Player());
      await keys.close();
      final controls = transport(player);
      await controls.press(-1);
      await controls.release(cancel: true);
      expect(player.seeks, isEmpty);
      await controls.press(1);
      await controls.hold(1);
      await controls.close();
      expect(player.state.rate, 1.5);
      expect(player.state.playing, true);
    },
  );

  test('reverse and short rewind clamp at the beginning', () async {
    final player = _Player();
    player.value = player.value.copyWith(position: Duration.zero);
    final keys = transport(player);
    await keys.press(-1);
    await keys.release();
    expect(player.state.position, Duration.zero);
    await keys.press(-1);
    await keys.hold(-1);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await keys.release();
    expect(player.state.position, Duration.zero);
    await keys.close();
  });
}
