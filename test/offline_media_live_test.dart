import 'dart:async';
import 'dart:io';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real HTTP range HLS download remains usable with its server offline',
    () async {
      final root = Directory(Platform.environment['NAKU_OFFLINE_FIXTURE']!);
      final storage = await Directory.systemTemp.createTemp(
        'naku-real-download-',
      );
      final old = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(storage.path);
      Hive.init(storage.path);
      await GStorage.init();
      DioFactory.downloadDio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            _RealHttp().createHttpClient(null)..findProxy = (_) => 'DIRECT',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final reads = <String>[];
      server.listen((request) async {
        final name = request.uri.path.substring(1);
        if (![
          'master.m3u8',
          'video.m3u8',
          'audio.m3u8',
          'video.mp4',
          'audio.mp4',
        ].contains(name)) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        reads.add(name);
        final bytes = await File('${root.path}/$name').readAsBytes();
        final range = request.headers.value('range');
        var start = 0, end = bytes.length - 1;
        if (range != null) {
          final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
          start = int.parse(match[1]!);
          end = int.tryParse(match[2]!) ?? end;
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      });
      final manager = DownloadManager();
      final url = 'http://127.0.0.1:${server.port}/master.m3u8';
      final episode = DownloadEpisode(
        1,
        'fixture',
        0,
        DownloadStatus.pending,
        0,
        0,
        0,
        '',
        '${root.path}/downloaded',
        url,
        null,
        '',
        0,
        url,
      );
      final done = Completer<void>();
      manager.onProgress = (_, _, e, _) {
        if ([
              DownloadStatus.completed,
              DownloadStatus.failed,
            ].contains(e.status) &&
            !done.isCompleted) {
          done.complete();
        }
      };
      try {
        await manager.enqueue(
          DownloadRequest(
            recordKey: 'fixture_1',
            bangumiId: 1,
            pluginName: 'fixture',
            episodeNumber: 1,
            m3u8Url: url,
            httpHeaders: const {},
            adBlockerEnabled: false,
            episode: episode,
          ),
        );
        await done.future.timeout(const Duration(seconds: 30));
        expect(
          episode.status,
          DownloadStatus.completed,
          reason: episode.errorMessage,
        );
        expect(reads, containsAll(['video.mp4', 'audio.mp4']));
        for (final name in [
          'master.m3u8',
          'playlist.m3u8',
          'audio/playlist.m3u8',
        ]) {
          expect(
            await File('${root.path}/downloaded/$name').readAsString(),
            isNot(contains('http')),
          );
        }
        await File(
          '${root.path}/download-result.txt',
        ).writeAsString(episode.localM3u8Path);
      } finally {
        await server.close(force: true);
        DioFactory.reset();
        await Hive.close();
        PathProviderPlatform.instance = old;
        await storage.delete(recursive: true);
      }
    },
    skip: Platform.environment['NAKU_OFFLINE_FIXTURE'] == null,
  );
}
