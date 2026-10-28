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
}
