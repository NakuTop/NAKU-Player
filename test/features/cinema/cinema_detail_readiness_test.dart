import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// flutter_cache_manager owns this plugin; register its native bridge in tests.
// ignore: depend_on_referenced_packages
import 'package:sqflite/sqflite.dart'
    show databaseFactory, databaseFactorySqflitePlugin;
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_neon_decode.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

const _sources = [
  CinemaSource(
    id: 'ready-a',
    name: '片源甲',
    kind: CinemaSourceKind.maccms,
    url: 'https://a.invalid/api',
  ),
  CinemaSource(
    id: 'ready-b',
    name: '片源乙',
    kind: CinemaSourceKind.maccms,
    url: 'https://b.invalid/api',
  ),
];

class _Poster extends ImageStreamCompleter {
  final listeners = <ImageStreamListener>{};
  @override
  void addListener(ImageStreamListener listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }

  void complete(ui.Image frame) => setImage(ImageInfo(image: frame.clone()));
  void fail() =>
      reportError(exception: StateError('poster fixture failed'), silent: true);
}

class _Repository extends CinemaRepository {
  bool posters = true;
  CinemaTitle title(CinemaSource source) => CinemaTitle(
    id: 'film',
    sourceId: source.id,
    title: '就绪影片',
    category: '电影',
    year: '2026',
  );
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '1', name: '电影'),
  ];
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async => const CinemaPage(items: []);
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) => browse(source);
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async => CinemaPage(items: [title(source)]);
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async =>
      CinemaTitle(
        id: title.id,
        sourceId: source.id,
        title: title.title,
        category: title.category,
        year: title.year,
        poster: posters ? 'https://posters.invalid/${source.id}.png' : '',
        routes: [
          CinemaRoute(
            name: '正片线路',
            episodes: [
              CinemaEpisode(
                name: '正片',
                url: 'https://${source.id}.invalid/video.mp4',
              ),
            ],
          ),
        ],
      );
}

class _Ratings extends CinemaRatingsRepository {
  final changeNotifier = ChangeNotifier();
  @override
  ChangeNotifier get changes => changeNotifier;
  final cached = <String, CinemaRatings>{};
  @override
  CinemaRatings? peek(CinemaTitle title) => cached[title.sourceId];
  final full = <String, Completer<CinemaRatings>>{};
  final metadata = <String, Completer<DoubanSubjectDetails>>{};
  final fetches = <String, int>{};
  CinemaRatings empty(CinemaTitle title) =>
      const CinemaRatings(identity: RatingIdentity(), ratings: [], message: '');
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async => empty(title);
  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async =>
      empty(title);
  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) =>
      full.putIfAbsent(title.sourceId, () {
        fetches.update(title.sourceId, (value) => value + 1, ifAbsent: () => 1);
        return Completer<CinemaRatings>();
      }).future;
  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) => metadata
      .putIfAbsent(title.sourceId, Completer<DoubanSubjectDetails>.new)
      .future;
  void complete(String source) {
    full[source]!.complete(
      const CinemaRatings(
        identity: RatingIdentity(),
        ratings: [],
        message: '暂无可用评分',
      ),
    );
    metadata[source]!.complete(
      const DoubanSubjectDetails(doubanId: '', note: '暂无官网资料'),
    );
  }
}

class _Artwork extends CinemaDetailArtworkRepository {
  Completer<CinemaDetailArtwork>? upgrade;
  @override
  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) async {
    if (identity.imdbId.isNotEmpty && upgrade != null) return upgrade!.future;
    return CinemaDetailArtwork(
      url: title.poster,
      width: 1600,
      height: 900,
      highResolution: title.poster.isNotEmpty,
    );
  }
}

