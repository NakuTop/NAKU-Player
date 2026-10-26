import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_navigation_preferences.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform oldPaths;
  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku-navigation-prefs-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init('${directory.path}/hive');
    await GStorage.init();
  });
  setUp(() => GStorage.resetSettings([CinemaNavigationPreferences.storageKey]));
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  test(
    'absent key defaults hidden without writing and saved true survives a fresh reader',
    () async {
      final preferences = CinemaNavigationPreferences();
      addTearDown(preferences.dispose);
      expect(preferences.showAnime, isFalse);
      expect(
        Hive.box(
          'setting',
        ).containsKey(CinemaNavigationPreferences.storageKey.name),
        isFalse,
      );
      await preferences.setShowAnime(true);
      await Hive.box('setting').flush();
      final recreated = CinemaNavigationPreferences();
      addTearDown(recreated.dispose);
      expect(recreated.showAnime, isTrue);

      // Read the actual persisted Hive snapshot rather than just the model's
      // in-memory value, without reopening or replacing the application's box.
      final snapshot = await Hive.openBox<dynamic>(
        'navigation-setting-snapshot',
        bytes: await File('${directory.path}/hive/setting.hive').readAsBytes(),
      );
      expect(snapshot.get('cinemaShowAnimeNavigation'), isTrue);
      await snapshot.close();
      await recreated.setShowAnime(false);
      expect(CinemaNavigationPreferences().showAnime, isFalse);
    },
  );

  test(
    'device preference stays outside portable settings and NAS library data',
    () async {
      final preferences = CinemaNavigationPreferences();
      addTearDown(preferences.dispose);
      await preferences.setShowAnime(true);
      final key = CinemaNavigationPreferences.storageKey.name;
      expect(GStorage.exportPortableSettings(), isNot(contains(key)));
      expect(
        () => GStorage.validatePortableSettings({key: false}),
        throwsFormatException,
      );
      final store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: const [],
      );
      await store.load();
      expect(await store.exportLibrary(), isNot(contains(key)));
      final backup = await store.exportLibrary();
      await store.restoreLibrary({...backup, key: false}, merge: false);
      expect(
        CinemaNavigationPreferences().showAnime,
        isTrue,
        reason: 'A remote library field cannot change this device preference.',
      );
      store.dispose();
    },
  );

  test(
    'failed and pending saves retain the previous visible preference',
    () async {
      final pending = Completer<void>();
      final preferences = CinemaNavigationPreferences(
        readValue: () => false,
        writeValue: (_) => pending.future,
      );
      addTearDown(preferences.dispose);
      final saving = preferences.setShowAnime(true);
      expect(preferences.saving, isTrue);
      expect(preferences.showAnime, isFalse);
      pending.completeError(const FileSystemException('fixture'));
      await saving;
      expect(preferences.saving, isFalse);
      expect(preferences.showAnime, isFalse);
      expect(preferences.error, isNotNull);
    },
  );

  for (final width in [600.0, 1280.0]) {
    testWidgets(
      'settings switch restores and persists anime entry at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preferences = CinemaNavigationPreferences();
        addTearDown(preferences.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: CinemaSettingsPage(
                platform: TargetPlatform.macOS,
                navigationPreferences: preferences,
                enabledSourceCount: 1,
                sourceCount: 1,
                onSources: () {},
                onAppearance: () {},
                onUpdates: () {},
              ),
            ),
          ),
        );
        final toggle = find.byKey(const ValueKey('settings-anime-navigation'));
        Future<void> tapAndSave() async {
          // Start the I/O in the real async zone too. Moving only a later
          // flush into runAsync cannot release a Hive write queue whose
          // futures were already created by a tap in the fake-clock zone.
          await tester.runAsync(() async {
            final saved = Completer<void>();
            var started = false;
            void changed() {
              if (preferences.saving) {
                started = true;
              } else if (started && !saved.isCompleted) {
                saved.complete();
              }
            }

            preferences.addListener(changed);
            try {
              await tester.tap(toggle);
              expect(
                started,
                isTrue,
                reason: 'The actual switch must start a save.',
              );
              await saved.future;
              expect(preferences.error, isNull);
              await Hive.box('setting').flush();
            } finally {
              preferences.removeListener(changed);
            }
          });
          await tester.pumpAndSettle();
        }

        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        await tapAndSave();
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        expect(CinemaNavigationPreferences().showAnime, isTrue);
        await tapAndSave();
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
        expect(CinemaNavigationPreferences().showAnime, isFalse);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
