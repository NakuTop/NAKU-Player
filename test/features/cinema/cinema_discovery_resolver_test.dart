import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_discovery_resolver.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

CinemaSource _source(
  String id, {
  bool enabled = true,
  CinemaSourceKind kind = CinemaSourceKind.maccms,
}) => CinemaSource(
  id: id,
  name: '片源 $id',
  kind: kind,
  url: 'https://$id.invalid/api',
  enabled: enabled,
);

CinemaTitle _title(
  String source, {
  String id = 'one',
  String name = '怒之杀',
  String year = '2026',
  String category = '电影',
  String doubanId = '36889088',
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: category,
  doubanId: doubanId,
);

class _Repository extends CinemaRepository {
  final replies = <String, Future<CinemaPage>>{};
  final queried = <String>[];
  final keywords = <String>[];

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) {
    queried.add(source.id);
    keywords.add(keyword);
    return replies[source.id] ?? Future.value(const CinemaPage(items: []));
  }
}

class _Harness {
  final result = Completer<List<CinemaTitle>?>();
  final navigator = GlobalKey<NavigatorState>();

  Future<void> open(
    WidgetTester tester, {
    required _Repository repository,
    required List<CinemaSource> sources,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result.complete(
                  await resolveCinemaDiscoverySources(
                    context,
                    anchor: _title('douban-discovery'),
                    sources: sources,
                    repository: repository,
                  ),
                );
              },
              child: const Text('作品目录'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('作品目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> showNextPage(WidgetTester tester) async {
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('下一页保持打开')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'returns compatible source identities only and skips disabled or absent sources',
    (tester) async {
      final repository = _Repository()
        ..replies['a'] = Future.value(
          CinemaPage(
            items: [
              _title('a', id: 'wrong-year', year: '2025'),
              _title('a', id: 'wrong-kind', category: '欧美剧'),
              _title('a', id: 'wrong-id', doubanId: '999999'),
              _title('a', id: 'wrong-name', name: '另一部电影'),
              _title('douban-discovery'),
              _title('removed'),
              _title('a'),
            ],
          ),
        )
        ..replies['b'] = Future.value(
          CinemaPage(items: [_title('b')]),
        );
      final harness = _Harness();
      await harness.open(
        tester,
        repository: repository,
        sources: [
          _source('a'),
          _source('b'),
          _source('off', enabled: false),
          _source('anime-rule', kind: CinemaSourceKind.kazumi),
          _source('douban-discovery'),
        ],
      );
      await tester.pumpAndSettle();
      final result = await harness.result.future;
      expect(repository.queried, ['a', 'b']);
      expect(repository.keywords, everyElement('怒之杀'));
      expect(result!.map((title) => title.sourceId), ['a', 'b']);
      expect(result.map((title) => title.id), everyElement('one'));
      expect(find.text('作品目录'), findsOneWidget);
    },
  );

  testWidgets('found sources can open before a later batch finishes', (
    tester,
  ) async {
    final pending = Completer<CinemaPage>();
    final repository = _Repository()
      ..replies['a'] = Future.value(CinemaPage(items: [_title('a')]))
      ..replies['d'] = pending.future;
    final harness = _Harness();
    await harness.open(
      tester,
      repository: repository,
      sources: [
        for (final id in ['a', 'b', 'c', 'd']) _source(id),
      ],
    );
    expect(harness.result.isCompleted, isFalse);
    expect(find.text('片源 a'), findsOneWidget);
    expect(find.text('打开已找到的线路'), findsOneWidget);
    await tester.tap(find.text('打开已找到的线路'));
    await tester.pumpAndSettle();
    expect((await harness.result.future)!.single.sourceId, 'a');
    await harness.showNextPage(tester);
    pending.complete(CinemaPage(items: [_title('d')]));
    await tester.pumpAndSettle();
    expect(find.text('下一页保持打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancellation stops later batches and never pops another page', (
    tester,
  ) async {
    final pending = Completer<CinemaPage>();
    final repository = _Repository()..replies['a'] = pending.future;
    final harness = _Harness();
    await harness.open(
      tester,
      repository: repository,
      sources: [
        for (final id in ['a', 'b', 'c', 'd']) _source(id),
      ],
    );
    expect(repository.queried, ['a', 'b', 'c']);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await harness.result.future, isNull);
    await harness.showNextPage(tester);
    pending.complete(CinemaPage(items: [_title('a')]));
    await tester.pumpAndSettle();
    expect(repository.queried, ['a', 'b', 'c']);
    expect(find.text('下一页保持打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no match stays visible until explicitly closed', (tester) async {
    final repository = _Repository()
      ..replies['a'] = Future.value(
        CinemaPage(items: [_title('a', year: '2021')]),
      );
    final harness = _Harness();
    await harness.open(tester, repository: repository, sources: [_source('a')]);
    await tester.pumpAndSettle();
    expect(harness.result.isCompleted, isFalse);
    expect(find.text('暂未找到匹配的片源'), findsOneWidget);
    expect(find.text('打开已找到的线路'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(await harness.result.future, isNull);
  });

  testWidgets('barrier dismissal suppresses a completed matching request', (
    tester,
  ) async {
    final pending = Completer<CinemaPage>();
    final repository = _Repository()..replies['a'] = pending.future;
    final harness = _Harness();
    await harness.open(tester, repository: repository, sources: [_source('a')]);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await harness.result.future, isNull);
    await harness.showNextPage(tester);
    pending.complete(CinemaPage(items: [_title('a')]));
    await tester.pumpAndSettle();
    expect(find.text('下一页保持打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
