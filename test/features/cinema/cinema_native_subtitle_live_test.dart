import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_live_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_replay.dart';
import 'package:kazumi/services/player/native_playback_setup.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_controller.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _SeasonClient extends CinemaOnlineSubtitles {
  _SeasonClient() : super(dio: Dio(), useFallbackCatalog: false);
  static const text = '1\n00:00:00,000 --> 00:00:04,000\n本季继承自写中文字幕\n';
  final requests = <({int season, int episode})>[];

  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    requests.add((season: season, episode: episode));
    return const CinemaSubtitleCatalogResult([
      {
        'url': 'https://fixture.invalid/AHS.S10E03.AMZN.FLUX.srt',
        'subtitleFileName': 'AHS.S10E03.AMZN.FLUX.srt',
        'provider': 'local test fixture',
        'lang': 'zh',
        'verified': true,
      },
    ], {});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async {
    expect(url, contains('S10E03'));
    return text;
  }
}

class _NetworkHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

// Move the Media Foundation fixture's moov before mdat for streaming.
Uint8List _streamableMp4(Uint8List source) {
  final data = ByteData.sublistView(source);
  final boxes = <({int start, int end, String type})>[];
  for (var at = 0; at + 8 <= source.length;) {
    final size = data.getUint32(at);
    if (size < 8 || at + size > source.length) {
      throw const FormatException('Invalid MP4 fixture');
    }
    boxes.add((
      start: at,
      end: at + size,
      type: String.fromCharCodes(source.sublist(at + 4, at + 8)),
    ));
    at += size;
  }
  final box = boxes.singleWhere((box) => box.type == 'moov');
  final moov = Uint8List.fromList(source.sublist(box.start, box.end));
  final offsets = ByteData.sublistView(moov);
  void adjust(int start, int end) {
    for (var at = start; at + 8 <= end;) {
      final size = offsets.getUint32(at);
      if (size < 8 || at + size > end) {
        throw const FormatException('Invalid MP4 box');
      }
      final type = String.fromCharCodes(moov.sublist(at + 4, at + 8));
      if (['moov', 'trak', 'mdia', 'minf', 'stbl'].contains(type)) {
        adjust(at + 8, at + size);
      }
      if (type == 'stco') {
        for (var index = 0; index < offsets.getUint32(at + 12); index++) {
          final entry = at + 16 + index * 4;
          offsets.setUint32(entry, offsets.getUint32(entry) + moov.length);
        }
      }
      at += size;
    }
  }

  adjust(0, moov.length);
  final output = BytesBuilder(copy: false);
  for (final box in boxes) {
    if (box.type == 'moov') continue;
    if (box.type == 'mdat') output.add(moov);
    output.add(source.sublist(box.start, box.end));
  }
  return output.takeBytes();
}

