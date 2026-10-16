import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_media_source.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_downloads.dart';
import 'package:kazumi/request/core/dio_logger_interceptor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final namespace = List.filled(64, 'a').join();
  late String reference;
  setUp(() {
    reference = nasMediaReference(
      namespace: namespace,
      id: 42,
      library: 2,
      path: '/volume1/收藏/测试 & 原画.mkv',
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CinemaNASClient.channel, null);
  });

  test(
    'reference round trips paths and rejects missing device identity and embedded credentials',
    () {
      expect(
        parseNASMediaReference(reference)['path'],
        '/volume1/收藏/测试 & 原画.mkv',
      );
      expect(
        () => parseNASMediaReference('$reference&token=secret'),
        throwsFormatException,
      );
      expect(
        () =>
            parseNASMediaReference(reference.replaceFirst(namespace, 'other')),
        throwsFormatException,
      );
      expect(
        () => parseNASMediaReference(reference.replaceFirst('id=42', 'id=0')),
        throwsFormatException,
      );
    },
  );

  test(
    'playback resolves current authenticated URL without rewriting stable metadata',
    () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(CinemaNASClient.channel, (call) async {
            methods.add(call.method);
            if (call.method == 'ensure') {
              expect((call.arguments as Map)['namespace'], namespace);
              return {'namespace': namespace};
            }
            if (call.method == 'asset') {
              return 'https://nas.test/ugreen/v1/video/details/downloadOriginalFile?token=ephemeral';
            }
            throw StateError('Unexpected method');
          });
      final episode = CinemaEpisode(name: '原画', url: reference);
      final resolved = await resolveCinemaMedia(
        source: cinemaNASSource,
        route: CinemaRoute(name: 'NAS 原画', episodes: [episode]),
        episode: episode,
        resolve: (_, _) => throw StateError('NAS must not use web scraping'),
      );
      expect(resolved.url, contains('token=ephemeral'));
      expect(episode.url, reference);
      expect(methods, ['ensure', 'asset']);
    },
  );

  test(
    'NAS playback and downloads share token-free history and offline identity',
    () async {
      final root = await Directory.systemTemp.createTemp('naku-nas-history-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/library.json');
      final store = CinemaStore(file: file, defaults: [], sourcePacks: []);
      final title = CinemaTitle(
        id: '$namespace:42',
        sourceId: cinemaNASSource.id,
        title: '测试电影',
        routes: [
          CinemaRoute(
            name: 'NAS 原画',
            episodes: [CinemaEpisode(name: '原画', url: reference)],
          ),
        ],
      );
      await store.recordProgress(
        title: title,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 123,
        durationSeconds: 1000,
      );
      final reopened = CinemaStore(file: file, defaults: [], sourcePacks: []);
      await reopened.load();
      expect(reopened.historyFor(title)?.positionSeconds, 123);
      final record = cinemaDownloadRecord(title, cinemaNASSource, 0);
      final payload = jsonEncode({
        'history': await file.readAsString(),
        'download': record.mediaMetadata,
      });
      expect(payload, isNot(contains('token=')));
      expect(payload, isNot(contains('password')));
      expect(
        jsonDecode(
          record.mediaMetadata,
        )['title']['routes'][0]['episodes'][0]['url'],
        reference,
      );
      store.dispose();
      reopened.dispose();
    },
  );

  test('request logs exclude NAS session query values', () {
    final value = DioLoggerInterceptor.safeUri(
      Uri.parse('https://nas.test/ugreen/download?token=secret&paths=private'),
    );
    expect(value, 'https://nas.test/ugreen/download');
    expect(
      DioLoggerInterceptor.safeUri(
        Uri.parse('https://source.test/list?page=2'),
      ),
      contains('page=2'),
    );
  });
  test(
    'movie versions are separate routes while television files remain episodes',
    () {
      final files = [
        (label: '4K', path: '/film/a.mkv'),
        (label: '1080P', path: '/film/b.mp4'),
      ];
      final movie = createCinemaNASTitle(
        namespace: namespace,
        row: {'ug_video_info_id': 42, 'media_lib_set_id': 2, 'type': 1},
        files: files,
      );
      expect(movie.routes.length, 2);
      expect(movie.routes.every((r) => r.episodes.length == 1), isTrue);
      final tv = createCinemaNASTitle(
        namespace: namespace,
        row: {'ug_video_info_id': 43, 'media_lib_set_id': 2, 'type': 2},
        files: files,
      );
      expect(tv.routes.length, 1);
      expect(tv.routes.single.episodes.length, 2);
    },
  );
  test(
    'NAS detail provider identities and metadata enrich the selected season',
    () {
      final title = createCinemaNASTitle(
        namespace: namespace,
        row: {
          'ug_video_info_id': 43,
          'media_lib_set_id': 2,
          'type': 2,
          'name': '老友记',
          'year': 0,
        },
        detail: {
          'video_info': {
            'ug_video_info_id': 999,
            'media_lib_set_id': 9,
            'type': 1,
            'name': '老友记 第一季',
            'year': 1994,
            'introduction': 'Six friends in New York.',
            'douban_id': 1393859,
            'imdb_id': 'tt0108778',
            'tmdb_id': 1668,
            'score': 8.4,
          },
        },
        files: [(label: '第 1 集', path: '/series/s01/e01.mkv')],
      );
      expect(title.title, '老友记 第一季');
      expect(title.description, 'Six friends in New York.');
      expect(title.year, '1994');
      expect(title.doubanId, '1393859');
      expect(title.imdbId, 'tt0108778');
      expect(title.sourceDoubanScore, isNull);
      expect(title.category, '电视剧');
      expect(title.id, '$namespace:43');
      final ref = parseNASMediaReference(
        title.routes.single.episodes.single.url,
      );
      expect(ref['id'], '43');
      expect(ref['library'], '2');
      expect(ref['nas'], namespace);
    },
  );

  test(
    'NAS provider IDs never cross namespaces or accept invalid identities',
    () {
      for (final row in [
        {'tmdb_id': 1393859, 'score': 9.7},
        {'douban_id': 0, 'imdb_id': '1393859'},
        {'douban_id': 'https://example.test/1393859', 'imdb_id': 'ttbad'},
        {'douban_id': '1234567890123'},
      ]) {
        final title = createCinemaNASTitle(
          namespace: namespace,
          row: {'ug_video_info_id': 42, 'media_lib_set_id': 2, ...row},
          files: [],
        );
        expect(title.doubanId, isEmpty);
        expect(title.imdbId, isEmpty);
        expect(title.sourceDoubanScore, isNull);
        expect(title.year, isEmpty);
      }
    },
  );
}
