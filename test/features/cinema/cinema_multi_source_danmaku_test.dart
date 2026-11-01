import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_multi_source_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';

const query = CinemaLogvarQuery(
  title: '测试剧集',
  series: true,
  episode: 2,
  year: '2024',
);
DanmakuEntry comment(double at, String text) => DanmakuEntry(
  time: at,
  message: text,
  type: 1,
  color: const Color(0xffffffff),
  source: '[fixture]',
);
CinemaLogvarSelection selection(
  String id,
  List<DanmakuEntry> entries, {
  CinemaDanmakuTimeline? timeline,
}) => CinemaLogvarSelection(
  CinemaLogvarWork(id: id.hashCode, title: query.title),
  const CinemaLogvarEpisode(2, '第2集', 2),
  entries,
  1800,
  provider: cinemaSelectableDanmakuSources[id]!,
  timeline: timeline,
  windowStart: 0,
  windowEnd: 150,
);

class _Matcher implements CinemaDanmakuMatcher {
  _Matcher(this.reply);
  final Future<CinemaLogvarSelection?> Function(CancelToken?) reply;
  var closed = false;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery q, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) => reply(cancelToken);
  @override
  void close() {
    closed = true;
  }
}

class _Timeline implements CinemaDanmakuTimeline {
  final calls = <double>[];
  @override
  double get endSeconds => 1800;
  @override
  Future<CinemaDanmakuWindow> window(
    double at, {
    CancelToken? cancelToken,
  }) async {
    calls.add(at);
    return CinemaDanmakuWindow([comment(at + 1, '分段弹幕')], at - 30, at + 150);
  }

  @override
  void close() {}
}

