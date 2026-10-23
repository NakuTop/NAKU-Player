import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_keyboard_transport.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const directory = String.fromEnvironment('SUBTITLE_NATIVE_FIXTURES');
  testWidgets(
    'native MPV applies temporary forward speed and continuous 2x reverse',
    (tester) async {
      final media = File('$directory/dialogue.wav');
      expect(await media.exists(), true);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      final duration = player.stream.duration.firstWhere(
        (d) => d.inSeconds > 100,
      );
      await player.open(Media(media.path), play: false);
      await duration;
      await player.setRate(1.25);
      await player.seek(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final controls = CinemaKeyboardTransport(
        player: player,
        setTemporaryRate: player.setRate,
        skipSeconds: 5,
      );
      try {
        final before = player.state.position;
        await controls.press(1);
        await controls.hold(1);
        expect(double.parse(await native.getProperty('speed')), 2);
        await Future<void>.delayed(const Duration(milliseconds: 750));
        await controls.release();
        final forward = player.state.position - before;
        expect(forward.inMilliseconds, inInclusiveRange(900, 2500));
        expect(double.parse(await native.getProperty('speed')), 1.25);
        expect(await native.getProperty('pause'), 'yes');
        await player.seek(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final reverseStart = player.state.position;
        await controls.press(-1);
        await controls.hold(-1);
        await Future<void>.delayed(const Duration(milliseconds: 750));
        await controls.release();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final reverse = reverseStart - player.state.position;
        expect(reverse.inMilliseconds, inInclusiveRange(1000, 2300));
        expect(double.parse(await native.getProperty('speed')), 1.25);
        expect(await native.getProperty('pause'), 'yes');
        debugPrint(
          'NATIVE_KEYBOARD: forward=${forward.inMilliseconds}ms/750ms reverse=${reverse.inMilliseconds}ms/750ms restored=1.25x paused',
        );
      } finally {
        await controls.close();
        await player.dispose();
      }
    },
    skip: directory.isEmpty,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
