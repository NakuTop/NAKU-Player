import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';

void main() {
  testWidgets('all settings entries fit a narrow window and dispatch actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CinemaSettingsPage(
            enabledSourceCount: 7,
            sourceCount: 10,
            onSources: () => opened.add('sources'),
            onAppearance: () => opened.add('appearance'),
            onUpdates: () => opened.add('updates'),
          ),
        ),
      ),
    );
    expect(find.text('已启用 7 / 10 个片源'), findsOneWidget);
    for (final entry in ['sources', 'appearance', 'updates']) {
      await tester.tap(find.byKey(ValueKey('settings-$entry')));
    }
    expect(opened, ['sources', 'appearance', 'updates']);
    expect(tester.takeException(), isNull);
  });
}
