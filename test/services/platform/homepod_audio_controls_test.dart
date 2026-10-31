import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/homepod-audio');
  final calls = <MethodCall>[];
  late HomePodAudioControls controls;
  final off = <String, dynamic>{
    'supported': true,
    'enabled': false,
    'status': 'off',
    'driverInstalled': true,
    'driverInstallStatus': 'ready',
    'needsDriverUpdate': false,
    'devices': <Map<String, dynamic>>[],
  };
  final discovered = <String, dynamic>{
    ...off,
    'devices': [
      {'id': 'bedroom', 'name': '卧室', 'address': '192.168.1.2', 'port': 7000},
    ],
  };
  final live = <String, dynamic>{
    ...discovered,
    'enabled': true,
    'status': 'streaming',
    'deviceId': 'bedroom',
    'deviceName': '卧室',
    'latencyMs': 120,
  };

  void handler(Future<Object?> Function(MethodCall) callback) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return callback(call);
        });
  }

  setUp(() {
    calls.clear();
    controls = HomePodAudioControls(
      channel: channel,
      platform: TargetPlatform.macOS,
    );
    handler(
      (call) async => switch (call.method) {
        'discover' => discovered,
        'enable' => live,
        _ => off,
      },
    );
  });

  tearDown(() {
    controls.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initialization reads state only and remains off', () async {
    expect(controls.enabled, false);
    expect(calls, isEmpty);
    await controls.initialize();
    expect(calls.map((call) => call.method), ['state']);
    expect(controls.enabled, false);
    expect(controls.devices, isEmpty);
  });

  test(
    'discovery and enabling require explicit calls and select the sole device',
    () async {
      await controls.discover();
      expect(controls.enabled, false);
      expect(controls.selectedDeviceId, 'bedroom');
      expect(await controls.enable(), true);
      expect(controls.status, 'streaming');
      expect(controls.latencyMs, 120);
      expect(calls.last.arguments, {'id': 'bedroom', 'latencyMs': 120});
      await controls.disable();
      expect(controls.enabled, false);
    },
  );

  test(
    'failed connection releases native capture and keeps the error visible',
    () async {
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') {
          throw PlatformException(code: 'permission', message: '请允许录制系统音频。');
        }
        return off;
      });
      await controls.discover();
      expect(await controls.enable(), false);
      expect(controls.enabled, false);
      expect(controls.error, '请允许录制系统音频。');
      expect(calls.last.method, 'disable');
      await controls.refresh();
      expect(controls.error, '请允许录制系统音频。');
    },
  );

  test('Stop wins over a late successful enable completion', () async {
    final response = Completer<Object?>();
    handler((call) async {
      if (call.method == 'discover') return discovered;
      if (call.method == 'enable') return response.future;
      return off;
    });
    await controls.discover();
    final connecting = controls.enable();
    await Future<void>.delayed(Duration.zero);
    expect(controls.connecting, true);
    await controls.disable();
    response.complete(live);
    expect(await connecting, false);
    expect(controls.enabled, false);
    expect(controls.status, 'off');
    expect(calls.where((call) => call.method == 'disable').length, 2);
  });

  test('Stop during initialization cancels the pending enable', () async {
    final state = Completer<Object?>();
    handler((call) async => call.method == 'state' ? state.future : off);
    final connecting = controls.enable();
    await Future<void>.delayed(Duration.zero);
    await controls.disable();
    state.complete(discovered);
    expect(await connecting, false);
    expect(calls.where((call) => call.method == 'enable'), isEmpty);
    expect(controls.enabled, false);
  });

  test(
    'a repeated On action cannot invalidate the pending connection',
    () async {
      final response = Completer<Object?>();
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') return response.future;
        return off;
      });
      await controls.discover();
      final first = controls.enable();
      await Future<void>.delayed(Duration.zero);
      expect(await controls.enable(), false);
      response.complete(live);
      expect(await first, true);
      expect(controls.enabled, true);
      expect(controls.connecting, false);
      expect(calls.where((call) => call.method == 'enable').length, 1);
    },
  );

  test('an unsupported platform never invokes native methods', () async {
    controls.dispose();
    controls = HomePodAudioControls(
      channel: channel,
      platform: TargetPlatform.android,
    );
    await controls.initialize();
    await controls.discover();
    await controls.enable();
    expect(controls.supported, false);
    expect(controls.enabled, false);
    expect(calls, isEmpty);
  });

  test(
    'closing settings does not stop an enabled background session',
    () async {
      await controls.discover();
      await controls.enable();
      controls.beginViewing();
      controls.endViewing();
      expect(controls.enabled, true);
      expect(calls.where((call) => call.method == 'disable'), isEmpty);
    },
  );

  testWidgets('opening settings never installs a missing driver', (
    tester,
  ) async {
    handler(
      (call) async => {
        ...off,
        'driverInstalled': false,
        'driverInstallStatus': 'idle',
      },
    );
    controls.beginViewing();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    controls.endViewing();
    expect(controls.enabled, false);
    expect(controls.installing, false);
    expect(calls.every((call) => call.method == 'state'), true);
  });

  test('an installed driver is reused without opening Installer', () async {
    await controls.discover();
    expect(await controls.enable(), true);
    expect(calls.where((call) => call.method == 'installDriver'), isEmpty);
    await controls.disable();
  });

  testWidgets(
    'explicit On installs once and resumes after ready while settings are closed',
    (tester) async {
      var ready = false;
      final missing = {
        ...discovered,
        'driverInstalled': false,
        'driverInstallStatus': 'idle',
      };
      handler((call) async {
        if (call.method == 'discover') return missing;
        if (call.method == 'installDriver') {
          return {...missing, 'driverInstallStatus': 'installing'};
        }
        if (call.method == 'enable') return live;
        return ready ? discovered : missing;
      });
      await controls.discover();
      expect(await controls.enable(), false);
      expect(controls.installing, true);
      expect(controls.enabled, false);
      expect(await controls.enable(), false);
      expect(calls.where((call) => call.method == 'installDriver').length, 1);
      ready = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(controls.installing, false);
      expect(controls.enabled, true);
      expect(calls.where((call) => call.method == 'enable').length, 1);
      await controls.disable();
    },
  );

  testWidgets('cancel during installation prevents later automatic enable', (
    tester,
  ) async {
    var ready = false;
    final missing = {
      ...discovered,
      'driverInstalled': false,
      'driverInstallStatus': 'idle',
    };
    handler((call) async {
      if (call.method == 'discover') return missing;
      if (call.method == 'installDriver') {
        return {...missing, 'driverInstallStatus': 'installing'};
      }
      return ready ? discovered : missing;
    });
    await controls.discover();
    await controls.enable();
    await controls.disable();
    ready = true;
    await tester.pump(const Duration(seconds: 3));
    await controls.refresh();
    expect(controls.installing, false);
    expect(controls.enabled, false);
    expect(calls.where((call) => call.method == 'enable'), isEmpty);
  });

  test(
    'authorization failure offers installation only on an explicit retry',
    () async {
      var needsUpdate = false;
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') {
          needsUpdate = true;
          throw PlatformException(
            code: 'driver_update_required',
            message: '驱动授权需要更新。',
          );
        }
        return {
          ...discovered,
          'needsDriverUpdate': needsUpdate,
          'driverInstallStatus': call.method == 'installDriver'
              ? 'installing'
              : 'ready',
        };
      });
      await controls.discover();
      expect(await controls.enable(), false);
      expect(controls.needsDriverUpdate, true);
      expect(calls.where((call) => call.method == 'installDriver'), isEmpty);
      await controls.enable();
      expect(controls.installing, true);
      expect(calls.where((call) => call.method == 'installDriver').length, 1);
      await controls.disable();
    },
  );

  testWidgets(
    'installation wait is bounded and cannot auto-enable after timeout',
    (tester) async {
      handler(
        (call) async => {
          ...discovered,
          'driverInstalled': false,
          'driverInstallStatus': call.method == 'installDriver'
              ? 'installing'
              : 'idle',
        },
      );
      await controls.discover();
      await controls.enable();
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(controls.installing, false);
      expect(controls.enabled, false);
      expect(controls.error, contains('安装尚未完成'));
      expect(calls.where((call) => call.method == 'enable'), isEmpty);
      expect(calls.where((call) => call.method == 'disable'), isNotEmpty);
    },
  );

  test(
    'driver check is explicit and reports a restored successful result',
    () async {
      handler((call) async {
        if (call.method == 'testDriver') {
          return {
            'success': true,
            'frames': 4410,
            'nonzeroSamples': 200,
            'restored': true,
          };
        }
        return off;
      });
      await controls.initialize();
      expect(calls.map((call) => call.method), ['state']);
      expect(controls.driverCheckMessage, isNull);
      expect(await controls.checkDriver(), true);
      expect(calls.where((call) => call.method == 'testDriver').length, 1);
      expect(controls.driverCheckMessage, '声卡检查通过');
      expect(controls.checkingDriver, false);
      expect(controls.enabled, false);
    },
  );

  test(
    'driver check blocks conflicting actions and ignores failure after Stop',
    () async {
      final response = Completer<Object?>();
      handler((call) async {
        if (call.method == 'testDriver') return response.future;
        return off;
      });
      await controls.initialize();
      final check = controls.checkDriver();
      await Future<void>.delayed(Duration.zero);
      expect(controls.checkingDriver, true);
      expect(await controls.enable(), false);
      expect(await controls.checkDriver(), false);
      await controls.disable();
      response.completeError(
        PlatformException(code: 'cancelled', message: 'stale check error'),
      );
      expect(await check, false);
      expect(controls.error, isNull);
      expect(controls.driverCheckMessage, isNull);
      expect(controls.checkingDriver, false);
      expect(calls.where((call) => call.method == 'testDriver').length, 1);
      expect(calls.where((call) => call.method == 'enable'), isEmpty);
    },
  );

  test(
    'driver check cannot report success when output was not restored',
    () async {
      handler(
        (call) async => call.method == 'testDriver'
            ? {
                'success': true,
                'frames': 4410,
                'nonzeroSamples': 200,
                'restored': false,
              }
            : off,
      );
      await controls.initialize();
      expect(await controls.checkDriver(), false);
      expect(controls.driverCheckMessage, isNull);
      expect(controls.error, '声卡检查未通过，请重试。');
    },
  );

  test(
    'confirmed audio route remains active until native Stop completes',
    () async {
      final stopped = Completer<Object?>();
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') return {...live, 'routeActive': true};
        if (call.method == 'disable') return stopped.future;
        return off;
      });
      await controls.discover();
      await controls.enable();
      expect(controls.audioRouteActive, true);
      final stopping = controls.disable();
      expect(controls.enabled, false);
      expect(controls.audioRouteActive, true);
      stopped.complete({...off, 'routeActive': false});
      await stopping;
      expect(controls.audioRouteActive, false);
    },
  );

  testWidgets(
    'route polling continues after Stop fails until native confirms restoration',
    (tester) async {
      var started = false;
      var restored = false;
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') {
          started = true;
          return {...live, 'routeActive': true};
        }
        if (call.method == 'disable') {
          throw PlatformException(code: 'stopping', message: '输出正在恢复。');
        }
        return started && !restored
            ? {...live, 'routeActive': true}
            : {...off, 'routeActive': false};
      });
      await controls.discover();
      await controls.enable();
      await controls.disable();
      expect(controls.enabled, false);
      expect(controls.audioRouteActive, true);
      restored = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(controls.audioRouteActive, false);
      expect(controls.enabled, false);
    },
  );

  test(
    'receiver volume is read without sending a setter and defaults to 40',
    () async {
      expect(controls.receiverVolume, 40);
      handler((call) async => {...off, 'receiverVolume': 63});
      await controls.initialize();
      expect(controls.receiverVolume, 63);
      expect(calls.where((call) => call.method == 'setVolume'), isEmpty);
      await controls.disable();
      expect(calls.where((call) => call.method == 'setVolume'), isEmpty);
    },
  );

  test(
    'receiver volume clamps finite levels and rejects non-finite input',
    () async {
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') return {...live, 'receiverVolume': 40};
        if (call.method == 'setVolume') {
          return {...live, 'receiverVolume': (call.arguments as Map)['volume']};
        }
        return off;
      });
      expect(await controls.setReceiverVolume(80), false);
      await controls.discover();
      await controls.enable();
      expect(await controls.setReceiverVolume(-20), true);
      expect(calls.last.arguments, {'volume': 0.0});
      expect(await controls.setReceiverVolume(125), true);
      expect(calls.last.arguments, {'volume': 100.0});
      expect(await controls.setReceiverVolume(double.nan), false);
      expect(await controls.setReceiverVolume(double.infinity), false);
      expect(calls.where((call) => call.method == 'setVolume').length, 2);
      expect(controls.receiverVolume, 100);
      await controls.disable();
    },
  );

  test(
    'receiver volume commits are serialized and late failure after Stop is ignored',
    () async {
      final volumeResult = Completer<Object?>();
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') return {...live, 'receiverVolume': 45};
        if (call.method == 'setVolume') return volumeResult.future;
        return {...off, 'routeActive': false};
      });
      await controls.discover();
      await controls.enable();
      final changing = controls.setReceiverVolume(75);
      expect(controls.settingVolume, true);
      expect(controls.receiverVolume, 75);
      expect(await controls.setReceiverVolume(85), false);
      expect(calls.where((call) => call.method == 'setVolume').length, 1);
      await controls.disable();
      volumeResult.completeError(
        PlatformException(code: 'network', message: 'stale volume error'),
      );
      expect(await changing, false);
      expect(controls.settingVolume, false);
      expect(controls.enabled, false);
      expect(controls.audioRouteActive, false);
      expect(controls.error, isNull);
    },
  );

  test(
    'receiver volume error preserves the last confirmed level and remains visible',
    () async {
      var started = false;
      handler((call) async {
        if (call.method == 'discover') return discovered;
        if (call.method == 'enable') {
          started = true;
          return {...live, 'receiverVolume': 55};
        }
        if (call.method == 'setVolume') {
          throw PlatformException(code: 'network', message: 'HomePod 暂时未响应。');
        }
        return started ? {...live, 'receiverVolume': 55} : off;
      });
      await controls.discover();
      await controls.enable();
      expect(await controls.setReceiverVolume(90), false);
      expect(controls.receiverVolume, 55);
      expect(controls.error, 'HomePod 暂时未响应。');
      await controls.refresh();
      expect(controls.error, 'HomePod 暂时未响应。');
    },
  );
}
