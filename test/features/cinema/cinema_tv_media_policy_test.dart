import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_nas_playback.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_route_probe.dart';
import 'package:kazumi/features/cinema/cinema_tv_media_policy.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'system proxy honors exclusions and explicit proxy remains authoritative',
    () async {
      final environment = CinemaTVMediaEnvironment(
        supported: () => true,
        reader: () async => {
          'key': 'network-a',
          'proxyHost': 'proxy.example',
          'proxyPort': 8080,
          'proxyExclusionList': ['*.direct.example'],
          'hasPac': false,
        },
      );
      await environment.refresh();
      expect(
        environment
            .proxyFor(
              Uri.parse('https://cdn.example/video'),
              const NetworkConfig(),
            )
            ?.host,
        'proxy.example',
      );
      expect(
        environment.proxyFor(
          Uri.parse('https://cdn.direct.example/video'),
          const NetworkConfig(),
        ),
        isNull,
      );
      expect(
        environment.proxyFor(
          Uri.parse('http://192.168.1.10/video'),
          const NetworkConfig(),
        ),
        isNull,
      );
      expect(
        environment
            .proxyFor(
              Uri.parse('https://cdn.example/video'),
              const NetworkConfig(proxyHost: 'manual.example', proxyPort: 8181),
            )
            ?.host,
        'manual.example',
      );
    },
  );
  test('unresolved PAC is not silently bypassed', () async {
    final environment = CinemaTVMediaEnvironment(
      supported: () => true,
      reader: () async => {'key': 'pac', 'hasPac': true},
    );
    await environment.refresh();
    expect(
      () => environment.proxyFor(
        Uri.parse('https://cdn.example/video'),
        const NetworkConfig(),
      ),
      throwsFormatException,
    );
    expect(
      environment.proxyFor(
        Uri.parse('https://192.168.1.10/video'),
        const NetworkConfig(),
      ),
      isNull,
    );
  });
  test('one codec maximum does not claim support for another codec', () async {
    final environment = CinemaTVMediaEnvironment(
      supported: () => true,
      reader: () async => {
        'key': 'decoder',
        'decoderCapabilities': [
          {'codec': 'AVC', 'maxWidth': 1920, 'maxHeight': 1080},
          {'codec': 'HEVC', 'maxWidth': 3840, 'maxHeight': 2160},
        ],
      },
    );
    await environment.refresh();
    CinemaMediaProbeResult result(String codec) => CinemaMediaProbeResult(
      ok: true,
      elapsedMs: 1,
      codec: codec,
      width: 3840,
      height: 2160,
    );
    expect(environment.supports(result('H.264')), false);
    expect(environment.supports(result('HEVC')), true);
    expect(environment.supports(result('AV1')), false);
  });
  test(
    'TV NAS profiles use numeric dimensions within decoder limit, not list order',
    () {
      final options = CinemaNASPlaybackOptions.fromMap({
        'isRelayOrigin': true,
        'profiles': [
          {'id': '854x480', 'label': '4K label is not evidence'},
          {'id': '3840x2160', 'label': '2160p'},
          {'id': '1920x1080', 'label': '1080p'},
          {'id': '1280x720', 'label': '720p'},
        ],
      });
      expect(options.tvProfiles(), ['1920x1080', '1280x720', '854x480']);
      expect(
        options.tvProfiles(maxWidth: 3840, maxHeight: 2160).first,
        '3840x2160',
      );
    },
  );
  test(
    'TV picks highest measured sustainable quality, not fastest lower quality',
    () {
      const source = CinemaSource(
        id: 'fixture',
        name: 'fixture',
        kind: CinemaSourceKind.maccms,
        url: 'https://example.invalid/api',
      );
      final title = CinemaTitle(
        id: 'one',
        sourceId: source.id,
        title: '同一集',
        routes: [
          for (final name in ['high', 'low'])
            CinemaRoute(
              name: name,
              episodes: [
                CinemaEpisode(
                  name: '第1集',
                  url: 'https://example.invalid/$name.mp4',
                ),
              ],
            ),
        ],
      );
      CinemaRouteMeasurement measure(
        int route,
        int width,
        int height,
        double mbps,
        int bitrate,
      ) => CinemaRouteMeasurement(
        CinemaPlaybackCandidate(
          title: title,
          source: source,
          routeIndex: route,
          episodeIndex: 0,
        ),
        CinemaMediaProbeResult(
          ok: true,
          elapsedMs: 100,
          width: width,
          height: height,
          mbps: mbps,
          bitrate: bitrate,
        ),
      );
      final high = measure(0, 3840, 2160, 50, 20000000),
          low = measure(1, 1920, 1080, 100, 4000000);
      expect(cinemaBestMeasuredTVRoute([low, high])?.candidate.routeIndex, 0);
      expect(
        cinemaBestMeasuredTVRoute([
          low,
          measure(0, 3840, 2160, 10, 20000000),
        ])?.candidate.routeIndex,
        1,
      );
      expect(
        cinemaBestMeasuredTVRoute([
          low,
          high,
        ], supported: (result) => result.width! <= 1920)?.candidate.routeIndex,
        1,
      );
    },
  );
  test(
    'HLS quality filtering retains rendition groups, headers and relative URI',
    () {
      const master =
          '#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="中文",URI="audio/index.m3u8"\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="简中",URI="sub/index.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,CODECS="hvc1.1.6.L120,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"\n4k/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"\n1080/index.m3u8\n';
      final base = Uri.parse('https://example.invalid/title/master.m3u8');
      final selected = cinemaTVSelectHlsVariant(
        master,
        base,
        base.resolve('1080/index.m3u8'),
      );
      expect(selected, contains('#EXT-X-VERSION:6'));
      expect(selected, contains('URI="audio/index.m3u8"'));
      expect(selected, contains('URI="sub/index.m3u8"'));
      expect(selected, contains('AUDIO="audio",SUBTITLES="subs"'));
      expect(selected, contains('1080/index.m3u8'));
      expect(selected, isNot(contains('4k/index.m3u8')));
      expect(cinemaHlsVariants(selected, base).single.codec, 'AVC');
    },
  );
}
