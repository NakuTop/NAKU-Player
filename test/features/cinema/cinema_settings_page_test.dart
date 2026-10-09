import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_settings_catalog.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

void main() {
  for (final size in [const Size(360, 700), const Size(1280, 900)]) {
    testWidgets(
      'unified settings fit $size and preserve every original route',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final opened = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: CinemaTheme.data.copyWith(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: CinemaSettingsPage(
                enabledSourceCount: 7,
                sourceCount: 10,
                onSources: () => opened.add('sources'),
                onAppearance: () => opened.add('appearance'),
                onUpdates: () => opened.add('updates'),
                onOpenRoute: opened.add,
              ),
            ),
          ),
        );
        expect(find.text('已启用 7 / 10 个片源'), findsOneWidget);
        for (final entry in ['sources', 'appearance', 'updates']) {
          final target = find.byKey(ValueKey('settings-$entry'));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
        }
        expect(opened, ['sources', 'appearance', 'updates']);
        final destinations = cinemaSettingsGroups
            .expand((group) => group.destinations)
            .where((destination) => !destination.androidOnly);
        for (final destination in destinations) {
          final target = find.byKey(ValueKey('settings-${destination.id}'));
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          expect(opened.last, destination.route);
        }
        expect(find.byKey(const ValueKey('settings-renderer')), findsNothing);
        expect(find.byKey(const ValueKey('settings-display')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('keeps platform-only settings visible on Android', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data.copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: CinemaSettingsPage(
            enabledSourceCount: 0,
            sourceCount: 0,
            onSources: () {},
            onAppearance: () {},
            onUpdates: () {},
            onOpenRoute: opened.add,
          ),
        ),
      ),
    );
    for (final id in ['renderer', 'display']) {
      final target = find.byKey(ValueKey('settings-$id'));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
    }
    expect(opened, ['/settings/player/renderer', '/settings/theme/display']);
    expect(tester.takeException(), isNull);
  });

  test('catalog keeps all original setting categories with explicit scope', () {
    final entries = cinemaSettingsGroups
        .expand((group) => group.destinations)
        .toList();
    expect(entries.map((item) => item.id).toSet(), hasLength(entries.length));
    final routes = entries
        .map((item) => item.route.replaceFirst(RegExp(r'/$'), ''))
        .toSet();
    expect(
      routes,
      containsAll([
        '/settings/player',
        '/settings/danmaku',
        '/settings/keyboard',
        '/settings/plugin',
        '/settings/download-settings',
        '/settings/theme',
        '/settings/interface',
        '/settings/sync',
        '/settings/proxy',
        '/settings/update',
        '/settings/storage',
        '/settings/about',
        '/settings/player/super',
        '/settings/player/decoder',
        '/settings/player/renderer',
      ]),
    );
    for (final id in ['danmaku', 'downloads', 'sync']) {
      expect(
        entries.singleWhere((item) => item.id == id).description,
        startsWith('动漫专用'),
      );
    }
  });
}
