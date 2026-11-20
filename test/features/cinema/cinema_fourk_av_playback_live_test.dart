import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_fourk_av.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '4K-AV native media engine decodes movie and series video plus audio',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      final resolver = CinemaFourkAV(
        transport: CinemaMediaTransport(
          dio: Dio()
            ..httpClientAdapter = IOHttpClientAdapter(
              createHttpClient: () => _RealHttp().createHttpClient(null),
            ),
        ),
      );
      addTearDown(() => resolver.transport.dio.close(force: true));
      for (final id in [
        'movie/006920-successor',
        'movie/005664-pegasus-2',
        'tv/105778-joy-of-life-s02e01',
      ]) {
        final url = await resolver.resolve('https://4k-av.com/$id/');
        final player = Player();
        try {
          final native = player.platform as NativePlayer;
          await native.setProperty('vo', 'null');
          await native.setProperty('ao', 'null');
          await native.setProperty('vid', 'auto');
          await player.open(Media(url, httpHeaders: cinemaFourkAVHeaders));
          await player.stream.position
              .firstWhere((p) => p.inSeconds >= 8)
              .timeout(const Duration(seconds: 35));
          final width = await native.getProperty('video-params/w');
          final height = await native.getProperty('video-params/h');
          final audio = await native.getProperty('audio-codec-name');
          final sampleRate = await native.getProperty(
            'audio-params/samplerate',
          );
          final dropped = await native.getProperty('decoder-frame-drop-count');
          debugPrint(
            '4KAV_NATIVE_PLAYBACK ${jsonEncode({'id': id, 'width': width, 'height': height, 'audio': audio, 'samplerate': sampleRate, 'position': player.state.position.inMilliseconds, 'decoderDropped': dropped})}',
          );
          expect(int.parse(width), greaterThanOrEqualTo(3840));
          expect(audio, isNotEmpty);
          expect(int.parse(sampleRate), greaterThan(0));
        } finally {
          await player.dispose();
        }
      }
    },
    skip: const String.fromEnvironment('NAKU_MPV_LIBRARY').isEmpty,
    timeout: const Timeout(Duration(seconds: 150)),
  );
}
