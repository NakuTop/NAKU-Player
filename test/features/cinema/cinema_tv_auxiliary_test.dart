import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_tracks_sheet.dart';
import 'package:kazumi/features/cinema/cinema_tv_auxiliary.dart';
import 'package:kazumi/features/cinema/cinema_tv_application.dart';
import 'package:kazumi/services/platform/naku_device.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      position: const Duration(seconds: 42),
      playing: true,
      tracks: const Tracks(
        audio: [AudioTrack('1', '隐藏的音轨', 'zh')],
        subtitle: [
          SubtitleTrack('no', null, null),
          SubtitleTrack('3', '内嵌中文', 'zh'),
        ],
      ),
    );
  }
  SubtitleTrack? applied;
  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    applied = track;
    state = state.copyWith(
      track: Track(audio: state.track.audio, subtitle: track),
    );
    trackController.add(state.track);
  }
}

class _Player implements Player {
  _Player(this.backend);
  final _Backend backend;
  @override
  PlatformPlayer get platform => backend;
  @override
  PlayerState get state => backend.state;
  @override
  PlayerStream get stream => backend.stream;
  @override
  Future<void> pause() => backend.pause();
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      backend.setSubtitleTrack(track);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SubtitleClient extends CinemaOnlineSubtitles {
  CinemaSubtitleQuery? query;
  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String title,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>>)? onVerified,
  }) async {
    query = CinemaSubtitleQuery(title, type, season, episode);
    return CinemaSubtitleCatalogResult([
      {
        'url': 'https://subs.example/fixture.srt',
        'lang': 'zho',
        'provider': '测试字幕源',
        'subtitleFileName': 'Fixture.S02E03.srt',
        'verified': true,
      },
    ], const {});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async =>
      '1\n00:00:01,000 --> 00:00:03,000\n自写测试字幕\n';
}

class _Matcher implements CinemaDanmakuMatcher {
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async => null;
  @override
  void close() {}
}

