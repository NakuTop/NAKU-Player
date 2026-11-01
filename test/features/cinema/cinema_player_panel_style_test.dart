import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_homepod_audio_settings.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    final font = FontLoader('.AppleSystemUIFont')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Light.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('player dialog repairs a legacy orange ancestor theme', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(900, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test/panel-style-homepod');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'supported': true,
        'enabled': true,
        'status': 'streaming',
        'driverInstalled': true,
        'driverInstallStatus': 'ready',
        'deviceName': '客厅 HomePod',
        'deviceId': 'fixture',
        'devices': [
          {'id': 'fixture', 'name': '客厅 HomePod'},
        ],
        'receiverVolume': 40,
        'latencyMs': 120,
        'capturedFrames': 44100,
        'packetsSent': 125,
      },
    );
    final controls = HomePodAudioControls(
      channel: channel,
      platform: TargetPlatform.macOS,
    );
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            platform: TargetPlatform.macOS,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.orange,
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showCinemaHomePodAudioSettings(
                    context,
                    controls: controls,
                  ),
                  child: const Text('打开音频设置'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开音频设置'));
    await tester.pumpAndSettle();
    final dialogTheme = Theme.of(tester.element(find.byType(AlertDialog)));
    expect(dialogTheme.colorScheme.primary, CinemaTheme.controlTint);
    expect(dialogTheme.colorScheme.primary, isNot(CinemaTheme.copper));
    expect(find.text('40%'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('40%')).style?.color,
      CinemaTheme.controlTint,
    );
    expect(tester.takeException(), isNull);

    final output = Platform.environment['NAKU_QA_SCREENSHOTS'];
    if (output != null) {
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 1);
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File(
          '$output/player-audio-panel.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        rendered.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    controls.dispose();
    await tester.pump();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
}
