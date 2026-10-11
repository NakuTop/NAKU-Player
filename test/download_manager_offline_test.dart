import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytes(
  List<int> bytes, {
  int status = 200,
  String type = 'video/mp4',
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromBytes(
  bytes,
  status,
  headers: {
    'content-length': ['${bytes.length}'],
    'content-type': [type],
    ...headers,
  },
);
ResponseBody _text(String text) =>
    _bytes(utf8.encode(text), type: 'application/vnd.apple.mpegurl');
DownloadEpisode _episode(String directory, String url, {int number = 1}) =>
    DownloadEpisode(
      number,
      '第$number 集',
      0,
      DownloadStatus.pending,
      0,
      0,
      0,
      '',
      directory,
      url,
      null,
      '',
      0,
      url,
    );
DownloadRequest _request(
  DownloadEpisode episode, {
  String plugin = 'fixture',
}) => DownloadRequest(
  recordKey: '${plugin}_1',
  bangumiId: 1,
  pluginName: plugin,
  episodeNumber: episode.episodeNumber,
  m3u8Url: episode.networkM3u8Url,
  httpHeaders: {'Referer': 'https://fixture.invalid/'},
  adBlockerEnabled: false,
  episode: episode,
);
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('download fixture did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, media;
  late PathProviderPlatform oldPaths;
  late DownloadManager manager;
  setUpAll(() async {
    Logger.level = Level.off;
    root = await Directory.systemTemp.createTemp('naku-download-tests-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  setUp(() async {
    media = await root.createTemp('media-');
    manager = DownloadManager();
  });
  tearDown(() async {
    DioFactory.reset();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });
  Future<void> complete(DownloadEpisode episode) async {
    await manager.enqueue(_request(episode));
    await _until(
      () => !manager.isDownloading('fixture_1', episode.episodeNumber),
    );
  }

  test(
    'server ignoring Range restarts direct download without duplicate bytes',
    () async {
      final content = List<int>.generate(128, (i) => i);
      await File(
        '${media.path}/video.mp4.tmp',
      ).writeAsBytes(content.take(17).toList());
      final adapter = _Adapter((_) => _bytes(content));
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final episode = _episode(media.path, 'https://fixture.invalid/video.mp4');
      await complete(episode);
      expect(
        episode.status,
        DownloadStatus.completed,
        reason: episode.errorMessage,
      );
      expect(await File(episode.localM3u8Path).readAsBytes(), content);
      expect(adapter.requests.last.headers['Range'], 'bytes=17-');
    },
  );

  test('wrong Content-Range and HTML never count as completed video', () async {
    for (final html in [false, true]) {
      final dir = await media.createTemp();
      await File('${dir.path}/video.mp4.tmp').writeAsBytes([1, 2, 3]);
      DioFactory.downloadDio.httpClientAdapter = _Adapter((options) {
        if (options.responseType != ResponseType.stream) {
          return _bytes([0, 1, 2, 3]);
        }
        if (html) {
          return _bytes(utf8.encode('<html>expired</html>'), type: 'text/html');
        }
        return _bytes(
          [4, 5, 6],
          status: 206,
          headers: {
            'content-range': ['bytes 8-10/11'],
          },
        );
      });
      final episode = _episode(dir.path, 'https://fixture.invalid/video.mp4');
      await complete(episode);
      expect(episode.status, DownloadStatus.failed);
      expect(episode.localM3u8Path, isEmpty);
      expect(await File('${dir.path}/video.mp4').exists(), isFalse);
    }
  });

  test(
    '4K fMP4 HLS caches init, byte ranges and external audio into a local master',
    () async {
      final blob = List<int>.generate(64, (i) => i);
      final adapter = _Adapter((options) {
        switch (options.uri.path) {
          case '/master.m3u8':
            return _text('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",DEFAULT=YES,URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1920x1080
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=3840x2160,AUDIO="aud"
video.m3u8
''');
          case '/video.m3u8':
            return _text('''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="video.mp4",BYTERANGE="16@0"
#EXTINF:4,
#EXT-X-BYTERANGE:24@16
video.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:24
video.mp4
#EXT-X-ENDLIST
''');
          case '/audio.m3u8':
            return _text('''#EXTM3U
#EXT-X-TARGETDURATION:8
#EXT-X-MAP:URI="audio-init.mp4"
#EXTINF:8,
audio.m4s
#EXT-X-ENDLIST
''');
          case '/video.mp4':
            final match = RegExp(
              r'bytes=(\d+)-(\d+)',
            ).firstMatch(options.headers['Range'] as String)!;
            final start = int.parse(match[1]!), end = int.parse(match[2]!);
            return _bytes(
              blob.sublist(start, end + 1),
              status: 206,
              headers: {
                'content-range': ['bytes $start-$end/64'],
              },
            );
          case '/audio-init.mp4':
            return _bytes([3, 4, 5]);
          case '/audio.m4s':
            return _bytes([6, 7, 8]);
          default:
            throw StateError('Unexpected resource ${options.uri}');
        }
      });
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final episode = _episode(
        media.path,
        'https://fixture.invalid/master.m3u8',
      );
      await complete(episode);
      expect(
        episode.status,
        DownloadStatus.completed,
        reason: episode.errorMessage,
      );
      expect(episode.localM3u8Path, endsWith('master.m3u8'));
      expect(
        await File('${media.path}/init_0.mp4').readAsBytes(),
        blob.sublist(0, 16),
      );
      expect(
        await File('${media.path}/seg_00000.ts').readAsBytes(),
        blob.sublist(16, 40),
      );
      expect(
        await File('${media.path}/seg_00001.ts').readAsBytes(),
        blob.sublist(40),
      );
      expect(await File('${media.path}/audio/seg_00000.ts').readAsBytes(), [
        6,
        7,
        8,
      ]);
      for (final file in [
        'master.m3u8',
        'playlist.m3u8',
        'audio/playlist.m3u8',
      ]) {
        final text = await File('${media.path}/$file').readAsString();
        expect(text, isNot(contains('https:')));
      }
      expect(
        adapter.requests.every(
          (r) => r.headers['Referer'] == 'https://fixture.invalid/',
        ),
        isTrue,
      );
      expect(adapter.requests.any((r) => r.uri.path == '/low.m3u8'), isFalse);
      expect(episode.downloadedSegments, 3);
      expect(episode.progressPercent, 1);
    },
  );

  test(
    'priority respects episode concurrency and cancellation drains before deleting',
    () async {
      manager.maxParallelEpisodes = 1;
      final gate = Completer<ResponseBody>();
      final started = Completer<void>();
      final adapter = _Adapter((options) {
        if (options.uri.path == '/first.mp4' &&
            options.responseType == ResponseType.stream) {
          if (!started.isCompleted) started.complete();
          return gate.future;
        }
        return _bytes([0, 1, 2, 3]);
      });
      DioFactory.downloadDio.httpClientAdapter = adapter;
      final first = _episode(
        '${media.path}/first',
        'https://fixture.invalid/first.mp4',
      );
      final second = _episode(
        '${media.path}/second',
        'https://fixture.invalid/second.mp4',
        number: 2,
      );
      await manager.enqueue(_request(first));
      await started.future;
      await manager.enqueuePriority(_request(second));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.requests.any((r) => r.uri.path == '/second.mp4'), isFalse);
      final deletion = manager.deleteEpisodeFiles(
        1,
        'fixture',
        1,
        episode: first,
      );
      gate.complete(_bytes([0, 1, 2, 3]));
      await deletion;
      await _until(() => !manager.isDownloading('fixture_1', 2));
      expect(await Directory(first.downloadDirectory).exists(), isFalse);
      expect(
        second.status,
        DownloadStatus.completed,
        reason: second.errorMessage,
      );
    },
  );
}
