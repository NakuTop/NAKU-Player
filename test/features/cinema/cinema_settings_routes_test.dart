import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/pages/settings/decoder_settings.dart';
import 'package:kazumi/pages/settings/player_settings.dart';
import 'package:kazumi/pages/settings/settings_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  final binding = CinemaSettingsHostBinding.instance;
  final owner = Object();

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku_settings_routes_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });
  tearDown(() => binding.unbind(owner));
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  for (final size in [const Size(390, 820), const Size(1280, 960)]) {
    testWidgets('root settings and nested details share navigation at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late BuildContext homeContext;
      var sourceOpens = 0;
      final input = TextEditingController(text: '保留主页面状态');
      addTearDown(input.dispose);
      final module = createModule(
        register: (c) {
          c
            ..route(
              '/home',
              child: (context, _) {
                homeContext = context;
                return Scaffold(
                  body: Column(
                    children: [
                      TextField(controller: input),
                      TextButton(
                        onPressed: () => context.pushNamed('/settings/'),
                        child: const Text('打开统一设置'),
                      ),
                    ],
                  ),
                );
              },
            )
            ..module(settingsModule);
        },
      );
      binding.bind(
        owner,
        onSources: () {
          sourceOpens++;
          final homeRoute = ModalRoute.of(homeContext);
          Navigator.of(
            homeContext,
            rootNavigator: true,
          ).popUntil((route) => identical(route, homeRoute));
        },
        enabledSourceCount: () => 3,
        sourceCount: () => 5,
      );
      await tester.pumpWidget(
        ModularApp(
          module: module,
          initialRoute: '/home',
          defaultTransition: TransitionType.none,
          child: Builder(
            builder: (context) => MaterialApp.router(
              theme: CinemaTheme.data,
              routerConfig: ModularApp.routerConfigOf(context),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开统一设置'));
      await tester.pumpAndSettle();
      expect(find.byType(CinemaSettingsPage), findsOneWidget);
      expect(find.text('已启用 3 / 5 个片源'), findsOneWidget);
      final settingsScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CinemaSettingsPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('settings-player')));
      await tester.pumpAndSettle();
      final offset = settingsScrollable.position.pixels;
      await tester.tap(find.byKey(const ValueKey('settings-player')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSettingsPage), findsOneWidget);
      expect(find.byType(CinemaSettingsPage), findsNothing);
      await tester.tap(find.text('硬件解码器'));
      await tester.pumpAndSettle();
      expect(find.byType(DecoderSettings), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSettingsPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CinemaSettingsPage), findsOneWidget);
      expect(settingsScrollable.position.pixels, closeTo(offset, .1));
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-sources')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-sources')));
      await tester.pumpAndSettle();
      expect(sourceOpens, 1);
      expect(find.text('保留主页面状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test(
    'host binding retains live counts and ignores an old owner disposal',
    () {
      final bridge = CinemaSettingsHostBinding();
      final oldOwner = Object(), newOwner = Object();
      var count = 2, calls = 0;
      bridge.bind(
        oldOwner,
        onSources: () => calls++,
        enabledSourceCount: () => count,
        sourceCount: () => 3,
      );
      count = 3;
      expect(bridge.enabledSourceCount, 3);
      bridge.bind(
        newOwner,
        onSources: () => calls += 10,
        enabledSourceCount: () => 4,
        sourceCount: () => 5,
      );
      bridge.unbind(oldOwner);
      expect(bridge.openSources(), isTrue);
      expect(calls, 10);
      bridge.unbind(newOwner);
      expect(bridge.hasHost, isFalse);
      expect(bridge.sourceCount, isNull);
      expect(bridge.openSources(), isFalse);
    },
  );
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}
