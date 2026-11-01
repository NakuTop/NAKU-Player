import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_multi_source_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
}

class _Player implements Player {
  _Player(this.backend);
  final _Backend backend;
  @override
  PlayerStream get stream => backend.stream;
  @override
  PlayerState get state => backend.state;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Source implements CinemaDanmakuMatcher {
  _Source(this.id, this.calls);
  final String id;
  final List<String> calls;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery q, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    calls.add(id);
    return CinemaLogvarSelection(
      CinemaLogvarWork(id: 1, title: q.title),
      const CinemaLogvarEpisode(1, '第1集', 1),
      [
        DanmakuEntry(
          time: 1,
          message: '$id 弹幕',
          type: 1,
          color: Colors.white,
          source: '[$id]',
        ),
        DanmakuEntry(
          time: 500,
          message: '$id 后段',
          type: 1,
          color: Colors.white,
          source: '[$id]',
        ),
      ],
      1800,
      provider: cinemaSelectableDanmakuSources[id]!,
    );
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CinemaStore store;
  late _Backend backend;
  final controllers = <CinemaDanmakuController>[];
  final calls = <String>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('naku-source-choice-');
    store = CinemaStore(
      file: File('${dir.path}/library.json'),
      defaults: const [],
    );
    await store.load();
    await store.setExtra(cinemaDanmakuSourcesPreference, ['renren']);
    backend = _Backend();
    calls.clear();
  });
  tearDown(() async {
    for (final controller in controllers) {
      await controller.close();
    }
    controllers.clear();
    await backend.dispose();
    // setExtra is awaited before matching starts; re-awaiting its completed
    // fake-zone future in real-zone tearDown would need another widget pump.
    store.dispose();
    await dir.delete(recursive: true);
  });
  CinemaDanmakuController make(String key) {
    final controller = CinemaDanmakuController(
      _Player(backend),
      store,
      key,
      autoQuery: const CinemaLogvarQuery(title: '测试剧集', series: true),
      directClientFactory: () => CinemaMultiSourceDanmakuClient(
        sourceFactory: (id) => _Source(id, calls),
      ),
    );
    controllers.add(controller);
    return controller;
  }

  test(
    'both overseas selections are merged and persisted; deselect/reselect reuses matches',
    () async {
      final c = make('current');
      await c.setSelectedSources({'renren', 'aiyifan'});
      expect(c.entries.map((e) => e.message).toSet(), {
        'renren 弹幕',
        'aiyifan 弹幕',
      });
      expect(calls.toSet(), {'renren', 'aiyifan'});
      final before = calls.length;
      await c.setSelectedSources({'aiyifan'});
      expect(c.entries.map((e) => e.message), ['aiyifan 弹幕']);
      await c.setSelectedSources({'renren', 'aiyifan'});
      expect(
        calls.length,
        before,
        reason: 'display filtering should not refetch already matched sources',
      );
      await c.setSelectedSources({'aiyifan'});
      final next = make('next-episode');
      expect(next.selectedSources, {'aiyifan'});
      await next.loadAutomatic();
      expect(next.entries.every((e) => e.source == '[aiyifan]'), true);
      await c.setSelectedSources({});
      expect(c.entries, isEmpty);
      expect(store.extras[cinemaDanmakuSourcesPreference], isEmpty);
    },
  );
  test(
    'reopening a cached multi-source episode never restores a deselected source',
    () async {
      final c = make('cached');
      await c.setSelectedSources({'renren', 'aiyifan'});
      await c.close();
      controllers.remove(c);
      await store.setExtra(cinemaDanmakuSourcesPreference, ['aiyifan']);
      final reopened = make('cached');
      await reopened.ready;
      expect(reopened.entries.map((e) => e.message), ['aiyifan 弹幕']);
    },
  );
  for (final size in [const Size(360, 640), const Size(900, 760)]) {
    testWidgets('checkboxes stage and cancel source choices at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = (await tester.runAsync(() async {
        final c = make('ui-${size.width}');
        await c.ready;
        return c;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCinemaDanmakuSourcesDialog(context, c),
                child: const Text('打开来源'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开来源'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('danmaku-source-renren')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('danmaku-source-aiyifan')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('danmaku-source-aiyifan')));
      await tester.pumpAndSettle();
      expect(c.selectedSources, {'renren'});
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('danmaku-source-aiyifan')),
            )
            .value,
        true,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.selectedSources, {'renren'});
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('Apply loads and displays both checked sources', (tester) async {
    final c = (await tester.runAsync(() async {
      final c = make('apply');
      await c.ready;
      return c;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCinemaDanmakuSourcesDialog(context, c),
              child: const Text('打开来源'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开来源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('danmaku-source-aiyifan')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    for (var i = 0; i < 100; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (!c.matching && c.entries.length == 2) break;
    }
    await tester.pumpAndSettle();
    expect(c.selectedSources, {'renren', 'aiyifan'});
    expect(c.entries.map((e) => e.message).toSet(), {
      'renren 弹幕',
      'aiyifan 弹幕',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // Flush event-triggered cache I/O while the widget test's fake zone still
    // runs; tearDown must not wait on an unpumped fake-zone continuation.
    var closed = false;
    c.close().then((_) => closed = true);
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(closed, true);
    controllers.remove(c);
  });
}
