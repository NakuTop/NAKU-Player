import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_featured_wall.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_nas_page.dart';
import 'package:kazumi/features/cinema/cinema_navigation_preferences.dart';
import 'package:kazumi/features/cinema/cinema_neon_decode.dart';
import 'package:kazumi/features/cinema/cinema_pane_transition.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_resource_badge.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_tv_application.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/services/platform/naku_device.dart';

const _source = CinemaSource(
  id: 'tv-fixture',
  name: '电视测试目录',
  kind: CinemaSourceKind.maccms,
  url: 'https://tv-fixture.invalid/api',
);
const _movie = CinemaTitle(
  id: 'movie',
  sourceId: 'tv-fixture',
  title: '电影测试作品',
  category: '剧情片',
  year: '2026',
  routes: [
    CinemaRoute(
      name: '测试片源',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://media.invalid/movie.mp4'),
      ],
    ),
  ],
);
const _series = CinemaTitle(
  id: 'series',
  sourceId: 'tv-fixture',
  title: '剧集测试作品',
  category: '欧美剧',
  year: '2026',
  routes: [
    CinemaRoute(
      name: '测试片源',
      episodes: [
        CinemaEpisode(
          name: '第 1 集',
          url: 'https://media.invalid/episode-1.mp4',
        ),
        CinemaEpisode(
          name: '第 2 集',
          url: 'https://media.invalid/episode-2.mp4',
        ),
      ],
    ),
  ],
);

class _Repository extends CinemaRepository {
  final searches = <String>[];
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: 'movie', name: '剧情片'),
    CinemaCategory(id: 'series', name: '欧美剧'),
  ];
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async => CinemaPage(items: [categoryId == 'series' ? _series : _movie]);
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) => browse(source, categoryId: categoryId, page: page);
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searches.add(keyword);
    return CinemaPage(items: [keyword.contains('剧') ? _series : _movie]);
  }

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async =>
      title.category.contains('剧') ? _series : _movie;
}

class _Discovery extends DoubanRepository {
  final kinds = <DoubanKind>[];
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
    kinds.add(kind);
    return DoubanResultPage(
      items: [
        DoubanTitle(
          id: kind == DoubanKind.movie ? '100001' : '100002',
          title: kind == DoubanKind.movie ? _movie.title : _series.title,
          kind: kind,
          year: '2026',
        ),
      ],
      start: 0,
      nextStart: 1,
      hasMore: false,
    );
  }
}

