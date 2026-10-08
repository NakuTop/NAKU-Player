import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_card_ratings.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

const _title = CinemaTitle(
  id: 'interstellar',
  sourceId: 'fixture',
  title: '星际穿越',
  year: '2014',
  doubanId: '1889243',
  sourceDoubanScore: 9.4,
);

const _result = CinemaRatings(
  identity: RatingIdentity(doubanId: '1889243', imdbId: 'tt0816692'),
  message: '',
  ratings: [
    CinemaRating(provider: '豆瓣', value: 9.4, note: '官网评分', verified: true),
    CinemaRating(
      provider: 'IMDb',
      value: 8.7,
      note: 'IMDb 每日数据',
      verified: true,
    ),
    CinemaRating(
      provider: '烂番茄',
      value: 73,
      scale: 100,
      note: 'Tomatometer',
      verified: true,
    ),
  ],
);

class _FakeRepository extends CinemaRatingsRepository {
  CinemaRatings? cached;
  final requests = <CinemaTitle>[];
  final isCurrentCallbacks = <bool Function()?>[];
  Future<CinemaRatings> Function(CinemaTitle)? onLoad;

  @override
  CinemaRatings? peek(CinemaTitle title) => cached;

  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
  }) async {
    requests.add(title);
    isCurrentCallbacks.add(isCurrent);
    return onLoad == null ? _result : await onLoad!(title);
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _FakeRepository repository, {
    CinemaTitle title = _title,
    double width = 220,
    bool settle = true,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: GestureDetector(
                onTap: onTap,
                child: CinemaCardRatings(title: title, repository: repository),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  String tooltip(WidgetTester tester, String provider) => tester
      .widget<Tooltip>(find.byKey(ValueKey('card-rating-$provider')))
      .message!;

  testWidgets(
    'no IDs still checks local bindings and keeps unbound source fallback',
    (tester) async {
      final repository = _FakeRepository()
        ..onLoad = (_) async => const CinemaRatings(
          identity: RatingIdentity(),
          ratings: [],
          message: '本地没有保存的关联',
        );
      await mount(
        tester,
        repository,
        title: const CinemaTitle(
          id: 'offline',
          sourceId: 'fixture',
          title: '无关联电影',
          sourceDoubanScore: 9.4,
        ),
      );
      expect(find.text('豆瓣 9.4*'), findsOneWidget);
      expect(find.text('IMDb —'), findsOneWidget);
      expect(find.text('烂番茄 —'), findsOneWidget);
      expect(tooltip(tester, '豆瓣'), contains('vod_douban_score'));
      expect(tooltip(tester, '豆瓣'), contains('未向豆瓣官网核验'));
      expect(repository.requests, hasLength(1));
    },
  );

  testWidgets('saved manual binding loads when original title has no IDs', (
    tester,
  ) async {
    final repository = _FakeRepository()
      ..onLoad = (_) async => CinemaRatings(
        identity: const RatingIdentity(
          doubanId: '1889243',
          imdbId: 'tt0816692',
          confirmed: true,
        ),
        ratings: _result.ratings,
        message: '已恢复本地手动关联',
      );
    expect(repository.cached, isNull);
    await mount(
      tester,
      repository,
      title: const CinemaTitle(
        id: 'manually-bound',
        sourceId: 'fixture',
        title: '星际穿越',
      ),
    );
    expect(repository.requests, hasLength(1));
    expect(repository.requests.single.doubanId, isEmpty);
    expect(repository.requests.single.imdbId, isEmpty);
    expect(find.text('豆瓣 9.4'), findsOneWidget);
    expect(find.text('IMDb 8.7'), findsOneWidget);
    expect(find.text('烂番茄 73%'), findsOneWidget);
  });

  testWidgets('local binding read failure is handled for a title without IDs', (
    tester,
  ) async {
    final repository = _FakeRepository()
      ..onLoad = (_) => throw const FormatException('本地评分设置读取失败');
    await mount(
      tester,
      repository,
      title: const CinemaTitle(
        id: 'read-error',
        sourceId: 'fixture',
        title: '未关联电影',
      ),
    );
    expect(find.text('IMDb —'), findsOneWidget);
    expect(tooltip(tester, 'IMDb'), contains('本地评分设置读取失败'));
    expect(repository.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('source fallback is immediate then verified values replace it', (
    tester,
  ) async {
    final pending = Completer<CinemaRatings>();
    final repository = _FakeRepository()..onLoad = (_) => pending.future;
    await mount(tester, repository, settle: false);
    expect(find.text('豆瓣 9.4*'), findsOneWidget);
    expect(find.text('IMDb —'), findsOneWidget);
    expect(tooltip(tester, 'IMDb'), contains('正在后台查询'));
    pending.complete(_result);
    await tester.pumpAndSettle();
    expect(find.text('豆瓣 9.4'), findsOneWidget);
    expect(find.text('IMDb 8.7'), findsOneWidget);
    expect(find.text('烂番茄 73%'), findsOneWidget);
    expect(find.text('豆瓣 9.4*'), findsNothing);
    expect(tooltip(tester, '豆瓣'), contains('豆瓣官网公开条目评分'));
    expect(tooltip(tester, 'IMDb'), contains('IMDb 官方每日评分数据'));
    expect(tooltip(tester, 'IMDb'), contains('8.7 / 10'));
    expect(tooltip(tester, '烂番茄'), contains('影评人正面评价百分比'));
    expect(repository.requests, hasLength(1));
  });

  testWidgets(
    'peek values render immediately and remain on a background error',
    (tester) async {
      final pending = Completer<CinemaRatings>();
      final repository = _FakeRepository()
        ..cached = _result
        ..onLoad = (_) => pending.future;
      await mount(tester, repository, settle: false);
      expect(find.text('IMDb 8.7'), findsOneWidget);
      pending.completeError(const FormatException('离线'));
      await tester.pumpAndSettle();
      expect(find.text('IMDb 8.7'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '140px wraps into at most two compact rows and preserves parent tap',
    (tester) async {
      var taps = 0;
      await mount(tester, _FakeRepository(), width: 140, onTap: () => taps++);
      final size = tester.getSize(
        find.byKey(const ValueKey('cinema-card-ratings')),
      );
      expect(size.width, lessThanOrEqualTo(140));
      expect(size.height, lessThanOrEqualTo(36));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('IMDb 8.7'));
      expect(taps, 1);
    },
  );

  testWidgets('a recycled card drops previous values and queued requests', (
    tester,
  ) async {
    final oldPending = Completer<CinemaRatings>();
    final newPending = Completer<CinemaRatings>();
    final repository = _FakeRepository()
      ..onLoad = (title) =>
          title.id == _title.id ? oldPending.future : newPending.future;
    await mount(tester, repository, settle: false);
    final oldCurrent = repository.isCurrentCallbacks.single!;
    expect(oldCurrent(), isTrue);
    await mount(
      tester,
      repository,
      title: const CinemaTitle(
        id: 'another',
        sourceId: 'fixture',
        title: '另一电影',
        imdbId: 'tt0111161',
      ),
      settle: false,
    );
    expect(find.text('豆瓣 9.4*'), findsNothing);
    expect(find.text('豆瓣 —'), findsOneWidget);
    expect(oldCurrent(), isFalse);
    oldPending.complete(_result);
    await tester.pumpAndSettle();
    expect(find.text('IMDb 8.7'), findsNothing);
    newPending.complete(
      const CinemaRatings(
        identity: RatingIdentity(imdbId: 'tt0111161'),
        ratings: [
          CinemaRating(
            provider: 'IMDb',
            value: 9.3,
            note: '官方数据',
            verified: true,
          ),
        ],
        message: '',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('IMDb 9.3'), findsOneWidget);
    final current = repository.isCurrentCallbacks.last!;
    await tester.pumpWidget(const SizedBox());
    expect(current(), isFalse);
  });

  testWidgets(
    'explicit null after identity correction does not reapply source score',
    (tester) async {
      final repository = _FakeRepository()
        ..onLoad = (_) async => const CinemaRatings(
          identity: RatingIdentity(doubanId: '1292052', confirmed: true),
          ratings: [CinemaRating(provider: '豆瓣', note: '关联已改，不使用原片源分数')],
          message: '',
        );
      await mount(tester, repository);
      expect(find.text('豆瓣 —'), findsOneWidget);
      expect(find.text('豆瓣 9.4*'), findsNothing);
      expect(tooltip(tester, '豆瓣'), contains('不使用原片源分数'));
    },
  );

  testWidgets(
    'invalid scales stay empty and valid zero percent remains visible',
    (tester) async {
      final repository = _FakeRepository()
        ..onLoad = (_) async => const CinemaRatings(
          identity: RatingIdentity(imdbId: 'tt0816692'),
          ratings: [
            CinemaRating(provider: 'IMDb', value: 87, scale: 100, note: '错误刻度'),
            CinemaRating(
              provider: '烂番茄',
              value: 0,
              scale: 100,
              note: '0% 影评人好评',
            ),
          ],
          message: '',
        );
      await mount(tester, repository);
      expect(find.text('IMDb —'), findsOneWidget);
      expect(find.text('烂番茄 0%'), findsOneWidget);
    },
  );
}
