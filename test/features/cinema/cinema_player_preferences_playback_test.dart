import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
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

class _Backend extends PlatformPlayer {
  _Backend(
    PlayerConfiguration configuration, {
    this.failOpen = false,
    this.emitVideo = true,
  }) : super(configuration: configuration);
  final bool failOpen;
  final bool emitVideo;
  Media? opened;
  int pauses = 0;
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
  @override
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) => requests.putIfAbsent(url, Completer<CinemaMediaProbeResult>.new).future;
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
    bool autoBest = false,
    CinemaMediaProbe? probe,
    int? initialPosition,
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
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaPlayerPage(
          title: _title,
          autoSelectBestRoute: autoBest,
          mediaProbe: probe,
          initialPositionSeconds: initialPosition,
          offlinePaths: offlinePaths,
          source: _source,
          store: store,
          watchTogether: together,
          repository: _Repository(),
          ratingsRepository: _Ratings(),
          preferences: prefs,
          windowControls: windowControls,
          createPlayer: (config) {
            final backend = _Backend(
              config,
              failOpen: failFirst && backends.isEmpty,
              emitVideo: !(stallFirst && backends.isEmpty),
            );
            backends.add(backend);
            return _Player(backend);
          },
          videoSurfaceBuilder: (_, _) => renderToolbar
              ? Builder(
                  builder: (context) => Column(
                    children: [
                      Row(
                        children: MaterialDesktopVideoControlsTheme.of(
                          context,
                        ).normal.topButtonBar,
                      ),
                      const Expanded(child: Text('fake video')),
                      Row(
                        children: MaterialDesktopVideoControlsTheme.of(context)
                            .normal
                            .bottomButtonBar
                            .where(
                              (w) =>
                                  w is IconButton ||
                                  w is StreamBuilder<bool> ||
                                  w is Spacer ||
                                  w is PopupMenuButton,
                            )
                            .toList(),
                      ),
                    ],
                  ),
                )
              : const SizedBox.expand(child: Text('fake video')),
        ),
      ),
    );
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

  Future<void> snapshotRecommendation(WidgetTester tester, String name) async {
    final output = Platform.environment['NAKU_QA_SCREENSHOTS'];
    if (output == null) return;
    await tester.runAsync(() async {
      RenderObject? render = tester
          .element(find.byKey(const ValueKey('route-recommendation-main')))
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
      await tester.tap(find.byTooltip('更多选项'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      for (final label in ['下载选集', '画中画', '一起看', '超分辨率', '倍速']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
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
      expect(backends.single.opened!.uri, local.path);
      expect(backends.single.state.position.inSeconds, 42);
      expect(find.text('离线播放'), findsOneWidget);
      await unmount(tester);
      expect(store.historyFor(_title)!.title.key, _title.key);
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
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.state.playing, isTrue);
      await unmount(tester);
      expect(player.disposed, isTrue);
    },
  );

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
}
