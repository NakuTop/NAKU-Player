import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/macos_playback_power.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naku/power-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<void> send(bool value) async {
    final complete = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('changed', {'lowPowerMode': value}),
      ),
      (_) => complete.complete(),
    );
    await complete.future;
  }

  test(
    'initial state and changes track explicit system low power mode',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'lowPowerMode': true},
      );
      final power = MacOSPlaybackPower(channel: channel, supported: true);
      addTearDown(power.dispose);
      await power.initialize();
      expect(power.lowPowerMode, true);
      await send(false);
      expect(power.lowPowerMode, false);
    },
  );
  test('new event cannot be overwritten by delayed startup state', () async {
    final result = Completer<Map>();
    messenger.setMockMethodCallHandler(channel, (_) => result.future);
    final power = MacOSPlaybackPower(channel: channel, supported: true);
    addTearDown(power.dispose);
    final initializing = power.initialize();
    await send(true);
    result.complete({'lowPowerMode': false});
    await initializing;
    expect(power.lowPowerMode, true);
  });
  test('unavailable host keeps ordinary pause grace usable', () async {
    final power = MacOSPlaybackPower(channel: channel, supported: true);
    addTearDown(power.dispose);
    await power.initialize();
    expect(power.lowPowerMode, false);
  });
}
