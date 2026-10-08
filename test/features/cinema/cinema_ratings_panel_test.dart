import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_ratings_panel.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

const _title = CinemaTitle(
  id: 'movie-1',
  sourceId: 'fixture',
  title: '星际穿越',
  year: '2014',
);

CinemaRatings _ratings({bool missingTomatoes = false}) => CinemaRatings(
  identity: const RatingIdentity(
    doubanId: '1889243',
    imdbId: 'tt0816692',
    rottenTomatoesId: 'm/interstellar_2014',
    label: '星际穿越 · 2014',
    wikidataId: 'Q13417189',
  ),
  message: '仅关联到确切条目后读取外站评分；可手动校对关联。',
  ratings: [
    const CinemaRating(provider: '豆瓣', value: 9.1, note: '评分由片源提供，未直接查询豆瓣官网'),
    CinemaRating(
      provider: 'IMDb',
      value: 8.7,
      count: 2617420,
      note: 'IMDb 官方每日数据',
      verified: true,
      fetchedAt: DateTime(2026, 10, 8, 12, 30),
      url: 'https://www.imdb.com/title/tt0816692/',
    ),
    CinemaRating(
      provider: '烂番茄',
      value: missingTomatoes ? null : 89,
      scale: 100,
      count: missingTomatoes ? null : 147,
      note: missingTomatoes ? '网页暂不可用，评分保留为空' : '烂番茄网页',
      verified: !missingTomatoes,
    ),
  ],
);

class _FakeRepository extends CinemaRatingsRepository {
  CinemaRatings result = _ratings();
  final forces = <bool>[];
  final saved = <RatingIdentity>[];
  Future<CinemaRatings> Function(CinemaTitle, bool)? onLoad;
  Object? saveError;

  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async {
    forces.add(force);
    return onLoad == null ? result : await onLoad!(title, force);
  }

