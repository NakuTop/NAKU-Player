import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_page.dart';

import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_unified_library.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/pages/download/download_widgets.dart';
import 'package:kazumi/pages/history/history_list_view.dart';
import 'package:kazumi/pages/history/history_record_tile.dart';

BangumiItem _item(int id, String name) => BangumiItem(
  id: id,
  type: 2,
  name: name,
  nameCn: name,
  summary: '',
  airDate: '2025-01-01',
  airWeekday: 1,
  rank: 0,
  images: const {},
  tags: [],
  alias: [],
  ratingScore: 8.5,
  votes: 10,
  votesCount: [],
  info: '',
);

Widget _host(Widget child) => MaterialApp(
  theme: CinemaTheme.data,
  home: MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: Scaffold(body: child),
  ),
);

void main() {
  for (final width in [340.0, 940.0]) {
    testWidgets(
      'download record keeps expansion, episode actions and menus at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        var expanded = false;
        final episode = DownloadEpisode(
          1,
          '第 1 集',
          0,
          DownloadStatus.failed,
          .42,
          100,
          42,
          '',
          '',
          '',
          null,
          '网络连接已断开，请重试；已下载内容保留',
          1024,
          'episode1',
        );
        final record = DownloadRecord(1, '保留进度的电影与剧集', '', 'source', {
          1: episode,
        }, DateTime(2026));
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: DownloadRecordCard(
                  record: record,
                  expanded: expanded,
                  totalSpeed: 0,
                  onToggle: () => setState(() => expanded = !expanded),
                  onResumeAll: () => calls.add('resume-all'),
                  onDeleteAll: () => calls.add('delete-all'),
                  episodeTileBuilder: () => [
                    DownloadEpisodeTile(
                      episode: episode,
                      statusText: episode.errorMessage,
                      actions: [
                        IconButton(
                          tooltip: '重试',
                          onPressed: () => calls.add('retry'),
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () => calls.add('delete'),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('展开集数'));
        await tester.pumpAndSettle();
        expect(find.text('第 1 集'), findsOneWidget);
        expect(find.text(episode.errorMessage), findsOneWidget);
        await tester.tap(find.byTooltip('重试'));
        await tester.tap(find.byTooltip('删除'));
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部开始'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部删除'));
        await tester.pumpAndSettle();
        expect(calls, ['retry', 'delete', 'resume-all', 'delete-all']);
        await tester.tap(find.byTooltip('收起集数'));
        await tester.pumpAndSettle();
        expect(find.text('第 1 集'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real download page preserves pause resume retry playback and delete confirmation',
    (tester) async {
      final record = DownloadRecord(
        0,
        '真实下载管理流程',
        '',
        'cinema_fixture',
        {
          for (final (number, status) in [
            (1, DownloadStatus.downloading),
            (2, DownloadStatus.paused),
            (3, DownloadStatus.failed),
            (4, DownloadStatus.completed),
          ])
            number: DownloadEpisode(
              number,
              '第$number集',
              0,
              status,
              .4,
              100,
              40,
              '',
              '',
              '',
              null,
              status == DownloadStatus.failed ? '连接失败，可重试' : '',
              4096,
              'url$number',
            ),
        },
        DateTime(2026),
        mediaMetadata: 'fixture',
        sourceLabel: '电影片源',
      );
      final controller = _DownloadUiController(record);
      final owner = Object();
      final played = <int>[];
      CinemaSettingsHostBinding.instance.bind(
        owner,
        onSources: () {},
        enabledSourceCount: () => 1,
        sourceCount: () => 1,
        onOfflinePlayback: (_, episode) => played.add(episode.episodeNumber),
      );
      addTearDown(() => CinemaSettingsHostBinding.instance.unbind(owner));
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          navigatorObservers: [KazumiDialog.observer],
          theme: CinemaTheme.data,
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: DownloadPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('暂停'));
      await tester.tap(find.byTooltip('继续'));
      await tester.tap(find.byTooltip('重试'));
      await tester.tap(find.byTooltip('播放'));
      await tester.pumpAndSettle();
      expect(controller.calls, ['pause:1', 'retry:2', 'retry:3']);
      expect(played, [4]);
      final deleteFailed = find.descendant(
        of: find.widgetWithText(DownloadEpisodeTile, '第3集'),
        matching: find.byTooltip('删除'),
      );
      await tester.tap(deleteFailed);
      await tester.pumpAndSettle();
      expect(find.text('删除下载'), findsOneWidget);
      expect(controller.calls.where((c) => c.startsWith('delete')), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.calls.where((c) => c.startsWith('delete')), isEmpty);
      await tester.tap(deleteFailed);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(controller.calls.last, 'delete:3');
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部开始'));
      await tester.pumpAndSettle();
      expect(controller.calls.last, 'resume-all');
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除全部下载'), findsOneWidget);
      expect(controller.calls.contains('delete-record'), isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.calls.contains('delete-record'), isFalse);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(controller.calls.last, 'delete-record');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'collection search, categories, layout and status menu keep their actions',
    (tester) async {
      final entries = [
        CollectedBangumi(
          _item(1, '星际旅行'),
          DateTime(2026),
          CollectType.watching.value,
        ),
        CollectedBangumi(
          _item(2, '海边故事'),
          DateTime(2025),
          CollectType.planToWatch.value,
        ),
      ];
      var layout = CollectLayout.cards;
      final opened = <int>[];
      final changed = <CollectType>[];
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => CollectLibraryView(
              entries: entries,
              showRating: true,
              layout: layout,
              onOpen: (item) => opened.add(item.id),
              canEdit: (_) => true,
              onChangeType: (_, type) => changed.add(type),
              onLayoutChanged: (value) => setState(() => layout = value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('星际旅行'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '海边');
      await tester.pumpAndSettle();
      expect(find.text('星际旅行'), findsNothing);
      await tester.tap(find.text('全部').first);
      await tester.pumpAndSettle();
      expect(find.text('海边故事'), findsOneWidget);
      await tester.tap(find.text('海边故事'));
      expect(opened, [2]);
      await tester.tap(find.byTooltip('列表布局'));
      await tester.pumpAndSettle();
      expect(layout, CollectLayout.list);
      await tester.tap(find.byTooltip('调整《海边故事》的观看状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(changed, [CollectType.none]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history filters and continue action preserve the selected record',
    (tester) async {
      final online = History(
        _item(1, '在线影片'),
        2,
        '线路 A',
        DateTime.now(),
        '',
        '第 2 集',
      )..progresses[2] = Progress(2, 0, 123000);
      final offline = History(
        _item(2, '离线影片'),
        4,
        '本地',
        DateTime.now().subtract(const Duration(hours: 1)),
        '',
        '第 4 集',
        entryKind: HistoryEntryKind.offline,
      );
      final played = <String>[];
      await tester.pumpWidget(
        _host(
          HistoryListView(
            entries: [online, offline],
            itemBuilder: (entry, radius) => HistoryRecordTile(
              history: entry,
              borderRadius: radius,
              collectType: CollectType.none,
              onPlay: () => played.add(entry.key),
              onDetails: () {},
              onDelete: () async {},
              onChangeCollect: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('看到 2:03'), findsOneWidget);
      await tester.tap(find.byTooltip('继续播放').first);
      expect(played, [online.key]);
      await tester.tap(find.text('缓存').first);
      await tester.pumpAndSettle();
      expect(find.text('在线影片'), findsNothing);
      expect(find.text('离线影片'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没有找到相关记录'), findsOneWidget);
      await tester.tap(find.text('查看全部记录'));
      await tester.pumpAndSettle();
      expect(find.text('在线影片'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unified history uses real resume time and favorite posters grow without losing actions',
    (tester) async {
      final folder = await tester.runAsync(
        () => Directory.systemTemp.createTemp('naku-library-layout-'),
      );
      final file = File('${folder!.path}/library.json');
      const title = CinemaTitle(
        id: '1',
        sourceId: 'test',
        title: '真实影片',
        year: '2025',
      );
      final entry = CinemaHistory(
        title: title,
        routeIndex: 2,
        episodeIndex: 3,
        positionSeconds: 321,
        durationSeconds: 6000,
        updatedAt: DateTime(2026),
      );
      await tester.runAsync(
        () => file.writeAsString(
          jsonEncode({
            'version': 1,
            'sources': [],
            'favorites': [title.toJson()],
            'history': [entry.toJson()],
          }),
        ),
      );
      final store = CinemaStore(file: file, defaults: const []);
      await tester.runAsync(store.load);
      final played = <CinemaHistory>[];
      var history = true;
      Widget view() => _host(
        CinemaUnifiedLibrary(
          store: store,
          anime: null,
          history: history,
          filters: const CinemaFilters(),
          onFilters: (_) {},
          titleCard: (title) => TextButton(
            key: const ValueKey('favorite-poster'),
            onPressed: () {},
            child: Text(title.title),
          ),
          poster: (_, width, height) => SizedBox(
            width: width,
            height: height,
            child: const ColoredBox(color: Colors.grey),
          ),
          onCinemaPlay: played.add,
          onAnimePlay: (_) {},
          sourceName: (_) => '测试片源',
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text('第 4 集 · 5:21'), findsOneWidget);
      await tester.tap(find.byTooltip('继续播放'));
      expect(played.single.routeIndex, 2);
      expect(played.single.episodeIndex, 3);
      expect(played.single.positionSeconds, 321);
      history = false;
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('favorite-poster')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await tester.runAsync(() => folder.delete(recursive: true));
    },
  );
}

class _DownloadUiController implements DownloadController {
  _DownloadUiController(this.record)
    : recordKeys = ObservableList.of([record.key]);
  final DownloadRecord record;
  final List<String> calls = [];
  @override
  final ObservableList<String> recordKeys;
  @override
  void refreshRecords() {}
  @override
  DownloadRecord? getRecordSnapshot(String key) =>
      key == record.key ? record : null;
  @override
  double getSpeed(int bangumiId, String pluginName, int episodeNumber) => 4096;
  @override
  Future<void> pauseDownload(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async => calls.add('pause:$episodeNumber');
  @override
  Future<void> retryDownload({
    required int bangumiId,
    required String pluginName,
    required int episodeNumber,
  }) async => calls.add('retry:$episodeNumber');
  @override
  Future<void> deleteEpisode(
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async => calls.add('delete:$episodeNumber');
  @override
  Future<void> deleteRecord(int bangumiId, String pluginName) async =>
      calls.add('delete-record');
  @override
  Future<void> resumeAllDownloads(int bangumiId, String pluginName) async =>
      calls.add('resume-all');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
