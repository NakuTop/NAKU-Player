import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_offline_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_multi_source_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';

DanmakuEntry comment(double time, String text) => DanmakuEntry(
  message: text,
  time: time,
  type: 1,
  color: Colors.white,
  source: '[fixture]',
);

class Timeline implements CinemaDanmakuTimeline {
  final calls = <double>[];
  @override
  double get endSeconds => 600;
  @override
  Future<CinemaDanmakuWindow> window(
    double at, {
    CancelToken? cancelToken,
  }) async {
    calls.add(at);
    return CinemaDanmakuWindow(
      [comment(at + 1, '分片${at.toInt()}')],
      at - 30,
      at + 150,
    );
  }

  @override
  void close() {}
}

class Matcher implements CinemaMultiSourceDanmakuMatcher {
  final timeline = Timeline();
  Set<String>? requested;
  bool closed = false;
  @override
  Future<void> matchSources(
    CinemaLogvarQuery query, {
    required Set<String> sources,
    required void Function(CinemaDanmakuSourceResult) onSource,
    CancelToken? cancelToken,
  }) async {
    requested = sources;
    for (final id in sources) {
      onSource(
        CinemaDanmakuSourceResult(
          id,
          id == 'renren' || id == 'aiyifan'
              ? CinemaDanmakuSourceStatus.loaded
              : CinemaDanmakuSourceStatus.unavailable,
          id == 'renren' || id == 'aiyifan'
              ? CinemaLogvarSelection(
                  const CinemaLogvarWork(id: 1, title: '测试'),
                  const CinemaLogvarEpisode(1, '第1集', 1),
                  id == 'renren'
                      ? [comment(3, '人人开头'), comment(580, '人人结尾')]
                      : [],
                  600,
                  timeline: id == 'aiyifan' ? timeline : null,
                )
              : null,
        ),
      );
    }
  }

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async => null;
  @override
  void close() => closed = true;
}

class Backend extends PlatformPlayer {
  Backend() : super(configuration: const PlayerConfiguration());
}

class FakePlayer implements Player {
  FakePlayer(this.backend);
  final Backend backend;
  @override
  PlayerStream get stream => backend.stream;
  @override
  PlayerState get state => backend.state;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('naku-offline-test-'),
  );
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  Future<Matcher> capture() async {
    final matcher = Matcher();
    await CinemaOfflineDanmaku.capture(
      episodeDirectory: directory.path,
      identity: 'movie|episode1',
      query: const CinemaLogvarQuery(title: '测试影片'),
      client: matcher,
      cancelToken: CancelToken(),
    );
    return matcher;
  }

  test(
    'snapshot traverses the entire timeline, keeps both sources and survives seeking backwards',
    () async {
      final stale = await Directory(
        '${directory.path}/.danmaku-crashed',
      ).create();
      final matcher = await capture();
      expect(await stale.exists(), false);
      expect(matcher.requested, cinemaSelectableDanmakuSources.keys.toSet());
      expect(matcher.closed, true);
      expect(matcher.timeline.calls, [0, 150, 300, 450]);
      final snapshot = (await CinemaOfflineDanmaku.open(
        directory.path,
        'movie|episode1',
      ))!;
      expect(
        await CinemaOfflineDanmaku.open(directory.path, 'different-episode'),
        isNull,
      );
      final timeline = snapshot.timeline({'renren', 'aiyifan'});
      final end = await timeline.window(560);
      expect(end.entries.map((e) => e.message), contains('人人结尾'));
      final start = await timeline.window(0);
      expect(start.entries.map((e) => e.source).toSet(), {
        '[renren]',
        '[aiyifan]',
      });
      timeline.select({'aiyifan'});
      expect(
        (await timeline.window(440)).entries.map((e) => e.source).toSet(),
        {'[aiyifan]'},
      );
      timeline.close();
      final repeat = await capture();
      expect(repeat.requested, isNull); // Immutable download-time snapshot.
    },
  );
  test(
    'offline controller restores and filters sources without invoking network matchers',
    () async {
      await capture();
      final store = CinemaStore(
        file: File('${directory.path}/library.json'),
        defaults: const [],
      );
      await store.load();
      final backend = Backend();
      var networkCalls = 0;
      final controller = CinemaDanmakuController(
        FakePlayer(backend),
        store,
        'movie|episode1',
        offlineDirectory: directory.path,
        autoQuery: const CinemaLogvarQuery(title: '测试影片'),
        directClientFactory: () {
          networkCalls++;
          return Matcher();
        },
      );
      await controller.ready;
      expect(controller.entries.map((e) => e.source).toSet(), {
        '[renren]',
        '[aiyifan]',
      });
      await controller.setSelectedSources({'renren'});
      expect(controller.entries.map((e) => e.source).toSet(), {'[renren]'});
      await controller.setSelectedSources({'aiyifan', 'youku'});
      expect(controller.entries.map((e) => e.source).toSet(), {'[aiyifan]'});
      await controller.loadAutomatic(force: true);
      expect(networkCalls, 0);
      await controller.close();
      await backend.dispose();
      await store.flush();
      store.dispose();
    },
  );
  test(
    'queue is serial, delete cancels active work before files are removed and skips queued work',
    () async {
      final queue = CinemaOfflineDanmakuQueue();
      final started = Completer<void>();
      final finished = Completer<void>();
      var second = 0;
      queue.schedule('first', (token) async {
        started.complete();
        await token.whenCancel;
        finished.complete();
      });
      queue.schedule('second', (_) async {
        second++;
      });
      await started.future;
      await queue.cancel('second');
      await queue.cancel('first');
      expect(finished.isCompleted, true);
      await Future<void>.delayed(Duration.zero);
      expect(second, 0);
    },
  );
  test('a cancelled capture cannot commit a snapshot', () async {
    final token = CancelToken()..cancel();
    final matcher = Matcher();
    await expectLater(
      CinemaOfflineDanmaku.capture(
        episodeDirectory: directory.path,
        identity: 'movie|episode1',
        query: const CinemaLogvarQuery(title: '测试'),
        client: matcher,
        cancelToken: token,
      ),
      throwsA(isA<DioException>()),
    );
    expect(matcher.closed, true);
    expect(
      await CinemaOfflineDanmaku.open(directory.path, 'movie|episode1'),
      isNull,
    );
  });
}
