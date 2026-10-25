import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';

const sourceA = CinemaSource(
  id: 'source-a',
  name: '备用源',
  kind: CinemaSourceKind.maccms,
  url: 'https://a.example/api',
);
const modu = CinemaSource(
  id: 'maccms-feifan',
  name: '非凡影视',
  kind: CinemaSourceKind.maccms,
  url: 'https://b.example/api',
);
CinemaTitle sample(CinemaSource source, {String? year}) => CinemaTitle(
  id: source == modu ? 'm1' : 'a1',
  sourceId: source.id,
  title: '星际穿越',
  year: year ?? '${DateTime.now().year}',
  category: '科幻片',
  sourceDoubanScore: 9.4,
);

class RatingsStub extends CinemaRatingsRepository {
  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) => load(title);
  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async => const DoubanSubjectDetails(doubanId: '');
  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async =>
      const CinemaRatings(
        identity: RatingIdentity(),
        ratings: [],
        message: 'fixture',
      );
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) => load(title);
}

class CatalogueStub extends CinemaRepository {
  final browsed = <String>[];
  final details = <String>[];
  Completer<CinemaTitle>? pendingA;
  bool delayA = false;
  bool qualityRoutes = false;
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '1', name: '科幻片'),
  ];
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) => browse(source, categoryId: categoryId, page: page);

  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browsed.add(source.id);
    return CinemaPage(
      items: [sample(source)],
      categories: const [CinemaCategory(id: '1', name: '科幻片')],
    );
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async => CinemaPage(items: [sample(source)]);
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    details.add(source.id);
    if (source.id == sourceA.id && delayA) {
      return (pendingA = Completer<CinemaTitle>()).future;
    }
    return resolved(source, title);
  }

  CinemaTitle resolved(CinemaSource source, CinemaTitle title) => CinemaTitle(
    id: title.id,
    sourceId: source.id,
    title: title.title,
    year: title.year,
    category: title.category,
    description: '${source.name}的详情',
    routes: [
      CinemaRoute(
        name: '${source.name}专属线路',
        episodes: [
          CinemaEpisode(
            name: '${source.name}正片',
            url: 'https://${source.id}.example/movie.mp4',
          ),
        ],
      ),
      if (qualityRoutes)
        CinemaRoute(
          name: '${source.name}4K线路',
          episodes: [
            CinemaEpisode(
              name: '4K正片',
              url: 'https://${source.id}.example/movie-4k.mp4',
            ),
          ],
        ),
    ],
  );
}

class _Store extends CinemaStore {
  _Store({required super.file, required super.defaults});
  bool captureReorder = false;
  List<String>? requestedOrder;
  @override
  Future<void> reorderMovieSources(List<String> ids) async {
    if (captureReorder) {
      requestedOrder = List.of(ids);
    } else {
      await super.reorderMovieSources(ids);
    }
  }
}

