import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/bilibili_anime_danmaku_dialog.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/bilibili_anime_matcher.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

BangumiItem _subject() => BangumiItem.fromJson({
  'id': 328609,
  'name': 'ぼっち・ざ・ろっく！',
  'name_cn': '孤独摇滚！',
  'date': '2022-10-08',
  'images': <String, String>{},
  'rating': <String, dynamic>{},
});

class _Client extends BilibiliDanmakuClient {
  final requestedCids = <int>[];
  final requestedVideos = <String>[];
  List<BilibiliAnimeCandidate> searchResults = const [];
  int searches = 0;
  Future<List<DanmakuEntry>> Function(int)? commentLoader;
  BilibiliDanmakuVideo details = const BilibiliDanmakuVideo('孤独摇滚！', [
    BilibiliDanmakuPage(99, '预告'),
    BilibiliDanmakuPage(101, '1 开始', episodeNumber: 1),
    BilibiliDanmakuPage(102, '2 后续', episodeNumber: 2),
  ], 0);
  @override
  Future<List<BilibiliAnimeCandidate>> searchAnime(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    searches++;
    return searchResults;
  }

  @override
  Future<BilibiliDanmakuVideo> video(
    String input, {
    CancelToken? cancelToken,
  }) async {
    requestedVideos.add(input);
    return details;
  }

  @override
  Future<List<DanmakuEntry>> comments(
    int cid, {
    CancelToken? cancelToken,
  }) async {
    requestedCids.add(cid);
    return commentLoader?.call(cid) ?? [_entry(cid)];
  }
}

