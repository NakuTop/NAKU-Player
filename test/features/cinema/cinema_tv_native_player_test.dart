import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_tv_native_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tv-native-player');
  late StreamController<dynamic> events;
  late List<MethodCall> calls;
  late CinemaTVNativePlayer player;
  setUp(() {
    events = StreamController<dynamic>.broadcast();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    player = CinemaTVNativePlayer(channel: channel, events: events.stream);
  });
  tearDown(() async {
    await player.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('implements Player without allocating the mpv NativePlayer', () async {
    final Player api = player;
    expect(api.platform, same(player));
    expect(api.platform, isNot(isA<NativePlayer>()));
    expect(await api.handle, player.id);
  });
  test(
    'open preserves signed request headers, seek position and paused intent',
    () async {
      player.mediaMimeType = 'application/x-mpegURL';
      await player.open(
        Media(
          'http://192.168.1.3/movie.mkv',
          start: const Duration(seconds: 47),
          httpHeaders: {'Authorization': 'fixture'},
        ),
        play: false,
      );
      final open = calls.singleWhere((c) => c.method == 'open');
      expect(open.arguments, containsPair('positionMs', 47000));
      expect(open.arguments, containsPair('mimeType', 'application/x-mpegURL'));
      expect(open.arguments, containsPair('play', false));
      expect(open.arguments['headers'], {'Authorization': 'fixture'});
      expect(player.state.playing, false);
      expect(player.state.buffering, true);
    },
  );
  test(
    'caption clearance is bounded, coalesced and preserves video intent',
    () async {
      await player.open(Media('https://fixture.invalid/movie.mkv'));
      calls.clear();
      await player.setSubtitleBottomFraction(168 / 720);
      await player.setSubtitleBottomFraction(168 / 720);
      await player.setSubtitleBottomFraction(3);
      await player.setSubtitleBottomFraction(double.nan);
      expect(calls.map((c) => c.method), [
        'captionInset',
        'captionInset',
        'captionInset',
      ]);
      expect(calls.map((c) => c.arguments['fraction']), [168 / 720, .45, .08]);
      expect(player.state.playing, true);
    },
  );
  test('dimensions cannot complete the first-frame gate', () async {
    var rendered = false;
    unawaited(player.waitUntilFirstFrameRendered.then((_) => rendered = true));
    events.add({'id': player.id, 'width': 3840, 'height': 2160});
    await Future<void>.delayed(Duration.zero);
    expect(rendered, false);
    events.add({'id': player.id + 1, 'firstFrame': true});
    await Future<void>.delayed(Duration.zero);
    expect(rendered, false);
    events.add({'id': player.id, 'firstFrame': true});
    await player.waitUntilFirstFrameRendered;
    expect(rendered, true);
  });
  test(
    'buffering retains play intent and updates real playback state streams',
    () async {
      events.add({
        'id': player.id,
        'positionMs': 12000,
        'durationMs': 90000,
        'bufferMs': 22000,
        'playing': true,
        'buffering': true,
        'completed': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.state.buffer, const Duration(seconds: 22));
      expect(player.state.playing, true);
      expect(player.state.buffering, true);
      await player.playOrPause();
      expect(calls.last.method, 'pause');
    },
  );
  test(
    'native tracks map to embedded subtitle and preserve external data selection',
    () async {
      events.add({
        'id': player.id,
        'tracks': [
          {
            'id': '2:0',
            'type': 'subtitle',
            'label': '中文',
            'language': 'zh',
            'selected': true,
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(player.state.tracks.subtitle.last.id, '2:0');
      await player.setSubtitleTrack(SubtitleTrack.data('fixture'));
      expect(calls.last.arguments['track'], 'no');
      expect(player.state.track.subtitle.data, true);
    },
  );
  test(
    'seek clamps negatives, dispose is idempotent and late events ignored',
    () async {
      await player.seek(const Duration(seconds: -5));
      expect(calls.last.arguments['positionMs'], 0);
      await player.dispose();
      events.add({'id': player.id, 'positionMs': 45000});
      await Future<void>.delayed(Duration.zero);
      await player.dispose();
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      expect(player.state.position, Duration.zero);
    },
  );
  test(
    'public online streams serialize an explicitly selected proxy',
    () async {
      player.httpProxy = Uri.parse('socks5://127.0.0.1:1080');
      await player.open(Media('https://media.example/movie.mp4'));
      final args = calls.singleWhere((c) => c.method == 'open').arguments;
      expect(args['proxy'], {
        'scheme': 'socks5',
        'host': '127.0.0.1',
        'port': 1080,
      });
    },
  );
  test(
    'NAS loopback and private redirect targets always bypass selected proxy',
    () {
      for (final host in [
        '127.0.0.1',
        '192.168.1.9',
        '10.1.2.3',
        '172.31.2.4',
        '169.254.8.3',
        '100.64.1.2',
        'nas.local',
        'NAS',
        '[::1]',
        '[fd01::23]',
        '[fe80::11]',
      ]) {
        expect(
          cinemaTVNativeProxyArguments(
            Uri.parse('http://$host/movie.mkv'),
            Uri.parse('http://proxy.example:8080'),
          ),
          isNull,
          reason: host,
        );
      }
      expect(
        cinemaTVNativeBypassesProxy(Uri.parse('https://fccdn.example/movie')),
        false,
      );
      expect(
        cinemaTVNativeBypassesProxy(Uri.parse('https://172.32.0.1/movie')),
        false,
      );
    },
  );
  test(
    'unsupported proxy never silently opens public media directly',
    () async {
      player.httpProxy = Uri.parse('https://proxy.example:8443');
      await expectLater(
        player.open(Media('https://media.example/movie.mp4')),
        throwsFormatException,
      );
      expect(calls.where((c) => c.method == 'open'), isEmpty);
    },
  );
  test(
    'duplicate metadata snapshots keep PlayerState identity and queue no unchanged streams',
    () async {
      final counts = <String, int>{};
      final subscriptions = <StreamSubscription<dynamic>>[];
      void observe(String name, Stream<dynamic> stream) {
        subscriptions.add(
          stream.listen(
            (_) => counts.update(name, (n) => n + 1, ifAbsent: () => 1),
          ),
        );
      }

      observe('position', player.stream.position);
      observe('duration', player.stream.duration);
      observe('width', player.stream.width);
      observe('height', player.stream.height);
      observe('subtitle', player.stream.subtitle);
      observe('tracks', player.stream.tracks);
      Map<String, dynamic> snapshot() => {
        'id': player.id,
        'positionMs': 5000,
        'durationMs': 120000,
        'bufferMs': 20000,
        'playing': true,
        'buffering': false,
        'completed': false,
        'width': 3840,
        'height': 2160,
        'cues': ['same caption'],
        'tracks': [
          {'id': '2:0', 'type': 'subtitle', 'label': '中文', 'selected': true},
        ],
      };
      events.add(snapshot());
      await Future<void>.delayed(Duration.zero);
      final stable = player.state;
      final before = Map<String, int>.of(counts);
      for (var i = 0; i < 120; i++) {
        events.add(snapshot());
      }
      await Future<void>.delayed(Duration.zero);
      expect(player.state, same(stable));
      expect(counts, before);
      expect(counts.values.every((value) => value == 1), true);
      for (final sub in subscriptions) {
        await sub.cancel();
      }
    },
  );
  test(
    'delta packets preserve independent dimensions and the exact 250ms subtitle clock',
    () async {
      final positions = <int>[];
      final sub = player.stream.position.listen(
        (value) => positions.add(value.inMilliseconds),
      );
      events.add({'id': player.id, 'width': 3840, 'height': 2160});
      events.add({'id': player.id, 'width': 4096});
      for (var ms = 250; ms <= 1000; ms += 250) {
        events.add({'id': player.id, 'positionMs': ms});
      }
      events.add({'id': player.id, 'positionMs': 5000, 'playing': false});
      await Future<void>.delayed(Duration.zero);
      expect(player.state.width, 4096);
      expect(player.state.height, 2160);
      expect(positions, [250, 500, 750, 1000, 5000]);
      expect(player.state.playing, false);
      await sub.cancel();
    },
  );
  test(
    'all changed fields commit together before stream listeners run',
    () async {
      PlayerState? observed;
      final sub = player.stream.position.listen((_) => observed = player.state);
      events.add({
        'id': player.id,
        'positionMs': 90000,
        'durationMs': 90000,
        'bufferMs': 90000,
        'playing': false,
        'buffering': false,
        'completed': true,
        'width': 1920,
        'height': 1080,
        'cues': [],
      });
      await Future<void>.delayed(Duration.zero);
      expect(observed, same(player.state));
      expect(observed!.position, const Duration(seconds: 90));
      expect(observed!.duration, const Duration(seconds: 90));
      expect(observed!.completed, true);
      expect(observed!.width, 1920);
      await sub.cancel();
    },
  );
  test(
    'track replay preserves external data and changed native labels still update',
    () async {
      Map<String, dynamic> tracks(String label) => {
        'id': player.id,
        'tracks': [
          {'id': '2:0', 'type': 'subtitle', 'label': label, 'selected': true},
        ],
      };
      events.add(tracks('Original'));
      await Future<void>.delayed(Duration.zero);
      await player.setSubtitleTrack(SubtitleTrack.data('fixture'));
      events.add(tracks('Original'));
      await Future<void>.delayed(Duration.zero);
      expect(player.state.track.subtitle.data, true);
      events.add(tracks('Updated'));
      await Future<void>.delayed(Duration.zero);
      expect(player.state.tracks.subtitle.last.title, 'Updated');
      expect(player.state.track.subtitle.data, true);
    },
  );
  test(
    'first-frame and repeated terminal error deltas do not allocate playback state',
    () async {
      final initial = player.state;
      final errors = <String>[];
      final sub = player.stream.error.listen(errors.add);
      events.add({'id': player.id, 'firstFrame': true});
      events.add({'id': player.id, 'error': 'Android TV 播放错误（4005）'});
      events.add({'id': player.id, 'error': 'Android TV 播放错误（4005）'});
      await player.waitUntilFirstFrameRendered;
      await Future<void>.delayed(Duration.zero);
      expect(player.state, same(initial));
      expect(errors, hasLength(2));
      await sub.cancel();
    },
  );
}