void main() {
  late Directory directory;
  late _Store store;
  late CatalogueStub repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-group-ui-');
    store = _Store(
      file: File('${directory.path}/library.json'),
      defaults: [modu, sourceA],
    );
    await store.load();
    repository = CatalogueStub();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          enableSearchDiscovery: false,
          enableWatchTogether: false,
          store: store,
          repository: repository,
          ratingsRepository: RatingsStub(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-sort-latest')));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, '星际穿越');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Finder card() => find.byKey(const ValueKey('title-card:maccms-feifan::m1'));

  testWidgets(
    'native details keep ratings left and tab changes reuse source loading',
    (tester) async {
      await mount(tester);
      await search(tester);
      await tester.tap(card());
      await tester.pumpAndSettle();
      final left = find.byKey(const ValueKey('cinema-detail-left'));
      final information = find.byKey(
        const ValueKey('cinema-detail-information'),
      );
      expect(
        tester.getTopLeft(left).dx,
        lessThan(tester.getTopLeft(information).dx),
      );
      for (final provider in ['豆瓣', 'IMDb', '烂番茄']) {
        expect(
          find.descendant(
            of: left,
            matching: find.byKey(ValueKey('rating-card-$provider')),
          ),
          findsOneWidget,
        );
      }
      expect(find.text('非凡影视的详情'), findsOneWidget);
      final sourceRequests = List<String>.of(repository.details);
      await tester.tap(find.byKey(const ValueKey('cinema-detail-tab-1')));
      await tester.pumpAndSettle();
      expect(find.text('此片源暂未提供演职员资料'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cinema-detail-tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('非凡影视的详情'), findsOneWidget);
      expect(repository.details, sourceRequests);
      expect(
        find.byKey(const ValueKey('cinema-detail-primary-play')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'details prefer the labelled 4K route and retain a manual override',
    (tester) async {
      repository.qualityRoutes = true;
      await mount(tester);
      await search(tester);
      await tester.tap(card());
      await tester.pumpAndSettle();
      final best = find.widgetWithText(ChoiceChip, '非凡影视4K线路');
      final standard = find.widgetWithText(ChoiceChip, '非凡影视专属线路');
      expect(tester.widget<ChoiceChip>(best).selected, isTrue);
      expect(find.text('4K正片'), findsOneWidget);
      await tester.ensureVisible(standard);
      await tester.tap(standard);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(standard).selected, isTrue);
      expect(tester.widget<ChoiceChip>(best).selected, isFalse);
      expect(find.text('非凡影视正片'), findsOneWidget);
      expect(find.text('4K正片'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drag handle submits the chosen playback priority', (
    tester,
  ) async {
    store.captureReorder = true;
    await mount(tester);
    expect(CinemaSettingsHostBinding.instance.openSources(), isTrue);
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('source-order:maccms-feifan'));
    final handle = find.descendant(
      of: first,
      matching: find.byType(ReorderableDragStartListener),
    );
    expect(handle, findsOneWidget);
    final next = find.byKey(ValueKey('source-order:${sourceA.id}'));
    final origin = tester.getCenter(handle);
    final destination = Offset(origin.dx, tester.getBottomLeft(next).dy + 12);
    final gesture = await tester.startGesture(origin);
    await tester.pump(const Duration(milliseconds: 100));
    for (var step = 1; step <= 20; step++) {
      await gesture.moveTo(Offset.lerp(origin, destination, step / 20)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 350));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(store.requestedOrder, [sourceA.id, modu.id]);
    // Atomic persistence and restart ordering are covered with real files in
    // cinema_source_upgrade_test, outside the widget fake-async clock.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'all sources are browsed while Feifan remains the preferred representative',
    (tester) async {
      await mount(tester);
      expect(repository.browsed.toSet(), {sourceA.id, modu.id});
      expect(card(), findsOneWidget);
      expect(find.textContaining('9.4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same movie becomes one card and details switch source-specific routes',
    (tester) async {
      await mount(tester);
      await search(tester);
      expect(find.text('1 部作品 · 2 个片源版本，进入详情切换片源'), findsOneWidget);
      expect(card(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('title-card:source-a::a1')),
        findsNothing,
      );
      final cardProof = List<String>.of(repository.details);
      expect(cardProof, [
        modu.id,
      ], reason: 'The catalogue badge hydrated this exact source entry once.');
      await tester.tap(card());
      await tester.pumpAndSettle();
      expect(find.text('非凡影视的详情'), findsOneWidget);
      final sheetScroll = find
          .descendant(
            of: find.byKey(const ValueKey('cinema-title-detail-layout')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('非凡影视专属线路'),
        200,
        scrollable: sheetScroll,
      );
      expect(find.text('非凡影视专属线路'), findsOneWidget);
      await tester.drag(sheetScroll, const Offset(0, 800));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('source-variant:source-a::a1')),
      );
      await tester.tap(
        find.byKey(const ValueKey('source-variant:source-a::a1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('备用源的详情'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('备用源专属线路'),
        200,
        scrollable: sheetScroll,
      );
      expect(find.text('备用源专属线路'), findsOneWidget);
      expect(find.text('非凡影视专属线路'), findsNothing);
      expect(
        repository.details.skip(cardProof.length),
        [modu.id, sourceA.id],
        reason:
            'Opening details and switching source each load their own route.',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late source response cannot overwrite a newer selection', (
    tester,
  ) async {
    await mount(tester);
    await search(tester);
    await tester.tap(card());
    await tester.pumpAndSettle();
    repository.delayA = true;
    await tester.ensureVisible(
      find.byKey(const ValueKey('source-variant:source-a::a1')),
    );
    await tester.tap(find.byKey(const ValueKey('source-variant:source-a::a1')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey('source-variant:maccms-feifan::m1')),
    );
    await tester.tap(
      find.byKey(const ValueKey('source-variant:maccms-feifan::m1')),
    );
    await tester.pumpAndSettle();
    repository.pendingA!.complete(
      repository.resolved(sourceA, sample(sourceA)),
    );
    await tester.pumpAndSettle();
    expect(find.text('非凡影视的详情'), findsOneWidget);
    expect(find.text('备用源的详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
