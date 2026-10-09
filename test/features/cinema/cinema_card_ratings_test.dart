import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_card_ratings.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_scroll_activity.dart';
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

class _ObservedNotifier extends ChangeNotifier {
  bool get isObserved => hasListeners;
}

class _ObservedScrollActivity extends CinemaScrollActivity {
  bool get isObserved => hasListeners;
}

class _FakeRepository extends CinemaRatingsRepository {
  CinemaRatings? cached;
  final updates = _ObservedNotifier();
  @override
  Listenable get changes => updates;
  final requests = <CinemaTitle>[];
  final isCurrentCallbacks = <bool Function()?>[];
  Future<CinemaRatings> Function(CinemaTitle)? onLoad;
  int peeks = 0;
  int revision = 0;

  @override
  int get bindingRevision => revision;

  @override
  CinemaRatings? peek(CinemaTitle title) {
    peeks++;
    return cached;
  }

  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
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
    CinemaScrollActivity? activity,
  }) async {
    final card = GestureDetector(
      onTap: onTap,
      child: CinemaCardRatings(title: title, repository: repository),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: activity == null
                  ? card
                  : CinemaScrollActivityScope(activity: activity, child: card),
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

  testWidgets('a card mounted during scrolling shows cache before querying', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity()..value = true;
    final repository = _FakeRepository()..cached = _result;
    await mount(tester, repository, activity: activity);
    expect(find.text('IMDb 8.7'), findsOneWidget);
    expect(repository.requests, isEmpty);
    expect(repository.peeks, 1);

    activity.value = false;
    await tester.pumpAndSettle();
    expect(repository.requests, hasLength(1));
    expect(find.text('IMDb 8.7'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    activity.dispose();
  });

  testWidgets('a card mounted during scrolling retains source score fallback', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity()..value = true;
    final repository = _FakeRepository();
    await mount(tester, repository, activity: activity);
    expect(find.text('豆瓣 9.4*'), findsOneWidget);
    expect(find.text('IMDb —'), findsOneWidget);
    expect(repository.requests, isEmpty);
    activity.value = false;
    await tester.pumpAndSettle();
    expect(repository.requests, hasLength(1));
    expect(find.text('豆瓣 9.4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    activity.dispose();
  });

  testWidgets('scrolling coalesces cache updates into one idle lookup', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity();
    final repository = _FakeRepository()..cached = _result;
    await mount(tester, repository, activity: activity);
    activity.value = true;
    final peeksBefore = repository.peeks;
    final labelsBefore = tester.widget<Text>(find.text('IMDb 8.7'));
    repository.cached = const CinemaRatings(
      identity: RatingIdentity(imdbId: 'tt0816692'),
      ratings: [
        CinemaRating(
          provider: 'IMDb',
          value: 8.8,
          verified: true,
          note: '官方数据',
        ),
      ],
      message: '',
    );
    for (var i = 0; i < 20; i++) {
      repository.updates.notifyListeners();
      await tester.pump();
    }
    expect(repository.peeks, peeksBefore);
    expect(tester.widget<Text>(find.text('IMDb 8.7')), same(labelsBefore));
    expect(find.text('IMDb 8.8'), findsNothing);
    activity.value = false;
    await tester.pump();
    expect(repository.peeks, peeksBefore + 1);
    expect(find.text('IMDb 8.8'), findsOneWidget);
    expect(repository.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    activity.dispose();
  });

  testWidgets(
    'in-flight results stay valid and are displayed after scrolling',
    (tester) async {
      final activity = _ObservedScrollActivity();
      final pending = Completer<CinemaRatings>();
      final repository = _FakeRepository()..onLoad = (_) => pending.future;
      await mount(tester, repository, activity: activity, settle: false);
      final isCurrent = repository.isCurrentCallbacks.single!;
      activity.value = true;
      final peeksBefore = repository.peeks;
      expect(isCurrent(), isTrue);
      pending.complete(_result);
      await tester.pumpAndSettle();
      expect(isCurrent(), isTrue);
      expect(repository.peeks, peeksBefore);
      expect(find.text('IMDb —'), findsOneWidget);
      activity.value = false;
      await tester.pump();
      expect(find.text('IMDb 8.7'), findsOneWidget);
      expect(repository.peeks, peeksBefore + 1);
      expect(repository.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      activity.dispose();
    },
  );

  testWidgets('an in-flight error is deferred without dropping cached scores', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity();
    final pending = Completer<CinemaRatings>();
    final repository = _FakeRepository()
      ..cached = const CinemaRatings(
        identity: RatingIdentity(imdbId: 'tt0816692'),
        ratings: [
          CinemaRating(
            provider: 'IMDb',
            value: 8.7,
            verified: true,
            note: '官方数据',
          ),
        ],
        message: '',
      )
      ..onLoad = (_) => pending.future;
    await mount(tester, repository, activity: activity, settle: false);
    activity.value = true;
    final peeksBefore = repository.peeks;
    pending.completeError(const FormatException('离线'));
    await tester.pumpAndSettle();
    expect(repository.peeks, peeksBefore);
    expect(tooltip(tester, '烂番茄'), isNot(contains('离线')));
    activity.value = false;
    await tester.pump();
    expect(find.text('IMDb 8.7'), findsOneWidget);
    expect(tooltip(tester, '烂番茄'), contains('离线'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    activity.dispose();
  });

  testWidgets(
    'recycled cards cannot apply a completion deferred for old title',
    (tester) async {
      final activity = _ObservedScrollActivity();
      final pending = Completer<CinemaRatings>();
      final repository = _FakeRepository()
        ..onLoad = (title) => title.id == _title.id
            ? pending.future
            : Future.value(
                const CinemaRatings(
                  identity: RatingIdentity(imdbId: 'tt0111161'),
                  ratings: [
                    CinemaRating(provider: 'IMDb', value: 9.3, note: '官方数据'),
                  ],
                  message: '',
                ),
              );
      await mount(tester, repository, activity: activity, settle: false);
      final oldCurrent = repository.isCurrentCallbacks.single!;
      activity.value = true;
      pending.complete(_result);
      await tester.pump();
      await mount(
        tester,
        repository,
        activity: activity,
        title: const CinemaTitle(
          id: 'another',
          sourceId: 'fixture',
          title: '另一电影',
          imdbId: 'tt0111161',
        ),
      );
      expect(oldCurrent(), isFalse);
      expect(find.text('IMDb 8.7'), findsNothing);
      expect(repository.requests, hasLength(1));
      activity.value = false;
      await tester.pumpAndSettle();
      expect(find.text('IMDb 9.3'), findsOneWidget);
      expect(repository.requests, hasLength(2));
      expect(repository.requests.last.id, 'another');
      await tester.pumpWidget(const SizedBox());
      activity.dispose();
    },
  );

  testWidgets('repository changes while scrolling detach old notifications', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity()..value = true;
    final oldRepository = _FakeRepository()..cached = _result;
    final repository = _FakeRepository();
    await mount(tester, oldRepository, activity: activity);
    await mount(tester, repository, activity: activity);
    expect(find.text('IMDb 8.7'), findsNothing);
    final peeksBefore = repository.peeks;
    oldRepository.updates.notifyListeners();
    expect(repository.peeks, peeksBefore);
    expect(oldRepository.updates.isObserved, isFalse);
    activity.value = false;
    await tester.pumpAndSettle();
    expect(oldRepository.requests, isEmpty);
    expect(repository.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(repository.updates.isObserved, isFalse);
    expect(activity.isObserved, isFalse);
    activity.dispose();
  });

  testWidgets('moving to an idle scope resumes and detaches the old scope', (
    tester,
  ) async {
    final scrolling = _ObservedScrollActivity()..value = true;
    final idle = _ObservedScrollActivity();
    final repository = _FakeRepository();
    await mount(tester, repository, activity: scrolling);
    expect(repository.requests, isEmpty);
    expect(scrolling.isObserved, isTrue);
    final peeksBefore = repository.peeks;
    await mount(tester, repository, activity: scrolling);
    expect(repository.peeks, peeksBefore);
    await mount(tester, repository, activity: idle);
    expect(repository.requests, hasLength(1));
    expect(find.text('IMDb 8.7'), findsOneWidget);
    expect(scrolling.isObserved, isFalse);
    final peeksAfter = repository.peeks;
    scrolling.value = false;
    await tester.pump();
    expect(repository.peeks, peeksAfter);
    expect(repository.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(idle.isObserved, isFalse);
    scrolling.dispose();
    idle.dispose();
  });

  testWidgets('a binding correction during scrolling supersedes old results', (
    tester,
  ) async {
    final activity = _ObservedScrollActivity();
    final pending = Completer<CinemaRatings>();
    final repository = _FakeRepository()..onLoad = (_) => pending.future;
    await mount(tester, repository, activity: activity, settle: false);
    final oldCurrent = repository.isCurrentCallbacks.single!;
    activity.value = true;
    pending.complete(_result);
    await tester.pump();
    repository.revision++;
    repository.onLoad = (_) async => const CinemaRatings(
      identity: RatingIdentity(doubanId: '1292052', confirmed: true),
      ratings: [CinemaRating(provider: '豆瓣', note: '关联已改，不使用原片源分数')],
      message: '',
    );
    final peeksBefore = repository.peeks;
    repository.updates.notifyListeners();
    await tester.pump();
    expect(repository.peeks, peeksBefore);
    expect(repository.requests, hasLength(1));
    activity.value = false;
    await tester.pumpAndSettle();
    expect(oldCurrent(), isFalse);
    expect(repository.requests, hasLength(2));
    expect(find.text('IMDb 8.7'), findsNothing);
    expect(find.text('豆瓣 —'), findsOneWidget);
    expect(tooltip(tester, '豆瓣'), contains('不使用原片源分数'));
    await tester.pumpWidget(const SizedBox());
    activity.dispose();
  });

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

  testWidgets(
    'a mounted card observes a later provider refresh without navigation',
    (tester) async {
      final repository = _FakeRepository()..cached = _result;
      await mount(tester, repository);
      repository.cached = const CinemaRatings(
        identity: RatingIdentity(doubanId: '1889243', imdbId: 'tt0816692'),
        ratings: [
          CinemaRating(
            provider: 'IMDb',
            value: 8.8,
            verified: true,
            note: '刷新后的官方评分',
          ),
        ],
        message: '',
      );
      repository.updates.notifyListeners();
      await tester.pump();
      expect(find.text('IMDb 8.8'), findsOneWidget);
      expect(find.text('IMDb 8.7'), findsNothing);
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
