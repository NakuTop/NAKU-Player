import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews_view.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

CinemaDoubanReview _review(
  String id, {
  bool spoiler = false,
  String? excerpt,
  double? rating = 4,
}) => CinemaDoubanReview(
  id: id,
  title: '影评标题 $id',
  author: '作者 $id',
  excerpt: excerpt ?? '影评摘要 $id',
  url: 'https://movie.douban.com/review/$id/',
  rating: rating,
  spoiler: spoiler,
);
CinemaDoubanReviews _data(String id, {List<CinemaDoubanReview>? items}) =>
    CinemaDoubanReviews(subjectId: id, items: items ?? [_review('123456')]);

class _Repository extends CinemaDoubanReviewsRepository {
  final calls = <(String, bool)>[];
  Future<CinemaDoubanReviews> Function(String, bool)? onLoad;
  @override
  Future<CinemaDoubanReviews> load(String id, {bool force = false}) async {
    calls.add((id, force));
    return onLoad == null ? _data(id) : await onLoad!(id, force);
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _Repository repository, {
    String id = '1889243',
    double width = 620,
    double textScale = 1,
    bool settle = true,
    Future<void> Function(Uri)? onOpenUrl,
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
              padding: const EdgeInsets.all(12),
              child: CinemaDoubanReviewsView(
                subjectId: id,
                repository: repository,
                onOpenUrl: onOpenUrl,
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets(
    'independent loading resolves into at most six five-star reviews and source links',
    (tester) async {
      final pending = Completer<CinemaDoubanReviews>();
      final repository = _Repository()..onLoad = (_, _) => pending.future;
      final links = <Uri>[];
      await mount(
        tester,
        repository,
        settle: false,
        onOpenUrl: (uri) async => links.add(uri),
      );
      expect(
        find.byKey(const ValueKey('douban-reviews-progress')),
        findsOneWidget,
      );
      expect(find.text('正在读取影评…'), findsOneWidget);
      pending.complete(
        _data(
          '1889243',
          items: [
            for (var i = 1; i <= 8; i++) _review('$i', rating: i == 1 ? 0 : 4),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('作者评分 0 / 5'), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-review-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-review-7')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('douban-review-open-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('douban-reviews-more')));
      await tester.pumpAndSettle();
      expect(links.map((uri) => uri.toString()), [
        'https://movie.douban.com/review/1/',
        'https://movie.douban.com/subject/1889243/reviews',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('spoiler content stays folded and excerpts remain bounded', (
    tester,
  ) async {
    final repository = _Repository()
      ..onLoad = (id, _) async => _data(
        id,
        items: [_review('1', spoiler: true, excerpt: '这是影评内容。' * 40)],
      );
    await mount(tester, repository);
    expect(find.text('影评标题 1'), findsNothing);
    expect(find.byKey(const ValueKey('douban-review-excerpt-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('douban-review-spoiler-1')));
    await tester.pumpAndSettle();
    expect(find.text('影评标题 1'), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('douban-review-excerpt-1')))
        .data!;
    expect(text.characters.length, lessThanOrEqualTo(120));
    await tester.ensureVisible(
      find.byKey(const ValueKey('douban-review-spoiler-1')),
    );
    await tester.tap(find.byKey(const ValueKey('douban-review-spoiler-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('douban-review-excerpt-1')), findsNothing);
  });
  testWidgets(
    'changing subject clears old content and ignores its later response',
    (tester) async {
      final first = Completer<CinemaDoubanReviews>(),
          second = Completer<CinemaDoubanReviews>();
      final repository = _Repository()
        ..onLoad = (id, _) => id == '1889243' ? first.future : second.future;
      await mount(tester, repository, settle: false);
      await mount(tester, repository, id: '1292052', settle: false);
      second.complete(_data('1292052', items: [_review('2')]));
      await tester.pumpAndSettle();
      first.complete(_data('1889243', items: [_review('1')]));
      await tester.pumpAndSettle();
      expect(find.text('影评标题 2'), findsOneWidget);
      expect(find.text('影评标题 1'), findsNothing);
      await mount(tester, repository, id: '');
      expect(find.text('豆瓣影评'), findsNothing);
      expect(find.text('影评标题 2'), findsNothing);
      expect(repository.calls, [('1889243', false), ('1292052', false)]);
    },
  );
  testWidgets(
    'new subject drops already loaded reviews while its own request waits',
    (tester) async {
      final pending = Completer<CinemaDoubanReviews>();
      final repository = _Repository();
      await mount(tester, repository);
      expect(find.text('影评标题 123456'), findsOneWidget);
      repository.onLoad = (_, _) => pending.future;
      await mount(tester, repository, id: '1292052', settle: false);
      expect(find.text('影评标题 123456'), findsNothing);
      pending.complete(_data('1292052', items: [_review('2')]));
      await tester.pumpAndSettle();
      expect(find.text('影评标题 2'), findsOneWidget);
    },
  );
  testWidgets(
    'restricted response offers a forced retry without blocking the section',
    (tester) async {
      final repository = _Repository()
        ..onLoad = (id, force) async => force
            ? _data(id)
            : CinemaDoubanReviews(
                subjectId: id,
                status: CinemaDoubanReviewsStatus.restricted,
                message: '豆瓣暂时限制访问。',
              );
      await mount(tester, repository);
      expect(find.text('豆瓣暂时限制访问。'), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-reviews-more')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('douban-reviews-retry')));
      await tester.pumpAndSettle();
      expect(repository.calls, [('1889243', false), ('1889243', true)]);
      expect(find.text('影评标题 123456'), findsOneWidget);
    },
  );
  testWidgets(
    'thrown failures and mismatched subjects never render a wrong review',
    (tester) async {
      final repository = _Repository()
        ..onLoad = (_, _) => throw StateError('offline');
      await mount(tester, repository);
      expect(find.textContaining('影评暂时无法读取'), findsOneWidget);
      repository.onLoad = (_, _) async => _data('54321');
      await tester.tap(find.byKey(const ValueKey('douban-reviews-retry')));
      await tester.pumpAndSettle();
      expect(find.text('影评条目不一致，请稍后重试。'), findsOneWidget);
      expect(find.text('影评标题 123456'), findsNothing);
    },
  );
  testWidgets(
    'narrow layout and larger text preserve the original five-star scale',
    (tester) async {
      final repository = _Repository()
        ..onLoad = (id, _) async => _data(
          id,
          items: [
            _review('1', spoiler: true, rating: 4.5),
            _review('2', rating: double.nan),
            _review('3', rating: null),
          ],
        );
      await mount(tester, repository, width: 320, textScale: 1.5);
      expect(find.text('作者评分 4.5 / 5'), findsOneWidget);
      expect(find.text('作者未评分'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'stale reviews retain their original timestamp and source access',
    (tester) async {
      final repository = _Repository()
        ..onLoad = (id, _) async => CinemaDoubanReviews(
          subjectId: id,
          items: [_review('1')],
          status: CinemaDoubanReviewsStatus.unavailable,
          stale: true,
          fetchedAt: DateTime(2026, 10, 8, 10, 30),
          message: '更新未完成，保留上次影评。',
        );
      await mount(tester, repository);
      expect(find.text('影评标题 1'), findsOneWidget);
      expect(find.text('影评缓存：2026-10-08 10:30'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('douban-reviews-retry')),
        findsOneWidget,
      );
    },
  );
}