class _Catalogue extends DoubanRepository {
  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async =>
      const DoubanResultPage(items: [], start: 0, nextStart: 0, hasMore: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cacheDirectory;
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _Ratings ratings;
  late _Artwork artwork;
  late Map<String, _Poster> posters;
  late ui.Image frame;

  setUpAll(() async {
    cacheDirectory = await Directory.systemTemp.createTemp('detail-cache-');
    databaseFactory = databaseFactorySqflitePlugin;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cacheDirectory.path,
    );
    // The image bytes are supplied by controlled streams. Only the cache's
    // startup/cleanup metadata bridge is needed while raster work is awaited.
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.tekartik.sqflite'),
      (call) async => switch (call.method) {
        'getDatabasesPath' => cacheDirectory.path,
        'openDatabase' => {'id': 1},
        'query' =>
          (call.arguments['sql'] as String).contains('user_version')
              ? [
                  {'user_version': 3},
                ]
              : <Map<String, Object>>[],
        'execute' || 'closeDatabase' || 'options' => null,
        _ => throw UnimplementedError('Unexpected cache call: ${call.method}'),
      },
    );
  });

  tearDownAll(() async {
    await ProxyAwareImageCacheManager.cinemaInstance.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.tekartik.sqflite'),
      null,
    );
    await cacheDirectory.delete(recursive: true);
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-detail-ready-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: _sources,
    );
    await store.load();
    repository = _Repository();
    ratings = _Ratings();
    artwork = _Artwork();
    posters = {};
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    frame.dispose();
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> frames(WidgetTester tester, [int count = 4]) async {
    for (var index = 0; index < count; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    ValueNotifier<Color>? windowColor,
  }) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    frame = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1600, 900),
        Paint()..color = Colors.blueGrey,
      );
      final picture = recorder.endRecording();
      final result = await picture.toImage(1600, 900);
      picture.dispose();
      return result;
    }))!;
    for (final source in _sources) {
      final provider = ResizeImage(
        CachedNetworkImageProvider(
          'https://posters.invalid/${source.id}.png',
          cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
        ),
        width: 3200,
        height: 2400,
        policy: ResizeImagePolicy.fit,
      );
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final completer = posters[source.id] = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(key, () => completer);
      final ambientKey = await ResizeImage.resizeIfNeeded(
        384,
        null,
        provider,
      ).obtainKey(ImageConfiguration.empty);
      PaintingBinding.instance.imageCache.putIfAbsent(
        ambientKey,
        () => completer,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        builder: windowColor == null
            ? null
            : (context, child) => RepaintBoundary(
                key: const ValueKey('detail-window-raster'),
                child: ValueListenableBuilder<Color>(
                  valueListenable: windowColor,
                  child: child,
                  builder: (context, color, child) =>
                      ColoredBox(color: color, child: child),
                ),
              ),
        home: CinemaHomePage(
          store: store,
          repository: repository,
          ratingsRepository: ratings,
          artworkRepository: artwork,
          catalogDiscovery: _Catalogue(),
          enableSearchDiscovery: false,
          enableWatchTogether: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '就绪影片');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('title-card:ready-a::film')));
    await frames(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  bool loading(WidgetTester tester) =>
      tester.widget<CinemaNeonDecode>(find.byType(CinemaNeonDecode)).loading;

  testWidgets('below HD artwork charcoal frost suppresses desktop clutter', (
    tester,
  ) async {
    final color = ValueNotifier(const Color(0xFFEA5030));
    addTearDown(color.dispose);
    await mount(tester, windowColor: color);
    ratings.complete('ready-a');
    posters['ready-a']!.complete(frame);
    await tester.pumpAndSettle();
    expect(loading(tester), isFalse);
    final bounds = tester.getRect(
      find.byKey(const ValueKey('cinema-detail-frost')),
    );
    final point = Offset(bounds.right - 24, bounds.bottom - 24);
    Future<List<int>> sample(String name) async {
      final image = await tester.runAsync(
        () => tester
            .renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('detail-window-raster')),
            )
            .toImage(pixelRatio: 1),
      );
      final pixels = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final index = (point.dy.floor() * image!.width + point.dx.floor()) * 4;
      final rgb = [for (var c = 0; c < 3; c++) pixels.getUint8(index + c)];
      const output = String.fromEnvironment('NAKU_DETAIL_RASTER');
      if (output.isNotEmpty) {
        await tester.runAsync(() async {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/$name.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      image.dispose();
      return rgb;
    }

    final warm = await sample('detail-warm');
    color.value = const Color(0xFF3060EA);
    await tester.pumpAndSettle();
    final cool = await sample('detail-cool');
    expect((warm[0] - cool[0]).abs(), lessThanOrEqualTo(10));
    expect((cool[2] - warm[2]).abs(), lessThanOrEqualTo(10));
    expect(warm.every((channel) => channel >= 20 && channel <= 45), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail waits for full ratings, metadata and the actual HD poster frame',
    (tester) async {
      await mount(tester);
      expect(loading(tester), isTrue);
      expect(posters['ready-a']!.listeners.length, greaterThanOrEqualTo(2));
      ratings.full['ready-a']!.complete(
        const CinemaRatings(
          identity: RatingIdentity(),
          ratings: [],
          message: '暂无评分',
        ),
      );
      await frames(tester);
      expect(loading(tester), isTrue);
      ratings.metadata['ready-a']!.complete(
        const DoubanSubjectDetails(doubanId: ''),
      );
      await frames(tester);
      expect(loading(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(loading(tester), isTrue);
      posters['ready-a']!.complete(frame);
      await frames(tester);
      expect(loading(tester), isFalse);
      expect(frame.width, 1600);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cinema-detail-tab-1')));
      await tester.pumpAndSettle();
      expect(loading(tester), isFalse);
      expect(ratings.fetches['ready-a'], 1);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('title-card:ready-a::film')));
      await frames(tester);
      expect(loading(tester), isFalse);
      expect(ratings.fetches['ready-a'], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late confirmed identity restarts the gate until the new HD frame is decoded',
    (tester) async {
      await mount(tester);
      ratings.complete('ready-a');
      posters['ready-a']!.complete(frame);
      await tester.pumpAndSettle();
      expect(loading(tester), isFalse);
      artwork.upgrade = Completer<CinemaDetailArtwork>();
      ratings.cached['ready-a'] = const CinemaRatings(
        identity: RatingIdentity(imdbId: 'tt0120338'),
        ratings: [],
        message: '',
      );
      ratings.changes.notifyListeners();
      await frames(tester);
      expect(loading(tester), isTrue);
      const url = 'https://posters.invalid/upgraded-hd.png';
      final provider = ResizeImage(
        CachedNetworkImageProvider(
          url,
          cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
        ),
        width: 3200,
        height: 2400,
        policy: ResizeImagePolicy.fit,
      );
      final hdStream = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(
        await provider.obtainKey(ImageConfiguration.empty),
        () => hdStream,
      );
      PaintingBinding.instance.imageCache.putIfAbsent(
        await ResizeImage.resizeIfNeeded(
          384,
          null,
          provider,
        ).obtainKey(ImageConfiguration.empty),
        () => hdStream,
      );
      artwork.upgrade!.complete(
        const CinemaDetailArtwork(
          url: url,
          width: 1920,
          height: 1080,
          highResolution: true,
        ),
      );
      await frames(tester);
      expect(
        loading(tester),
        isTrue,
        reason: 'A verified URL is not a decoded image frame.',
      );
      hdStream.complete(frame);
      await frames(tester);
      expect(loading(tester), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late ratings and poster callbacks from another source cannot release the gate',
    (tester) async {
      await mount(tester);
      final alternate = find.byKey(
        const ValueKey('source-variant:ready-b::film'),
      );
      await tester.ensureVisible(alternate);
      await tester.tap(alternate);
      await frames(tester);
      expect(loading(tester), isTrue);
      ratings.complete('ready-a');
      posters['ready-a']!.complete(frame);
      await frames(tester);
      expect(loading(tester), isTrue);
      ratings.complete('ready-b');
      await frames(tester);
      expect(loading(tester), isTrue);
      posters['ready-b']!.complete(frame);
      await frames(tester);
      expect(loading(tester), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rating and poster failures are terminal and retain visible failure information',
    (tester) async {
      await mount(tester);
      ratings.full['ready-a']!.completeError(
        StateError('fixture ratings failed'),
      );
      ratings.metadata['ready-a']!.completeError(
        StateError('fixture metadata failed'),
      );
      await frames(tester);
      expect(loading(tester), isTrue);
      posters['ready-a']!.fail();
      await frames(tester);
      expect(loading(tester), isFalse);
      expect(find.text('海报暂未加载'), findsOneWidget);
      expect(find.byKey(const ValueKey('ratings-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing cancels owned image listeners while shared pending work can finish safely',
    (tester) async {
      await mount(tester);
      final before = posters['ready-a']!.listeners.length;
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(CinemaNeonDecode), findsNothing);
      expect(posters['ready-a']!.listeners.length, lessThan(before));
      ratings.complete('ready-a');
      posters['ready-a']!.complete(frame);
      await frames(tester);
      expect(find.byType(CinemaNeonDecode), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
