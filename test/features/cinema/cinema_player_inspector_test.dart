import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_player_inspector.dart';

void main() {
  testWidgets('outside click closes nested settings and never reaches playback', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var toggles = 0;
    await tester.pumpWidget(MaterialApp(home: Material(child: Builder(builder: (player) =>
      Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
          onTap: () => toggles++)),
        TextButton(onPressed: () => showCinemaPlayerPanel<void>(
          context: player, title: '设置', builder: (panel) => TextButton(
            onPressed: () => showCinemaSettingsDialog<void>(context: panel,
              builder: (_) => const AlertDialog(title: Text('来源'))),
            child: const Text('弹幕来源'))), child: const Text('打开')),
      ])))));
    await tester.tap(find.text('打开')); await tester.pumpAndSettle();
    await tester.tap(find.text('弹幕来源')); await tester.pumpAndSettle();
    expect(find.text('来源'), findsOneWidget);
    await tester.tapAt(const Offset(12, 200)); await tester.pumpAndSettle();
    expect(find.text('来源'), findsNothing);
    expect(find.text('弹幕来源'), findsNothing);
    expect(find.text('打开').hitTestable(), findsOneWidget);
    expect(toggles, 0);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('compact Mac inspector fits, scrolls and closes with Escape', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 320);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCinemaPlayerPanel<void>(
                context: context,
                title: '播放选项',
                builder: (_) => ListView(
                  children: [
                    for (var i = 0; i < 24; i++) ListTile(title: Text('设置 $i')),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ListView)).right, 464);
    await tester.scrollUntilVisible(find.text('设置 23'), 200);
    expect(find.text('设置 23').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('播放选项'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
