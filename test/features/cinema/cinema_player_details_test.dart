import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_details_view.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews_view.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_ratings_panel.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';

const _source = CinemaSource(
  id: 'player-fixture',
  name: '原始片源',
  kind: CinemaSourceKind.maccms,
  url: 'https://player.invalid/api',
);
const _otherSource = CinemaSource(
  id: 'other-player-fixture',
  name: '备用片源',
  kind: CinemaSourceKind.maccms,
  url: 'https://other-player.invalid/api',
);
const _title = CinemaTitle(
  id: '1',
  sourceId: 'player-fixture',
  title: '测试电影',
  year: '2020',
  category: '剧情片',
  doubanId: '1889243',
  description: '播放器下方保留本片简介。',
);
const _variant = CinemaTitle(
  id: '2',
  sourceId: 'other-player-fixture',
  title: '测试电影',
  year: '2020',
  category: '剧情片',
  routes: [CinemaRoute(name: '备用线路', episodes: [])],
);
const _recommendation = DoubanRecommendation(
  doubanId: '1292052',
  title: '推荐电影',
);
const _details = DoubanSubjectDetails(
  doubanId: '1889243',
  title: '测试电影',
  year: '2020',
  originalTitle: 'Fixture Film',
  releaseDates: ['2020-01-02（中国大陆）'],
  durations: ['95分钟'],
  aliases: ['另一译名'],
  score: 8.6,
  ratingCount: 3200,
  stars: [
    DoubanStarShare(stars: 5, share: .5),
    DoubanStarShare(stars: 4, share: .3),
  ],
  recommendations: [_recommendation],
);
const _ratings = CinemaRatings(
  message: 'isolated player fixture',
  identity: RatingIdentity(
    doubanId: '1889243',
    imdbId: 'tt0816692',
    rottenTomatoesId: 'm/fixture',
  ),
  ratings: [
    CinemaRating(provider: '豆瓣', value: 8.6, verified: true, note: 'fixture'),
    CinemaRating(provider: 'IMDb', value: 8.2, verified: true, note: 'fixture'),
    CinemaRating(
      provider: '烂番茄',
      value: 91,
      scale: 100,
      verified: true,
      note: 'fixture',
    ),
  ],
);

class _Ratings extends CinemaRatingsRepository {
  final loaded = <CinemaTitle>[];
  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async {
    loaded.add(title);
    return _ratings;
  }

  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async => _ratings;
  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async => _details;
}

class _Reviews extends CinemaDoubanReviewsRepository {
  final subjects = <String>[];
  @override
  Future<CinemaDoubanReviews> load(
    String subjectId, {
    bool force = false,
  }) async {
    subjects.add(subjectId);
    return CinemaDoubanReviews(
      subjectId: subjectId,
      items: const [
        CinemaDoubanReview(
          id: '12345',
          title: '播放器影评示例',
          author: '测试作者',
          excerpt: '这段资料也属于影片详情。',
          url: 'https://movie.douban.com/review/12345/',
        ),
      ],
    );
  }
}

class _Repository extends CinemaRepository {
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) => throw StateError(
    'No source search should run in this isolated player fixture',
  );
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) =>
      throw StateError(
        'No media detail should run in this isolated player fixture',
      );
}

class _Together extends CinemaWatchTogether {
  _Together(File file)
    : super(
        pairingFile: file,
        clientFactory: (_, _) =>
            throw StateError('No sync server should connect'),
      );
  Completer<void>? detachGate;
  bool detachStarted = false, detached = false;
  @override
  Future<void> detachPlayback(Object owner) async {
    detachStarted = true;
    await detachGate?.future;
    await super.detachPlayback(owner);
    detached = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late CinemaStore store;
  late _Together together;
  late _Ratings ratings;
  late _Reviews reviews;
  var fullScreen = false;
  final nativeCalls = <String>[];

  Future<void> windowEvent(String name) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onEvent', {'eventName': name}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-player-details-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source, _otherSource],
    );
    together = _Together(File('${directory.path}/pairing.json'));
    await store.load();
    await together.initialize();
    ratings = _Ratings();
    reviews = _Reviews();
    fullScreen = false;
    nativeCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      switch (call.method) {
        case 'isFullScreen':
          return fullScreen;
        case 'getBounds':
          return {'x': 80.0, 'y': 50.0, 'width': 1280.0, 'height': 860.0};
        case 'isAlwaysOnTop':
          return false;
        case 'setFullScreen':
          fullScreen = (call.arguments as Map)['isFullScreen'] as bool;
          await windowEvent(
            fullScreen ? 'enter-full-screen' : 'leave-full-screen',
          );
          return null;
        default:
          return null;
      }
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    together.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  CinemaPlayerPage player({
    ValueChanged<DoubanRecommendation>? onRecommendationSelected,
  }) => CinemaPlayerPage(
    title: _title,
    source: _source,
    store: store,
    variants: [_variant],
    repository: _Repository(),
    watchTogether: together,
    ratingsRepository: ratings,
    reviewsRepository: reviews,
    onRecommendationSelected: onRecommendationSelected,
  );

