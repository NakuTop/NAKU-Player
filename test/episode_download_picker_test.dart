import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';

void main() {
  const groups = [
    DownloadEpisodeGroup(
      name: '线路一',
      labels: ['第1集', '第2集', '第3集', '第4集'],
      urls: ['1', '2', '3', '4'],
      queuedUrls: {'1'},
    ),
    DownloadEpisodeGroup(
      name: '线路二',
      labels: ['第1集', '第2集'],
      urls: ['b1', 'b2'],
    ),
  ];
  Future<void> mount(
    WidgetTester tester,
    Future<int> Function(int, List<int>) submit, {
    Size size = const Size(900, 760),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('download-picker-snapshot'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CinemaTheme.data,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAdaptiveBottomSheet<void>(
                  context: context,
                  builder: (_) => EpisodeDownloadPicker(
                    title: '测试剧集 · 第一季',
                    groups: groups,
                    onDownload: submit,
                  ),
                ),
                child: const Text('下载'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'select all excludes queued episodes; one action submits the selection once',
    (tester) async {
      final submissions = <List<int>>[];
      final submitted = Completer<int>();
      await mount(tester, (road, indexes) {
        expect(road, 0);
        submissions.add(indexes);
        return submitted.future;
      });
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载 3 集'));
      await tester.pump();
      expect(submissions, [
        [1, 2, 3],
      ]);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '正在添加'))
            .onPressed,
        isNull,
      );
      submitted.complete(3);
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeDownloadPicker), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'changing routes clears old selection and empty/error states remain usable',
    (tester) async {
      await mount(tester, (_, _) async => throw StateError('fixture'));
      await tester.tap(find.text('第2集'));
      await tester.pumpAndSettle();
      expect(find.text('下载 1 集'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('线路二').last);
      await tester.pumpAndSettle();
      expect(find.text('选择集数'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载 2 集'));
      await tester.pumpAndSettle();
      expect(find.text('未能添加下载，请检查已有任务后重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Kazumi selection layout fits a short window and can render a QA snapshot',
    (tester) async {
      const snapshot = String.fromEnvironment('NAKU_UI_SNAPSHOT');
      if (snapshot.isNotEmpty) {
        for (final family in ['MI_Sans_Regular', '.AppleSystemUIFont']) {
          final loader = FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      }
      await mount(
        tester,
        (_, indexes) async => indexes.length,
        size: const Size(600, 460),
      );
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('下载 3 集'), findsOneWidget);
      expect(
        tester.getSize(find.byType(GridView)).height,
        greaterThanOrEqualTo(56),
      );
      final button = find.widgetWithText(FilledButton, '下载 3 集');
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(460));
      if (snapshot.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('download-picker-snapshot')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(snapshot).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}
