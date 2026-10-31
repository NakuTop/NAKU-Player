import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_homepod_audio_settings.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/homepod-settings');

  testWidgets(
    'system output starts off and permissions are requested only on enable',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'enable') {
              throw PlatformException(
                code: 'permission',
                message: '请允许录制系统音频。',
              );
            }
            return {
              'supported': true,
              'enabled': false,
              'status': 'off',
              'driverInstalled': true,
              'driverInstallStatus': 'ready',
              'needsDriverUpdate': false,
              'devices': call.method == 'discover'
                  ? [
                      {
                        'id': 'bedroom',
                        'name': '卧室',
                        'address': '192.168.1.2',
                        'port': 7000,
                      },
                    ]
                  : [],
            };
          });
      final controls = HomePodAudioControls(
        channel: channel,
        platform: TargetPlatform.macOS,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CinemaHomePodAudioSettings(controls: controls)),
        ),
      );
      await tester.pump();
      expect(calls, ['state']);
      final toggle = find.byKey(const ValueKey('homepod-system-audio-toggle'));
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      expect(find.textContaining('整个 Mac'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('homepod-discover')));
      await tester.pumpAndSettle();
      expect(find.text('卧室'), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('请允许录制系统音频。'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.pumpWidget(const SizedBox());
      controls.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  testWidgets(
    'HomePod volume slider sends one commit only when dragging ends',
    (tester) async {
      final calls = <MethodCall>[];
      final off = <String, dynamic>{
        'supported': true,
        'enabled': false,
        'status': 'off',
        'driverInstalled': true,
        'driverInstallStatus': 'ready',
        'devices': [
          {
            'id': 'bedroom',
            'name': '卧室',
            'address': '192.168.1.2',
            'port': 7000,
          },
        ],
      };
      final live = {
        ...off,
        'enabled': true,
        'status': 'streaming',
        'routeActive': true,
        'receiverVolume': 65,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'enable') return live;
            if (call.method == 'setVolume') {
              return {
                ...live,
                'receiverVolume': (call.arguments as Map)['volume'],
              };
            }
            return off;
          });
      final controls = HomePodAudioControls(
        channel: channel,
        platform: TargetPlatform.macOS,
      );
      await controls.discover();
      await controls.enable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CinemaHomePodAudioSettings(controls: controls)),
        ),
      );
      await tester.pump();
      final slider = find.byKey(const ValueKey('homepod-receiver-volume'));
      expect(tester.widget<Slider>(slider).value, 65);
      expect(calls.where((call) => call.method == 'setVolume'), isEmpty);
      tester.widget<Slider>(slider).onChanged!(70);
      tester.widget<Slider>(slider).onChanged!(75);
      await tester.pump();
      expect(calls.where((call) => call.method == 'setVolume'), isEmpty);
      tester.widget<Slider>(slider).onChangeEnd!(75);
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'setVolume').length, 1);
      expect(calls.last.arguments, {'volume': 75.0});
      await tester.pumpWidget(const SizedBox());
      await controls.disable();
      controls.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
}