class _Ratings extends CinemaRatingsRepository {
  final notifier = ChangeNotifier();
  @override
  Listenable get changes => notifier;
  @override
  CinemaRatings peek(CinemaTitle title) => const CinemaRatings(
    identity: RatingIdentity(),
    ratings: [],
    message: '测试评分',
  );
  @override
  Future<void> restore() async {}
  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async =>
      peek(title);
  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async =>
      peek(title);
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async => peek(title);
  @override
  Future<CinemaRatings> loadForProvider(
    CinemaTitle title,
    String provider, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async => peek(title);
  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async => const DoubanSubjectDetails(doubanId: '', note: '测试资料');
}

class _Artwork extends CinemaDetailArtworkRepository {
  @override
  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) async => const CinemaDetailArtwork(url: '');
  @override
  Future<CinemaDetailArtwork> resolveLandscape(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) async => const CinemaDetailArtwork(url: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const capture = String.fromEnvironment('NAKU_TV_UI_OUTPUT');
    if (capture.isEmpty) return;
    final font = await rootBundle.load('assets/fonts/MiSans-Regular.ttf');
    for (final family in ['.AppleSystemUIFont', 'MI_Sans_Regular', 'Ahem']) {
      await (FontLoader(family)..addFont(Future.value(font))).load();
    }
    final icons = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
    await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _Discovery discovery;
  late _Ratings ratings;
  late CinemaNavigationPreferences navigation;
  setUp(() async {
    NakuDevice.isTV = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          CinemaNASClient.channel,
          (_) async => <String, dynamic>{},
        );
    directory = await Directory.systemTemp.createTemp('naku-tv-home-test-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [_source],
    );
    await store.load();
    await store.toggleFavorite(_movie);
    repository = _Repository();
    discovery = _Discovery();
    ratings = _Ratings();
    navigation = CinemaNavigationPreferences(
      readValue: () => true,
      writeValue: (_) async {},
    );
  });
  tearDown(() async {
    NakuDevice.isTV = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CinemaNASClient.channel, null);
    await store.flush();
    store.dispose();
    navigation.dispose();
    ratings.notifier.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: RepaintBoundary(
          key: const ValueKey('home-tv-capture'),
          child: MediaQuery(
            data: MediaQueryData(size: size, disableAnimations: true),
            child: CinemaTVApplication(
              now: () => Duration.zero,
              screensaverBuilder: (_) => const Scaffold(body: Text('屏保测试页')),
              home: CinemaHomePage(
                store: store,
                repository: repository,
                catalogDiscovery: discovery,
                ratingsRepository: ratings,
                artworkRepository: _Artwork(),
                navigationPreferences: navigation,
                enableWatchTogether: false,
                enableSearchDiscovery: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    'TV header keeps Mine then Screensaver and removes unrelated destinations',
    (tester) async {
      await mount(tester);
      for (final key in [
        'search',
        'home',
        'movies',
        'series',
        'nas',
        'mine',
        'screensaver',
      ]) {
        expect(find.byKey(ValueKey('tv-nav-$key')), findsOneWidget);
      }
      final mine = tester.getRect(find.byKey(const ValueKey('tv-nav-mine'))),
          saver = tester.getRect(
            find.byKey(const ValueKey('tv-nav-screensaver')),
          );
      expect(saver.left, greaterThanOrEqualTo(mine.right));
      expect(saver.center.dy, mine.center.dy);
      expect(find.text('动漫'), findsNothing);
      expect(find.text('设置'), findsNothing);
      expect(find.text('下载'), findsNothing);
      expect(find.text('一起看'), findsNothing);
      expect(find.byType(CinemaFeaturedWall), findsOneWidget);
      expect(find.byType(CinemaGlass), findsNothing);
      expect(find.byType(CinemaPaneTransition), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      for (var destination = 0; destination < 5; destination++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      expect(
        Focus.of(
          tester.element(find.byKey(const ValueKey('tv-nav-screensaver'))),
        ).hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('屏保测试页'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('屏保测试页'), findsNothing);
      expect(find.byKey(const ValueKey('tv-nav-screensaver')), findsOneWidget);
      await clean(tester);
    },
  );
  testWidgets('TV directional navigation enters movie and series catalogues', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(
      Focus.of(
        tester.element(find.byKey(const ValueKey('tv-nav-movies'))),
      ).hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.textContaining('电影测试作品'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(
      Focus.of(
        tester.element(find.byKey(const ValueKey('tv-nav-series'))),
      ).hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(discovery.kinds, contains(DoubanKind.tv));
    expect(find.textContaining('剧集测试作品'), findsWidgets);
    await clean(tester);
  });
  testWidgets(
    'TV search carries the query into NAS scope without querying online sources',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('tv-nav-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tv-search-field')),
        '电影测试',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.searches, contains('电影测试'));
      await tester.tap(find.widgetWithText(TextButton, 'NAS').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CinemaNASPage>(find.byType(CinemaNASPage)).initialKeyword,
        '电影测试',
      );
      final onlineCalls = repository.searches.length;
      await tester.enterText(
        find.byKey(const ValueKey('tv-search-field')),
        '我的NAS片名',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repository.searches.length, onlineCalls);
      expect(
        tester.widget<CinemaNASPage>(find.byType(CinemaNASPage)).initialKeyword,
        '我的NAS片名',
      );
      await clean(tester);
    },
  );
  testWidgets(
    'TV keeps artwork but removes decorative processing from home and detail',
    (tester) async {
      await mount(tester);
      expect(
        find.byKey(const ValueKey('tv-featured-original')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tv-nav-mine')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影测试作品').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-static-detail')), findsOneWidget);
      expect(find.byType(CinemaNeonDecode), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(const ValueKey('cinema-detail-tab-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('cinema-detail-primary-play')),
        findsOneWidget,
      );
      expect(find.byTooltip('关闭'), findsNothing);
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );
  for (final size in const [Size(960, 540), Size(1280, 720)]) {
    testWidgets(
      'TV large artwork and quiet catalogue at ${size.width} x ${size.height}',
      (tester) async {
        await mount(tester, size: size);
        final hero = tester.getRect(
          find.byKey(const ValueKey('tv-static-featured')),
        );
        expect(hero.height, closeTo(size.height * .76, 1));
        expect(hero.width, size.width);
        const capture = String.fromEnvironment('NAKU_TV_UI_OUTPUT');
        if (capture.isNotEmpty) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('home-tv-capture')),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '$capture/tv-home-fixture-${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.text('浏览剧集'), findsNothing);
        expect(find.text('观看后会在这里接着上次的进度。'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('tv-nav-movies')));
        await tester.pumpAndSettle();
        expect(find.byType(CinemaFilterBar), findsNothing);
        expect(find.byType(CinemaResourceBadge), findsNothing);
        expect(find.byTooltip('片源状态'), findsNothing);
        expect(find.byTooltip('刷新'), findsNothing);
        final cards = find.byWidgetPredicate(
          (widget) =>
              widget is InkWell &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('title-card:'),
        );
        expect(cards, findsWidgets);
        expect(tester.getRect(cards.first).width, greaterThan(260));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('tv-nav-mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('账号与连接'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('tv-software-update')),
          findsOneWidget,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        await clean(tester);
      },
    );
  }
  testWidgets('TV episode actions stay in a focused on-demand list', (
    tester,
  ) async {
    await tester.runAsync(() => store.toggleFavorite(_series));
    await mount(tester, size: const Size(960, 540));
    await tester.tap(find.byKey(const ValueKey('tv-nav-mine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集测试作品').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-static-detail')), findsOneWidget);
    expect(find.text('第 1 集'), findsNothing);
    expect(find.text('第 2 集'), findsNothing);
    expect(find.text('自动优选可播放版本'), findsNothing);
    final episodes = find.byKey(const ValueKey('tv-detail-episodes'));
    await tester.ensureVisible(episodes);
    await tester.tap(episodes);
    await tester.pumpAndSettle();
    expect(find.text('选择集数'), findsOneWidget);
    expect(find.text('第 1 集'), findsOneWidget);
    expect(find.text('第 2 集'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
    await clean(tester);
  });
}