  @override
  Future<void> setIdentity(CinemaTitle title, RatingIdentity identity) async {
    if (saveError != null) throw saveError!;
    saved.add(identity);
    result = CinemaRatings(
      identity: identity,
      ratings: result.ratings,
      message: result.message,
    );
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _FakeRepository repository, {
    double width = 900,
    double textScale = 1,
    bool settle = true,
    CinemaTitle title = _title,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: CinemaRatingsPanel(
                title: title,
                sourceName: '测试片源',
                repository: repository,
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('keeps ten-point scores and critic percentage distinct', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await mount(tester, repository);
    expect(find.text('9.1'), findsOneWidget);
    expect(find.text('8.7'), findsOneWidget);
    expect(find.text('89'), findsOneWidget);
    expect(find.text('/10'), findsNWidgets(2));
    expect(find.text('%'), findsOneWidget);
    expect(find.text('影评人 · Tomatometer'), findsOneWidget);
    expect(find.text('片源转述 · 未核验'), findsOneWidget);
    expect(find.text('来自 测试片源'), findsOneWidget);
    expect(find.text('2,617,420 人评价'), findsOneWidget);
    expect(find.text('147 条影评'), findsOneWidget);
    expect(find.text('更新 2026-10-08 12:30'), findsOneWidget);
    expect(find.text('查看来源'), findsOneWidget);
    expect(repository.forces, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps missing score empty and explains the cause', (
    tester,
  ) async {
    final repository = _FakeRepository()
      ..result = _ratings(missingTomatoes: true);
    await mount(tester, repository);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('网页暂不可用，评分保留为空'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('0.0'), findsNothing);
    await tester.tap(find.text('关联与说明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅关联到确切条目'), findsOneWidget);
    expect(find.textContaining('Wikidata：Q13417189'), findsOneWidget);
  });

  testWidgets('narrow view and larger text wrap without overflow', (
    tester,
  ) async {
    await mount(tester, _FakeRepository(), width: 320, textScale: 1.3);
    expect(tester.takeException(), isNull);
    final douban = tester.getRect(find.byKey(const ValueKey('rating-card-豆瓣')));
    final imdb = tester.getRect(find.byKey(const ValueKey('rating-card-IMDb')));
    expect(imdb.top, greaterThan(douban.bottom));
    await tester.ensureVisible(find.text('关联条目'));
    await tester.tap(find.text('关联条目'));
    await tester.pumpAndSettle();
    expect(find.text('关联评分条目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'validates edits before saving and forces reload after confirmation',
    (tester) async {
      final repository = _FakeRepository();
      await mount(tester, repository);
      await tester.tap(find.text('关联条目'));
      await tester.pumpAndSettle();
      expect(find.text('星际穿越 · 2014'), findsNWidgets(2));
      await tester.enterText(
        find.byKey(const ValueKey('rating-douban-id')),
        'invalid',
      );
      await tester.tap(find.text('确认并保存'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('rating-identity-error')),
        findsOneWidget,
      );
      expect(repository.saved, isEmpty);
      expect(repository.forces, [false]);
      await tester.enterText(
        find.byKey(const ValueKey('rating-douban-id')),
        ' 1292052 ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('rating-imdb-id')),
        'tt0111161',
      );
      await tester.enterText(
        find.byKey(const ValueKey('rating-rotten-tomatoes-id')),
        'm/shawshank_redemption',
      );
      await tester.tap(find.text('确认并保存'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.saved.single.doubanId, '1292052');
      expect(repository.saved.single.imdbId, 'tt0111161');
      expect(
        repository.saved.single.rottenTomatoesId,
        'm/shawshank_redemption',
      );
      expect(repository.saved.single.confirmed, isTrue);
      expect(repository.saved.single.wikidataId, isEmpty);
      expect(repository.forces, [false, true]);
    },
  );

  testWidgets('clearing fields is only persisted after active confirmation', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await mount(tester, repository);
    await tester.tap(find.text('关联条目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空字段'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.saved, isEmpty);
    await tester.tap(find.text('关联条目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空字段'));
    await tester.tap(find.text('确认并保存'));
    await tester.pumpAndSettle();
    final identity = repository.saved.single;
    expect(identity.doubanId, isEmpty);
    expect(identity.imdbId, isEmpty);
    expect(identity.rottenTomatoesId, isEmpty);
    expect(identity.confirmed, isTrue);
    expect(repository.forces, [false, true]);
  });

  testWidgets('refresh bypasses cache and handles a readable request failure', (
    tester,
  ) async {
    final repository = _FakeRepository();
    await mount(tester, repository);
    repository.onLoad = (_, _) => throw const FormatException('服务暂不可用');
    await tester.tap(find.text('刷新评分'));
    await tester.pumpAndSettle();
    expect(repository.forces, [false, true]);
    expect(find.text('评分暂未加载：服务暂不可用'), findsOneWidget);
    expect(find.text('8.7'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '刷新评分'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'loading explains first dataset download and ignores stale title response',
    (tester) async {
      final pending = Completer<CinemaRatings>();
      final repository = _FakeRepository()..onLoad = (_, _) => pending.future;
      await mount(tester, repository, settle: false);
      expect(find.textContaining('约 9 MB'), findsOneWidget);
      repository.onLoad = (_, _) async => const CinemaRatings(
        identity: RatingIdentity(label: '另一作品'),
        ratings: [],
        message: '尚未关联',
      );
      await mount(
        tester,
        repository,
        title: const CinemaTitle(
          id: 'movie-2',
          sourceId: 'fixture',
          title: '另一作品',
        ),
      );
      pending.complete(_ratings());
      await tester.pumpAndSettle();
      expect(find.text('另一作品'), findsOneWidget);
      expect(find.text('8.7'), findsNothing);
      expect(find.text('—'), findsNWidgets(3));
    },
  );

  testWidgets(
    'save failure keeps prior scores and displays a retryable error',
    (tester) async {
      final repository = _FakeRepository()
        ..saveError = const FormatException('本地文件只读');
      await mount(tester, repository);
      await tester.tap(find.text('关联条目'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认并保存'));
      await tester.pumpAndSettle();
      expect(find.text('评分关联未保存：本地文件只读'), findsOneWidget);
      expect(find.text('8.7'), findsOneWidget);
      expect(find.text('关联条目'), findsOneWidget);
      expect(repository.forces, [false]);
    },
  );
}
