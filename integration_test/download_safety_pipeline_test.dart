import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/services/download/download_catalog.dart';
import 'package:kazumi/services/video_source/services.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

class _NativePaths extends PathProviderPlatform {
  _NativePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Native download did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const fixtures = String.fromEnvironment('NAKU_DOWNLOAD_NATIVE_FIXTURES');
  const media = String.fromEnvironment('NAKU_DOWNLOAD_NATIVE_MEDIA');
  const expectedVideos = int.fromEnvironment('NAKU_DOWNLOAD_NATIVE_COUNT');
  const liveManifest = String.fromEnvironment('NAKU_DOWNLOAD_LIVE_MANIFEST');
  testWidgets(
    'native recovery, all retained videos open/seek/play, isolated WKWebView episodes',
    (tester) async {
      await windowManager.ensureInitialized();
      await windowManager.show();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('NAKU 下载恢复与原生播放验证'))),
        ),
      );
      final catalog = DownloadCatalog(Directory('$fixtures/read-only-index'));
      final records = await catalog.recover([media]);
      expect(records, isNotEmpty);
      expect(
        records.fold<int>(
          0,
          (n, r) =>
              n +
              r.episodes.values
                  .where((e) => e.status == DownloadStatus.completed)
                  .length,
        ),
        expectedVideos,
      );
      final player = Player();
      final videoController = VideoController(player);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Video(controller: videoController, controls: NoVideoControls),
          ),
        ),
      );
      await videoController.platform.future.timeout(
        const Duration(seconds: 10),
      );
      await (player.platform as NativePlayer).setProperty('ao', 'null');
      final results = <Map<String, dynamic>>[];
      try {
        for (final record in records) {
          final episodes =
              record.episodes.values
                  .where((e) => e.status == DownloadStatus.completed)
                  .toList()
                ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
          for (final episode in episodes) {
            await player.open(Media(episode.localM3u8Path), play: false);
            if (player.state.duration.inSeconds < 1000) {
              await player.stream.duration
                  .firstWhere((d) => d.inSeconds > 1000)
                  .timeout(const Duration(seconds: 15));
            }
            await player.seek(const Duration(seconds: 30));
            final advanced = player.stream.position.firstWhere(
              (position) => position.inMilliseconds > 30200,
            );
            await player.play();
            await advanced.timeout(const Duration(seconds: 10));
            await player.pause();
            expect(player.state.position.inMilliseconds, greaterThan(30200));
            expect(player.state.videoParams.w ?? 0, greaterThan(0));
            final row = {
              'id': record.bangumiId,
              'episode': episode.episodeNumber,
              'duration': player.state.duration.inSeconds,
              'positionMs': player.state.position.inMilliseconds,
              'width': player.state.videoParams.w,
              'height': player.state.videoParams.h,
            };
            results.add(row);
            debugPrint('NATIVE_RETAINED_VIDEO: ${jsonEncode(row)}');
          }
        }
      } finally {
        await player.dispose();
      }
      // Native WKWebView loads independent episode documents, even with the
      // same parser and origin. Local HTTP removes third-party availability from
      // this regression while exercising the real JS bridge and native plugin.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final episode = request.uri.pathSegments.last;
        request.response.headers.contentType = ContentType.html;
        request.response.write('''<!doctype html><html><body><script>
        function report(){
          if(window.flutter_inappwebview){window.flutter_inappwebview.callHandler('VideoBridgeDebug','$origin/media/$episode.mp4');}
          else {setTimeout(report,20);}
        } setTimeout(report,100);
        </script></body></html>''');
        await request.response.close();
      });
      final resolver = WebViewVideoSourceService();
      try {
        for (var episode = 1; episode <= 3; episode++) {
          final resolved = await resolver.resolve(
            '$origin/page/$episode',
            useLegacyParser: false,
            timeout: const Duration(seconds: 15),
          );
          expect(resolved.url, '$origin/media/$episode.mp4');
          debugPrint('NATIVE_FRESH_RESOLVER: episode=$episode passed');
        }
      } finally {
        await resolver.dispose();
        await server.close(force: true);
      }
      await File('$fixtures/native-result.json').writeAsString(
        jsonEncode({'videos': results, 'nativeWebViewEpisodes': 3}),
        flush: true,
      );
    },
    skip: fixtures.isEmpty || media.isEmpty,
  );

  testWidgets(
    'native iframe parsing, real HTTP downloads, duplicate quarantine and index recovery',
    (tester) async {
      final sandbox = await Directory(
        '$fixtures/pipeline-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _NativePaths(sandbox.path);
      await Directory('${sandbox.path}/hive').create();
      Hive.init('${sandbox.path}/hive');
      await GStorage.init();
      final repository = DownloadRepository();
      final writes = AsyncSerialQueue();
      final manager = DownloadManager();
      manager.onProgress = (key, number, episode, _) {
        unawaited(
          writes.run(() => repository.updateEpisode(key, number, episode)),
        );
      };
      final contents = {
        1: await File('$fixtures/episode-1.mp4').readAsBytes(),
        2: await File('$fixtures/episode-2.mp4').readAsBytes(),
      };
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final parts = request.uri.pathSegments;
        final number = int.tryParse(parts.last.replaceAll('.mp4', '')) ?? 1;
        if (parts.first == 'media') {
          request.response.headers.contentType = ContentType('video', 'mp4');
          final bytes = contents[number == 3 ? 1 : number]!;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          request.response.headers.contentType = ContentType.html;
          if (parts.first == 'legacy') {
            request.response.write(
              '<iframe src="$origin/player?url=${Uri.encodeComponent('$origin/media/$number.mp4')}"></iframe>',
            );
          } else if (parts.first == 'page') {
            request.response.write(
              '<iframe src="$origin/frame/$number"></iframe>',
            );
          } else {
            request.response.write(
              '<html><body><video src="$origin/media/$number.mp4"></video></body></html>',
            );
          }
        }
        await request.response.close();
      });
      final resolver = WebViewVideoSourceService();
      final player = Player();
      final controller = VideoController(player);
      final record = DownloadRecord(
        9001,
        '原生下载隔离验证',
        '',
        'native-fixture',
        {},
        DateTime.now(),
      );
      final evidence = <Map<String, Object?>>[];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Video(controller: controller, controls: NoVideoControls),
            ),
          ),
        );
        await controller.platform.future.timeout(const Duration(seconds: 10));
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        // Same host and same service, modern nested frames followed by a legacy
        // iframe parser. The third URL serves episode one's identical bytes.
        for (var number = 1; number <= 3; number++) {
          final legacy = number == 2;
          final page = '$origin/${legacy ? 'legacy' : 'page'}/$number';
          final resolved = await resolver.resolve(
            page,
            useLegacyParser: legacy,
            timeout: const Duration(seconds: 15),
          );
          expect(resolved.url, '$origin/media/$number.mp4');
          final episode = DownloadEpisode(
            number,
            '第$number集',
            0,
            DownloadStatus.pending,
            0,
            0,
            0,
            '',
            '${sandbox.path}/downloads/9001_native-fixture/$number',
            resolved.url,
            null,
            '',
            0,
            page,
          );
          record.episodes[number] = episode;
          await repository.putRecord(record);
          await manager.enqueue(
            DownloadRequest(
              recordKey: record.key,
              bangumiId: record.bangumiId,
              pluginName: record.pluginName,
              episodeNumber: number,
              m3u8Url: resolved.url,
              httpHeaders: {},
              adBlockerEnabled: false,
              episode: episode,
            ),
          );
          await _until(() => !manager.isDownloading(record.key, number));
          await writes.run(() async {});
          if (number == 3) {
            expect(episode.status, DownloadStatus.failed);
            expect(episode.networkM3u8Url, isEmpty);
            expect(
              await File('${episode.downloadDirectory}/video.mp4').exists(),
              isFalse,
            );
            expect(
              await File('${episode.downloadDirectory}/video.mp4.tmp').exists(),
              isTrue,
            );
            evidence.add({
              'episode': number,
              'duplicateBlocked': true,
              'retryWillResolveAgain': true,
            });
            continue;
          }
          expect(
            episode.status,
            DownloadStatus.completed,
            reason: episode.errorMessage,
          );
          final bytes = await File(episode.localM3u8Path).readAsBytes();
          expect(bytes, contents[number]);
          await player.open(Media(episode.localM3u8Path), play: false);
          if (player.state.duration.inMilliseconds < 1000) {
            await player.stream.duration
                .firstWhere((d) => d.inMilliseconds > 1000)
                .timeout(const Duration(seconds: 10));
          }
          await player.seek(const Duration(milliseconds: 200));
          final advanced = player.stream.position.firstWhere(
            (d) => d.inMilliseconds > 400,
          );
          await player.play();
          await advanced.timeout(const Duration(seconds: 10));
          await player.pause();
          expect(player.state.videoParams.w, 320);
          evidence.add({
            'episode': number,
            'sha256': sha256.convert(bytes).toString(),
            'nativePlayback': true,
            'parser': legacy ? 'legacy' : 'modern',
          });
        }
        // Clear only the isolated test index, not the user's database or media.
        await GStorage.downloads.clear();
        await GStorage.downloads.flush();
        final recovered = await repository.recoverLocalRecords();
        expect(recovered, 3);
        final restored = repository.getRecord(record.key)!;
        expect(restored.episodes[1]!.status, DownloadStatus.completed);
        expect(restored.episodes[2]!.status, DownloadStatus.completed);
        expect(restored.episodes[3]!.status, isNot(DownloadStatus.completed));
        await File('$fixtures/download-pipeline-result.json').writeAsString(
          jsonEncode({
            'episodes': evidence,
            'recoveredRecords': recovered,
            'userStorageWasNotOpened': true,
          }),
          flush: true,
        );
      } finally {
        await resolver.dispose();
        await player.dispose();
        await server.close(force: true);
        await Hive.close();
        PathProviderPlatform.instance = previousPaths;
      }
    },
    skip: fixtures.isEmpty,
  );

  testWidgets(
    'original 7sefun pages resolve to the independently audited episode media',
    (tester) async {
      final audit = jsonDecode(await File(liveManifest).readAsString()) as Map;
      final rows = (audit['episodes'] as List).cast<Map>().where(
        (row) =>
            row['route'] == 1 &&
            ((row['series'] == 32571 && {7, 9, 10}.contains(row['episode'])) ||
                (row['series'] == 29133 && {2, 4}.contains(row['episode']))),
      );
      final resolver = WebViewVideoSourceService();
      final results = <Map<String, Object?>>[];
      try {
        for (final row in rows) {
          final resolved = await resolver.resolve(
            row['page'] as String,
            useLegacyParser: false,
            timeout: const Duration(seconds: 35),
          );
          final actual = Uri.parse(resolved.url),
              expected = Uri.parse(row['media'] as String);
          expect(actual.host, expected.host);
          expect(actual.path, expected.path);
          results.add({
            'series': row['series'],
            'entry': row['episode'],
            'matchesAuditedOriginal': true,
          });
          debugPrint('NATIVE_ORIGINAL_EPISODE: ${jsonEncode(results.last)}');
        }
        expect(results.length, 5);
        await File(
          '$fixtures/original-source-result.json',
        ).writeAsString(jsonEncode(results), flush: true);
      } finally {
        await resolver.dispose();
      }
    },
    skip: fixtures.isEmpty || liveManifest.isEmpty,
  );
}
