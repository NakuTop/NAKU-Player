import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  late DesktopWindowControls controls;
  late String saved;
  late List<Map<dynamic, dynamic>> configurations;
  const channel = MethodChannel('naku/version-opacity-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('home-version-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [],
    );
    await store.load();
    saved = '{}';
    configurations = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'configure') {
        configurations.add(Map.of(call.arguments as Map));
        return {
          'registered': true,
          'hidden': false,
          'reduceTransparency': false,
        };
      }
      return null;
    });
    controls = DesktopWindowControls(
      supported: true,
      channel: channel,
      read: () => saved,
      save: (value) async {
        saved = value;
      },
    );
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    controls.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, String version, String build) async {
    PackageInfo.setMockInitialValues(
      appName: 'NAKU播放器',
      packageName: 'com.shenminghao.yingchuan',
      version: version,
      buildNumber: build,
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          windowControls: controls,
          enableWatchTogether: false,
          enableSearchDiscovery: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'version label keeps its appearance while toggling native opacity',
    (tester) async {
      await mount(tester, '1.5.2', '15');
      final versionLabel = find.byKey(const ValueKey('cinema-app-version'));
      expect(tester.widget<Text>(versionLabel).data, 'NAKU播放器  1.5.2+15');
      await tester.ensureVisible(versionLabel);
      await tester.tap(versionLabel);
      await tester.pumpAndSettle();
      if (Platform.isMacOS) {
        expect(find.byType(AboutDialog), findsNothing);
        expect(configurations.last['translucent'], true);
        expect(configurations.last['opacity'], .8);
        final unchanged = tester.widget<Text>(versionLabel);
        expect(unchanged.data, 'NAKU播放器  1.5.2+15');
        expect(unchanged.style?.fontSize, 11);
        await tester.tap(versionLabel);
        await tester.pumpAndSettle();
        expect(configurations.last['translucent'], false);
        expect(controls.preferences.opacity, .8);
      } else {
        expect(
          tester
              .widget<AboutDialog>(find.byType(AboutDialog))
              .applicationVersion,
          '1.5.2+15',
        );
      }
      expect(find.textContaining('1.5.0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing platform version does not invent an old release', (
    tester,
  ) async {
    await mount(tester, '', '');
    final versionLabel = find.byKey(const ValueKey('cinema-app-version'));
    expect(tester.widget<Text>(versionLabel).data, 'NAKU播放器  版本信息暂不可用');
    await tester.ensureVisible(versionLabel);
    await tester.tap(versionLabel);
    await tester.pumpAndSettle();
    if (Platform.isMacOS) {
      expect(find.byType(AboutDialog), findsNothing);
      expect(configurations.last['translucent'], true);
      expect(configurations.last['opacity'], .8);
    } else {
      expect(
        tester.widget<AboutDialog>(find.byType(AboutDialog)).applicationVersion,
        '版本信息暂不可用',
      );
    }
    expect(find.textContaining('1.5.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
