import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_live_subtitles.dart';

class _Direct extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

class _Streams implements PlayerStream {
  final positions = StreamController<Duration>.broadcast();
  final playingEvents = StreamController<bool>.broadcast();
  @override
  Stream<Duration> get position => positions.stream;
  @override
  Stream<bool> get playing => playingEvents.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState get state =>
      const PlayerState(playing: true, position: Duration(seconds: 10));
  @override
  final _Streams stream = _Streams();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real local engine produces original captions and discards text on seek',
    () async {
      final calls = <String>[];
      final fixture = await File(
        const String.fromEnvironment('NAKU_ASR_FIXTURE'),
      ).readAsBytes();
      var supplied = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('naku/live_audio'), (
            call,
          ) async {
            calls.add(call.method);
            if (call.method == 'pull') {
              final pcm = supplied
                  ? Uint8List(0)
              : Uint8List.sublistView(fixture, 44, 32044);
              supplied = true;
              return {'active': true, 'error': 0, 'pcm': pcm};
            }
            return null;
          });
      final player = _Player();
      final live = CinemaLiveSubtitles(
        player,
        enginePath: const String.fromEnvironment('NAKU_ASR_ENGINE'),
        modelDirectory: const String.fromEnvironment('NAKU_ASR_MODELS'),
      );
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          await live.start();
          expect(live.enabled, true, reason: live.status);
          for (var i = 0; i < 100 && live.text.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(live.text.toLowerCase(), contains('welcome'));
          // ignore: avoid_print
          print('One-second audio recognition ms: ${live.lastRecognitionMilliseconds}');
          player.stream.positions.add(const Duration(seconds: 60));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(live.text, isEmpty);
          expect(calls, contains('clear'));
          await live.stop();
          expect(live.enabled, false);
          expect(calls.last, 'stop');
          expect(player.state.playing, true);
        }, _Direct());
      } finally {
        live.dispose();
        await player.stream.positions.close();
        await player.stream.playingEvents.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('naku/live_audio'),
              null,
            );
      }
    },
    skip: !const bool.fromEnvironment('NAKU_LIVE_ASR_TEST'),
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
