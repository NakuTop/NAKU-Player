import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_source.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/services/video_source/services.dart';
import 'package:kazumi/services/player/native_playback_setup.dart';

void main() {
  const source = CinemaSource(
    id: 'fixture',
    name: 'Fixture',
    kind: CinemaSourceKind.maccms,
    url: 'https://fixture.invalid/api',
  );
  test('HTML resolution keeps format and originating page Referer', () async {
    final result = await resolveCinemaMedia(
      source: source,
      route: const CinemaRoute(name: 'yun', episodes: []),
      episode: const CinemaEpisode(
        name: '1',
        url: 'https://fixture.invalid/play/1',
      ),
      resolve: (url, legacy) async => const VideoSource(
        url: 'https://cdn.invalid/token',
        offset: 0,
        type: VideoSourceType.online,
        format: VideoSourceFormat.hls,
      ),
    );
    expect(result.format, VideoSourceFormat.hls);
    expect(result.headers['Referer'], 'https://fixture.invalid/play/1');
  });
  test('direct HLS never opens a WebView', () async {
    final result = await resolveCinemaMedia(
      source: source,
      route: const CinemaRoute(name: 'm3u8', episodes: []),
      episode: const CinemaEpisode(
        name: '1',
        url: 'https://fixture.invalid/1.m3u8',
      ),
      resolve: (_, _) => throw StateError('must not resolve direct HLS'),
    );
    expect(result.format, VideoSourceFormat.hls);
    expect(result.headers, source.headers);
  });
  test('decoder fallback warnings are not terminal failures', () {
    expect(
      playbackFailureKind('Using software decoding after hwdec failure'),
      isNull,
    );
    expect(
      playbackFailureKind('tls: mbedtls_ssl_handshake returned -0x4e'),
      PlaybackFailureKind.network,
    );
    expect(
      playbackFailureKind('HTTP error 403 Forbidden'),
      PlaybackFailureKind.network,
    );
    expect(
      playbackFailureKind('Failed to recognize file format'),
      PlaybackFailureKind.format,
    );
  });
}
