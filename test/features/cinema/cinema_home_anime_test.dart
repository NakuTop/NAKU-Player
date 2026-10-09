import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

class _Repository extends CinemaRepository {
  int searches = 0, browses = 0;
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async =>
      const [];
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browses++;
    return const CinemaPage(items: []);
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searches++;
    return const CinemaPage(items: []);
  }
}

class _AnimeStateProbe extends StatefulWidget {
  const _AnimeStateProbe({
    required this.active,
    required this.onMount,
    required this.onDispose,
  });
  final bool active;
  final VoidCallback onMount, onDispose;
  @override
  State<_AnimeStateProbe> createState() => _AnimeStateProbeState();
}

class _AnimeStateProbeState extends State<_AnimeStateProbe> {
  final input = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    input.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(widget.active ? '动漫前台' : '动漫已隐藏'),
      TextField(key: const ValueKey('anime-search-probe'), controller: input),
    ],
  );
}

void main() {
  late Directory directory;
  late CinemaStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-anime-home-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [
        CinemaSource(
          id: 'movie-api',
          name: '影视接口',
          kind: CinemaSourceKind.maccms,
          url: 'https://example.com/api',
        ),
      ],
    );
    await store.load();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'one lazy anime entry retains its page and avoids source search',
    (tester) async {
      final repository = _Repository();
      var mounts = 0, disposals = 0;
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaHomePage(
            store: store,
            repository: repository,
            enableWatchTogether: false,
            enableSearchDiscovery: false,
            animePageBuilder: (_, active) => _AnimeStateProbe(
              active: active,
              onMount: () => mounts++,
              onDispose: () => disposals++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(mounts, 0);
      expect(find.text('Bangumi 动漫目录'), findsNothing);
      final initialBrowses = repository.browses;
      await tester.tap(find.widgetWithText(ListTile, '动漫'));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(find.text('动漫前台'), findsOneWidget);
      expect(
        find.byType(TextField),
        findsOneWidget,
        reason: 'The old source search bar is removed.',
      );
      expect(find.text('片源目录'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('anime-search-probe')),
        '赛博朋克',
      );
      await tester.tap(find.widgetWithText(ListTile, '电影'));
      await tester.pumpAndSettle();
      expect(disposals, 0);
      expect(find.text('动漫前台'), findsNothing);
      expect(
        tester
            .widget<_AnimeStateProbe>(
              find.byType(_AnimeStateProbe, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await tester.tap(find.widgetWithText(ListTile, '动漫'));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(find.text('赛博朋克'), findsOneWidget);
      expect(repository.browses, initialBrowses);
      expect(repository.searches, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(disposals, 1);
    },
  );
}
