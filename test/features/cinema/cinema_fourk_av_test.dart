import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_detail_comparison.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_fourk_av.dart';
import 'package:kazumi/features/cinema/cinema_media_source.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_route_probe.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

String fixture(String name) =>
    File('test/features/cinema/fixtures/4kav/$name.html').readAsStringSync();
Uint8List box(String name, List<int> data) {
  final out = Uint8List(8 + data.length);
  ByteData.sublistView(out).setUint32(0, out.length);
  out.setRange(4, 8, name.codeUnits);
  out.setRange(8, out.length, data);
  return out;
}

Uint8List init(int width) {
  final sample = Uint8List(28);
  ByteData.sublistView(sample)
    ..setUint16(24, width)
    ..setUint16(26, 2160);
  return box(
    'moov',
    box(
      'trak',
      box(
        'mdia',
        box(
          'minf',
          box(
            'stbl',
            box('stsd', [...List.filled(8, 0), ...box('hvc1', sample)]),
          ),
        ),
      ),
    ),
  );
}

class Transport extends CinemaMediaTransport {
  Transport({this.width = 3840, this.low = false}) : super(dio: Dio());
  final int width;
  final bool low;
  final calls = <Uri>[];
  @override
  Future<Uint8List> bytes(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    int limit = 2 * 1024 * 1024,
    bool partial = false,
    String? range,
    bool metadata = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add(uri);
    expect(headers['User-Agent'], contains('Safari/605'));
    expect(cancel?.isCancelled ?? false, false);
    if (uri.path.endsWith('.mp4')) return init(width);
    if (uri.path.endsWith('.m3u8')) {
      return Uint8List.fromList(
        utf8.encode('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\n1.m4s\n'),
      );
    }
    return Uint8List.fromList(
      utf8.encode(fixture('movie').replaceAll('/4K/', low ? '/720P/' : '/4K/')),
    );
  }
}

void main() {
  final source = cinemaFourkAVSourcePack.sources.single;
  test(
    'search uses existing identity and never advertises unmeasured quality',
    () {
      final rows = CinemaFourkAV.parseSearch(fixture('search'));
      expect(rows, isNotEmpty);
      expect(rows.first['vod_name'], '抓娃娃');
      expect(rows.first['vod_year'], '2024');
      final parsed = CinemaRepository.parseMacCmsPage(source, {'list': rows});
      expect(parsed.items.first.remarks, isEmpty);
      expect(parsed.items.first.routes, isEmpty);
      final other = CinemaTitle.fromJson({
        ...parsed.items.first.toJson(),
        'id': '123',
        'sourceId': 'maccms-ruyi',
      });
      expect(
        groupCinemaTitles([parsed.items.first, other]).single.variants,
        hasLength(2),
      );
      expect(CinemaFourkAV.title('庆余年 第2季第1集'), '庆余年 第2季');
      expect(CinemaFourkAV.title('抓娃娃 4K版'), '抓娃娃');
    },
  );
  test(
    'series preserves 36 sorted episodes in same season and native page identities',
    () {
      final row = CinemaFourkAV.parseDetail(
        fixture('tv'),
        'tv/105778-joy-of-life-s02e01',
      );
      final title = CinemaRepository.parseMacCmsPage(source, {
        'list': [row],
      }).items.single;
      expect(title.title, '庆余年 第2季');
      expect(title.year, '2024');
      final episodes = title.routes.single.episodes;
      expect(episodes.length, 36);
      expect(episodes.first.name, '第1集');
      expect(episodes.last.name, '第36集');
      expect(episodes.every((e) => CinemaFourkAV.isPage(e.url)), isTrue);
      final candidate = CinemaPlaybackCandidate(
        title: title,
        source: source,
        routeIndex: 0,
        episodeIndex: 0,
      );
      expect(CinemaRouteProbeBatch.plan([candidate]), hasLength(1));
      expect(
        cinemaUsesDirectMedia(source, title.routes.single, episodes.first),
        isFalse,
      );
    },
  );
  test(
    'rejects other origins, adult category, traversal and malformed catalogue',
    () {
      for (final url in [
        'http://4k-av.com/movie/006920-successor/',
        'https://evil.com/movie/006920-successor/',
        'https://4k-av.com/av/006920-successor/',
        'https://4k-av.com/movie/006920-successor/?u=x',
      ]) {
        expect(CinemaFourkAV.isPage(url), isFalse);
      }
      expect(
        () => CinemaFourkAV.parseSearch('<html>blocked</html>'),
        throwsFormatException,
      );
    },
  );
  test(
    'playback and downloads use header-confirmed native 4K without web resolver',
    () async {
      final transport = Transport();
      addTearDown(() => transport.dio.close());
      final result = await resolveCinemaMedia(
        source: source,
        route: const CinemaRoute(name: '原画', episodes: []),
        episode: const CinemaEpisode(
          name: '正片',
          url: 'https://4k-av.com/movie/006920-successor/',
        ),
        fourkAV: CinemaFourkAV(transport: transport),
        resolve: (_, _) => throw StateError('unexpected web resolver'),
      );
      expect(result.url, contains('/4K/'));
      expect(result.format, VideoSourceFormat.hls);
      expect(result.headers, cinemaFourkAVHeaders);
      expect(transport.calls, hasLength(3));
    },
  );
  test(
    '1080 headers and 720 fallback cannot become a 4K playback route',
    () async {
      for (final transport in [Transport(width: 1920), Transport(low: true)]) {
        addTearDown(() => transport.dio.close());
        await expectLater(
          CinemaFourkAV(
            transport: transport,
          ).resolve('https://4k-av.com/movie/006920-successor/'),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'native live catalogue, 4K resolver and media probe',
    () async {
      final repository = CinemaRepository();
      final page = await repository.search(source, '抓娃娃');
      expect(page.items.any((t) => t.title == '抓娃娃'), isTrue);
      final title = await repository.detail(
        source,
        page.items.firstWhere((t) => t.title == '抓娃娃'),
      );
      final client = CinemaFourkAV();
      addTearDown(() => client.transport.dio.close(force: true));
      final url = await client.resolve(title.routes.first.episodes.first.url);
      final result = await CinemaMediaProbe.detail(transport: client.transport)
          .measure(
            url,
            cinemaFourkAVHeaders,
            hls: true,
            timeout: const Duration(seconds: 9),
          );
      debugPrint(
        '4KAV_NATIVE_LIVE ${jsonEncode({'title': title.title, 'url': url, 'ok': result.ok, 'width': result.width, 'height': result.height, 'ms': result.elapsedMs, 'reason': result.reason})}',
      );
      expect(result.confirmedQualityTier, 2160);
      final comparison = CinemaDetailComparison(
        title: title,
        source: source,
        variants: [],
        sources: [source],
        repository: repository,
      );
      addTearDown(comparison.dispose);
      await comparison.start();
      expect(comparison.measuredRecommendation?.source.id, source.id);
      expect(comparison.results.values.single.confirmedQualityTier, 2160);
      final browse = await repository.browse(source, categoryId: '1');
      expect(browse.items, isNotEmpty);
    },
    skip: !const bool.fromEnvironment('NAKU_4KAV_LIVE'),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
