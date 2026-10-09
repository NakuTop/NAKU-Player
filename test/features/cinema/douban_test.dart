import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_page.dart';

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
        home: DoubanPage(repository: repo, onSelect: (s) => selected = s),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集').first);
    await tester.pumpAndSettle();
    expect(repo.requests, [DoubanKind.movie, DoubanKind.tv]);
    await tester.tap(find.byKey(const ValueKey('douban-1')));
    expect(selected!.kind, DoubanKind.tv);
    expect(tester.takeException(), isNull);
  });
}
