import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_settings_sheet.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/recording_semantics.dart';

void main() {
  final binding = RecordingSemanticsBinding();
  late Directory storage;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('naku-danmaku-sheet-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(storage.path);
    Hive.init(storage.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await storage.delete(recursive: true);
  });

  testWidgets(
    'closing and reopening live danmaku settings sends a valid native accessibility tree',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      binding.resetRecording();
      final semantics = tester.ensureSemantics();
      var semanticsDisposed = false;
      addTearDown(() {
        if (!semanticsDisposed) semantics.dispose();
      });
      final frame = ValueNotifier(0);
      addTearDown(frame.dispose);
      var option = const DanmakuOption();
      var pauses = 0;
      final controller = DanmakuController(
        addDanmaku: (_) {},
        updateOption: (value) => option = value,
        pause: () => pauses++,
        resume: () {},
        clear: () {},
        getOption: () => option,
        isRunning: () => true,
        findDanmaku: (_) => [],
        findSingleDanmaku: (_) => null,
        getViewWidth: () => 800,
        getViewHeight: () => 600,
        scrollDanmaku: [],
        staticDanmaku: [],
        specialDanmaku: [],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: frame,
                    builder: (_, value, _) => Text('正在播放 $value'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(
                      showDanmakuSettingsSheet(
                        context: context,
                        danmakuController: controller,
                        onUpdateDanmakuSpeed: () {},
                      ),
                    ),
                    child: const Text('打开弹幕设置'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.tap(find.text('打开弹幕设置'));
        for (var tick = 0; tick < 20; tick++) {
          frame.value++;
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(find.text('弹幕设置'), findsOneWidget);
        expect(
          binding.adjustableNodes,
          isNotEmpty,
          reason: 'The fix must retain screen-reader slider controls.',
        );
        await tester.runAsync(() async {
          await tester.drag(find.byType(Slider).first, const Offset(35, 0));
          await Hive.box<dynamic>('setting').flush();
        });
        await tester.pump();
        await tester.tap(find.byTooltip('关闭'));
        for (var tick = 0; tick < 15; tick++) {
          frame.value++;
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(find.text('弹幕设置'), findsNothing);
      }

      await tester.tap(find.text('打开弹幕设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('时间校准'), 150,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('danmaku-playback')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('时间校准'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕时间校准'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.drag(find.byType(Slider), const Offset(35, 0));
        await Hive.box<dynamic>('setting').flush();
      });
      await tester.pump();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕时间校准'), findsNothing);
      expect(
        pauses,
        0,
        reason: 'A settings close must not interrupt playback.',
      );
      expect(binding.commits, greaterThan(6));
      expect(binding.violations, isEmpty);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      semanticsDisposed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
