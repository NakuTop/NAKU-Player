import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/features/cinema/cinema_startup_preferences.dart';
import 'package:kazumi/pages/settings/interface_settings.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform oldPaths;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku-startup-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  test('each visible option round trips to the exact shell destination', () {
    for (final location in CinemaStartupPreferences.options.keys) {
      final target = CinemaStartupTarget.fromStored(location);
      expect(target.location, location);
      expect(Uri.parse(target.location).path, '/cinema');
    }
    expect(
      CinemaStartupPreferences.options.keys
          .map((value) => CinemaStartupTarget.fromStored(value).section)
          .toSet(),
      CinemaStartupSection.values.toSet(),
    );
  });

  for (final legacy in {
    '/tab/popular/': CinemaAnimeStartupTab.popular,
    '/tab/timeline/': CinemaAnimeStartupTab.timeline,
    '/tab/my/': CinemaAnimeStartupTab.more,
  }.entries) {
    test('legacy ${legacy.key} keeps the corresponding anime tab', () {
      final target = CinemaStartupTarget.fromStored(legacy.key);
      expect(target.section, CinemaStartupSection.anime);
      expect(target.animeTab, legacy.value);
      expect(CinemaStartupPreferences.options, contains(target.location));
    });
  }

  test('old anime collection startup opens the unified favorites', () {
    for (final location in [
      '/tab/collect/',
      '/cinema?section=anime&animeTab=collect',
    ]) {
      final target = CinemaStartupTarget.fromStored(location);
      expect(target.section, CinemaStartupSection.favorites);
      expect(CinemaStartupPreferences.options, contains(target.location));
    }
  });

  test('missing and unknown settings fall back to movies without writing', () {
    final writes = <String>[];
    for (final raw in [
      null,
      '',
      'unknown',
      '/missing/',
      '/cinema?section=missing',
      'https://example.com/cinema?section=series',
    ]) {
      final preferences = CinemaStartupPreferences(
        readValue: () => raw,
        writeValue: (value) async => writes.add(value),
      );
      expect(preferences.read().section, CinemaStartupSection.movies);
    }
    final anime = CinemaStartupTarget.fromStored(
      '/cinema?section=anime&animeTab=unknown',
    );
    expect(anime.animeTab, CinemaAnimeStartupTab.popular);
    expect(writes, isEmpty);
  });

  test(
    'the existing storage key preserves explicit legacy preferences',
    () async {
      await GStorage.resetSettings([SettingsKeys.defaultStartupPage]);
      const preferences = CinemaStartupPreferences();
      // The old key's fallback is still /tab/popular/. The adapter distinguishes
      // it from a choice actually stored by the user.
      expect(
        GStorage.getSetting(SettingsKeys.defaultStartupPage),
        '/tab/popular/',
      );
      expect(preferences.read().section, CinemaStartupSection.movies);
      await GStorage.putSetting(
        SettingsKeys.defaultStartupPage,
        '/tab/collect/',
      );
      expect(preferences.read().section, CinemaStartupSection.favorites);
      expect(
        GStorage.getSetting(SettingsKeys.defaultStartupPage),
        '/tab/collect/',
      );
      await preferences.save(
        const CinemaStartupTarget(section: CinemaStartupSection.history),
      );
      expect(
        GStorage.getSetting(SettingsKeys.defaultStartupPage),
        '/cinema?section=history',
      );
      expect(
        const CinemaStartupPreferences().read().section,
        CinemaStartupSection.history,
      );
    },
  );

  Future<void> mount(
    WidgetTester tester,
    CinemaStartupPreferences preferences,
  ) => tester.pumpWidget(
    MaterialApp(
      home: SettingsPaneScope(
        embedded: true,
        showBackButton: false,
        onBack: () {},
        child: InterfaceSettingsPage(startupPreferences: preferences),
      ),
    ),
  );

  SettingsDropdownTile<String> startupDropdown(WidgetTester tester) =>
      tester.widget(find.byType(SettingsDropdownTile<String>));

  testWidgets('selecting a startup destination persists across reopening', (
    tester,
  ) async {
    String? stored = '/tab/timeline/';
    final preferences = CinemaStartupPreferences(
      readValue: () => stored,
      writeValue: (value) async => stored = value,
    );
    await mount(tester, preferences);
    expect(
      startupDropdown(tester).value,
      '/cinema?section=anime&animeTab=timeline',
    );
    await tester.tap(find.text('启动页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集').last);
    await tester.pumpAndSettle();
    expect(stored, '/cinema?section=series');
    expect(startupDropdown(tester).value, stored);
    await tester.pumpWidget(const SizedBox());
    await mount(tester, preferences);
    expect(startupDropdown(tester).value, '/cinema?section=series');
  });

  testWidgets(
    'failed save keeps the previous visible choice and allows retry',
    (tester) async {
      final saving = Completer<void>();
      final writes = <String>[];
      await mount(
        tester,
        CinemaStartupPreferences(
          readValue: () => '/cinema?section=movies',
          writeValue: (value) {
            writes.add(value);
            return saving.future;
          },
        ),
      );
      startupDropdown(tester).onChanged('/cinema?section=series');
      await tester.pump();
      expect(startupDropdown(tester).enabled, isFalse);
      expect(startupDropdown(tester).value, '/cinema?section=movies');
      expect(find.text('正在保存…'), findsOneWidget);
      saving.completeError(const FileSystemException('fixture write failure'));
      await tester.pumpAndSettle();
      expect(writes, ['/cinema?section=series']);
      expect(startupDropdown(tester).value, '/cinema?section=movies');
      expect(startupDropdown(tester).enabled, isTrue);
      expect(find.text('启动页面未保存，请重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unavailable storage disables the startup option', (
    tester,
  ) async {
    final writes = <String>[];
    await mount(
      tester,
      CinemaStartupPreferences(
        readValue: () => throw StateError('fixture read failure'),
        writeValue: (value) async => writes.add(value),
      ),
    );
    expect(startupDropdown(tester).enabled, isFalse);
    expect(find.text('启动设置暂时无法读取，请重新打开设置。'), findsOneWidget);
    expect(find.text('暂不可用'), findsOneWidget);
    expect(writes, isEmpty);
  });

  testWidgets('anime-only settings and renamed exit fit a narrow pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, CinemaStartupPreferences(readValue: () => null));
    expect(find.text('动漫追番默认布局'), findsNothing);
    expect(find.text('显示动漫评分'), findsOneWidget);
    expect(find.textContaining('不改变电影、剧集与豆瓣榜单评分'), findsOneWidget);
    final exit = tester.widget<SettingsDropdownTile<int>>(
      find.byType(SettingsDropdownTile<int>),
    );
    expect(exit.options[0], '退出 NAKU播放器');
    expect(
      exit.options.values.any((value) => value.contains('Kazumi')),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
