import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/anime/cinema_anime_page.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';
import 'package:kazumi/features/cinema/cinema_startup_preferences.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_page.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_themes.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_page.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_page.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
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

const _source = CinemaSource(
  id: 'fixture',
  name: '启动测试片源',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.com/api',
);

void main() {
  late Directory directory;
  late PathProviderPlatform oldPaths;
  late CinemaStore store;
  late _Catalogue repository;
  late _Douban douban;
  late DoubanThemeCatalog themes;
  var sequence = 0;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('naku-home-startup-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'direct');
  });
  setUp(() async {
    repository = _Catalogue();
    douban = _Douban();
    themes = DoubanThemeCatalog();
    store = CinemaStore(
      file: File('${directory.path}/library-${sequence++}.json'),
      defaults: const [_source],
    );
    await store.load();
    DioFactory.reset();
    DioFactory.bangumiDio.httpClientAdapter.close();
    DioFactory.bangumiDio.httpClientAdapter = _BangumiAdapter();
  });
  tearDown(() async {
    DioFactory.reset();
    await store.flush();
    store.dispose();
    themes.dispose();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, String startup) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final target = CinemaStartupTarget.fromStored(startup);
    final module = createModule(
      register: (c) {
        c
          ..addSingleton<ICollectRepository>(CollectRepository.new)
          ..addSingleton<ICollectCrudRepository>(CollectCrudRepository.new)
          ..addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new)
          ..addSingleton<CollectController>(CollectController.new)
          ..addInstance<MyController>(_MyController())
          ..route(
            '/cinema',
            provide: provideCinemaAnimeControllers,
            child: (_, state) => CinemaHomePage(
              initialStartup: CinemaStartupTarget.fromStored(
                state.uri.toString(),
              ),
              store: store,
              repository: repository,
              catalogDiscovery: douban,
              doubanThemeCatalog: themes,
              enableWatchTogether: false,
              enableSearchDiscovery: false,
            ),
          );
      },
    );
    await tester.pumpWidget(
      ModularApp(
        module: module,
        initialRoute: target.location,
        navigatorObservers: [rootRouteObserver],
        defaultTransition: TransitionType.none,
        child: Builder(
          builder: (context) => MaterialApp.router(
            routerConfig: ModularApp.routerConfigOf(context),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  bool selected(WidgetTester tester, String label) => tester
      .widget<ListTile>(find.widgetWithText(ListTile, label).first)
      .selected;

  testWidgets('settings startup reaches the real pane without loading movies', (
    tester,
  ) async {
    await mount(tester, '/cinema?section=settings');
    expect(find.byType(CinemaSettingsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-sources')), findsOneWidget);
    expect(selected(tester, '设置'), isTrue);
    expect(repository.categoriesRead, 0);
    expect(repository.browsed, isEmpty);
    await tester.tap(find.widgetWithText(ListTile, '剧集').first);
    await tester.pumpAndSettle();
    expect(selected(tester, '剧集'), isTrue);
    final context = tester.element(find.byType(CinemaHomePage));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covered page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('covered page'))).pop();
    await tester.pumpAndSettle();
    expect(selected(tester, '剧集'), isTrue);
    expect(find.byType(CinemaSettingsPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('series startup only requests series categories', (tester) async {
    await mount(tester, '/cinema?section=series');
    expect(selected(tester, '剧集'), isTrue);
    expect(repository.browsed, ['22']);
    expect(repository.browsed, isNot(contains('11')));
    await tester.tap(find.widgetWithText(ListTile, '电影').first);
    await tester.pumpAndSettle();
    expect(repository.browsed, ['22', '11']);
    await tester.tap(find.widgetWithText(ListTile, '剧集').first);
    await tester.pumpAndSettle();
    expect(repository.browsed, ['22', '11']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final entry in {
    '/tab/popular/': (0, PopularPage),
    '/tab/timeline/': (1, TimelinePage),
    '/tab/collect/': (3, CollectPage),
    '/tab/my/': (4, MyPage),
  }.entries) {
    testWidgets('${entry.key} opens its real anime page in the NAKU shell', (
      tester,
    ) async {
      await mount(tester, entry.key);
      expect(selected(tester, '动漫'), isTrue);
      expect(find.byType(entry.value.$2), findsOneWidget);
      final host = tester.widget<CinemaAnimePage>(find.byType(CinemaAnimePage));
      expect(host.initialTab, entry.value.$1);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(ValueKey('anime-tab-${entry.value.$1}')),
            )
            .selected,
        isTrue,
      );
      expect(repository.browsed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('anime-tab-2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '赛博朋克');
      await tester.tap(find.widgetWithText(ListTile, '电影').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '动漫').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('anime-tab-2')))
            .selected,
        isTrue,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '赛博朋克',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Douban startup opens once and does not reopen after returning', (
    tester,
  ) async {
    await mount(tester, '/cinema?section=douban');
    expect(find.byType(DoubanPage), findsOneWidget);
    expect(douban.browses, 1);
    Navigator.of(tester.element(find.byType(DoubanPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DoubanPage), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '设置').first);
    await tester.pumpAndSettle();
    expect(find.byType(CinemaSettingsPage), findsOneWidget);
    expect(find.byType(DoubanPage), findsNothing);
    expect(douban.browses, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final entry in {'favorites': '我的收藏', 'history': '继续观看'}.entries) {
    testWidgets('${entry.key} startup avoids movie catalogue work', (
      tester,
    ) async {
      await mount(tester, '/cinema?section=${entry.key}');
      expect(selected(tester, entry.value), isTrue);
      expect(repository.categoriesRead, 0);
      expect(repository.browsed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _Catalogue extends CinemaRepository {
  int categoriesRead = 0;
  final browsed = <String?>[];
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async {
    categoriesRead++;
    return const [
      CinemaCategory(id: '11', name: '剧情片'),
      CinemaCategory(id: '22', name: '欧美剧'),
    ];
  }

  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browsed.add(categoryId);
    return const CinemaPage(items: []);
  }
}

class _Douban extends DoubanRepository {
  int browses = 0;
  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async {
    browses++;
    return const DoubanResultPage(
      items: [],
      start: 0,
      nextStart: 0,
      hasMore: false,
    );
  }

  @override
  Future<List<DoubanTagGroup>> tagGroups({
    required DoubanKind kind,
    DoubanFilters filters = const DoubanFilters(),
    CancelToken? cancelToken,
  }) async => [];

  @override
  Future<List<String>> discoverThemes({
    required DoubanKind kind,
    String? seed,
    CancelToken? cancelToken,
  }) async => [];
}

class _BangumiAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final response = options.uri.path == '/p1/calendar'
        ? {for (var day = 1; day <= 7; day++) '$day': []}
        : {'data': []};
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

class _MyController extends MyController {
  _MyController() : super(_History(), _Downloads(), _Shield());
  @override
  void attach() {}
  @override
  void detach() {}
}

class _History extends Fake implements IHistoryRepository {}

class _Downloads extends Fake implements IDownloadRepository {}

class _Shield extends Fake implements IDanmakuShieldRepository {}

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