void main() {
  late Directory temp;
  late CinemaStore store;
  late _Backend backend;
  late _Player player;
  setUp(() async {
    NakuDevice.isTV = true;
    temp = await Directory.systemTemp.createTemp('naku-tv-aux-test-');
    store = CinemaStore(
      file: File('${temp.path}/store.json'),
      defaults: const [],
    );
    await store.load();
    backend = _Backend();
    player = _Player(backend);
    cinemaExternalSubtitleState(player);
  });
  tearDown(() async {
    NakuDevice.isTV = false;
    await closeCinemaExternalSubtitles(player);
    await backend.dispose();
    await store.flush();
    store.dispose();
    await temp.delete(recursive: true);
  });
  Future<void> size(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'TV nested subtitle input suspends player keys and stays below Home Display',
    (tester) async {
      await size(tester);
      final app = GlobalKey<CinemaTVApplicationState>();
      late ModalRoute<dynamic> playerRoute;
      var interceptedPlayerKeys = 0;
      KeyEventResult playerKeyProbe(KeyEvent event) {
        if (playerRoute.isCurrent &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          interceptedPlayerKeys++;
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: CinemaTheme.data,
          home: CinemaTVApplication(
            key: app,
            now: () => Duration.zero,
            screensaverBuilder: (_) => const Scaffold(body: Text('嵌套屏保探针')),
            home: Builder(
              builder: (context) {
                playerRoute = ModalRoute.of(context)!;
                return Scaffold(
                  body: FilledButton(
                    autofocus: true,
                    onPressed: () => showCinemaTracksSheet(
                      context,
                      player,
                      store,
                      title: '测试影片',
                    ),
                    child: const Text('打开字幕面板'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      FocusManager.instance.addEarlyKeyEventHandler(playerKeyProbe);
      addTearDown(
        () => FocusManager.instance.removeEarlyKeyEventHandler(playerKeyProbe),
      );
      await tester.tap(find.text('打开字幕面板'));
      await tester.pumpAndSettle();
      final tracksContext = tester.element(find.byType(CinemaTracksPanel));
      final tracksRoute = ModalRoute.of(tracksContext)!;
      expect(playerRoute.isCurrent, isFalse);
      expect(tracksRoute.isCurrent, isTrue);
      await tester.tap(find.byKey(const ValueKey('tv-online-subtitle-entry')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('tv-subtitle-query'));
      final inputContext = tester.element(field);
      final inputRoute = ModalRoute.of(inputContext)!;
      expect(playerRoute.isCurrent, isFalse);
      expect(tracksRoute.isCurrent, isFalse);
      expect(inputRoute.isCurrent, isTrue);
      await tester.enterText(field, '测试影片XYZ');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(interceptedPlayerKeys, 0);
      expect(
        tester.widget<TextField>(field).controller!.selection.baseOffset,
        lessThan('测试影片XYZ'.length),
      );
      unawaited(app.currentState!.showScreensaver());
      await tester.pumpAndSettle();
      expect(find.text('嵌套屏保探针'), findsOneWidget);
      expect(inputRoute.isCurrent, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(inputRoute.isCurrent, isTrue);
      expect(tester.widget<TextField>(field).controller!.text, '测试影片XYZ');
      Navigator.of(inputContext).pop();
      await tester.pumpAndSettle();
      expect(tracksRoute.isCurrent, isTrue);
      expect(
        Focus.of(
          tester.element(
            find.byKey(const ValueKey('tv-online-subtitle-entry')),
          ),
        ).hasFocus,
        isTrue,
      );
      Navigator.of(tracksContext).pop();
      await tester.pumpAndSettle();
      expect(playerRoute.isCurrent, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(interceptedPlayerKeys, 1);
      FocusManager.instance.removeEarlyKeyEventHandler(playerKeyProbe);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV native embedded subtitles do not offer unsupported delay actions',
    (tester) async {
      await size(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: CinemaTheme.data,
          home: Scaffold(
            body: CinemaTracksPanel(
              player: player,
              store: store,
              title: '测试影片',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('内嵌中文'), findsOneWidget);
      expect(find.text('关闭字幕'), findsOneWidget);
      expect(find.text('提前 0.5 秒'), findsNothing);
      expect(find.text('延后 0.5 秒'), findsNothing);
      expect(find.text('偏移归零'), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'TV tracks exposes subtitles only and remote offset does not seek',
    (tester) async {
      await size(tester);
      final session = cinemaExternalSubtitleState(player);
      session.select(
        '1\n00:00:01,000 --> 00:00:03,000\n测试字幕\n',
        'fixture',
        'external',
        0,
        title: '测试外挂字幕',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: CinemaTheme.data,
          home: Scaffold(
            body: CinemaTracksPanel(
              player: player,
              store: store,
              title: '测试影片',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tv-online-subtitle-entry')),
        findsOneWidget,
      );
      expect(find.text('字幕与音轨'), findsNothing);
      expect(find.text('隐藏的音轨'), findsNothing);
      expect(find.byType(Slider), findsNothing);
      await tester.ensureVisible(find.text('延后 0.5 秒'));
      await tester.tap(find.text('延后 0.5 秒'));
      await tester.pumpAndSettle();
      expect(session.delay, .5);
      expect(player.state.position, const Duration(seconds: 42));
      await tester.ensureVisible(find.text('偏移归零'));
      await tester.tap(find.text('偏移归零'));
      await tester.pumpAndSettle();
      expect(session.delay, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'TV subtitle search uses current season episode and applies without resuming',
    (tester) async {
      await size(tester);
      final client = _SubtitleClient();
      addTearDown(client.close);
      var remembered = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: CinemaTheme.data,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showCinemaTVPanel<void>(
                  context,
                  title: '字幕搜索',
                  width: 760,
                  builder: (_) => CinemaOnlineSubtitlesPanel(
                    player: player,
                    title: '测试剧集',
                    category: '剧集',
                    episodeName: 'S02E03',
                    episodeNumber: 3,
                    client: client,
                    onApplied: (_) async {
                      remembered = true;
                    },
                  ),
                ),
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开搜索'));
      await tester.pumpAndSettle();
      expect(find.text('当前：第 2 季 · 第 3 集'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(client.query?.season, 2);
      expect(client.query?.episode, 3);
      expect(find.textContaining('测试字幕源'), findsOneWidget);
      await tester.ensureVisible(find.text('Fixture.S02E03.srt'));
      await tester.tap(find.text('Fixture.S02E03.srt'));
      await tester.pumpAndSettle();
      expect(backend.applied?.title, 'Fixture.S02E03.srt');
      expect(remembered, isTrue);
      expect(player.state.playing, isFalse);
      expect(player.state.position, const Duration(seconds: 42));
      expect(find.text('打开搜索'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('TV nested danmaku correction and remote presets remain modal', (
    tester,
  ) async {
    await size(tester);
    late CinemaDanmakuController controller;
    await tester.runAsync(() async {
      controller = CinemaDanmakuController(
        player,
        store,
        'fixture',
        autoQuery: const CinemaLogvarQuery(
          title: '测试剧集',
          year: '2026',
          series: true,
          season: 2,
          episode: 3,
        ),
        directClientFactory: _Matcher.new,
      );
      await controller.ready;
    });
    late ModalRoute<dynamic> playerRoute;
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: CinemaTVApplication(
          now: () => Duration.zero,
          home: Builder(
            builder: (context) {
              playerRoute = ModalRoute.of(context)!;
              return Scaffold(
                body: FilledButton(
                  autofocus: true,
                  onPressed: () => showCinemaDanmakuSheet(context, controller),
                  child: const Text('打开弹幕面板'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开弹幕面板'));
    await tester.pumpAndSettle();
    final panelRoute = ModalRoute.of(
      tester.element(find.byType(CinemaDanmakuStylePanel)),
    )!;
    expect(playerRoute.isCurrent, isFalse);
    expect(panelRoute.isCurrent, isTrue);
    await tester.tap(find.byKey(const ValueKey('tv-danmaku-correct')));
    await tester.pumpAndSettle();
    expect(playerRoute.isCurrent, isFalse);
    expect(panelRoute.isCurrent, isFalse);
    expect(
      ModalRoute.of(
        tester.element(find.byKey(const ValueKey('danmaku-match-title'))),
      )!.isCurrent,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('danmaku-match-title')),
      '电视更正测试',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('danmaku-match-title')))
          .controller!
          .selection
          .baseOffset,
      lessThan('电视更正测试'.length),
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(panelRoute.isCurrent, isTrue);
    expect(find.byType(Slider), findsNothing);
    expect(find.textContaining('第 2 季 第 3 集'), findsOneWidget);
    expect(controller.fontSize, 28);
    await tester.ensureVisible(find.text('字号：28'));
    await tester.runAsync(() async {
      await tester.tap(find.text('字号：28'));
      await store.flush();
    });
    await tester.pumpAndSettle();
    expect(controller.fontSize, 30);
    await tester.ensureVisible(
      find.byKey(const ValueKey('tv-danmaku-enabled')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('tv-danmaku-enabled')));
      await store.flush();
    });
    await tester.pumpAndSettle();
    expect(controller.enabled, isFalse);
    expect(controller.automaticMatching, isFalse);
    expect(store.extras['cinemaDanmakuEnabled'], isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => controller.close());
  });
}
