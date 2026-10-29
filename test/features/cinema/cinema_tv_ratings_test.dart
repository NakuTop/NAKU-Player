import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_tv_ratings.dart';
import 'package:kazumi/services/platform/naku_device.dart';

const _title = CinemaTitle(
  id: 'movie',
  sourceId: 'fixture',
  title: '星际穿越',
  year: '2014',
  category: '电影',
  doubanId: '1889243',
);
const _scores = CinemaRatings(
  identity: RatingIdentity(
    doubanId: '1889243',
    imdbId: 'tt0816692',
    rottenTomatoesId: 'm/interstellar_2014',
  ),
  message: '',
  ratings: [
    CinemaRating(provider: '豆瓣', value: 9.4, note: '官网', verified: true),
    CinemaRating(provider: 'IMDb', value: 8.7, note: '官网', verified: true),
    CinemaRating(
      provider: '烂番茄',
      value: 73,
      scale: 100,
      note: '官网',
      verified: true,
    ),
  ],
);

class _Repository extends CinemaRatingsRepository {
  final updates = ChangeNotifier();
  final cached = <String, CinemaRatings>{};
  final requests = <CinemaTitle>[];
  final effective = <CinemaTitle>[];
  final gates = <Completer<CinemaRatings>>[];
  @override
  Listenable get changes => updates;
  @override
  CinemaRatings? peek(CinemaTitle title) => cached[title.key];
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    requests.add(title);
    final gate = Completer<CinemaRatings>();
    gates.add(gate);
    effective.add(resolveTitle == null ? title : await resolveTitle(title));
    final result = await gate.future;
    if (isCurrent?.call() != false) publish(title, result);
    return result;
  }

  void publish(CinemaTitle title, CinemaRatings result) {
    cached[title.key] = result;
    updates.notifyListeners();
  }
}

void main() {
  late _Repository repository;
  setUp(() {
    NakuDevice.isTV = true;
    repository = _Repository();
  });
  tearDown(() {
    NakuDevice.isTV = false;
    repository.updates.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    CinemaTitle title = _title,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: Scaffold(
          body: SizedBox(
            width: 760,
            child: CinemaTVRatings(
              title: title,
              repository: repository,
              resolveTitle: resolveTitle,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String value(WidgetTester tester, String provider) => tester
      .widget<Text>(find.byKey(ValueKey('tv-rating-value-$provider')))
      .data!;

  testWidgets(
    'fresh TV detail fetches three real providers without actions or effects',
    (tester) async {
      await mount(tester);
      expect(repository.requests, [_title]);
      expect(find.text('查询中'), findsNWidgets(3));
      for (final provider in ['豆瓣', 'IMDb', '烂番茄']) {
        expect(value(tester, provider), '—');
      }
      repository.gates.single.complete(_scores);
      await tester.pumpAndSettle();
      expect(value(tester, '豆瓣'), '9.4');
      expect(value(tester, 'IMDb'), '8.7');
      expect(value(tester, '烂番茄'), '73');
      expect(find.text('%'), findsOneWidget);
      expect(find.text('/10'), findsNWidgets(2));
      final row = find.byKey(const ValueKey('tv-three-provider-ratings'));
      expect(tester.getSize(row).height, lessThan(90));
      final y = tester
          .getTopLeft(find.byKey(const ValueKey('tv-rating-豆瓣')))
          .dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tv-rating-IMDb'))).dy,
        y,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('tv-rating-烂番茄'))).dy,
        y,
      );
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'provider progress updates independently and missing or invalid scores stay explicit',
    (tester) async {
      await mount(tester);
      repository.publish(
        _title,
        const CinemaRatings(
          identity: RatingIdentity(),
          message: '',
          ratings: [
            CinemaRating(
              provider: '豆瓣',
              value: 9.4,
              note: '官网',
              verified: true,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(value(tester, '豆瓣'), '9.4');
      expect(value(tester, 'IMDb'), '—');
      expect(find.text('查询中'), findsNWidgets(2));
      repository.gates.single.complete(
        const CinemaRatings(
          identity: RatingIdentity(),
          message: '',
          ratings: [
            CinemaRating(provider: '豆瓣', note: '未找到确切条目'),
            CinemaRating(provider: 'IMDb', value: 87, scale: 100, note: '错误刻度'),
            CinemaRating(provider: '烂番茄', value: -1, scale: 100, note: '错误数值'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      for (final provider in ['豆瓣', 'IMDb', '烂番茄']) {
        expect(value(tester, provider), '—');
      }
      expect(find.text('暂无评分'), findsNWidgets(3));
      expect(find.text('0.0'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'NAS exact identity enrichment keeps media references and then fetches all scores',
    (tester) async {
      final nas = createCinemaNASTitle(
        namespace: List.filled(64, 'a').join(),
        row: {
          'ug_video_info_id': 42,
          'media_lib_set_id': 2,
          'name': '星际穿越',
          'year': 2014,
          'type': 1,
        },
        files: [(label: '原画', path: '/volume1/movie.mkv')],
      );
      final lookup = CinemaRatingIdentitySearch(
        search: (_) async => const CinemaSearchDiscovery(
          titles: [
            CinemaDiscoveryTitle(
              id: '1889243',
              title: '星际穿越',
              year: '2014',
              kind: 'movie',
              identityVerified: true,
            ),
          ],
        ),
      );
      await mount(tester, title: nas, resolveTitle: lookup.resolve);
      expect(repository.effective.single.doubanId, '1889243');
      expect(repository.effective.single.key, nas.key);
      expect(
        repository.effective.single.routes.single.episodes.single.url,
        nas.routes.single.episodes.single.url,
      );
      expect(repository.effective.single.sourceDoubanScore, isNull);
      repository.gates.single.complete(_scores);
      await tester.pumpAndSettle();
      expect(value(tester, '豆瓣'), '9.4');
      expect(value(tester, 'IMDb'), '8.7');
      expect(value(tester, '烂番茄'), '73');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late scores cannot replace the next selected TV title', (
    tester,
  ) async {
    await mount(tester);
    const other = CinemaTitle(
      id: 'second',
      sourceId: 'fixture',
      title: '另一部电影',
    );
    await mount(tester, title: other);
    expect(repository.requests, [_title, other]);
    repository.gates[1].complete(_scores);
    await tester.pumpAndSettle();
    repository.gates[0].complete(
      const CinemaRatings(
        identity: RatingIdentity(),
        message: '',
        ratings: [CinemaRating(provider: '豆瓣', value: 1.1, note: '旧请求')],
      ),
    );
    await tester.pumpAndSettle();
    expect(value(tester, '豆瓣'), '9.4');
    expect(find.text('1.1*'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
