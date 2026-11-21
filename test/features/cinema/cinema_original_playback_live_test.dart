import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_search.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/services/player/native_playback_setup.dart'
    show configureLocalOriginalPlayback;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const host = String.fromEnvironment('NAKU_ORIGINAL_HOST');
  for (final example in [
    (name: '八仙', year: '2026', kind: '动画电影', label: '正片'),
    (name: '海上钢琴师', year: '1998', kind: '电影', label: '正片'),
    (name: '爱乐之城', year: '2016', kind: '电影', label: '正片'),
    (name: '流人 第一季', year: '2022', kind: '欧美剧', label: '第01集'),
    (name: '基地 第二季', year: '2023', kind: '欧美剧', label: '第03集'),
  ]) {
    test(
      'local original discovery, decoding and seek for ${example.name}',
      () async {
        final engine = CinemaOriginalEngine(host: host);
        final lookup = CinemaOriginalSearch.instance.find(
          CinemaTitle(
            id: 'sample',
            sourceId: 'sample',
            title: example.name,
            category: example.kind,
            year: example.year,
          ),
          example.label,
        );
        await lookup.finished.timeout(const Duration(seconds: 45));
        final matches = lookup.matches;
        expect(
          matches?.editions ?? const [],
          isNotEmpty,
          reason: lookup.incomplete ? '原画索引或作品资料请求中断' : '没有匹配的原画',
        );
        stdout.writeln(
          'MATCH ${example.name} editions=${matches!.editions.length} season=${matches.work.season} episode=${matches.work.episode}',
        );
        MediaKit.ensureInitialized(
          libmpv: const String.fromEnvironment('NAKU_MPV_LIBRARY'),
        );
        bool played = false;
        for (final version in matches.editions) {
          final player = Player();
          OriginalStream? media;
          final cancel = CancelToken();
          try {
            stdout.writeln(
              'TRY ${example.name} ${version.label} ${version.seeds}',
            );
            media = await engine.open(
              matches,
              version,
              cancel: cancel,
              budget: const Duration(seconds: 12),
            );
            expect(media.url.host, '127.0.0.1');
            expect(media.headers, isEmpty);
            stdout.writeln('METADATA ${media.file.length}');
            final native = player.platform as NativePlayer;
            await configureLocalOriginalPlayback(native);
            await native.setProperty('vo', 'null');
            await native.setProperty('ao', 'null');
            await native.setProperty('vid', 'auto');
            await player
                .open(Media(media.url.toString()))
                .timeout(const Duration(seconds: 22));
            await player.stream.position
                .firstWhere((d) => d.inMilliseconds >= 900)
                .timeout(const Duration(seconds: 32));
            final width = int.parse(await native.getProperty('video-params/w'));
            final height = int.parse(
              await native.getProperty('video-params/h'),
            );
            final audio = await native.getProperty('audio-codec-name');
            expect(
              width >= 3840 || height >= 2160,
              isTrue,
              reason: '实际解码为 ${width}x$height',
            );
            final duration = player.state.duration;
            expect(duration.inSeconds, greaterThan(90));
            final seek = Duration(seconds: duration.inSeconds ~/ 2);
            stdout.writeln(
              'FRAME ${width}x$height seekable=${await native.getProperty('seekable')} from=${player.state.position.inSeconds}s to=${seek.inSeconds}s',
            );
            await player.seek(seek);
            await player.stream.position
                .firstWhere(
                  (d) =>
                      d > seek + const Duration(milliseconds: 600) &&
                      d < seek + const Duration(seconds: 12),
                )
                .timeout(
                  const Duration(seconds: 45),
                  onTimeout: () => throw TimeoutException(
                    'seek pos=${player.state.position} buffer=${player.state.buffer}',
                  ),
                );
            final postWidth = await native.getProperty('video-params/w');
            expect(postWidth, '$width');
            expect(audio, isNotEmpty);
            stdout.writeln(
              'DECODE ${example.name} ${width}x$height audio=$audio seek=${seek.inSeconds} played=${player.state.position.inMilliseconds}ms',
            );
            played = true;
          } catch (error) {
            stdout.writeln(
              'EDITION ${example.name} ${error.runtimeType} $error',
            );
          } finally {
            cancel.cancel();
            await player.dispose();
            await media?.close();
          }
          if (played) break;
        }
        expect(played, isTrue);
      },
      skip: host.isEmpty,
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}