DanmakuEntry _entry(int cid) => DanmakuEntry(
  message: 'episode-$cid',
  time: 1,
  type: 1,
  color: Colors.white,
  source: '[BiliBili]',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, temp;
  late PathProviderPlatform oldPaths;
  late _Client client;
  late BilibiliAnimeMatcher matcher;
  Future<Map<String, List<String>>> mappings() async => {
    '328609': ['md42'],
  };
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('naku-auto-danmaku-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    Hive.init('${root.path}/hive');
    await GStorage.init();
  });
  setUp(() async {
    temp = await root.createTemp('case-');
    client = _Client();
    matcher = BilibiliAnimeMatcher(
      client: client,
      directory: temp,
      mappingLoader: mappings,
    );
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  test(
    'automatic display defaults on but a saved manual off remains authoritative',
    () async {
      await GStorage.resetSettings([SettingsKeys.danmakuEnabledByDefault]);
      expect(GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault), isTrue);
      await GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, false);
      expect(
        GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault),
        isFalse,
      );
      await GStorage.resetSettings([SettingsKeys.danmakuEnabledByDefault]);
    },
  );

  test(
    'exact subject mapping loads current episode and ignores PV list position',
    () async {
      final result = await matcher.load(_subject(), 2);
      expect(result.single.message, 'episode-102');
      expect(client.requestedCids, [102]);
      expect(client.requestedVideos, ['md42']);
      expect(client.searches, 0);
    },
  );

  test(
    'missing or duplicate episode numbers never silently use list index',
    () async {
      for (final pages in [
        [
          const BilibiliDanmakuPage(99, 'PV'),
          const BilibiliDanmakuPage(103, '3', episodeNumber: 3),
        ],
        [
          const BilibiliDanmakuPage(100, '1', episodeNumber: 1),
          const BilibiliDanmakuPage(101, '1 repeat', episodeNumber: 1),
        ],
      ]) {
        client.details = BilibiliDanmakuVideo('fixture', pages, 0);
        final isolated = BilibiliAnimeMatcher(
          client: client,
          directory: temp,
          mappingLoader: mappings,
        );
        await expectLater(isolated.load(_subject(), 1), throwsFormatException);
      }
      expect(client.requestedCids, isEmpty);
    },
  );

  test(
    'search keeps season and year distinctions and does not choose fuzzy names',
    () async {
      client.searchResults = const [
        BilibiliAnimeCandidate('ss1', '孤独摇滚！', year: 2022),
        BilibiliAnimeCandidate('ss2', '孤独摇滚 第二季', year: 2026),
        BilibiliAnimeCandidate('ss3', '孤独摇滚！', year: 2024),
      ];
      matcher = BilibiliAnimeMatcher(
        client: client,
        directory: temp,
        mappingLoader: () async => {},
      );
      expect((await matcher.discover(_subject())).automatic?.reference, 'ss1');
      client.searchResults = const [
        BilibiliAnimeCandidate('ss2', '孤独摇滚 第二季', year: 2026),
        BilibiliAnimeCandidate('ss3', '孤独摇滚！', year: 2024),
      ];
      expect((await matcher.discover(_subject())).automatic, isNull);
    },
  );

  test(
    'multiple exact versions require selection and never fetch random comments',
    () async {
      client.searchResults = const [
        BilibiliAnimeCandidate('ss1', '孤独摇滚！', year: 2022),
        BilibiliAnimeCandidate('ss2', '孤独摇滚！', year: 2022),
      ];
      matcher = BilibiliAnimeMatcher(
        client: client,
        directory: temp,
        mappingLoader: () async => {},
      );
      await expectLater(matcher.load(_subject(), 1), throwsFormatException);
      expect(client.requestedCids, isEmpty);
    },
  );

  test(
    'manual version and episode offset survive restart; cached text works offline',
    () async {
      client.details = const BilibiliDanmakuVideo('第2部分', [
        BilibiliDanmakuPage(113, '13', episodeNumber: 13),
      ], 0);
      await matcher.remember(
        328609,
        const BilibiliAnimeCandidate('ss9', '第2部分'),
        12,
      );
      expect((await matcher.load(_subject(), 1)).single.message, 'episode-113');
      final offline = _Client()
        ..commentLoader = (_) => throw StateError('Network must not run');
      final reopened = BilibiliAnimeMatcher(
        client: offline,
        directory: temp,
        mappingLoader: () =>
            throw StateError('Known binding avoids mapping and search'),
      );
      expect(
        (await reopened.load(_subject(), 1)).single.message,
        'episode-113',
      );
      expect(offline.requestedVideos, isEmpty);
      expect(offline.searches, 0);
    },
  );

  test(
    'a late automatic load never overwrites a newer explicit selection',
    () async {
      final started = Completer<void>(),
          pending = Completer<List<DanmakuEntry>>();
      client.commentLoader = (_) {
        started.complete();
        return pending.future;
      };
      final old = matcher.load(_subject(), 1);
      await started.future;
      await matcher.remember(
        328609,
        const BilibiliAnimeCandidate('ss8', '用户选择版本'),
        0,
      );
      pending.complete([_entry(101)]);
      await old;
      expect((await matcher.discover(_subject())).automatic?.reference, 'ss8');
    },
  );

  test(
    'duplicate episode loads share requests and private playback writes no history cache',
    () async {
      final a = matcher.load(_subject(), 1, persist: false);
      final b = matcher.load(_subject(), 1, persist: false);
      await Future.wait([a, b]);
      expect(client.requestedCids, [101]);
      expect(await temp.list(recursive: true).toList(), isEmpty);
    },
  );

  test(
    'production player automatically loads and switches anime episodes without credentials',
    () async {
      final player = PlayerDanmakuController(
        isLocalPlayback: () => false,
        downloadController: _Downloads(),
        bilibiliMatcher: matcher,
        localStore: LocalDanmakuStore(
          directory: Directory('${temp.path}/manual'),
        ),
      );
      for (final episode in [1, 2]) {
        final result = await player.fetchDanmaku(
          328609,
          'fixture',
          episode,
          subject: _subject(),
        );
        expect(result.hasDanmakus, isTrue, reason: result.failureMessage);
        expect(result.danmakus.single.message, 'episode-${100 + episode}');
      }
      expect(client.requestedCids, [101, 102]);
    },
  );

  testWidgets(
    'matching dialog starts from current anime and episode without a URL',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<DanmakuEntry>? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await showDialog<List<DanmakuEntry>>(
                    context: context,
                    builder: (_) => BilibiliAnimeDanmakuDialog(
                      subject: _subject(),
                      episode: 2,
                      matcher: matcher,
                    ),
                  );
                },
                child: const Text('修正匹配'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('修正匹配'));
      await tester.pump();
      await _completeIo(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '孤独摇滚！',
      );
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        2,
      );
      expect(find.text('视频链接 / BV、av、ep、ss 编号'), findsNothing);
      await tester.tap(find.text('应用到本集'));
      await _completeIo(tester);
      await tester.pumpAndSettle();
      expect(chosen?.single.message, 'episode-102');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _completeIo(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('The matching dialog did not complete its local file operations');
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Downloads extends Fake implements DownloadController {}
