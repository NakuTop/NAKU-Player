import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/pages/download/download_widgets.dart';
import 'package:kazumi/services/download/download_library.dart';

class _Controller extends Fake implements DownloadController {
  _Controller(List<DownloadRecord> records)
    : values = ObservableMap.of({for (final r in records) r.key: r}),
      recordKeys = ObservableList.of(records.map((r) => r.key));
  final ObservableMap<String, DownloadRecord> values;
  @override
  final ObservableList<String> recordKeys;
  final deleted = <(String, int)>[];
  @override
  void refreshRecords() {}
  @override
  DownloadRecord? getRecordSnapshot(String key) => values[key];
  @override
  double getSpeed(int id, String plugin, int number) => 0;
  @override
  Future<void> deleteEntries(Iterable<DownloadEntry> entries) async {
    final selection = entries.toList();
    deleted.addAll(selection.map((e) => e.key));
    runInAction(() {
      for (final e in selection) {
        values[e.record.key]?.episodes.remove(e.episode.episodeNumber);
        if (values[e.record.key]?.episodes.isEmpty ?? false) {
          values.remove(e.record.key);
          recordKeys.remove(e.record.key);
        }
      }
    });
  }
}

DownloadRecord _record(String source, List<(int, int)> episodes) =>
    DownloadRecord(412916, '死神 千年血战篇-诀别谭-', '', source, {
      for (final (n, status) in episodes)
        n: DownloadEpisode(
          n,
          '第$n集',
          0,
          status,
          .42,
          100,
          42,
          '',
          '',
          '',
          null,
          status == DownloadStatus.failed ? '解析结果重复，请重试或更换来源' : '',
          2048,
          '/$source/$n',
        ),
    }, DateTime(2026));

void main() {
  Future<void> mount(
    WidgetTester tester,
    _Controller controller, {
    Size size = const Size(1100, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const snapshot = String.fromEnvironment('NAKU_DOWNLOAD_SNAPSHOT');
    if (snapshot.isNotEmpty) {
      for (final family in ['MI_Sans_Regular', '.AppleSystemUIFont']) {
        final font = FontLoader(family)
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
        await font.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('downloads-snapshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: MediaQuery(
            data: MediaQueryData(size: size, disableAnimations: true),
            child: DownloadPage(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    const target = String.fromEnvironment('NAKU_DOWNLOAD_SNAPSHOT');
    if (target.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('downloads-snapshot')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$target/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'cross-source work supports filtered selection, Escape cancellation and Enter deletion',
    (tester) async {
      final a = _record('来源甲', [
        (1, DownloadStatus.paused),
        (2, DownloadStatus.failed),
      ]);
      final b = _record('来源乙', [(3, DownloadStatus.completed)]);
      final controller = _Controller([a, b]);
      await mount(tester, controller);
      expect(find.byType(DownloadRecordCard), findsOneWidget);
      expect(find.byType(DownloadEpisodeTile), findsNWidgets(3));
      expect(find.textContaining('解析结果重复'), findsOneWidget);
      await snapshot(tester, '下载管理-跨源归组');
      await tester.tap(find.text('批量管理'));
      await tester.tap(find.text('已暂停'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前结果'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('删除所选'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.deleted, isEmpty);
      await tester.tap(find.text('删除所选'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.deleted, [(a.key, 1)]);
      expect(a.episodes.keys, [2]);
      expect(b.episodes.keys, [3]);
      await tester.tap(find.text('完成管理'));
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('包含 2 个来源'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pumpAndSettle();
      expect(controller.deleted.toSet(), {(a.key, 1), (a.key, 2), (b.key, 3)});
      expect(find.text('还没有下载记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long anime seasons limit initial rows and fit a short window', (
    tester,
  ) async {
    final controller = _Controller([
      _record('来源甲', [
        for (var n = 1; n <= 366; n++) (n, DownloadStatus.paused),
      ]),
    ]);
    await mount(tester, controller, size: const Size(600, 460));
    expect(find.byType(DownloadEpisodeTile), findsNWidgets(30));
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await snapshot(tester, '下载管理-小窗口');
  });
}
