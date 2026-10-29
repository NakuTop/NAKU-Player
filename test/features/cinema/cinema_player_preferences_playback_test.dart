import 'dart:async';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_nas_playback.dart';
import 'package:kazumi/features/cinema/cinema_mobile_playback_bar.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/platform/desktop_fullscreen.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/features/cinema/cinema_tv_session.dart';
import 'package:kazumi/features/cinema/cinema_tv_native_player.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_prefetch.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_player_entrance.dart';
import 'package:kazumi/features/cinema/cinema_player_preferences.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_ratings_panel.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';
import 'package:kazumi/features/cinema/cinema_video_gestures.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const _source = CinemaSource(
  id: 'fixture',
  name: 'Fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.invalid/api',
);
const _title = CinemaTitle(
  id: '1',
  sourceId: 'fixture',
  title: '播放偏好测试',
  routes: [
    CinemaRoute(
      name: 'mp4',
      episodes: [
        CinemaEpisode(name: '第1集', url: 'https://fixture.invalid/1.mp4'),
        CinemaEpisode(name: '第2集', url: 'https://fixture.invalid/2.mp4'),
      ],
    ),
    CinemaRoute(
      name: 'backup mp4',
      episodes: [
        CinemaEpisode(name: '第1集', url: 'https://fixture.invalid/backup.mp4'),
      ],
    ),
    CinemaRoute(
      name: 'manual mp4',
      episodes: [
        CinemaEpisode(name: '花絮', url: 'https://fixture.invalid/extra.mp4'),
      ],
    ),
  ],
);

class _PopObserver extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

class _Backend extends PlatformPlayer {
  _Backend(
    PlayerConfiguration configuration, {
    this.failOpen = false,
    this.emitVideo = true,
  }) : super(configuration: configuration);
  final bool failOpen;
  final bool emitVideo;
  void emitVideoDimensions() {
    widthController.add(1280);
    heightController.add(720);
  }

  Media? opened;
  int pauses = 0;
  final subtitles = <SubtitleTrack>[];
  bool disposed = false;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (failOpen) throw StateError('fixture route unavailable');
    opened = playable as Media;
    state = state.copyWith(
      playing: play,
      duration: const Duration(minutes: 20),
      position: opened!.start ?? Duration.zero,
    );
    durationController.add(state.duration);
    if (emitVideo) {
      widthController.add(1280);
      heightController.add(720);
    }
    positionController.add(state.position);
    playingController.add(play);
  }

  @override
  Future<void> setVolume(double value) async {
    state = state.copyWith(volume: value);
    volumeController.add(value);
  }

  @override
  Future<void> setRate(double value) async {
    state = state.copyWith(rate: value);
    rateController.add(value);
  }

  @override
  Future<void> seek(Duration value) async {
    state = state.copyWith(position: value);
    positionController.add(value);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  void reportBuffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }

  void reportBuffer(Duration value) {
    state = state.copyWith(buffer: value);
    bufferController.add(value);
  }

  void reportLog(PlayerLog event) => logController.add(event);

  void complete() {
    state = state.copyWith(completed: true, playing: false);
    completedController.add(true);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class _Player implements Player {
  _Player(this.backend);
  final _Backend backend;
  @override
  PlatformPlayer? get platform => backend;
  @override
  PlayerState get state => backend.state;
  @override
  PlayerStream get stream => backend.stream;
  @override
  Future<void> open(Playable media, {bool play = true}) =>
      backend.open(media, play: play);
  @override
  Future<void> setVolume(double value) => backend.setVolume(value);
  @override
  Future<void> setRate(double value) => backend.setRate(value);
  @override
  Future<void> seek(Duration value) => backend.seek(value);
  @override
  Future<void> play() => backend.play();
  @override
  Future<void> pause() => backend.pause();
  @override
  Future<void> playOrPause() => backend.playOrPause();
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    backend.subtitles.add(track);
  }

  @override
  Future<void> dispose() => backend.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository extends CinemaRepository {
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async => const CinemaPage(items: []);
}

class _EpisodeSubtitleClient extends CinemaOnlineSubtitles {
  _EpisodeSubtitleClient() : super(dio: Dio(), useFallbackCatalog: false);
  final requests = <Map<String, dynamic>>[];
  final downloads = <String>[];
  bool closed = false;

  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    requests.add({
      'query': query,
      'type': type,
      'imdbId': imdbId,
      'season': season,
      'episode': episode,
      'language': language,
    });
    final rows = <Map<String, dynamic>>[
      {
        'url': 'https://fixture.invalid/subtitle-$episode.srt',
        'subtitleFileName':
            'Fixture.S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}.简体.srt',
        'lang': 'zh',
        'verified': true,
        'provider': 'fixture',
      },
    ];
    onVerified?.call(rows);
    return CinemaSubtitleCatalogResult(rows, const {});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async {
    downloads.add(url);
    final episode = RegExp(r'subtitle-(\d+)\.srt').firstMatch(url)![1]!;
    return '1\n00:00:01,000 --> 00:00:02,000\n第 $episode 集的中文字幕\n';
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Ratings extends CinemaRatingsRepository {
  static const result = CinemaRatings(
    identity: RatingIdentity(),
    ratings: [],
    message: 'fixture',
  );
  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async =>
      result;
  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async => result;
}

class _Probe extends CinemaMediaProbe {
  _Probe() : super(transport: CinemaMediaTransport(dio: Dio()));
  final requests = <String, Completer<CinemaMediaProbeResult>>{};
  final tokens = <CancelToken>[];
  final calls = <String>[];
  @override
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) {
    calls.add(url);
    if (cancel != null) tokens.add(cancel);
    return requests
        .putIfAbsent(url, Completer<CinemaMediaProbeResult>.new)
        .future;
  }

  void complete() {
    for (final entry in requests.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          CinemaMediaProbeResult(
            ok: true,
            elapsedMs: 100,
            firstByteMs: 20,
            mbps: entry.key.contains('backup') ? 40 : 8,
          ),
        );
      }
    }
  }
}

class _Warmup {
  _Warmup(this.url, this.cancel);
  final String url;
  final CancelToken cancel;
  final finished = Completer<void>();
}

class _Cache extends CinemaMediaCache {
  final warmups = <_Warmup>[];

  @override
  Future<void> warmNext(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) {
    final request = _Warmup(url, cancel!);
    warmups.add(request);
    return request.finished.future;
  }

  void finish() {
    for (final request in warmups) {
      if (!request.finished.isCompleted) request.finished.complete();
    }
  }
}

