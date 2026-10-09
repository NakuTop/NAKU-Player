import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_player_preferences.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';
import 'package:kazumi/services/storage/storage.dart';
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
  _Backend(PlayerConfiguration configuration, {this.failOpen = false})
    : super(configuration: configuration);
  final bool failOpen;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  late CinemaWatchTogether together;
  final backends = <_Backend>[];
  const channel = MethodChannel('window_manager');
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
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isFullScreen' ? false : null,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    together.dispose();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    Map<String, Object?> values, {
    bool failFirst = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
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
          source: _source,
          store: store,
          watchTogether: together,
          repository: _Repository(),
          ratingsRepository: _Ratings(),
          preferences: prefs,
          createPlayer: (config) {
            final backend = _Backend(
              config,
              failOpen: failFirst && backends.isEmpty,
            );
            backends.add(backend);
            return _Player(backend);
          },
          videoSurfaceBuilder: (_, _) =>
              const SizedBox.expand(child: Text('fake video')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(tester.takeException(), isNull);
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