void main() {
  test(
    'selected overseas sources both finish; a fast source does not cancel the slower source',
    () async {
      final gate = Completer<CinemaLogvarSelection?>();
      final first = Completer<void>();
      final tokens = <String, CancelToken?>{};
      final results = <CinemaDanmakuSourceResult>[];
      final client = CinemaMultiSourceDanmakuClient(
        sourceFactory: (id) => _Matcher((token) async {
          tokens[id] = token;
          return id == 'renren'
              ? selection(id, [comment(2, '人人弹幕')])
              : gate.future;
        }),
      );
      addTearDown(client.close);
      final done = client.matchSources(
        query,
        sources: {'renren', 'aiyifan'},
        onSource: (r) {
          results.add(r);
          if (r.id == 'renren' && r.selection != null) first.complete();
        },
      );
      await first.future;
      expect(tokens.keys.toSet(), {'renren', 'aiyifan'});
      expect(tokens['aiyifan']!.isCancelled, false);
      gate.complete(selection('aiyifan', [comment(3, '爱一帆弹幕')]));
      await done;
      expect(
        results.where((r) => r.selection != null).map((r) => r.id).toSet(),
        {'renren', 'aiyifan'},
      );
    },
  );
  test(
    'only selected sources are created, cancellation stops active requests and queued work',
    () async {
      final started = Completer<void>();
      final ids = <String>[];
      final token = CancelToken();
      final client = CinemaMultiSourceDanmakuClient(
        sourceFactory: (id) {
          ids.add(id);
          return _Matcher((child) async {
            if (ids.length == 3 && !started.isCompleted) started.complete();
            final error = await child!.whenCancel;
            throw error;
          });
        },
      );
      addTearDown(client.close);
      final future = client.matchSources(
        query,
        sources: cinemaSelectableDanmakuSources.keys.toSet(),
        cancelToken: token,
        onSource: (_) {},
      );
      final assertion = expectLater(future, throwsA(isA<DioException>()));
      await started.future;
      expect(ids.length, 3);
      token.cancel('切集');
      await assertion;
      expect(
        ids.length,
        3,
        reason: 'cancelled batches must not launch queued lookups',
      );
    },
  );
  test(
    'one timeout or empty source does not remove a successful selected source',
    () async {
      final client = CinemaMultiSourceDanmakuClient(
        sourceTimeout: const Duration(milliseconds: 20),
        sourceFactory: (id) => _Matcher((token) async {
          if (id == 'renren') return selection(id, [comment(2, '可用弹幕')]);
          if (id == 'qq') return null;
          return Completer<CinemaLogvarSelection?>().future;
        }),
      );
      addTearDown(client.close);
      final results = <String, CinemaDanmakuSourceResult>{};
      await client.matchSources(
        query,
        sources: {'renren', 'aiyifan', 'qq'},
        onSource: (r) => results[r.id] = r,
      );
      expect(results['renren']!.status, CinemaDanmakuSourceStatus.loaded);
      expect(results['aiyifan']!.status, CinemaDanmakuSourceStatus.unavailable);
      expect(results['qq']!.status, CinemaDanmakuSourceStatus.empty);
    },
  );
  test(
    'merge orders and deduplicates selected sources; toggling keeps cached data; rewinding refills each timeline',
    () async {
      final segmented = _Timeline();
      final combined = CinemaCombinedDanmakuTimeline()
        ..add(
          'renren',
          selection('renren', [
            comment(11, '相同弹幕'),
            comment(12, '人人独有'),
            comment(501, '未来人人'),
          ]),
        )
        ..add(
          'aiyifan',
          selection('aiyifan', [
            comment(11, '相同弹幕'),
            comment(13, '爱一帆独有'),
            comment(502, '未来爱一帆'),
          ]),
        )
        ..add('qq', selection('qq', [comment(15, '初始分段')], timeline: segmented))
        ..select({'renren', 'aiyifan', 'qq'});
      addTearDown(combined.close);
      final first = await combined.window(10);
      expect(first.entries.map((e) => e.message), [
        '相同弹幕',
        '人人独有',
        '爱一帆独有',
        '初始分段',
      ]);
      final later = await combined.window(500);
      expect(
        later.entries.map((e) => e.message),
        containsAll(['未来人人', '未来爱一帆', '分段弹幕']),
      );
      final back = await combined.window(10);
      expect(
        back.entries.map((e) => e.message),
        containsAll(['相同弹幕', '人人独有', '爱一帆独有']),
      );
      expect(segmented.calls, [500, 10]);
      combined.select({'aiyifan'});
      final filtered = await combined.window(10);
      expect(filtered.entries.every((e) => e.source == '[aiyifan]'), true);
      expect(filtered.entries.map((e) => e.message), ['相同弹幕', '爱一帆独有']);
    },
  );
  test(
    'dense sources stay bounded without suppressing the smaller selected source',
    () async {
      final combined = CinemaCombinedDanmakuTimeline()
        ..add(
          'renren',
          selection('renren', [
            for (var i = 0; i < 12000; i++) comment(i / 100, '人人$i'),
          ]),
        )
        ..add('aiyifan', selection('aiyifan', [comment(10, '稀少来源也保留')]))
        ..select({'renren', 'aiyifan'});
      addTearDown(combined.close);
      final window = await combined.window(0);
      expect(window.entries.length, lessThanOrEqualTo(6000));
      expect(window.entries.any((e) => e.message == '稀少来源也保留'), true);
    },
  );
  test(
    'private or malformed media identifiers are rejected before any source is contacted',
    () async {
      var calls = 0;
      final client = CinemaMultiSourceDanmakuClient(
        sourceFactory: (_) {
          calls++;
          return _Matcher((_) async => null);
        },
      );
      addTearDown(client.close);
      for (final title in [
        'https://private.invalid/movie',
        '/Users/private/file',
        'bad\nname',
      ]) {
        await expectLater(
          client.matchSources(
            CinemaLogvarQuery(title: title),
            sources: {'renren', 'aiyifan'},
            onSource: (_) {},
          ),
          throwsFormatException,
        );
      }
      expect(calls, 0);
      await client.matchSources(
        const CinemaLogvarQuery(title: 'The Last of Us'),
        sources: {'renren'},
        onSource: (_) {},
      );
      expect(calls, 1);
    },
  );
  test(
    'explicitly empty selection stays empty while invalid preference keys are discarded',
    () {
      expect(cinemaDanmakuSourcesFrom([]), isEmpty);
      expect(cinemaDanmakuSourcesFrom(['renren', 'http://private', 1]), {
        'renren',
      });
      expect(
        cinemaDanmakuSourcesFrom(null),
        containsAll(['renren', 'aiyifan']),
      );
    },
  );
}
