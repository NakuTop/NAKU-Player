import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

const sourceA = CinemaSource(
  id: 'source-a',
  name: '备用源',
  kind: CinemaSourceKind.maccms,
  url: 'https://a.example/api',
);
const modu = CinemaSource(
  id: 'maccms-modu',
  name: '魔都影视',
  kind: CinemaSourceKind.maccms,
  url: 'https://b.example/api',
);
CinemaTitle sample(CinemaSource source, {String year = '2014'}) => CinemaTitle(
  id: source == modu ? 'm1' : 'a1',
  sourceId: source.id,
  title: '星际穿越',
  year: year,
  category: '科幻片',
  sourceDoubanScore: 9.4,
);

class RatingsStub extends CinemaRatingsRepository {
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
  }) => load(title);
}

class CatalogueStub extends CinemaRepository {
  final browsed = <String>[];
  final details = <String>[];
  Completer<CinemaTitle>? pendingA;
  bool delayA = false;
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
    ],
  );
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late CatalogueStub repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-group-ui-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [sourceA, modu],
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
          enableWatchTogether: false,
          store: store,
          repository: repository,
          ratingsRepository: RatingsStub(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, '星际穿越');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Finder card() => find.byKey(const ValueKey('title-card:maccms-modu::m1'));

  testWidgets(
    'Modu is the default even when it is not first in the source library',
    (tester) async {
      await mount(tester);
      expect(repository.browsed.toSet(), {modu.id});
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
      await tester.tap(card());
      await tester.pumpAndSettle();
      expect(find.text('魔都影视的详情'), findsOneWidget);
      final sheetScroll = find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('魔都影视专属线路'),
        200,
        scrollable: sheetScroll,
      );
      expect(find.text('魔都影视专属线路'), findsOneWidget);
      await tester.drag(sheetScroll, const Offset(0, 800));
      await tester.pumpAndSettle();
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
      expect(find.text('魔都影视专属线路'), findsNothing);
      expect(repository.details, [modu.id, sourceA.id]);
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
    await tester.tap(find.byKey(const ValueKey('source-variant:source-a::a1')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('source-variant:maccms-modu::m1')),
    );
    await tester.pumpAndSettle();
    repository.pendingA!.complete(
      repository.resolved(sourceA, sample(sourceA)),
    );
    await tester.pumpAndSettle();
    expect(find.text('魔都影视的详情'), findsOneWidget);
    expect(find.text('备用源的详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