  Future<void> mount(
    WidgetTester tester, {
    double width = 1280,
    bool withRoute = false,
    ValueChanged<DoubanRecommendation>? onRecommendationSelected,
  }) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: withRoute ? const Scaffold(body: Text('测试片库')) : player(),
      ),
    );
    if (withRoute) {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                player(onRecommendationSelected: onRecommendationSelected),
          ),
        ),
      );
    }
    await tester.pumpAndSettle();
  }

  for (final width in [1280.0, 430.0, 360.0]) {
    testWidgets(
      'normal player at width $width shows the shared details component below video',
      (tester) async {
        await mount(tester, width: width);
        final panel = tester.widget<CinemaRatingsPanel>(
          find.byType(CinemaRatingsPanel),
        );
        expect(identical(panel.title, _title), isTrue);
        expect(identical(panel.repository, ratings), isTrue);
        expect(identical(panel.reviewsRepository, reviews), isTrue);
        expect(panel.sourceName, _source.name);
        expect(find.byType(DoubanDetailsView), findsOneWidget);
        expect(find.byType(CinemaDoubanReviewsView), findsOneWidget);
        expect(
          tester.getTopLeft(find.byType(CinemaRatingsPanel)).dy,
          greaterThan(tester.getBottomLeft(find.byType(AspectRatio).first).dy),
        );
        await tester.ensureVisible(find.text('影片资料'));
        await tester.pumpAndSettle();
        expect(find.text('影片资料').hitTestable(), findsOneWidget);
        expect(find.text('95分钟'), findsOneWidget);
        expect(find.text('另一译名'), findsOneWidget);
        expect(find.text('豆瓣星级分布'), findsOneWidget);
        await tester.ensureVisible(find.text('播放器影评示例'));
        await tester.pumpAndSettle();
        expect(find.text('播放器影评示例').hitTestable(), findsOneWidget);
        expect(ratings.loaded, [_title]);
        expect(reviews.subjects, ['1889243']);
        expect(
          store.history,
          isEmpty,
          reason: 'No-route smoke must not start media or record progress.',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'changing to an ID-less source keeps the original work details anchor',
    (tester) async {
      await mount(tester);
      final originalState = tester.state(find.byType(CinemaRatingsPanel));
      await tester.tap(
        find.byKey(ValueKey('playback-route:${_variant.key}:0')),
      );
      await tester.pumpAndSettle();
      final panel = tester.widget<CinemaRatingsPanel>(
        find.byType(CinemaRatingsPanel),
      );
      expect(identical(panel.title, _title), isTrue);
      expect(
        identical(tester.state(find.byType(CinemaRatingsPanel)), originalState),
        isTrue,
      );
      expect(ratings.loaded, [_title]);
      expect(find.text('备用片源  /  暂无集数'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'native fullscreen event hides details and restoring reveals them',
    (tester) async {
      await mount(tester);
      fullScreen = true;
      await windowEvent('enter-full-screen');
      await tester.pumpAndSettle();
      expect(find.byType(CinemaRatingsPanel), findsNothing);
      expect(find.text('影片资料'), findsNothing);
      expect(find.byTooltip('返回片库'), findsNothing);
      fullScreen = false;
      await windowEvent('leave-full-screen');
      await tester.pumpAndSettle();
      expect(find.byType(CinemaRatingsPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'picture-in-picture uses video-only content and restores details on exit',
    (tester) async {
      await mount(tester);
      final enter = find.widgetWithText(OutlinedButton, '画中画');
      await tester.ensureVisible(enter);
      await tester.tap(enter);
      await tester.pumpAndSettle();
      expect(find.byType(CinemaRatingsPanel), findsNothing);
      expect(find.text('影片资料'), findsNothing);
      expect(find.byTooltip('退出画中画'), findsOneWidget);
      expect(
        nativeCalls,
        containsAll([
          'getBounds',
          'setAlwaysOnTop',
          'setAspectRatio',
          'setBounds',
        ]),
      );
      await tester.tap(find.byTooltip('退出画中画'));
      await tester.pumpAndSettle();
      expect(find.byType(CinemaRatingsPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'recommendation waits for playback ownership cleanup before returning to catalogue',
    (tester) async {
      final selected = <DoubanRecommendation>[];
      together.detachGate = Completer<void>();
      await mount(
        tester,
        withRoute: true,
        onRecommendationSelected: (recommendation) {
          expect(together.detached, isTrue);
          selected.add(recommendation);
        },
      );
      final recommendation = find.byKey(const ValueKey('douban-rec-1292052'));
      await tester.ensureVisible(recommendation);
      await tester.tap(recommendation);
      await tester.pump();
      expect(together.detachStarted, isTrue);
      expect(selected, isEmpty);
      expect(find.byType(CinemaPlayerPage), findsOneWidget);
      together.detachGate!.complete();
      // The temporary store's initial flush future belongs to setUp's real-I/O
      // zone. Allow the player cleanup continuation to cross back into the UI.
      for (var i = 0; i < 40 && selected.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(selected, [_recommendation]);
      expect(find.byType(CinemaPlayerPage), findsNothing);
      expect(find.text('测试片库'), findsOneWidget);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
