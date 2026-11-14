import 'package:flutter/gestures.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_page.dart';
import 'package:kazumi/features/cinema/douban/douban_themes.dart';

Map<String, dynamic> subject(String id) => {
  'id': id,
  'type': 'movie',
  'card': 'subject',
  'title': '测试电影$id',
  'year': '2024',
  'pic': {'large': ''},
  'rating': {'value': 8.2, 'max': 10, 'count': 42},
};

class Repo extends DoubanRepository {
  final requests = <DoubanKind>[];
  @override
  Future<DoubanCharts> charts({required CancelToken cancelToken}) async =>
      const DoubanCharts([
        DoubanChartSection('豆瓣新片榜', [
          DoubanTitle(id: '2', title: '榜单影片', kind: DoubanKind.movie),
        ]),
      ], {});
  @override
  Future<String> chartPoster(String id) async => '';

  @override
  Future<List<String>> discoverThemes({
    required DoubanKind kind,
    String? seed,
    dynamic cancelToken,
  }) async => const [];
  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    dynamic cancelToken,
  }) async {
    requests.add(kind);
    return DoubanResultPage(
      items: [DoubanTitle(id: '1', title: kind.label, kind: kind, score: 8.2)],
      start: 0,
      nextStart: 20,
      hasMore: false,
      sorts: [const DoubanSort(name: 'U', text: '近期热度')],
    );
  }

  @override
  Future<List<DoubanTagGroup>> tagGroups({
    required DoubanKind kind,
    DoubanFilters filters = const DoubanFilters(),
    dynamic cancelToken,
  }) async => const [];
}

void main() {
  testWidgets(
    'trackpad switches adjacent Douban boards without leaving the page',
    (tester) async {
      final repository = Repo();
      await tester.pumpWidget(
        MaterialApp(
          home: DoubanPage(
            repository: repository,
            themeCatalog: DoubanThemeCatalog(),
            onSelect: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> swipe(double dx) async {
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        await gesture.panZoomStart(const Offset(400, 400));
        await gesture.panZoomUpdate(const Offset(400, 400), pan: Offset(dx, 0));
        await gesture.panZoomEnd();
        await tester.pumpAndSettle();
      }

      await swipe(-150);
      expect(repository.requests.last, DoubanKind.tv);
      await swipe(-150);
      expect(find.text('榜单影片'), findsOneWidget);
      await swipe(150);
      expect(find.text('榜单影片'), findsNothing);
      expect(find.text('豆瓣榜单'), findsOneWidget);
    },
  );

  test('official chart preserves board order, genres and title aliases', () async {
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.host, 'movie.douban.com');
          if (options.path.endsWith('/chart')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data:
                    '<div class="article"><table><tr class="item"><td><a href="/subject/1/" title="本地片名"></a></td>'
                    '<td class="pl2"><a href="/subject/1/">本地片名 / 海外片名</a><p>2007-11-01</p></td></tr></table></div>'
                    '<div class="types"><a href="/typerank?type=11">剧情</a></div>'
                    '<ul id="listCont2"><li><a href="/subject/1/">本地片名</a></li></ul>',
              ),
            );
          } else {
            expect(options.queryParameters['type'], '11');
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data:
                    '[{"id":"1","title":"本地片名","score":"8.5","types":["剧情"]}]',
              ),
            );
          }
        },
      ),
    );
    final repository = DoubanRepository(dio: dio);
    final charts = await repository.charts(cancelToken: CancelToken());
    expect(charts.sections.map((board) => board.label), ['豆瓣新片榜', '一周口碑榜']);
    expect(charts.sections.last.items.single.aliases, '海外片名');
    expect(charts.genres, {'剧情': '11'});
    final films = await repository.genreChart('11', cancelToken: CancelToken());
    expect(films.single.score, 8.5);
  });

  test(
    'only valid subjects, correct score scale and raw pagination survive',
    () {
      final page = DoubanResultPage.fromJson(
        {
          'total': 41,
          'items': [
            {'type': 'ad'},
            subject('1'),
            subject('1'),
            {...subject('2'), 'card': 'doulist'},
            {...subject('3'), 'type': 'tv'},
          ],
        },
        DoubanKind.movie,
        start: 0,
        count: 20,
      );
      expect(page.items.map((e) => e.id), ['1']);
      expect(page.items.single.score, 8.2);
      expect(page.nextStart, 20);
      expect(page.hasMore, isTrue);
      expect(
        DoubanTitle.fromJson({
          ...subject('1'),
          'rating': {'value': 82, 'max': 100},
        }, DoubanKind.movie)!.score,
        isNull,
      );
    },
  );
  testWidgets('movie and TV switch requests actual separate kind', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = Repo();
    DoubanTitle? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: DoubanPage(
          repository: repo,
          themeCatalog: DoubanThemeCatalog(),
          onSelect: (s) => selected = s,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选剧集').first);
    await tester.pumpAndSettle();
    expect(repo.requests, [DoubanKind.movie, DoubanKind.tv]);
    await tester.ensureVisible(find.byKey(const ValueKey('douban-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('douban-1')));
    expect(selected!.kind, DoubanKind.tv);
    expect(tester.takeException(), isNull);
  });
}