class _NAS extends CinemaNASClient {
  bool routeChanged = false;
  final calls = <String>[];
  final starts = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    calls.add(method);
    if (method == 'autoConnect') {
      final changed = routeChanged;
      routeChanged = false;
      return {'changed': changed};
    }
    if (method == 'playbackOptions') {
      return {
        'isRelayOrigin': true,
        'profiles': [
          {'id': '1080P', 'label': '1080P'},
          {'id': '480P', 'label': '480P'},
        ],
        'audios': [
          {'id': 4354, 'label': '中文'},
        ],
        'subtitles': [
          {'id': -1, 'label': '关闭'},
          {'id': 6145, 'label': '中文'},
        ],
      };
    }
    if (method == 'startPlayback') {
      starts.add(Map.of(args!));
      return {
        'url': 'https://fixture.invalid/stream.m3u8?token=ephemeral',
        'taskId': 'task-${starts.length}',
        'resolution': args['resolution'],
        'audio': args['audio'] ?? 4354,
        'subtitle': args['subtitle'] ?? -1,
      };
    }
    if (method == 'closePlayback') return {};
    throw StateError(method);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    for (final family in ['Roboto', '.AppleSystemUIFont']) {
      final font = FontLoader(family)
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Light.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  late Directory directory;
  late CinemaStore store;
  late CinemaWatchTogether together;
  final backends = <_Backend>[];
  const channel = MethodChannel('window_manager');
  const visibilityChannel = MethodChannel('naku/cinema-player-window-test');
  late DesktopWindowControls windowControls;
  late Map<String, dynamic> nativeWindowState;
  final visibilityCalls = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'cinema-shared-preferences-',
    );
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    await store.load();
    together = CinemaWatchTogether(
      pairingFile: File('${directory.path}/pairing.json'),
      clientFactory: (_, _) => throw StateError('fixture must stay offline'),
    );
    await together.initialize();
    backends.clear();
    visibilityCalls.clear();
    nativeWindowState = {
      'registered': true,
      'hidden': false,
      'reduceTransparency': false,
    };
    messenger.setMockMethodCallHandler(visibilityChannel, (call) async {
      visibilityCalls.add(call.method);
      return Map.of(nativeWindowState);
    });
    windowControls = DesktopWindowControls(
      supported: true,
      channel: visibilityChannel,
      read: () => '{"pauseOnHide":true}',
      save: (_) async {},
    );
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isFullScreen' ? false : null,
    );
  });
  tearDown(() async {
    windowControls.dispose();
    messenger.setMockMethodCallHandler(visibilityChannel, null);
    messenger.setMockMethodCallHandler(channel, null);
    together.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    Map<String, Object?> values, {
    bool failFirst = false,
    bool stallFirst = false,
    Size viewport = const Size(1200, 900),
    Map<String, String>? offlinePaths,
    bool renderToolbar = false,
    bool withLibraryRoute = false,
    NavigatorObserver? navigatorObserver,
    bool? mobileControls,
    bool autoBest = false,
    CinemaMediaProbe? probe,
    CinemaMediaCache? cache,
    int? initialPosition,
    CinemaTitle? selectedTitle,
    CinemaSource? selectedSource,
    Player Function(PlayerConfiguration)? playerFactory,
    CinemaNASPlaybackClient? nasPlayback,
    Future<CinemaTitle> Function(CinemaTitle)? resolveNASRatings,
    CinemaOnlineSubtitles Function()? subtitleClientFactory,
    int initialEpisode = 0,
    Duration Function()? backgroundClock,
    VoidCallback? onSurfaceBuild,
  }) async {
    await windowControls.initialize();
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = CinemaPlayerPreferences.read(
      readSetting: <T>(SettingKey<T> key) =>
          (values.containsKey(key.name)
                  ? values[key.name]
                  : key.name == 'privateMode'
                  ? true
                  : key.defaultValue)
              as T,
      readShortcut: (name, defaults) =>
          name == 'shortcut_forward' ? ['L'] : defaults,
      isMetered: false,
    );
    final playbackPage = CinemaPlayerPage(
      title: selectedTitle ?? _title,
      episodeIndex: initialEpisode,
      subtitleClientFactory: subtitleClientFactory,
      nasPlayback: nasPlayback,
      mobileControls: mobileControls,
      resolveNASRatings: resolveNASRatings,
      autoSelectBestRoute: autoBest,
      backgroundPlaybackClock: backgroundClock,
      mediaProbe: probe,
      mediaCache: cache,
      initialPositionSeconds: initialPosition,
      offlinePaths: offlinePaths,
      source: selectedSource ?? _source,
      store: store,
      watchTogether: together,
      repository: _Repository(),
      ratingsRepository: _Ratings(),
      preferences: prefs,
      windowControls: windowControls,
      createPlayer:
          playerFactory ??
          (config) {
            final backend = _Backend(
              config,
              failOpen: failFirst && backends.isEmpty,
              emitVideo: !(stallFirst && backends.isEmpty),
            );
            backends.add(backend);
            return _Player(backend);
          },
      videoSurfaceBuilder: (_, player) {
        onSurfaceBuild?.call();
        return renderToolbar
            ? Builder(
                builder: (context) => Column(
                  children: [
                    Row(
                      children: MaterialDesktopVideoControlsTheme.of(
                        context,
                      ).normal.topButtonBar,
                    ),
                    Expanded(
                      child: StreamBuilder<bool>(
                        stream: player.stream.buffering,
                        initialData: false,
                        builder: (context, snapshot) {
                          final theme = MaterialDesktopVideoControlsTheme.of(
                            context,
                          ).normal;
                          if (snapshot.data == true) {
                            return theme.bufferingIndicatorBuilder?.call(
                                  context,
                                ) ??
                                const SizedBox();
                          }
                          return theme.primaryButtonBar.isEmpty
                              ? const Text('fake video')
                              : Row(children: theme.primaryButtonBar);
                        },
                      ),
                    ),
                    Row(
                      children: MaterialDesktopVideoControlsTheme.of(
                        context,
                      ).normal.bottomButtonBar.toList(),
                    ),
                  ],
                ),
              )
            : const SizedBox.expand(child: Text('fake video'));
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [?navigatorObserver],
        home: withLibraryRoute
            ? const Scaffold(body: Text('测试片库'))
            : playbackPage,
      ),
    );
    if (withLibraryRoute) {
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              PageRouteBuilder<void>(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, _, _) => playbackPage,
              ),
            ),
      );
      await tester.pump();
    }
    if (offlinePaths != null) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    if (stallFirst || probe != null) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  Future<void> waitForSubtitles(WidgetTester tester, _Backend backend) async {
    for (
      var attempt = 0;
      attempt < 100 && backend.subtitles.isEmpty;
      attempt++
    ) {
      // File I/O finishes outside the widget test's fake clock, while its
      // continuation must be pumped inside it. Wait for the actual selection.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(backend.subtitles, isNotEmpty);
  }

  Future<void> snapshotRecommendation(
    WidgetTester tester,
    String name, {
    Finder? target,
  }) async {
    final output = Platform.environment['NAKU_QA_SCREENSHOTS'];
    if (output == null) return;
    await tester.runAsync(() async {
      RenderObject? render = tester
          .element(
            target ?? find.byKey(const ValueKey('route-recommendation-main')),
          )
          .findRenderObject();
      RenderRepaintBoundary? boundary;
      while (render != null) {
        if (render is RenderRepaintBoundary) boundary = render;
        render = render.parent;
      }
      final image = await boundary!.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('buffering keeps only the spinner in the video center', (
    tester,
  ) async {
    await mount(tester, {}, renderToolbar: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 500));
    backends.single.reportBuffering(true);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('字幕与音轨'),
      findsNothing,
      reason: 'Buffering must not mount a second tools bar under the spinner',
    );
    expect(find.text('线路 / 选集'), findsNothing);
    expect(
      find.byTooltip('字幕与音轨'),
      findsWidgets,
      reason: 'Regular playback controls remain available',
    );
    backends.single.reportBuffering(false);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'Android phone exposes quality, tracks and online subtitles in a touch menu',
    (tester) async {
      await mount(
        tester,
        {},
        viewport: const Size(360, 800),
        mobileControls: true,
        renderToolbar: true,
      );
      expect(find.byType(CinemaMobilePlaybackBar), findsOneWidget);
      await tester.tap(find.byTooltip('播放工具'));
      await tester.pumpAndSettle();
      expect(find.text('在线搜索字幕'), findsWidgets);
      await tester.tap(find.text('在线搜索字幕').last);
      await tester.pumpAndSettle();
      expect(find.text('片名或 IMDb ID'), findsOneWidget);
      expect(backends.single.state.playing, isFalse);
      final pauses = backends.single.pauses;
      Navigator.of(
        tester.element(find.byType(CinemaOnlineSubtitlesPanel)),
      ).pop();
      await tester.pumpAndSettle();
      expect(find.byType(CinemaOnlineSubtitlesPanel), findsNothing);
      expect(backends.single.state.playing, isFalse);
      expect(backends.single.pauses, pauses);
      await unmount(tester);
    },
  );

  testWidgets(
    'player automatically loads each subsequent season episode into its own player',
    (tester) async {
      const title = CinemaTitle(
        id: 'season-subtitle-fixture',
        sourceId: 'fixture',
        title: '自动字幕测试 第十季',
        category: '电视剧',
        imdbId: 'tt1844624',
        routes: [
          CinemaRoute(
            name: 'mp4',
            episodes: [
              CinemaEpisode(
                name: 'S10E02',
                url: 'https://fixture.invalid/season-10-2.mp4',
              ),
              CinemaEpisode(
                name: 'S10E03',
                url: 'https://fixture.invalid/season-10-3.mp4',
              ),
              CinemaEpisode(
                name: 'S10E04',
                url: 'https://fixture.invalid/season-10-4.mp4',
              ),
            ],
          ),
        ],
      );
      await tester.runAsync(
        () => CinemaSeasonSubtitlePreferences(store).remember(
          seriesIdentity: title.key,
          season: 10,
          fromEpisode: 2,
          queryTitle: '自动字幕测试',
          imdbId: title.imdbId,
          row: const {
            'subtitleFileName': 'Fixture.S10E02.简体.srt',
            'lang': 'zh',
            'verified': true,
            'provider': 'fixture',
          },
        ),
      );
      final clients = <_EpisodeSubtitleClient>[];
      await mount(
        tester,
        {'autoPlay': true},
        selectedTitle: title,
        initialEpisode: 1,
        renderToolbar: true,
        subtitleClientFactory: () {
          final client = _EpisodeSubtitleClient();
          clients.add(client);
          return client;
        },
      );
      expect(backends.single.opened!.uri, endsWith('/season-10-3.mp4'));
      await waitForSubtitles(tester, backends.single);
      await tester.pumpAndSettle();
      final batch = CinemaSeasonSubtitlePrefetch.forStore(store);
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (batch.total > 0 && !batch.busy) break;
      }
      expect(batch.ready, 3);
      expect(
        clients
            .expand((client) => client.requests)
            .map((row) => row['episode']),
        unorderedEquals([2, 3, 4]),
        reason:
            'each episode is searched once, including foreground reuse of the background queue',
      );
      final clientsBeforeNext = clients.length;
      expect(backends.single.subtitles, hasLength(1));
      expect(backends.single.subtitles.single.id, contains('第 3 集的中文字幕'));
      expect(backends.single.subtitles.single.language, 'zh');
      final previous = backends.single;
      final previousClient = clients.first;
      final next = find.widgetWithIcon(IconButton, Icons.skip_next_rounded);
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(backends, hasLength(2));
      await waitForSubtitles(tester, backends.last);
      await tester.pumpAndSettle();
      expect(clients, hasLength(clientsBeforeNext + 1));
      expect(previous.disposed, isTrue);
      expect(previousClient.closed, isTrue);
      expect(previous.subtitles, hasLength(1));
      expect(backends.last.opened!.uri, endsWith('/season-10-4.mp4'));
      expect(
        clients.last.requests,
        isEmpty,
        reason: 'next episode must load from the season cache',
      );
      expect(clients.last.downloads, isEmpty);
      expect(backends.last.subtitles, hasLength(1));
      expect(backends.last.subtitles.single.id, contains('第 4 集的中文字幕'));
      expect(backends.last.subtitles.single.id, isNot(contains('第 3 集的中文字幕')));
      // Wait for the completed selection notice, which follows releasing the
      // owned pause and writing the selected file, rather than track arrival.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.textContaining('已从本季缓存加载').evaluate().isNotEmpty &&
            backends.last.state.playing) {
          break;
        }
      }
      expect(backends.last.state.playing, isTrue);
      await unmount(tester);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  testWidgets(
    'NAS quality is selectable before the first video frame and keeps resume intent',
    (tester) async {
      final nas = _NAS();
      final reference = nasMediaReference(
        namespace: 'a' * 64,
        id: 1,
        library: 1,
        path: '/movie.mkv',
      );
      final title = CinemaTitle(
        id: 'nas-stall',
        sourceId: cinemaNASSource.id,
        title: 'NAS stalled fixture',
        routes: [
          CinemaRoute(
            name: 'NAS',
            episodes: [CinemaEpisode(name: '电影', url: reference)],
          ),
        ],
      );
      await mount(
        tester,
        {'autoPlay': false},
        stallFirst: true,
        selectedTitle: title,
        nasPlayback: CinemaNASPlaybackClient(client: nas),
        initialPosition: 123,
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(nas.starts, hasLength(1));
      // The loading mask itself exposes a working quality selector.
      await tester.tap(find.text('清晰度').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('1080P').last);
      await tester.pumpAndSettle();
      expect(nas.starts, hasLength(2));
      expect(nas.starts.last['resolution'], '1080P');
      expect(backends.last.state.position.inSeconds, 123);
      expect(backends.last.state.playing, false);
      await unmount(tester);
    },
  );

  testWidgets(
    'NAS streaming retains resume, hide pause, and closes tasks on quality switch and exit',
    (tester) async {
      final nas = _NAS();
      final identity = Completer<CinemaTitle>();
      final reference = nasMediaReference(
        namespace: 'a' * 64,
        id: 1,
        library: 1,
        path: '/movie.mkv',
      );
      final title = CinemaTitle(
        id: 'nas-1',
        sourceId: cinemaNASSource.id,
        title: 'NAS fixture',
        routes: [
          CinemaRoute(
            name: 'NAS',
            episodes: [CinemaEpisode(name: '电影', url: reference)],
          ),
        ],
      );
      await mount(
        tester,
        {},
        selectedTitle: title,
        nasPlayback: CinemaNASPlaybackClient(client: nas),
        resolveNASRatings: (_) => identity.future,
        initialPosition: 123,
        renderToolbar: true,
      );
      expect(nas.starts.single['resolution'], '480P');
      identity.complete(title.copyWith(doubanId: '25662329'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CinemaRatingsPanel>(find.byType(CinemaRatingsPanel))
            .title
            .doubanId,
        '25662329',
      );
      expect(nas.starts.length, 1);
      expect(backends.single.opened!.uri, contains('stream.m3u8'));
      expect(backends.single.state.position.inSeconds, 123);
      expect(find.byType(CinemaNASInlinePlaybackControls), findsWidgets);
      expect(find.byTooltip('更多选项'), findsNothing);
      await tester.ensureVisible(find.text('清晰度').last);
      await tester.pumpAndSettle();
      await snapshotRecommendation(
        tester,
        'nas-detail-direct-controls',
        target: find.byType(CinemaPlayerPage),
      );
      await tester.ensureVisible(find.text('清晰度与 NAS 播放设置'));
      await tester.tap(find.text('清晰度与 NAS 播放设置'));
      await tester.pumpAndSettle();
      expect(find.text('NAS 清晰度、音轨与字幕'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1080P · NAS 流式输出').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用并保留播放进度'));
      await tester.pumpAndSettle();
      expect(nas.starts.length, 2);
      expect(nas.calls.where((v) => v == 'closePlayback').length, 1);
      expect(backends.last.state.position.inSeconds, 123);
      final fullscreenEntered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'enter-full-screen'}),
        ),
        (_) => fullscreenEntered.complete(),
      );
      await fullscreenEntered.future;
      await tester.pumpAndSettle();
      expect(find.byType(CinemaNASInlinePlaybackControls), findsWidgets);
      await snapshotRecommendation(
        tester,
        'nas-fullscreen-direct-controls',
        target: find.byType(CinemaPlayerPage),
      );
      expect(find.byTooltip('外挂字幕 / 播放器音轨'), findsOneWidget);
      expect(find.byTooltip('画中画'), findsWidgets);
      expect(find.byTooltip('更多选项'), findsNothing);
      backends.last.reportBuffering(true);
      await tester.pump();
      expect(find.byType(CinemaNASInlinePlaybackControls), findsWidgets);
      expect(find.text('清晰度'), findsWidgets);
      await tester.tap(find.text('清晰度').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('480P').last);
      await tester.pump(const Duration(milliseconds: 350));
      backends.last.reportBuffering(false);
      await tester.pumpAndSettle();
      expect(nas.starts.length, 3);
      expect(nas.starts.last['resolution'], '480P');
      expect(backends.last.state.position.inSeconds, 123);
      backends.last.reportBuffering(false);
      await tester.pump();
      nativeWindowState['hidden'] = true;
      await windowControls.refreshVisibility();
      await tester.pumpAndSettle();
      expect(backends.last.state.playing, false);
      nas.routeChanged = true;
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(nas.starts.length, 4);
      expect(backends.last.state.position.inSeconds, 123);
      expect(backends.last.state.playing, false);
      expect(nas.starts.last['resolution'], '480P');
      await unmount(tester);
      expect(nas.calls.where((v) => v == 'closePlayback').length, 4);
    },
  );

  Future<void> waitForProbe(WidgetTester tester, _Probe probe) async {
    for (var i = 0; i < 30 && probe.requests.length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(probe.requests.length, 2);
    expect(
      probe.requests.keys,
      isNot(contains('https://fixture.invalid/extra.mp4')),
    );
  }

  testWidgets(
    'opening a title automatically chooses measured best line once, retaining progress and pause state',
    (tester) async {
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(
        tester,
        {},
        autoBest: true,
        probe: probe,
        initialPosition: 77,
      );
      await waitForProbe(tester, probe);
      expect(find.text('正在寻找最优线路'), findsWidgets);
      await backends.single.seek(const Duration(seconds: 88));
      await backends.single.pause();
      await tester.pump();
      probe.complete();
      await tester.pumpAndSettle();
      expect(backends.length, 2);
      expect(backends.last.opened!.uri, 'https://fixture.invalid/backup.mp4');
      expect(backends.last.opened!.start, const Duration(seconds: 88));
      expect(backends.last.state.playing, isFalse);
      expect(find.text('本次最佳线路'), findsWidgets);
      expect(find.textContaining('40.0Mbps'), findsWidgets);
      expect(find.textContaining('已自动选择本次最佳线路'), findsWidgets);
      await snapshotRecommendation(tester, 'recommended-route-wide');
      await unmount(tester);
    },
  );

  testWidgets(
    'manual episode selection cancels automatic recommendation without reopening old episode',
    (tester) async {
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(tester, {}, autoBest: true, probe: probe);
      await waitForProbe(tester, probe);
      final episode = find.widgetWithText(OutlinedButton, '第2集');
      await tester.ensureVisible(episode);
      await tester.tap(episode);
      await tester.pump();
      probe.complete();
      await tester.pumpAndSettle();
      expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
      expect(
        backends.where((b) => b.opened?.uri.contains('backup') ?? false),
        isEmpty,
      );
      expect(find.text('本次最佳线路'), findsNothing);
      await unmount(tester);
    },
  );
  testWidgets(
    'explicitly keeping the current route cancels the pending automatic switch',
    (tester) async {
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(tester, {}, autoBest: true, probe: probe);
      await waitForProbe(tester, probe);
      final route = find.byKey(ValueKey('playback-route:${_title.key}:0'));
      await tester.ensureVisible(route);
      await tester.tap(route);
      await tester.pump();
      probe.complete();
      await tester.pumpAndSettle();
      expect(backends.length, 1);
      expect(backends.single.opened!.uri, 'https://fixture.invalid/1.mp4');
      expect(find.text('已手动选择，取消自动切换'), findsWidgets);
      await unmount(tester);
    },
  );
  testWidgets('recommended route remains readable in a narrow window', (
    tester,
  ) async {
    final probe = _Probe();
    addTearDown(() => probe.transport.dio.close(force: true));
    await mount(
      tester,
      {},
      autoBest: true,
      probe: probe,
      viewport: const Size(720, 900),
    );
    await waitForProbe(tester, probe);
    probe.complete();
    await tester.pumpAndSettle();
    final recommendation = find.byKey(
      const ValueKey('route-recommendation-main'),
    );
    await tester.ensureVisible(recommendation);
    expect(find.text('本次最佳线路'), findsWidgets);
    expect(find.text('40.0 Mbps'), findsWidgets);
    expect(tester.takeException(), isNull);
    await snapshotRecommendation(tester, 'recommended-route-narrow');
    await unmount(tester);
  });

  for (final autoPlay in [true, false]) {
    testWidgets(
      'cold-launch history resume keeps first Play and Space usable (autoPlay=$autoPlay)',
      (tester) async {
        await tester.runAsync(() async {
          await store.recordProgress(
            title: _title,
            routeIndex: 0,
            episodeIndex: 0,
            positionSeconds: 90,
            durationSeconds: 1200,
          );
          store.dispose();
          store = CinemaStore(
            file: File('${directory.path}/library.json'),
            defaults: [_source],
          );
          await store.load();
        });
        // Recreate the library and window bridge as on a fresh application
        // launch. A temporarily unordered native window is tested in the
        // production Swift controller check, before it is first shown.
        await mount(tester, {
          'autoPlay': autoPlay,
          'playResume': true,
          'playerDisableAnimations': true,
        }, renderToolbar: true);
        final player = backends.single;
        expect(player.opened!.start, const Duration(seconds: 90));
        expect(windowControls.blocksPlayback, isFalse);
        expect(player.state.playing, autoPlay);
        if (autoPlay) {
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(player.state.playing, isFalse);
        }
        await tester.tap(find.byTooltip('播放'));
        await tester.pumpAndSettle();
        expect(player.state.playing, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(player.state.playing, isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(player.state.playing, isTrue);
        expect(backends.length, 1);
        expect(visibilityCalls, isNot(contains('hide')));
        expect(visibilityCalls, isNot(contains('show')));
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'first Space and toolbar Play recover after a missed window restore notification',
    (tester) async {
      await mount(tester, {
        'autoPlay': false,
        'playerDisableAnimations': true,
      }, renderToolbar: true);
      final player = backends.single;
      Future<void> missedRestore() async {
        // Reproduce the cache left by a missing native restore notification;
        // native event dispatch/deduplication is covered in the bridge tests.
        windowControls.hidden = true;
        await player.pause();
        await tester.pump();
        expect(windowControls.blocksPlayback, isTrue);
        expect(player.state.playing, isFalse);
        nativeWindowState['hidden'] = false;
      }

      await missedRestore();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(visibilityCalls, contains('state'));
      expect(windowControls.blocksPlayback, isFalse);
      expect(player.state.playing, isTrue);
      await missedRestore();
      await tester.tap(find.byTooltip('播放'));
      await tester.pumpAndSettle();
      expect(windowControls.blocksPlayback, isFalse);
      expect(player.state.playing, isTrue);
      expect(
        backends.length,
        1,
        reason: 'Recovery must keep the existing decoder and episode.',
      );
      await unmount(tester);
    },
  );

  testWidgets('in-player PiP preserves playback and restores details', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isFullScreen' || call.method == 'isAlwaysOnTop') {
        return false;
      }
      if (call.method == 'getBounds') {
        return {'x': 80.0, 'y': 50.0, 'width': 1200.0, 'height': 900.0};
      }
      return null;
    });
    await mount(tester, {'autoPlay': true}, renderToolbar: true);
    expect(find.byType(CinemaRatingsPanel), findsOneWidget);
    await tester.tap(find.byTooltip('画中画'));
    await tester.pumpAndSettle();
    expect(
      find.byType(CinemaRatingsPanel),
      findsNothing,
      reason: calls.join(','),
    );
    expect(
      calls,
      containsAll([
        'getBounds',
        'setAlwaysOnTop',
        'setAspectRatio',
        'setBounds',
      ]),
    );
    expect(backends.single.state.playing, isTrue);
    await tester.tap(find.byTooltip('退出画中画'));
    await tester.pumpAndSettle();
    expect(find.byType(CinemaRatingsPanel), findsOneWidget);
    expect(backends.single.state.playing, isTrue);
    await unmount(tester);
  });

  testWidgets(
    'duration alone is not ready; repeated TLS failure advances before the startup deadline',
    (tester) async {
      await mount(tester, {'autoPlay': true}, stallFirst: true);
      expect(find.text('正在加载视频'), findsOneWidget);
      final first = backends.single;
      const failure = PlayerLog(
        prefix: 'tls',
        level: 'error',
        text: 'mbedtls_ssl_handshake returned -0x4e',
      );
      first.reportLog(failure);
      first.reportLog(failure);
      await tester.pump();
      final started = tester.binding.clock.now();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(
        tester.binding.clock.now().difference(started).inSeconds,
        lessThan(15),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(backends.length, 2);
      expect(backends.last.opened!.uri, endsWith('/backup.mp4'));
      expect(first.disposed, isTrue);
      await unmount(tester);
    },
  );

  testWidgets(
    'toolbar speed selection and next/previous actually reach the active player',
    (tester) async {
      await mount(tester, {'autoPlay': true}, renderToolbar: true);
      await tester.ensureVisible(find.byTooltip('倍速'));
      await tester.tap(find.byTooltip('倍速'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5×').last);
      await tester.pumpAndSettle();
      expect(backends.last.state.rate, 1.5);
      await tester.ensureVisible(find.byTooltip('下一集'));
      await tester.tap(find.byTooltip('下一集'));
      await tester.pumpAndSettle();
      expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
      expect(backends.last.state.rate, 1.5);
      await tester.ensureVisible(find.byTooltip('上一集'));
      await tester.tap(find.byTooltip('上一集'));
      await tester.pumpAndSettle();
      expect(backends.last.opened!.uri, 'https://fixture.invalid/1.mp4');
      expect(backends.last.state.rate, 1.5);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
            )
            .onPressed,
        isNull,
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'narrow player keeps episodes and extra controls reachable without overflow',
    (tester) async {
      await mount(
        tester,
        {'autoPlay': true},
        renderToolbar: true,
        viewport: const Size(440, 820),
      );
      expect(find.byTooltip('下一集'), findsOneWidget);
      expect(find.byTooltip('线路 / 选集'), findsOneWidget);
      expect(find.byTooltip('更多选项'), findsNothing);
      for (final label in ['下载选集', 'NAS 用户配对', '超分辨率']) {
        expect(find.text(label), findsWidgets);
      }
      expect(find.byTooltip('画中画'), findsWidgets);
      expect(find.byTooltip('倍速'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );

  for (final fullscreen in [false, true]) {
    testWidgets(
      'next episode is available in fullscreen=$fullscreen and disabled at end',
      (tester) async {
        await mount(tester, {'autoPlay': true}, renderToolbar: true);
        if (fullscreen) {
          final done = Completer<void>();
          messenger.handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onEvent', {'eventName': 'enter-full-screen'}),
            ),
            (_) => done.complete(),
          );
          await done.future;
          await tester.pumpAndSettle();
        }
        final next = find.widgetWithIcon(IconButton, Icons.skip_next_rounded);
        expect(next, findsOneWidget);
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
        expect(backends.last.state.playing, isTrue);
        expect(tester.widget<IconButton>(next).onPressed, isNull);
        await unmount(tester);
      },
    );
  }
  testWidgets(
    'offline media opens local file and shares original online history identity',
    (tester) async {
      final local = File('${directory.path}/offline.mp4');
      await tester.runAsync(() async {
        await local.writeAsBytes([0, 1, 2, 3]);
        await store.recordProgress(
          title: _title,
          routeIndex: 0,
          episodeIndex: 0,
          positionSeconds: 42,
          durationSeconds: 1200,
        );
      });
      await mount(
        tester,
        {'autoPlay': true, 'privateMode': false},
        offlinePaths: {'https://fixture.invalid/1.mp4': local.path},
      );
      expect(
        backends.single.opened!.uri.replaceAll('\\', '/'),
        local.path.replaceAll('\\', '/'),
      );
      expect(backends.single.state.position.inSeconds, 42);
      expect(find.text('离线播放'), findsOneWidget);
      await unmount(tester);
      expect(store.historyFor(_title)!.title.key, _title.key);
    },
  );

  testWidgets(
    'Windows fullscreen toggles immediately without AppKit events or reload',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(DesktopFullscreen.channel, null);
      });
      var full = false;
      final transitions = <bool>[];
      messenger.setMockMethodCallHandler(DesktopFullscreen.channel, (
        call,
      ) async {
        if (call.method == 'isFullscreen') return full;
        if (call.method == 'setFullscreen') {
          full = (call.arguments as Map)['isFullScreen'] as bool;
          transitions.add(full);
          return null; // No window_manager enter/leave animation events on Win32.
        }
        throw StateError('Unexpected native call');
      });
      await mount(tester, {'autoPlay': true});
      final player = backends.single;
      final originalSurface = tester.element(find.text('fake video'));
      await player.seek(const Duration(seconds: 90));
      for (var i = 0; i < 4; i++) {
        // Each pair starts after Flutter's double-click cooldown.
        await tester.pump(const Duration(milliseconds: 350));
        final surface = tester.getCenter(find.byType(CinemaVideoGestures));
        await tester.tapAt(surface);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(surface);
        await tester.pump(const Duration(milliseconds: 250));
        expect(transitions.length, i + 1);
        expect(player.state.playing, isTrue);
        expect(player.state.position.inSeconds, 90);
        expect(player.pauses, 0);
        expect(backends.length, 1);
        expect(
          identical(tester.element(find.text('fake video')), originalSurface),
          isTrue,
        );
      }
      expect(transitions, [true, false, true, false]);
      await unmount(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final initiallyPlaying in [true, false]) {
    testWidgets(
      'fullscreen entry and exit preserve playing=$initiallyPlaying without reloading',
      (tester) async {
        var fullScreen = false;
        final transitions = <bool>[];
        await mount(tester, {
          'autoPlay': initiallyPlaying,
          'backgroundPlayback': false,
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isFullScreen') return fullScreen;
          if (call.method == 'setFullScreen') {
            fullScreen = (call.arguments as Map)['isFullScreen'] as bool;
            transitions.add(fullScreen);
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            final done = Completer<void>();
            messenger.handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('onEvent', {
                  'eventName': fullScreen
                      ? 'enter-full-screen'
                      : 'leave-full-screen',
                }),
              ),
              (_) => done.complete(),
            );
            await done.future;
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
          }
          return null;
        });
        final player = backends.single;
        await player.seek(const Duration(seconds: 90));
        for (var i = 0; i < 2; i++) {
          final surface = tester.getCenter(find.byType(CinemaVideoGestures));
          await tester.tapAt(surface);
          await tester.pump(const Duration(milliseconds: 80));
          await tester.tapAt(surface);
          await tester.pumpAndSettle();
          expect(player.state.playing, initiallyPlaying);
          expect(player.pauses, 0);
          expect(backends.length, 1);
          expect(player.state.position.inSeconds, 90);
        }
        expect(transitions, [true, false]);
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'shared defaults reach playback; custom seeking and speed keys run actual actions',
    (tester) async {
      await mount(tester, {
        'defaultPlaySpeed': 1.75,
        'defaultVolume': 37.0,
        'arrowKeySkipTime': 7,
        'buttonSkipTime': 45,
        'autoPlay': false,
        'playerControllerLayerDisappearTime': 5500,
        'playerDisableAnimations': true,
      });
      final player = backends.single;
      expect(player.state.rate, 1.75);
      expect(player.state.volume, 37);
      expect(player.state.playing, isFalse);
      final controls = tester.widget<MaterialDesktopVideoControlsTheme>(
        find.byType(MaterialDesktopVideoControlsTheme),
      );
      expect(
        controls.normal.controlsHoverDuration,
        const Duration(milliseconds: 5500),
      );
      expect(controls.normal.controlsTransitionDuration, Duration.zero);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(player.state.position.inSeconds, 7);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.state.position.inSeconds, 7);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(player.state.position.inSeconds, 52);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(player.state.rate, 2);
      // The unbound arrow key can move focus into a control. Return focus to
      // the video before asserting the player's Space shortcut.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      FocusScope.of(tester.element(find.text('fake video'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.state.playing, isTrue);
      await unmount(tester);
      expect(player.disposed, isTrue);
    },
  );

  testWidgets(
    'Mac cinema fills the first viewport and waits for real video dimensions',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const soundChannel = MethodChannel('naku/desktop-controls');
      final soundCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(soundChannel, (call) async {
        soundCalls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(soundChannel, null));
      await mount(tester, {}, stallFirst: true, renderToolbar: true);
      final viewport = find.byKey(const ValueKey('cinema-mac-player-viewport'));
      expect(tester.getRect(viewport), const Rect.fromLTWH(0, 0, 1200, 900));
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byKey(ValueKey('playback-route:${_title.key}:0')),
        findsNothing,
      );
      final entrance = tester.state<CinemaPlayerEntranceState>(
        find.byType(CinemaPlayerEntrance),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(entrance.debugPhase, 'waiting');
      expect(entrance.debugIsAnimating, isFalse);
      final frames = entrance.debugFrameCount;
      await tester.pump(const Duration(seconds: 3));
      expect(entrance.debugFrameCount, frames);
      expect(
        soundCalls.where((c) => c.method == 'playCinemaStartupSound'),
        isEmpty,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在加载视频'), findsNothing);
      expect(find.text('正在等待视频首帧'), findsNothing);
      expect(find.text('启用视频直连并重试'), findsNothing);
      expect(find.text('取消'), findsNothing);
      expect(find.byTooltip('取消加载').hitTestable(), findsOneWidget);
      expect(find.byTooltip('返回片库').hitTestable(), findsOneWidget);
      expect(entrance.debugLoadStage, CinemaPlayerLoadStage.opening);
      final openingExtent = entrance.debugLampExtent;
      backends.single.reportBuffering(true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(entrance.debugLampExtent, openingExtent);
      backends.single.reportBuffering(false);
      await tester.pump();
      final backend = backends.single;
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('cinema-mac-page-scroll')),
          )
          .controller!;
      scroll.jumpTo(600);
      await tester.pump();
      expect(backends, [backend]);
      expect(backend.disposed, isFalse);
      scroll.jumpTo(0);
      backend.emitVideoDimensions();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(entrance.debugPhase, 'lighting');
      expect(
        soundCalls.where((c) => c.method == 'playCinemaStartupSound'),
        hasLength(1),
      );
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pump();
      expect(entrance.debugPhase, 'complete');
      expect(backends, [backend]);
      final chooser = find.byKey(const ValueKey('cinema-mac-work-chooser'));
      expect(tester.getTopLeft(chooser).dy, greaterThanOrEqualTo(900));
      expect(chooser.hitTestable(), findsNothing);
      expect(find.text('在线搜索字幕'), findsNothing);
      expect(find.text('保存截图'), findsNothing);
      expect(find.text('NAS 用户配对'), findsNothing);
      expect(find.text('选集与片源'), findsOneWidget);
      await tester.tap(find.byTooltip('选集与片源'));
      await tester.pumpAndSettle();
      for (var route = 0; route < 3; route++) {
        expect(
          find.byKey(ValueKey('playback-route:${_title.key}:$route')),
          findsOneWidget,
        );
      }
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第2集'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      expect(backends, [backend]);
      await tester.tap(find.byTooltip('播放选项'));
      await tester.pumpAndSettle();
      expect(find.text('在线搜索字幕'), findsOneWidget);
      expect(find.text('保存截图'), findsOneWidget);
      expect(find.text('NAS 用户配对'), findsOneWidget);
      expect(find.text('超分辨率'), findsOneWidget);
      expect(find.text('播放线路测速'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(chooser);
      await tester.pumpAndSettle();
      expect(chooser.hitTestable(), findsOneWidget);
      await tester.tap(chooser);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('playback-route:${_title.key}:2')),
        findsOneWidget,
      );
      expect(find.text('第2集'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pumpAndSettle();
      expect(backends, [backend]);
      expect(backend.disposed, isFalse);
      await unmount(tester);
      expect(backend.disposed, isTrue);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('Mac cinema cancel exposes retry and starts a new generation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await mount(tester, {}, stallFirst: true);
    await tester.pump(const Duration(milliseconds: 600));
    final entrance = tester.state<CinemaPlayerEntranceState>(
      find.byType(CinemaPlayerEntrance),
    );
    expect(entrance.debugPhase, 'waiting');
    await tester.tap(find.byTooltip('取消加载').hitTestable());
    await tester.pump();
    expect(entrance.debugPhase, 'cancelled');
    expect(find.text('已取消加载').hitTestable(), findsOneWidget);
    expect(find.byTooltip('取消加载'), findsNothing);
    expect(find.text('选集与片源').hitTestable(), findsOneWidget);
    expect(find.text('重试').hitTestable(), findsOneWidget);
    expect(find.byTooltip('返回片库').hitTestable(), findsOneWidget);
    await tester.tap(find.text('重试').hitTestable());
    await tester.pumpAndSettle();
    expect(backends, hasLength(2));
    expect(backends.first.state.playing, isFalse);
    // Subtitle persistence uses real disk I/O; media is already paused while
    // its existing asynchronous cleanup finishes.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(backends.first.disposed, isTrue);
    expect(backends.last.state.playing, isTrue);
    expect(entrance.debugPhase, 'complete');
    await unmount(tester);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'Mac return closes the television before one pop and saves history',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const soundChannel = MethodChannel('naku/desktop-controls');
      final soundCalls = <String>[];
      messenger.setMockMethodCallHandler(soundChannel, (call) async {
        soundCalls.add(call.method);
        return call.method == 'playCinemaStartupSound' ? true : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(soundChannel, null));
      final observer = _PopObserver();
      await mount(
        tester,
        {'privateMode': false},
        initialPosition: 120,
        renderToolbar: true,
        withLibraryRoute: true,
        navigatorObserver: observer,
      );
      final backend = backends.single;
      final entrance = tester.state<CinemaPlayerEntranceState>(
        find.byType(CinemaPlayerEntrance),
      );
      soundCalls.clear();
      final back = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '返回',
            ),
          )
          .onPressed!;
      back();
      back();
      await tester.pump();
      await tester.pump();
      expect(entrance.debugPhase, 'exiting');
      expect(backend.state.playing, isFalse);
      expect(backend.disposed, isFalse);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(CinemaPlayerPage), findsOneWidget);
      expect(observer.pops, 0);
      expect(entrance.debugPhase, 'exiting');
      backend.emitVideoDimensions();
      await tester.pump();
      expect(entrance.debugPhase, 'exiting');
      await tester.pump(const Duration(milliseconds: 300));
      for (
        var i = 0;
        i < 40 && find.byType(CinemaPlayerPage).evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(find.byType(CinemaPlayerPage), findsNothing);
      expect(find.text('测试片库'), findsOneWidget);
      expect(observer.pops, 1);
      expect(backends, [backend]);
      expect(backend.disposed, isTrue);
      expect(store.history.single.positionSeconds, 120);
      expect(
        soundCalls.where((method) => method == 'playCinemaStartupSound'),
        isEmpty,
      );
      await unmount(tester);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final scenario in ['loading', 'reduced']) {
    testWidgets(
      'Mac return during $scenario skips exit animation without hanging',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final observer = _PopObserver();
        await mount(
          tester,
          {if (scenario == 'reduced') 'playerDisableAnimations': true},
          renderToolbar: true,
          withLibraryRoute: true,
          navigatorObserver: observer,
          stallFirst: scenario == 'loading',
        );
        if (scenario == 'loading') {
          await tester.tap(find.byTooltip('返回片库'));
        } else {
          unawaited(
            tester.state<NavigatorState>(find.byType(Navigator)).maybePop(),
          );
        }
        await tester.pump();
        for (
          var i = 0;
          i < 40 && find.byType(CinemaPlayerPage).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
        }
        expect(find.text('测试片库'), findsOneWidget);
        expect(find.byType(CinemaPlayerPage), findsNothing);
        expect(observer.pops, 1);
        expect(backends, hasLength(1));
        await unmount(tester);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('desktop bottom bar has one subtitle/audio entry', (
    tester,
  ) async {
    await mount(tester, {}, renderToolbar: true);
    expect(find.byTooltip('字幕与音轨'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byIcon(Icons.closed_caption_outlined),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets(
    'long press uses shared rate and releases back to the session rate',
    (tester) async {
      await mount(tester, {
        'defaultPlaySpeed': 1.5,
        'defaultShortcutForwardPlaySpeed': 2.5,
      });
      final player = backends.single;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(player.state.rate, 2.5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(player.state.rate, 1.5);
      expect(player.state.position, Duration.zero);
      await unmount(tester);
    },
  );

  testWidgets(
    'timed arrow holds need no repeat, restore on focus loss, and do not leak into next episode',
    (tester) async {
      await mount(tester, {'defaultPlaySpeed': 1.5, 'autoPlay': true});
      final first = backends.single;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
      await tester.pump(const Duration(milliseconds: 400));
      expect(first.state.rate, 2);
      expect(find.text('2.0× 快进'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(first.state.rate, 1.5);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(first.state.playing, false);
      expect(find.text('2× 回退'), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(first.state.playing, true);
      expect(first.state.rate, 1.5);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
      await tester.pump(const Duration(milliseconds: 400));
      expect(first.state.rate, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(backends, hasLength(2));
      expect(backends.last.state.rate, 1.5);
      expect(backends.last.state.position, Duration.zero);
      await unmount(tester);
    },
  );
  for (final enabled in [false, true]) {
    testWidgets(
      'background playback $enabled keeps ordinary focus changes harmless',
      (tester) async {
        await mount(tester, {'backgroundPlayback': enabled});
        final player = backends.single;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(player.state.playing, isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(player.state.playing, enabled);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(
          player.state.playing,
          enabled,
          reason: 'Returning never unexpectedly starts a paused video.',
        );
        expect(
          store.history,
          isEmpty,
          reason: 'Shared private mode suppresses cinema history too.',
        );
        await unmount(tester);
      },
    );
    testWidgets('automatic continuation $enabled respects the setting', (
      tester,
    ) async {
      await mount(tester, {'autoPlayNext': enabled, 'defaultPlaySpeed': 1.25});
      backends.single.complete();
      await tester.pumpAndSettle();
      expect(backends.length, enabled ? 2 : 1);
      if (enabled) {
        expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
        expect(backends.last.state.rate, 1.25);
      }
      await unmount(tester);
    });
  }

  testWidgets(
    'failed source still changes automatically and retains session preferences',
    (tester) async {
      await mount(tester, {
        'defaultPlaySpeed': 1.5,
        'defaultVolume': 31.0,
      }, failFirst: true);
      expect(backends.length, 2);
      expect(backends.last.opened!.uri, 'https://fixture.invalid/backup.mp4');
      expect(backends.last.state.rate, 1.5);
      expect(backends.last.state.volume, 31);
      await unmount(tester);
    },
  );

  testWidgets(
    'turning resume off ignores stored history but does not erase it',
    (tester) async {
      await tester.runAsync(
        () => store.recordProgress(
          title: _title,
          routeIndex: 0,
          episodeIndex: 0,
          positionSeconds: 90,
          durationSeconds: 1200,
        ),
      );
      await mount(tester, {'playResume': false});
      expect(backends.single.opened!.start, Duration.zero);
      expect(store.history.single.positionSeconds, 90);
      await unmount(tester);
      expect(store.history.single.positionSeconds, 90);
    },
  );

  testWidgets(
    'buffering cancels next-episode traffic and stable playback can retry',
    (tester) async {
      final cache = _Cache();
      addTearDown(cache.finish);
      await mount(tester, {}, cache: cache);
      final backend = backends.single;
      backend.reportBuffer(const Duration(seconds: 30));
      await backend.seek(const Duration(seconds: 20));
      await tester.pump();
      expect(cache.warmups, isEmpty, reason: 'Playback needs buffer headroom.');

      backend.reportBuffer(const Duration(seconds: 60));
      await backend.seek(const Duration(seconds: 21));
      await tester.pump();
      expect(cache.warmups.single.url, 'https://fixture.invalid/2.mp4');
      final first = cache.warmups.single;
      backend.reportBuffering(true);
      await tester.pump();
      expect(first.cancel.isCancelled, isTrue);

      await backend.seek(const Duration(seconds: 22));
      await tester.pump();
      expect(cache.warmups, hasLength(1));
      backend.reportBuffering(false);
      await backend.seek(const Duration(seconds: 23));
      await tester.pump();
      expect(cache.warmups, hasLength(2));
      final resumed = cache.warmups.last;
      expect(resumed.cancel.isCancelled, isFalse);

      // Cancellation can finish late. It must not clear the resumed request.
      first.finished.complete();
      await tester.pump();
      await backend.seek(const Duration(seconds: 24));
      await tester.pump();
      expect(cache.warmups, hasLength(2));
      await unmount(tester);
      expect(resumed.cancel.isCancelled, isTrue);
      cache.finish();
      await tester.pump();
    },
  );

  for (final autoplay in [true, false]) {
    testWidgets(
      'manual episode navigation preserves the explicit play intent with global autoplay=$autoplay',
      (tester) async {
        await mount(tester, {'autoPlay': autoplay}, renderToolbar: true);
        await tester.ensureVisible(find.byTooltip(autoplay ? '暂停' : '播放'));
        await tester.tap(find.byTooltip(autoplay ? '暂停' : '播放'));
        await tester.pumpAndSettle();
        expect(backends.last.state.playing, !autoplay);
        await tester.ensureVisible(find.byTooltip('下一集'));
        await tester.tap(find.byTooltip('下一集'));
        await tester.pumpAndSettle();
        expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
        expect(backends.last.state.playing, !autoplay);
        await tester.ensureVisible(find.byTooltip('上一集'));
        await tester.tap(find.byTooltip('上一集'));
        await tester.pumpAndSettle();
        expect(backends.last.state.playing, !autoplay);
        await unmount(tester);
      },
    );
  }
  testWidgets(
    'automatic next episode continues an explicit Play even with global autoplay disabled',
    (tester) async {
      await mount(tester, {
        'autoPlay': false,
        'autoPlayNext': true,
      }, renderToolbar: true);
      await tester.ensureVisible(find.byTooltip('播放'));
      await tester.tap(find.byTooltip('播放'));
      await tester.pumpAndSettle();
      backends.last.complete();
      await tester.pumpAndSettle();
      expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
      expect(backends.last.state.playing, isTrue);
      await unmount(tester);
    },
  );

  testWidgets(
    'network recovery retries the same episode twice and then falls back with progress and rate intact',
    (tester) async {
      await mount(tester, {'autoPlay': false, 'defaultPlaySpeed': 1.5});
      for (var attempt = 0; attempt < 3; attempt++) {
        final backend = backends.last;
        await backend.seek(const Duration(seconds: 42));
        backend.reportBuffering(true);
        backend.reportLog(
          const PlayerLog(
            prefix: 'ffmpeg',
            level: 'error',
            text: 'Connection reset by peer',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          backends.last.opened!.uri,
          attempt < 2
              ? 'https://fixture.invalid/1.mp4'
              : 'https://fixture.invalid/backup.mp4',
        );
        expect(backends.last.state.position.inSeconds, 42);
        expect(backends.last.state.rate, 1.5);
        expect(backends.last.state.playing, isFalse);
      }
      expect(backends, hasLength(4));
      await unmount(tester);
    },
  );

  testWidgets(
    'manual next episode cancels a pending retry and cannot reopen the old episode',
    (tester) async {
      await mount(tester, {'autoPlay': true});
      final backend = backends.single;
      backend.reportBuffering(true);
      backend.reportLog(
        const PlayerLog(
          prefix: 'ffmpeg',
          level: 'error',
          text: 'HTTP error 503',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(backends, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(backends, hasLength(2));
      expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');
      await unmount(tester);
    },
  );

  testWidgets(
    'a recovered stream cancels the pending reconnect before replacement',
    (tester) async {
      await mount(tester, {'autoPlay': true});
      final backend = backends.single;
      backend.reportBuffering(true);
      backend.reportLog(
        const PlayerLog(
          prefix: 'ffmpeg',
          level: 'error',
          text: 'HTTP error 503',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      backend.reportBuffering(false);
      await backend.seek(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(backends, hasLength(1));
      expect(backend.state.playing, isTrue);
      await unmount(tester);
    },
  );

  testWidgets(
    'double speed cancels speculative next-episode traffic until real playback headroom recovers',
    (tester) async {
      final cache = _Cache();
      addTearDown(cache.finish);
      await mount(tester, {}, cache: cache);
      final backend = backends.single;
      backend.reportBuffer(const Duration(seconds: 60));
      await backend.seek(const Duration(seconds: 21));
      await tester.pump();
      final first = cache.warmups.single;
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(backend.state.rate, 2);
      expect(first.cancel.isCancelled, isTrue);
      backend.reportBuffer(const Duration(seconds: 80));
      await backend.seek(const Duration(seconds: 22));
      await tester.pump();
      expect(cache.warmups, hasLength(2));
      expect(cache.warmups.last.cancel.isCancelled, isFalse);
      first.finished.complete();
      await tester.pump();
      expect(cache.warmups.last.cancel.isCancelled, isFalse);
      await unmount(tester);
      cache.finish();
      await tester.pump();
    },
  );

  testWidgets(
    'changing episodes cancels old warmup without disturbing the new selection',
    (tester) async {
      final cache = _Cache();
      addTearDown(cache.finish);
      final title = _title.copyWith(
        routes: const [
          CinemaRoute(
            name: 'mp4',
            episodes: [
              CinemaEpisode(name: '第1集', url: 'https://fixture.invalid/1.mp4'),
              CinemaEpisode(name: '第2集', url: 'https://fixture.invalid/2.mp4'),
              CinemaEpisode(name: '第3集', url: 'https://fixture.invalid/3.mp4'),
            ],
          ),
        ],
      );
      await mount(tester, {}, cache: cache, selectedTitle: title);
      backends.single.reportBuffer(const Duration(seconds: 60));
      await backends.single.seek(const Duration(seconds: 20));
      await tester.pump();
      final old = cache.warmups.single;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(backends, hasLength(2));
      expect(old.cancel.isCancelled, isTrue);
      expect(backends.last.opened!.uri, 'https://fixture.invalid/2.mp4');

      backends.last.reportBuffer(const Duration(seconds: 60));
      await backends.last.seek(const Duration(seconds: 20));
      await tester.pump();
      expect(cache.warmups, hasLength(2));
      final current = cache.warmups.last;
      expect(current.url, 'https://fixture.invalid/3.mp4');
      old.finished.complete();
      await tester.pump();
      await backends.last.seek(const Duration(seconds: 21));
      await tester.pump();
      expect(cache.warmups, hasLength(2));
      expect(current.cancel.isCancelled, isFalse);
      await unmount(tester);
      expect(current.cancel.isCancelled, isTrue);
      cache.finish();
      await tester.pump();
    },
  );

  testWidgets(
    'private playback preserves in-session progress through manual route selection',
    (tester) async {
      await mount(tester, {'privateMode': true});
      await backends.single.seek(const Duration(seconds: 64));
      await tester.pump();
      final manualRoute = find.byKey(
        ValueKey('playback-route:${_title.key}:2'),
      );
      await tester.ensureVisible(manualRoute);
      await tester.tap(manualRoute);
      await tester.pumpAndSettle();
      expect(backends.length, 1);
      final originalRoute = find.byKey(
        ValueKey('playback-route:${_title.key}:0'),
      );
      await tester.ensureVisible(originalRoute);
      await tester.tap(originalRoute);
      await tester.pumpAndSettle();
      final episode = find.widgetWithText(OutlinedButton, '第1集');
      await tester.ensureVisible(episode);
      await tester.tap(episode);
      await tester.pumpAndSettle();
      expect(backends.last.opened!.start, const Duration(seconds: 64));
      expect(store.history, isEmpty);
      expect(find.text('隐身模式已开启，本次不会保存观看记录。'), findsOneWidget);
      await unmount(tester);
    },
  );
  testWidgets(
    'TV NAS prefers original direct movie despite available transcodes and shows flat loading',
    (tester) async {
      final wasTV = NakuDevice.isTV;
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = wasTV);
      final nas = _NAS();
      final nativeCalls = <MethodCall>[];
      final original = Completer<String>();
      messenger.setMockMethodCallHandler(CinemaNASClient.channel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'ensure') return {'namespace': 'a' * 64};
        if (call.method == 'asset') return original.future;
        throw StateError('Unexpected original NAS call: ${call.method}');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(CinemaNASClient.channel, null),
      );
      final reference = nasMediaReference(
        namespace: 'a' * 64,
        id: 1,
        library: 1,
        path: '/original-dolby-movie.mkv',
      );
      final title = CinemaTitle(
        id: 'tv-original',
        sourceId: cinemaNASSource.id,
        title: 'TV 原画直连',
        routes: [
          CinemaRoute(
            name: 'NAS',
            episodes: [CinemaEpisode(name: '电影', url: reference)],
          ),
        ],
      );
      await mount(
        tester,
        {'autoPlay': false},
        viewport: const Size(1280, 720),
        stallFirst: true,
        selectedTitle: title,
        selectedSource: cinemaNASSource,
        initialPosition: 123,
        nasPlayback: CinemaNASPlaybackClient(client: nas),
        resolveNASRatings: (value) async => value,
      );
      for (
        var i = 0;
        i < 8 && !nativeCalls.any((c) => c.method == 'asset');
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(nas.calls, contains('playbackOptions'));
      expect(
        nativeCalls.map((c) => c.method),
        containsAllInOrder(['ensure', 'asset']),
      );
      expect(nativeCalls.last.arguments['path'], '/original-dolby-movie.mkv');
      expect(
        nas.starts,
        isEmpty,
        reason: 'available NAS transcodes must not replace original playback',
      );
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final entrance = tester.widget<CinemaPlayerEntrance>(
        find.byType(CinemaPlayerEntrance),
      );
      expect(entrance.enabled, false);
      expect(find.text('画质'), findsNothing);
      original.complete('http://192.168.1.9/original.mkv');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(backends.single.opened!.uri, 'http://192.168.1.9/original.mkv');
      expect(backends.single.opened!.start, const Duration(seconds: 123));
      expect(
        backends.single.state.playing,
        true,
        reason: 'explicit TV entry must honor play intent',
      );
      expect(nas.starts, isEmpty);
      backends.single.emitVideoDimensions();
      await tester.pump();
      expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
      await unmount(tester);
    },
  );
  testWidgets(
    'TV episode switch retires old native decoder before next player opens',
    (tester) async {
      final wasTV = NakuDevice.isTV;
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = wasTV);
      const nativeChannel = MethodChannel('test/tv-retirement');
      final events = StreamController<dynamic>.broadcast();
      final calls = <MethodCall>[];
      final releaseOldStop = Completer<void>();
      int? firstId;
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call);
        final args = call.arguments as Map;
        final id = args['id'] as int;
        if (call.method == 'create') firstId ??= id;
        if (call.method == 'stop' && id == firstId) {
          await releaseOldStop.future;
        }
        if (call.method == 'open') {
          events.add({
            'id': id,
            'width': 1920,
            'height': 1080,
            'durationMs': 1200000,
            'positionMs': args['positionMs'],
            'playing': args['play'],
            'buffering': false,
            'completed': false,
            'firstFrame': true,
          });
        }
        return null;
      });
      addTearDown(() async {
        if (!releaseOldStop.isCompleted) releaseOldStop.complete();
        await events.close();
        messenger.setMockMethodCallHandler(nativeChannel, null);
      });
      await mount(
        tester,
        {'autoPlay': true},
        viewport: const Size(1280, 720),
        playerFactory: (configuration) => CinemaTVNativePlayer(
          configuration: configuration,
          channel: nativeChannel,
          events: events.stream,
        ),
      );
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第2集').last);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(calls.where((c) => c.method == 'stop'), hasLength(1));
      expect(
        calls.where((c) => c.method == 'open'),
        hasLength(1),
        reason:
            'second episode must wait for exclusive hardware decoder retirement',
      );
      releaseOldStop.complete();
      for (
        var i = 0;
        i < 20 && calls.where((c) => c.method == 'open').length < 2;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        calls.where((c) => c.method == 'open'),
        hasLength(2),
        reason: calls.map((c) => c.method).join(','),
      );
      final retiredAt = calls.indexWhere(
        (c) => c.method == 'dispose' && c.arguments['id'] == firstId,
      );
      final nextOpenAt = calls.indexWhere(
        (c) => c.method == 'open' && c.arguments['id'] != firstId,
      );
      expect(retiredAt, greaterThanOrEqualTo(0));
      expect(nextOpenAt, greaterThan(retiredAt));
      expect(
        calls[nextOpenAt].arguments['url'],
        'https://fixture.invalid/2.mp4',
      );
      await unmount(tester);
    },
  );
  testWidgets(
    'TV hidden controls accept immediate seek and pause without manual source UI',
    (tester) async {
      final wasTV = NakuDevice.isTV;
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = wasTV);
      await mount(tester, {'autoPlay': true}, initialPosition: 20);
      expect(CinemaTVPlaybackActivity.instance.isWatching, true);
      expect(find.text('音轨'), findsNothing);
      expect(find.text('画质'), findsNothing);
      expect(find.text('选集 / 线路'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(backends.single.state.position, const Duration(seconds: 30));
      expect(backends.single.state.playing, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(backends.single.state.playing, false);
      expect(backends.single.state.position, const Duration(seconds: 30));
      expect(CinemaTVPlaybackActivity.instance.isWatching, false);
      await unmount(tester);
      expect(CinemaTVPlaybackActivity.instance.isWatching, false);
    },
  );
  testWidgets('TV Back first hides controls then returns directly to library', (
    tester,
  ) async {
    final wasTV = NakuDevice.isTV;
    NakuDevice.isTV = true;
    addTearDown(() => NakuDevice.isTV = wasTV);
    await mount(tester, {'autoPlay': true}, withLibraryRoute: true);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('测试片库'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));
    for (
      var i = 0;
      i < 40 && find.byType(CinemaPlayerPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(find.text('测试片库'), findsOneWidget);
    expect(CinemaTVPlaybackActivity.instance.isWatching, false);
    await unmount(tester);
  });
  testWidgets(
    'TV startup protects its tiny buffer and a later pause cancels optional auto switching',
    (tester) async {
      final wasTV = NakuDevice.isTV;
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = wasTV);
      var now = Duration.zero;
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      final cache = _Cache();
      addTearDown(cache.finish);
      await mount(
        tester,
        {'autoPlay': false},
        autoBest: true,
        probe: probe,
        cache: cache,
        initialPosition: 77,
        backgroundClock: () => now,
      );
      final backend = backends.single;
      expect(backend.state.playing, true);
      for (var tick = 0; tick < 14; tick++) {
        now += const Duration(seconds: 1);
        backend.reportBuffer(
          backend.state.position + const Duration(seconds: 2),
        );
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(
        probe.calls,
        isEmpty,
        reason:
            'Startup and the old12s diagnostics timer must yield bandwidth.',
      );
      expect(cache.warmups, isEmpty);
      for (var tick = 0; tick < 9; tick++) {
        now += const Duration(seconds: 1);
        backend.reportBuffer(
          backend.state.position + const Duration(seconds: 65),
        );
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(probe.requests.length, 2);
      expect(cache.warmups, isEmpty, reason: 'Optional jobs do not overlap.');
      final position = backend.state.position;
      await backend.pause();
      await tester.pump();
      expect(probe.tokens.every((token) => token.isCancelled), true);
      probe.complete();
      await tester.pumpAndSettle();
      expect(backends, hasLength(1));
      expect(backend.state.position, position);
      expect(backend.state.playing, false);
      await unmount(tester);
    },
  );

  testWidgets(
    'TV buffering and user seek cancel active comparison without extra media fetch',
    (tester) async {
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = false);
      var now = Duration.zero;
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(
        tester,
        {},
        autoBest: true,
        probe: probe,
        backgroundClock: () => now,
      );
      final backend = backends.single;
      for (var tick = 0; tick < 9; tick++) {
        now += const Duration(seconds: 1);
        backend.reportBuffer(
          backend.state.position + const Duration(seconds: 65),
        );
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(probe.requests.length, 2);
      backend.reportBuffering(true);
      await tester.pump();
      expect(probe.tokens.every((token) => token.isCancelled), true);
      final calls = probe.calls.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(backend.state.position.inSeconds, 19);
      for (var tick = 0; tick < 12; tick++) {
        now += const Duration(seconds: 1);
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(probe.calls.length, calls);
      expect(backends, hasLength(1));
      expect(backend.state.playing, true);
      probe.complete();
      await unmount(tester);
    },
  );

  testWidgets(
    'hidden TV probe progress keeps the video surface mounted without rebuilding',
    (tester) async {
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = false);
      var now = Duration.zero;
      var surfaces = 0;
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(
        tester,
        {},
        probe: probe,
        backgroundClock: () => now,
        onSurfaceBuild: () => surfaces++,
      );
      final backend = backends.single;
      for (var tick = 0; tick < 9; tick++) {
        now += const Duration(seconds: 1);
        backend.reportBuffer(
          backend.state.position + const Duration(seconds: 65),
        );
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('暂停'), findsNothing);
      expect(probe.requests.length, 1);
      final before = surfaces;
      probe.complete();
      await tester.pumpAndSettle();
      expect(surfaces, before);
      expect(backends, hasLength(1));
      await unmount(tester);
    },
  );
  testWidgets(
    'healthy TV automatic comparison still selects the best route at the current position',
    (tester) async {
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = false);
      var now = Duration.zero;
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      await mount(
        tester,
        {},
        autoBest: true,
        probe: probe,
        initialPosition: 77,
        backgroundClock: () => now,
      );
      final backend = backends.single;
      for (var tick = 0; tick < 9; tick++) {
        now += const Duration(seconds: 1);
        backend.reportBuffer(
          backend.state.position + const Duration(seconds: 65),
        );
        await backend.seek(backend.state.position + const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(probe.requests.length, 2);
      probe.complete();
      await tester.pumpAndSettle();
      expect(backends, hasLength(2));
      expect(backends.last.opened!.uri, 'https://fixture.invalid/backup.mp4');
      expect(backends.last.opened!.start, const Duration(seconds: 86));
      expect(backends.last.state.playing, true);
      await unmount(tester);
    },
  );

  for (final userPaused in [false, true]) {
    testWidgets(
      'TV native IDLE network retry preserves explicit paused=$userPaused intent',
      (tester) async {
        NakuDevice.isTV = true;
        addTearDown(() => NakuDevice.isTV = false);
        const nativeChannel = MethodChannel('test/tv-idle-retry');
        final events = StreamController<dynamic>.broadcast();
        final opens = <Map<String, dynamic>>[];
        int? activeId;
        messenger.setMockMethodCallHandler(nativeChannel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final id = args['id'] as int;
          if (call.method == 'open') {
            activeId = id;
            opens.add(args);
            events.add({
              'id': id,
              'width': 1920,
              'height': 1080,
              'durationMs': 1200000,
              'positionMs': args['positionMs'],
              'bufferMs': 160000,
              'playing': args['play'],
              'buffering': false,
              'completed': false,
              'firstFrame': true,
            });
          } else if (call.method == 'pause' || call.method == 'play') {
            events.add({'id': id, 'playing': call.method == 'play'});
          }
          return null;
        });
        addTearDown(() async {
          await events.close();
          messenger.setMockMethodCallHandler(nativeChannel, null);
        });
        await mount(
          tester,
          {'autoPlay': false},
          initialPosition: 123,
          viewport: const Size(1280, 720),
          playerFactory: (configuration) => CinemaTVNativePlayer(
            configuration: configuration,
            channel: nativeChannel,
            events: events.stream,
          ),
        );
        expect(opens.single['play'], true);
        events.add({'id': activeId, 'positionMs': 133000});
        await tester.pump();
        if (userPaused) {
          await tester.tap(find.text('暂停'));
          await tester.pumpAndSettle();
          expect(find.text('播放'), findsOneWidget);
        }
        // Mirror Media3: terminal IDLE/playing=false arrives before its error.
        events.add({'id': activeId, 'playing': false, 'buffering': false});
        await tester.pump();
        events.add({'id': activeId, 'error': '视频连接失败（2001）'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        for (var i = 0; i < 30 && opens.length < 2; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(opens, hasLength(2));
        expect(opens.last['positionMs'], 133000);
        expect(
          opens.last['play'],
          !userPaused,
          reason:
              'Terminal IDLE must not erase the explicit play or pause command.',
        );
        await unmount(tester);
      },
    );
  }
}
