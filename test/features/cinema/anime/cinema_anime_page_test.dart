import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/features/cinema/anime/cinema_anime_page.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/pages/settings/settings_module.dart';
import 'package:kazumi/pages/settings/sync/sync_settings_page.dart';
import 'package:kazumi/pages/settings/sync/bangumi_sync_page.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_page.dart';
import 'package:kazumi/pages/info/info_module.dart';
import 'package:kazumi/pages/info/info_page.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_page.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/pages/search/image_search_page.dart';
import 'package:kazumi/pages/search/search_module.dart';
import 'package:kazumi/pages/search/search_page.dart';
import 'package:kazumi/pages/timeline/timeline_page.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late _BangumiAdapter adapter;
  late _TrackingMyController myController;
  late ValueNotifier<bool> active;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku_anime_host_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'direct');
  });
  setUp(() {
    DioFactory.reset();
    adapter = _BangumiAdapter();
    DioFactory.bangumiDio.httpClientAdapter.close();
    DioFactory.bangumiDio.httpClientAdapter = adapter;
    myController = _TrackingMyController();
    active = ValueNotifier(true);
  });
  tearDown(() {
    active.dispose();
    DioFactory.reset();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final module = createModule(
      register: (c) {
        c
          ..addSingleton<ICollectRepository>(CollectRepository.new)
          ..addSingleton<ISearchHistoryRepository>(_SearchHistoryRepository.new)
          ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
          ..addSingleton<CollectController>(CollectController.new)
          ..addInstance<MyController>(myController)
          ..route(
            '/cinema',
            provide: provideCinemaAnimeControllers,
            child: (context, state) => Scaffold(
              body: Row(
                children: [
                  const SizedBox(width: 240),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: active,
                      builder: (_, value, _) => CinemaAnimePage(active: value),
                    ),
                  ),
                ],
              ),
            ),
          )
          ..module(infoModule)
          ..module(searchModule)
          ..module(settingsModule)
          ..route(
            '/covered',
            child: (_, _) => const Scaffold(body: Text('cover')),
          );
      },
    );
    await tester.pumpWidget(
      ModularApp(
        module: module,
        initialRoute: '/cinema',
        navigatorObservers: [rootRouteObserver],
        defaultTransition: TransitionType.none,
        child: Builder(
          builder: (context) => MaterialApp.router(
            theme: CinemaTheme.data,
            routerConfig: ModularApp.routerConfigOf(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> tab(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(ValueKey('anime-tab-$index')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'keeps original pages lazy and preserves scroll and local search state',
    (tester) async {
      await mount(tester);
      expect(find.byType(PopularPage), findsOneWidget);
      expect(find.byType(TimelinePage, skipOffstage: false), findsNothing);
      expect(find.byType(SearchPage, skipOffstage: false), findsNothing);
      expect(find.byType(CollectPage, skipOffstage: false), findsNothing);
      expect(find.byType(MyPage, skipOffstage: false), findsNothing);
      expect(adapter.trendingRequests, 1);
      final popular = tester.widget<PopularPage>(find.byType(PopularPage));
      final popularState = tester.state(find.byType(PopularPage));
      expect(
        MediaQuery.sizeOf(tester.element(find.byType(PopularPage))).width,
        960,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -470));
      await tester.pumpAndSettle();
      final offset = popular.controller.scrollOffset;
      final loadedRequests = adapter.trendingRequests;
      expect(offset, greaterThan(0));

      await tab(tester, 2);
      final searchState = tester.state(find.byType(SearchPage));
      await tester.enterText(find.byType(TextField), '赛博朋克');
      await tab(tester, 1);
      expect(find.byType(TimelinePage), findsOneWidget);
      expect(adapter.calendarRequests, 1);
      await tab(tester, 2);
      expect(tester.state(find.byType(SearchPage)), same(searchState));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '赛博朋克',
      );
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      expect(tester.state(find.byType(SearchPage)), same(searchState));
      await tab(tester, 0);
      expect(tester.state(find.byType(PopularPage)), same(popularState));
      expect(popular.controller.scrollOffset, closeTo(offset, .01));
      expect(adapter.trendingRequests, loadedRequests);
      await tab(tester, 1);
      expect(adapter.calendarRequests, 1);
      final owner = Object();
      var openedFavorites = 0;
      CinemaSettingsHostBinding.instance.bind(
        owner,
        onSources: () {},
        onFavorites: () => openedFavorites++,
        enabledSourceCount: () => 0,
        sourceCount: () => 0,
      );
      addTearDown(() => CinemaSettingsHostBinding.instance.unbind(owner));
      await tab(tester, 3);
      expect(openedFavorites, 1);
      expect(find.byType(CollectPage, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'original Chinese and English search retains full info and image search routes',
    (tester) async {
      await mount(tester);
      await tab(tester, 2);
      for (final keyword in ['赛博朋克', 'Cyberpunk']) {
        await tester.enterText(find.byType(TextField), keyword);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(adapter.searchKeywords.last, keyword);
        expect(find.text('赛博朋克：边缘行者'), findsOneWidget);
      }
      final searchState = tester.state(find.byType(SearchPage));
      final results = adapter.searchKeywords.length;
      await tester.tap(find.text('赛博朋克：边缘行者'));
      await tester.pumpAndSettle();
      expect(find.byType(InfoPage), findsOneWidget);
      for (final title in ['概览', '吐槽', '角色', '关联', '制作人员']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('开始观看'), findsOneWidget);
      Navigator.of(tester.element(find.byType(InfoPage))).pop();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SearchPage)), same(searchState));
      expect(adapter.searchKeywords.length, results);
      await tester.tap(find.byTooltip('以图搜番'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageSearchPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(ImageSearchPage))).pop();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SearchPage)), same(searchState));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Cyberpunk',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden tabs and covering original routes detach account listeners',
    (tester) async {
      await mount(tester);
      await tab(tester, 4);
      final myState = tester.state(find.byType(MyPage));
      expect(myController.viewers, 1);
      active.value = false;
      await tester.pump();
      expect(myController.viewers, 0);
      expect(
        Focus.of(
          tester.element(find.byKey(const ValueKey('anime-tab-0'))),
          scopeOk: true,
        ).canRequestFocus,
        isFalse,
      );
      expect(
        RouteVisibility.isCoveredOf(tester.element(find.byType(MyPage))),
        isTrue,
      );
      expect(
        TickerMode.valuesOf(tester.element(find.byType(MyPage))).enabled,
        isFalse,
      );
      active.value = true;
      await tester.pump();
      expect(myController.viewers, 1);
      final context = tester.element(find.byType(MyPage));
      context.pushNamed('/covered');
      await tester.pumpAndSettle();
      expect(myController.viewers, 0);
      Navigator.of(tester.element(find.text('cover'))).pop();
      await tester.pumpAndSettle();
      expect(myController.viewers, 1);
      await tab(tester, 0);
      expect(myController.viewers, 0);
      await tab(tester, 4);
      expect(tester.state(find.byType(MyPage)), same(myState));
      expect(myController.viewers, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(myController.viewers, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more keeps original settings and Bangumi account routes', (
    tester,
  ) async {
    await mount(tester);
    await tab(tester, 4);
    final state = tester.state(find.byType(MyPage));
    await tester.ensureVisible(find.text('同步备份'));
    await tester.tap(find.text('同步备份'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncSettingsPage), findsOneWidget);
    expect(find.text('设置 WebDAV'), findsOneWidget);
    expect(myController.viewers, 0);
    await tester.tap(find.text('连接 Bangumi'));
    await tester.pumpAndSettle();
    expect(find.byType(BangumiSyncPage), findsOneWidget);
    Navigator.of(
      tester.element(find.byType(BangumiSyncPage)),
      rootNavigator: true,
    ).pop();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MyPage)), same(state));
    expect(myController.viewers, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'original popular card opens original details and returns without refetch',
    (tester) async {
      await mount(tester);
      final state = tester.state(find.byType(PopularPage));
      await tester.tap(find.byType(BangumiCardV).first);
      await tester.pumpAndSettle();
      expect(find.byType(InfoPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(InfoPage))).pop();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(PopularPage)), same(state));
      expect(adapter.trendingRequests, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

class _TrackingMyController extends MyController {
  _TrackingMyController()
    : super(_UnusedHistory(), _UnusedDownloads(), _UnusedShield());
  int viewers = 0;
  @override
  void attach() => viewers++;
  @override
  void detach() => viewers--;
}

class _UnusedHistory extends Fake implements IHistoryRepository {}

class _UnusedDownloads extends Fake implements IDownloadRepository {}

class _UnusedShield extends Fake implements IDanmakuShieldRepository {}

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

Map<String, dynamic> _subject(int id) => {
  'id': id,
  'type': 2,
  'name': 'Cyberpunk: Edgerunners',
  'name_cn': id == 309311 ? '赛博朋克：边缘行者' : '番剧 $id',
  'summary': '用于验证原版详情、搜索和导航的数据。',
  'date': '2022-09-13',
  'rating': {
    'rank': 100,
    'score': 8.2,
    'total': 10,
    'count': {for (var index = 1; index <= 10; index++) '$index': 1},
  },
  'images': <String, String>{},
};

class _BangumiAdapter implements HttpClientAdapter {
  int trendingRequests = 0;
  int calendarRequests = 0;
  final searchKeywords = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    Object response;
    if (path == '/p1/trending/subjects') {
      trendingRequests++;
      response = {
        'data': List.generate(24, (i) => {'subject': _subject(309311 + i)}),
      };
    } else if (path == '/p1/calendar') {
      calendarRequests++;
      response = {
        for (var day = 1; day <= 7; day++)
          '$day': [
            {'subject': _subject(309311 + day)},
          ],
      };
    } else if (path == '/v0/search/subjects') {
      searchKeywords.add((options.data as Map)['keyword'] as String);
      response = {
        'data': [_subject(309311)],
      };
    } else {
      throw StateError('Unexpected request: ${options.uri}');
    }
    return ResponseBody.fromString(
      jsonEncode(response),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SearchHistoryRepository implements ISearchHistoryRepository {
  final entries = <SearchHistory>[];
  @override
  List<SearchHistory> getAllHistories() => List.of(entries);
  @override
  Future<bool> saveHistory(String keyword) async {
    entries.insert(0, SearchHistory(keyword, entries.length));
    return true;
  }

  @override
  Future<void> deleteHistory(SearchHistory history) async =>
      entries.remove(history);
  @override
  Future<void> clearAllHistories() async => entries.clear();
  @override
  Future<void> deleteDuplicates(String keyword) async =>
      entries.removeWhere((entry) => entry.keyword == keyword);
  @override
  bool isHistoryFull(int maxCount) => entries.length >= maxCount;
  @override
  Future<void> deleteOldest() async {
    if (entries.isNotEmpty) entries.removeLast();
  }
}
