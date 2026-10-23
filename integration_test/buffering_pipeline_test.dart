import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/features/cinema/cinema_buffer_status.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/features/cinema/cinema_native_cache_state.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/services/player/native_playback_setup.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const fixtures = String.fromEnvironment('NAKU_BUFFER_NATIVE_FIXTURES');
  testWidgets(
    'real HLS keeps preloading while paused and while playing',
    (tester) async {
      final config =
          jsonDecode(await File('$fixtures/config.json').readAsString()) as Map;
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
      await MacOSSystemProxy.initialize();
      final cache = CinemaMediaCache(directory: Directory('$fixtures/cache'));
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      final monitor = CinemaBufferMonitor(player);
      CinemaCacheSession? session;
      var playing = false, stalls = 0;
      final subscription = player.stream.buffering.listen((buffering) {
        session?.update(player.state.position, buffering: buffering);
        if (playing && buffering) stalls++;
      });
      final positions = player.stream.position.listen((position) {
        session?.update(position, buffering: player.state.buffering);
      });
      Map<String, Object> sample() => {
        'position': player.state.position.inMilliseconds / 1000,
        'bufferedUntil': player.state.buffer.inMilliseconds / 1000,
        'bytes': monitor.value.bytes,
        'mediaSeconds': monitor.value.mediaSeconds,
        'idle': monitor.value.idle,
        'end': cinemaNativeCacheState(native)['cache-end'] ?? 0,
        'route': session?.networkRoute ?? '',
      };
      try {
        final opened = (await cache.open(
          config['episode']['url'],
          Map<String, String>.from(config['sourceHeaders']),
          hls: true,
        ))!;
        session = opened.session;
        await native.setProperty('ao', 'null');
        // media_kit starts in audio-only mode until a video controller binds.
        // This headless probe explicitly enables the video demuxer as well.
        await native.setProperty('vid', 'auto');
        await configureNativePlayback(
          native,
          Uri.parse(opened.url),
          isCurrent: () => true,
          diskCache: false,
          bufferBytes: 256 * 1024 * 1024,
        );
        final ready = player.stream.duration.firstWhere(
          (d) => d.inSeconds > 1000,
        );
        await player.open(
          Media(
            opened.url,
            start: Duration(seconds: config['positionSeconds']),
          ),
          play: false,
        );
        await ready.timeout(const Duration(seconds: 35));
        monitor.start();
        final initial = sample();
        debugPrint('BUFFER_STAGE: paused preload started');
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(seconds: 1));
          await monitor.sample();
          if (monitor.value.mediaSeconds > 50) break;
        }
        final paused = sample();
        debugPrint(
          'BUFFER_PAUSED: ${jsonEncode({...paused, 'playing': player.state.playing, 'duration': player.state.duration.inSeconds, 'diskBytes': cache.bytesUsed, 'downloadedBytes': session.downloadedBytes, 'vid': await native.getProperty('vid'), 'aid': await native.getProperty('aid'), 'cache-secs': await native.getProperty('cache-secs'), 'demuxer-max-bytes': await native.getProperty('demuxer-max-bytes')})}',
        );
        expect(player.state.playing, isFalse);
        expect(monitor.value.bytes, greaterThan(1024 * 1024));
        expect(monitor.value.mediaSeconds, greaterThan(30));
        expect(session.networkRoute.isNotEmpty || cache.hits > 0, true);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('buffer-preview'),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '美国恐怖故事 · 第十季 · 第三集',
                        style: TextStyle(fontSize: 24),
                      ),
                      const SizedBox(height: 18),
                      const Text('真实片源 · 暂停预加载测试'),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          CinemaBufferStatus(
                            monitor: monitor,
                            capacity: 256 * 1024 * 1024,
                            rate: 1,
                            routeLabel: () => session?.networkRoute ?? '',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('buffer-preview')),
        );
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$fixtures/buffer.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        playing = true;
        await player.play();
        await Future<void>.delayed(const Duration(seconds: 2));
        await monitor.sample();
        final before = sample();
        debugPrint('BUFFER_STAGE: playing and refilling');
        await Future<void>.delayed(const Duration(seconds: 8));
        await monitor.sample();
        final after = sample();
        expect(
          (after['position'] as num) - (before['position'] as num),
          greaterThan(5),
        );
        expect(after['end'] as num, greaterThan(before['end'] as num));
        expect(
          after['bufferedUntil'] as num,
          greaterThan(before['bufferedUntil'] as num),
        );
        final report = {
          'title': config['title'],
          'episode': config['episode']['name'],
          'initial': initial,
          'paused': paused,
          'playingBefore': before,
          'playingAfter': after,
          'bufferingEventsDuringPlayback': stalls,
          'cacheDiskBytes': cache.bytesUsed,
        };
        await File('$fixtures/result.json').writeAsString(jsonEncode(report));
        debugPrint('NATIVE_HLS_BUFFER: ${jsonEncode(report)}');
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        monitor.dispose();
        await subscription.cancel();
        await positions.cancel();
        await session?.close();
        await player.dispose();
        await cache.shutdown();
        cache.dispose();
        cache.transport.dio.close(force: true);
        CinemaMediaRouter.instance.close();
      }
    },
    skip: fixtures.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
