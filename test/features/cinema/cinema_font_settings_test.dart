import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/features/cinema/cinema_appearance.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/pages/settings/theme_settings_page.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku_font_settings_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  testWidgets(
    'font switch updates existing global theme without resetting navigation',
    (tester) async {
      await tester.runAsync(
        () => GStorage.putSetting(SettingsKeys.useSystemFont, false),
      );
      final appearance = CinemaAppearance(
        settingsFile: File('${directory.path}/appearance.json'),
        observeNativeAccessibility: false,
      );
      await tester.runAsync(appearance.initialize);
      addTearDown(appearance.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              CinemaAppearanceScope(appearance: appearance, child: child!),
          home: const Scaffold(body: Text('保留的主页')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsPaneScope(
            embedded: true,
            showBackButton: false,
            onBack: () {},
            child: const ThemeSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final routeState = tester.state(find.byType(ThemeSettingsPage));
      final context = tester.element(find.text('使用系统字体'));
      expect(
        Theme.of(context).textTheme.bodyMedium!.fontFamily,
        'MI_Sans_Regular',
      );
      final themeBefore = CinemaTheme.of(context);
      await tester.runAsync(() async {
        await tester.tap(find.text('使用系统字体'));
        await Hive.box('setting').flush();
      });
      await tester.pumpAndSettle();
      expect(GStorage.getSetting(SettingsKeys.useSystemFont), isTrue);
      expect(
        Theme.of(context).textTheme.bodyMedium!.fontFamily,
        '.AppleSystemUIFont',
      );
      expect(
        CinemaTheme.of(context).textTheme.bodyMedium!.fontFamily,
        '.AppleSystemUIFont',
      );
      expect(
        CinemaTheme.of(context).colorScheme.primary,
        themeBefore.colorScheme.primary,
      );
      expect(
        CinemaTheme.of(context).scaffoldBackgroundColor,
        themeBefore.scaffoldBackgroundColor,
      );
      expect(tester.state(find.byType(ThemeSettingsPage)), same(routeState));
      expect(find.text('深色模式'), findsNothing);
      expect(find.text('动态配色'), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('保留的主页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
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
