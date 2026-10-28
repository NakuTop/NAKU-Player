import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_webview_page.dart';
import 'package:kazumi/features/cinema/cinema_navigation_island.dart';
import 'package:kazumi/features/cinema/cinema_navigation_preferences.dart';
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

  Future<void> mount(
    WidgetTester tester,
    String version,
    String build, {
    bool showAnime = false,
  }) async {
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
    final navigation = CinemaNavigationPreferences(
      readValue: () => showAnime,
      writeValue: (_) async {},
    );
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          windowControls: controls,
          enableWatchTogether: false,
          enableSearchDiscovery: false,
          navigationPreferences: navigation,
          animePageBuilder: (_, _) => const SizedBox.expand(),
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

  for (final showAnime in [true, false]) {
    testWidgets(
      'history right swipe returns to ${showAnime ? 'anime' : 'series'}',
      (tester) async {
        await mount(tester, '3.0.14', '94', showAnime: showAnime);
        await tester.tap(
          find.byKey(const ValueKey('cinema-destination-history')),
        );
        await tester.pumpAndSettle();
        await tester.dragFrom(const Offset(130, 260), const Offset(170, 0));
        await tester.pumpAndSettle();
        final destination = tester
            .widget<CinemaNavigationIsland>(
              find.byKey(const ValueKey('cinema-floating-island')),
            )
            .value
            .toString();
        expect(destination, contains(showAnime ? 'anime' : 'series'));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('fish toolbar entry opens the requested site inside the app', (
    tester,
  ) async {
    await mount(tester, '3.0.10', '86');
    final entry = find.byKey(const ValueKey('cinema-moyu-entry'));
    expect(entry, findsOneWidget);
    expect(find.text('🐟'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final page = tester.widget<CinemaWebviewPage>(
      find.byType(CinemaWebviewPage),
    );
    expect(page.url, 'https://1in8b.life/zh-hans/');
    expect(page.mediaToolsEnabled, isFalse);
    expect(find.byTooltip('视频画中画 / 视频浮窗'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'home left/right swipes change the floating navigation destination',
    (tester) async {
      await mount(tester, '3.0.13', '92');
      String destination() => tester
          .widget<CinemaNavigationIsland>(
            find.byKey(const ValueKey('cinema-floating-island')),
          )
          .value
          .toString();
      expect(destination(), contains('movies'));
      await tester.dragFrom(const Offset(130, 260), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(destination(), contains('series'));
      await tester.dragFrom(const Offset(130, 260), const Offset(170, 0));
      await tester.pumpAndSettle();
      expect(destination(), contains('movies'));
      await tester.pumpWidget(const SizedBox());
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
