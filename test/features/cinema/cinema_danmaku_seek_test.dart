import 'dart:async';
import 'dart:io';
import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';

DanmakuEntry comment(double time, String text) => DanmakuEntry(
  message: text,
  time: time,
  type: 1,
  color: Colors.white,
  source: '[renren]',
);

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
  void at(double seconds, {bool playing = true, bool buffering = false}) {
    state = state.copyWith(
      position: Duration(milliseconds: (seconds * 1000).round()),
      playing: playing,
      buffering: buffering,
    );
    positionController.add(state.position);
  }
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

class _Timeline implements CinemaDanmakuTimeline {
  final pending = Completer<CinemaDanmakuWindow>();
  final requested = Completer<void>();
  CancelToken? token;
  var loads = 0;
  @override
  double get endSeconds => 1000;
  @override
  Future<CinemaDanmakuWindow> window(double at, {CancelToken? cancelToken}) {
    loads++;
    token = cancelToken;
    if (!requested.isCompleted) requested.complete();
    return pending.future;
  }

  @override
  void close() {}
}

class _Matcher implements CinemaDanmakuMatcher {
  _Matcher(this.timeline);
  final _Timeline timeline;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery q, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async => CinemaLogvarSelection(
    CinemaLogvarWork(id: 1, title: q.title),
    const CinemaLogvarEpisode(1, '第1集', 1),
    [comment(41, '回退后应再次显示'), comment(139, '稍后的弹幕')],
    1000,
    provider: '人人视频',
    timeline: timeline,
    windowStart: 0,
    windowEnd: 150,
  );
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CinemaStore store;
  late _Backend backend;
  late CinemaDanmakuController controller;
  var clears = 0;
  final rendered = <String>[];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('naku-danmaku-seek-');
    store = CinemaStore(
      file: File('${dir.path}/library.json'),
      defaults: const [],
    );
    await store.load();
    backend = _Backend();
    clears = 0;
    rendered.clear();
  });
  tearDown(() async {
    await controller.close();
    await backend.dispose();
    await store.flush();
    store.dispose();
    await dir.delete(recursive: true);
  });
  void attach() => controller.attach(
    canvas.DanmakuController(
      addDanmaku: (entry) => rendered.add(entry.text),
      updateOption: (_) {},
      pause: () {},
      resume: () {},
      clear: () {
        clears++;
        rendered.clear();
      },
      getOption: () => controller.option,
      isRunning: () => true,
      findDanmaku: (_) => const [],
      findSingleDanmaku: (_) => null,
      getViewWidth: () => 1200,
      getViewHeight: () => 700,
      scrollDanmaku: [],
      staticDanmaku: [],
      specialDanmaku: [],
    ),
  );
  Future<void> drain() => Future<void>.delayed(Duration.zero);
  test(
    'paused and buffering rewind clears the future overlay and moves the clock',
    () async {
      controller = CinemaDanmakuController(_Player(backend), store, 'paused');
      await controller.setEntries([
        comment(11, '目标弹幕'),
        comment(101, '未来弹幕'),
      ], '人人视频');
      attach();
      backend.at(100);
      await drain();
      backend.at(101);
      await drain();
      expect(rendered, ['未来弹幕']);
      final before = clears;
      backend.at(10, playing: false, buffering: true);
      await drain();
      expect(clears, greaterThan(before));
      expect(rendered, isEmpty);
      expect(controller.clock.previous, 10);
      backend.at(11);
      await drain();
      expect(rendered, ['目标弹幕']);
    },
  );
  test(
    'held paused rewind debounces window downloads until the seek settles',
    () async {
      final timeline = _Timeline();
      controller = CinemaDanmakuController(
        _Player(backend),
        store,
        'held',
        autoQuery: const CinemaLogvarQuery(title: '测试剧集', series: true),
        directClientFactory: () => _Matcher(timeline),
      );
      await controller.loadAutomatic();
      for (var at = 240; at >= 230; at--) {
        backend.at(at.toDouble(), playing: false);
        await drain();
      }
      expect(timeline.loads, 0);
      await timeline.requested.future.timeout(const Duration(seconds: 1));
      expect(timeline.loads, 1);
      timeline.pending.complete(
        CinemaDanmakuWindow([comment(231, '定位后弹幕')], 200, 380),
      );
      await drain();
    },
  );
  test(
    'late forward prefetch cannot replace the window after rewinding into the old window',
    () async {
      final timeline = _Timeline();
      controller = CinemaDanmakuController(
        _Player(backend),
        store,
        'prefetch',
        autoQuery: const CinemaLogvarQuery(title: '测试剧集', series: true),
        directClientFactory: () => _Matcher(timeline),
      );
      await controller.loadAutomatic();
      attach();
      backend.at(100);
      await drain();
      backend.at(140);
      await timeline.requested.future;
      backend.at(40);
      await drain();
      timeline.pending.complete(
        CinemaDanmakuWindow([comment(141, '过期预取')], 110, 290),
      );
      await drain();
      await drain();
      expect(timeline.token?.isCancelled, true);
      expect(
        controller.entries.any((entry) => entry.message == '回退后应再次显示'),
        true,
      );
      backend.at(41);
      await drain();
      expect(rendered, ['回退后应再次显示']);
    },
  );
}
