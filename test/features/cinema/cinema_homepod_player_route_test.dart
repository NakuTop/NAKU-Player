import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_homepod_player_route.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';
import 'package:media_kit/media_kit.dart';

class _Controls extends HomePodAudioControls {
  _Controls() : super(platform: TargetPlatform.macOS);
  bool _active = false;

  @override
  bool get audioRouteActive => _active;

  void confirmRoute(bool active) {
    _active = active;
    notifyListeners();
  }

  void unrelatedUpdate() => notifyListeners();
}

class _Player implements Player {
  _Player([AudioDevice? initialDevice])
    : _state = PlayerState(
        audioDevice: initialDevice ?? AudioDevice.auto(),
        volume: 37,
      );

  PlayerState _state;
  final devices = <AudioDevice>[];
  final events = <String>[];
  Completer<void>? nextSetter;

  @override
  PlayerState get state => _state;

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> setAudioDevice(AudioDevice device) async {
    devices.add(device);
    events.add('route:${device.name}');
    final pending = nextSetter;
    nextSetter = null;
    if (pending != null) await pending.future;
    _state = _state.copyWith(audioDevice: device);
  }

  @override
  Future<void> open(Playable media, {bool play = true}) async {
    events.add('open');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player call: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Controls controls;
  late _Player player;
  late CinemaHomePodPlayerRoute route;
  final messages = <String>[];
  const previous = AudioDevice('coreaudio/fixture-usb', 'USB audio');

  CinemaHomePodPlayerRoute bind({
    TargetPlatform platform = TargetPlatform.macOS,
  }) {
    return route = CinemaHomePodPlayerRoute(
      player,
      controls: controls,
      platform: platform,
      onDiagnostic: messages.add,
    );
  }

  setUp(() {
    controls = _Controls();
    player = _Player();
    messages.clear();
  });

  tearDown(() async {
    await route.dispose();
    controls.dispose();
  });

  test('default off makes no device calls or playback changes', () async {
    bind();
    controls.unrelatedUpdate();
    await route.prepareForOpen();
    expect(player.devices, isEmpty);
    expect(player.state.volume, 37);
    expect(messages, isEmpty);
  });

  test('existing player follows confirmed active explicit route', () async {
    bind();
    controls.confirmRoute(true);
    await route.prepareForOpen();
    expect(player.devices, [CinemaHomePodPlayerRoute.device]);
    expect(player.state.volume, 37);
    controls.unrelatedUpdate();
    await route.prepareForOpen();
    expect(player.devices, hasLength(1));
  });

  test('new player registered active applies its route before open', () async {
    controls.confirmRoute(true);
    bind();
    await route.prepareForOpen();
    await player.open(Media('fixture:movie'));
    expect(player.events, [
      'route:${CinemaHomePodPlayerRoute.device.name}',
      'open',
    ]);
  });

  test('confirmed off restores the prior player device', () async {
    player = _Player(previous);
    bind();
    controls.confirmRoute(true);
    await route.prepareForOpen();
    controls.confirmRoute(false);
    await route.prepareForOpen();
    expect(player.devices, [CinemaHomePodPlayerRoute.device, previous]);
    expect(player.state.audioDevice, previous);
    controls.unrelatedUpdate();
    await route.prepareForOpen();
    expect(player.devices, hasLength(2));
  });

  test('rapid toggle last off wins over an in-flight virtual setter', () async {
    player = _Player(previous);
    final gate = player.nextSetter = Completer<void>();
    bind();
    controls.confirmRoute(true);
    await Future<void>.delayed(Duration.zero);
    expect(player.devices, [CinemaHomePodPlayerRoute.device]);
    controls.confirmRoute(false);
    gate.complete();
    await route.prepareForOpen();
    expect(player.devices, [CinemaHomePodPlayerRoute.device, previous]);
    expect(player.state.audioDevice, previous);
  });

  test(
    'reactivating during restoration retains the original prior route',
    () async {
      player = _Player(previous);
      bind();
      controls.confirmRoute(true);
      await route.prepareForOpen();
      final gate = player.nextSetter = Completer<void>();
      controls.confirmRoute(false);
      await Future<void>.delayed(Duration.zero);
      controls.confirmRoute(true);
      gate.complete();
      await route.prepareForOpen();
      expect(player.state.audioDevice, CinemaHomePodPlayerRoute.device);
      controls.confirmRoute(false);
      await route.prepareForOpen();
      expect(player.devices, [
        CinemaHomePodPlayerRoute.device,
        previous,
        CinemaHomePodPlayerRoute.device,
        previous,
      ]);
    },
  );

  test('disposed binding ignores queued toggles and future updates', () async {
    bind();
    controls.confirmRoute(true);
    final closing = route.dispose();
    controls.confirmRoute(false);
    await closing;
    controls.confirmRoute(true);
    await route.prepareForOpen();
    expect(player.devices, isEmpty);
  });

  test('dispose joins an in-flight setter before player destruction', () async {
    final gate = player.nextSetter = Completer<void>();
    bind();
    controls.confirmRoute(true);
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final closing = route.dispose().then((_) => closed = true);
    controls.confirmRoute(false);
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    gate.complete();
    await closing;
    expect(player.devices, hasLength(1));
    controls.confirmRoute(true);
    await route.prepareForOpen();
    expect(player.devices, hasLength(1));
  });

  test('non macOS player remains untouched when the route is active', () async {
    controls.confirmRoute(true);
    bind(platform: TargetPlatform.android);
    await route.prepareForOpen();
    controls.confirmRoute(false);
    await route.prepareForOpen();
    expect(player.devices, isEmpty);
  });
}