const fixtureAss = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Microsoft YaHei,36,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,测试中文字幕\\NOriginal line
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native season inheritance binds an exact episode and timing',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      final folder = await Directory.systemTemp.createTemp(
        'naku-native-season-',
      );
      final store = CinemaStore(
        file: File('${folder.path}/library.json'),
        defaults: const [],
      );
      final player = Player();
      CinemaSeasonSubtitleController? controller;
      try {
        await store.load();
        await CinemaSeasonSubtitlePreferences(store).remember(
          seriesIdentity: 'self-authored-season-fixture',
          season: 10,
          fromEpisode: 2,
          queryTitle: 'Native season fixture',
          row: const {
            'subtitleFileName': 'AHS.S10E02.AMZN.FLUX.srt',
            'provider': 'local test fixture',
            'lang': 'zh',
            'verified': true,
          },
          timing: const CinemaSubtitleTiming(offsetSeconds: 2.5),
        );
        await player.open(
          Media(
            File(
              const String.fromEnvironment('NAKU_ASR_FIXTURE'),
            ).uri.toString(),
          ),
          play: false,
        );
        for (
          var index = 0;
          index < 100 && player.state.duration.inSeconds < 4;
          index++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final client = _SeasonClient();
        controller = CinemaSeasonSubtitleController(
          player: player,
          store: store,
          seriesIdentity: 'self-authored-season-fixture',
          mediaIdentity: 'self-authored-E03',
          query: const CinemaSubtitleQuery(
            'Native season fixture',
            'series',
            10,
            3,
          ),
          client: client,
        );
        await controller.load();
        expect(client.requests.single, (season: 10, episode: 3));
        final native = player.platform as NativePlayer;
        expect(await native.getProperty('sid'), isNot(anyOf('no', 'auto', '')));
        final session = cinemaExternalSubtitleState(player);
        expect(session.active.value, true);
        expect(session.delay, 2.5);
        expect(player.state.playing, false);
        await player.seek(const Duration(milliseconds: 3500));
        for (
          var index = 0;
          index < 100 && !session.text.value.contains('本季继承');
          index++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(session.text.value, contains('本季继承自写中文字幕'));
        for (final boundary in [
          (at: 2499, visible: false),
          (at: 2500, visible: true),
          (at: 6499, visible: true),
          (at: 6500, visible: false),
        ]) {
          session.updatePosition(Duration(milliseconds: boundary.at));
          expect(
            session.text.value.isNotEmpty,
            boundary.visible,
            reason: 'Calibrated subtitle boundary ${boundary.at} ms',
          );
        }
        expect(player.state.playing, false);
        // ignore: avoid_print
        print(
          'Native E03 selected, season offset +2.5s, overlay visible at [2.5s, 6.5s), original paused intent preserved',
        );
      } finally {
        controller?.close();
        await player.dispose();
        await store.flush();
        store.dispose();
        for (final file in folder.listSync().whereType<File>()) {
          await file.delete();
        }
        await folder.delete();
      }
    },
    skip:
        !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST') ||
        const String.fromEnvironment('NAKU_ASR_FIXTURE').isEmpty,
    timeout: const Timeout(Duration(seconds: 25)),
  );
  test(
    'native MPV replays the heard words then pauses and restores playback rate',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      final player = Player();
      final replay = CinemaSubtitleReplay(player);
      try {
        await player.open(
          Media(
            File(
              const String.fromEnvironment('NAKU_ASR_FIXTURE'),
            ).uri.toString(),
          ),
          play: false,
        );
        for (var i = 0; i < 100 && player.state.duration.inSeconds < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await player.setRate(1.25);
        await player.seek(const Duration(seconds: 3));
        for (
          var i = 0;
          i < 100 && player.state.position.inMilliseconds < 2900;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await replay.capture();
        final target = replay.end!;
        await replay.play();
        expect(replay.listening, true);
        for (
          var i = 0;
          i < 100 &&
              (replay.listening ||
                  player.state.playing ||
                  player.state.rate != 1.25);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(replay.listening, false);
        expect(player.state.playing, false);
        expect(player.state.rate, 1.25);
        expect(
          (player.state.position - target).inMilliseconds.abs(),
          lessThan(500),
        );
      } finally {
        await replay.stop();
        replay.dispose();
        await player.dispose();
      }
    },
    skip:
        !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST') ||
        const String.fromEnvironment('NAKU_ASR_FIXTURE').isEmpty,
    timeout: const Timeout(Duration(seconds: 25)),
  );
  test(
    'extensionless HLS video and external subtitles probe independently',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      final clip = _streamableMp4(
        await File(
          const String.fromEnvironment('NAKU_HLS_VIDEO_FIXTURE'),
        ).readAsBytes(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final listener = server.listen((request) async {
        if (request.uri.path == '/watch') {
          request.response.headers.set(
            'Content-Type',
            'application/vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:3.0,\n/clip.mp4\n#EXT-X-ENDLIST\n',
          );
        } else if (request.uri.path == '/clip.mp4') {
          request.response.headers.set('Content-Type', 'video/mp4');
          request.response.add(clip);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final player = Player();
      final messages = <String>[];
      final logSubscription = player.stream.log.listen(
        (entry) => messages.add(entry.text),
      );
      try {
        await (player.platform as NativePlayer).setProperty('vid', 'auto');
        await (player.platform as NativePlayer).setProperty('vo', 'null');
        await player.open(
          Media('http://127.0.0.1:${server.port}/watch'),
          play: false,
        );
        for (
          var i = 0;
          i < 150 && player.state.duration.inMilliseconds < 2000;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          player.state.duration.inMilliseconds,
          greaterThanOrEqualTo(2000),
        );
        for (
          var i = 0;
          i < 100 &&
              !player.state.tracks.video.any(
                (track) => !['auto', 'no'].contains(track.id),
              );
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // ignore: avoid_print
        print(
          'HLS track count=${await (player.platform as NativePlayer).getProperty('track-list/count')}; logs=$messages',
        );
        expect(
          player.state.tracks.video.any(
            (track) => !['auto', 'no'].contains(track.id),
          ),
          true,
        );
        await applyCinemaExternalSubtitle(player, fixtureAss);
        expect(cinemaExternalSubtitleState(player).active.value, true);
        expect(
          cinemaExternalSubtitleState(player).text.value,
          contains('测试中文字幕'),
        );
        expect(
          messages.any((message) => message.contains('partial file')),
          isFalse,
        );
      } finally {
        await player.dispose();
        await logSubscription.cancel();
        await listener.cancel();
        await server.close(force: true);
      }
    },
    skip:
        !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST') ||
        const String.fromEnvironment('NAKU_HLS_VIDEO_FIXTURE').isEmpty,
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'live S10E02 English subtitle downloads and loads into MPV',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        MediaKit.ensureInitialized(
          libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
        );
        final client = CinemaOnlineSubtitles();
        final folder = await Directory.systemTemp.createTemp(
          'naku-english-live-',
        );
        final player = Player();
        try {
          final rows = await client.subtitles(
            'tt1844624',
            'series',
            season: 10,
            episode: 2,
          );
          final row = rows.firstWhere(
            (row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'eng'),
          );
          final text = await client.download('${row['url']}');
          final cue = cinemaSubtitleCues(text).first;
          final audio = File('${folder.path}/silence.wav');
          await audio.writeAsBytes(
            cinemaPcmWave(Uint8List(((cue.end ~/ 1000) + 5) * 32000)),
          );
          await player.open(Media(audio.path), play: false);
          for (
            var i = 0;
            i < 100 && player.state.duration.inMilliseconds < cue.end;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await player.seek(Duration(milliseconds: cue.start + 50));
          for (
            var i = 0;
            i < 100 && player.state.position.inMilliseconds < cue.start;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await (player.platform as NativePlayer).setProperty(
            'demuxer-lavf-format',
            'hls',
          );
          await applyCinemaExternalSubtitle(player, text, language: 'eng');
          expect(cinemaExternalSubtitleState(player).active.value, true);
          expect(cinemaExternalSubtitleState(player).text.value, isNotEmpty);
          expect(
            await (player.platform as NativePlayer).getProperty('sid'),
            isNot(anyOf('no', 'auto')),
          );
        } finally {
          client.close();
          await player.dispose();
          for (final file in folder.listSync().whereType<File>()) {
            await file.delete();
          }
          await folder.delete();
        }
      }, _NetworkHttp());
    },
    skip:
        !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST') ||
        !const bool.fromEnvironment('NAKU_LIVE_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
  test(
    'actual bilingual ASS is loaded mid-playback and produces Chinese dialogue',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      var text = await File(
        const String.fromEnvironment('NAKU_SUBTITLE_FIXTURE'),
      ).readAsString();
      if (const bool.fromEnvironment('NAKU_LIVE_SUBTITLE_TEST')) {
        await HttpOverrides.runWithHttpOverrides(() async {
          final client = CinemaOnlineSubtitles();
          try {
            final query = CinemaSubtitleQuery.parse(
              '美国恐怖故事 第10季',
              category: '欧美剧',
              episodeName: '第02集',
            );
            final result = await client.aggregate(
              query.title,
              query.type,
              season: query.season,
              episode: query.episode,
            );
            final row = result.rows.firstWhere(
              (row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'zh'),
            );
            text = await client.download(
              '${row['url']}',
              archiveEntry: row['archiveEntry'] as String?,
            );
            expect((row['chineseCueCount'] as int), greaterThan(500));
          } finally {
            client.close();
          }
        }, _NetworkHttp());
      }
      final cue = cinemaSubtitleCues(text).firstWhere(
        (cue) =>
            cue.start > 60000 && RegExp(r'[\u4e00-\u9fff]').hasMatch(cue.text),
      );
      final folder = await Directory.systemTemp.createTemp(
        'naku-native-subtitle-test-',
      );
      final audio = File('${folder.path}/silence.wav');
      await audio.writeAsBytes(
        cinemaPcmWave(Uint8List(((cue.end ~/ 1000) + 3) * 32000)),
      );
      final player = Player();
      try {
        final backend = player.platform as NativePlayer;
        await configureNativePlayback(
          backend,
          audio.uri,
          isCurrent: () => true,
          diskCache: false,
          bufferBytes: 128 * 1024 * 1024,
        );
        final forward = int.parse(
          await backend.getProperty('demuxer-max-bytes'),
        );
        final backward = int.parse(
          await backend.getProperty('demuxer-max-back-bytes'),
        );
        expect(forward + backward, 128 * 1024 * 1024);
        await player.open(Media(audio.path), play: false);
        for (
          var i = 0;
          i < 100 && player.state.duration.inMilliseconds < cue.end;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await player.seek(Duration(milliseconds: cue.start + 50));
        for (
          var i = 0;
          i < 100 && player.state.position.inMilliseconds < cue.start;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await applyCinemaExternalSubtitle(
          player,
          text,
          title: 'Public bilingual subtitle fixture',
        );
        final native = player.platform as NativePlayer;
        // ignore: avoid_print
        print(
          'Expected cue=${cue.start}-${cue.end}; position=${await native.getProperty('time-pos')}; sub-start=${await native.getProperty('sub-start')}; delay=${await native.getProperty('sub-delay')}; emitted chars=${player.state.subtitle.join().length}',
        );
        for (
          var i = 0;
          i < 40 &&
              !RegExp(
                r'[\u4e00-\u9fff]',
              ).hasMatch(player.state.subtitle.join());
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(player.state.subtitle.join()),
          true,
        );
        expect(cinemaExternalSubtitleState(player).active.value, true);
        expect(
          RegExp(
            r'[\u4e00-\u9fff]',
          ).hasMatch(cinemaExternalSubtitleState(player).text.value),
          true,
        );
        final selectedId = await native.getProperty('sid');
        await player.setSubtitleTrack(SubtitleTrack.no());
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(cinemaExternalSubtitleState(player).active.value, false);
        await player.setSubtitleTrack(
          SubtitleTrack(selectedId, 'Restored external', 'zh'),
        );
        for (
          var i = 0;
          i < 50 && !cinemaExternalSubtitleState(player).active.value;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(cinemaExternalSubtitleState(player).active.value, true);
        expect(
          RegExp(
            r'[\u4e00-\u9fff]',
          ).hasMatch(cinemaExternalSubtitleState(player).text.value),
          true,
        );
        // ignore: avoid_print
        print(
          'Real bilingual ASS: selected external SRT, Chinese dialogue emitted at ${cue.start} ms; source cues=${cinemaSubtitleCues(text).length}',
        );
      } finally {
        await player.dispose();
        if (await audio.exists()) await audio.delete();
        await folder.delete();
      }
    },
    skip:
        !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST') ||
        const String.fromEnvironment('NAKU_SUBTITLE_FIXTURE').isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'real MPV accepts ASS data and emits Chinese subtitle text',
    () async {
      MediaKit.ensureInitialized(
        libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
      );
      final player = Player(configuration: const PlayerConfiguration());
      final logs = <String>[];
      final sub = player.stream.log.listen((value) {
        logs.add(value.text);
      });
      try {
        await player.open(
          Media(
            File(
              const String.fromEnvironment('NAKU_ASR_FIXTURE'),
            ).uri.toString(),
          ),
          play: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await player.pause();
        // Reproduce the production HLS option leaking into subtitle inputs.
        await (player.platform as NativePlayer).setProperty(
          'demuxer-lavf-format',
          'hls',
        );
        final folder = await Directory.systemTemp.createTemp('naku-hls-repro-');
        final file = File('${folder.path}/original.srt');
        try {
          await file.writeAsString(cinemaSubtitleSrt(fixtureAss));
          try {
            await player.setSubtitleTrack(SubtitleTrack.uri(file.path));
          } catch (_) {
            // Some MPV builds reject sub-add; others return without a track.
          }
          final sid = await (player.platform as NativePlayer).getProperty(
            'sid',
          );
          expect(sid, anyOf('no', 'auto'));
        } finally {
          await file.delete();
          await folder.delete();
        }
        await applyCinemaExternalSubtitle(
          player,
          fixtureAss,
          title: 'Native ASS fixture',
          language: 'zh',
        );
        final native = player.platform as NativePlayer;
        for (
          var i = 0;
          i < 60 && !(await native.getProperty('sub-text')).contains('测试中文字幕');
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // ignore: avoid_print
        print(
          'sid=${await native.getProperty('sid')}; tracks=${await native.getProperty('track-list/count')}; subtitle=${player.state.subtitle}; logs=${logs.take(10).toList()}',
        );
        // Selecting the numeric track can clear media-kit's cached subtitle
        // without a new MPV text event while paused. Check the native property
        // and the actual NAKU caption layer rather than that stale cache.
        expect(await native.getProperty('sub-text'), contains('测试中文字幕'));
        expect(
          cinemaExternalSubtitleState(player).text.value,
          contains('测试中文字幕'),
        );
      } finally {
        await sub.cancel();
        await player.dispose();
      }
    },
    skip: !const bool.fromEnvironment('NAKU_NATIVE_MPV_TEST'),
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
