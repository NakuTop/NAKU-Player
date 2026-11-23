import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_match.dart';
import 'package:kazumi/features/cinema/cinema_original_search.dart';
import 'package:kazumi/features/cinema/cinema_tv_native_player.dart';
import 'package:kazumi/features/cinema/cinema_tv_media_policy.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Device-only smoke entry for a bencoded two-episode fixture and a real Android
/// player. NAKU_ORIGINAL_FIXTURE is supplied by the private emulator test.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NakuDevice.initialize();
  MediaKit.ensureInitialized();
  final player = NakuDevice.isTV ? CinemaTVNativePlayer() : Player();
  final surface = player is CinemaTVNativePlayer
      ? CinemaTVNativeVideo(player: player)
      : Video(controller: VideoController(player), controls: NoVideoControls);
  runApp(MaterialApp(home: Scaffold(body: surface)));
  try {
    await WidgetsBinding.instance.endOfFrame;
    final fixture = Uri.parse(
      const String.fromEnvironment('NAKU_ORIGINAL_FIXTURE'),
    );
    Future<dynamic> fetch(String path) async {
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final response = await (await client.getUrl(
          fixture.resolve(path),
        )).close();
        return jsonDecode(await utf8.decoder.bind(response).join());
      } finally {
        client.close(force: true);
      }
    }

    final spec = await fetch('fixture.json');
    final work = OriginalWork(
      names: ['River'],
      years: {'2020'},
      season: 1,
      episode: 2,
    );
    final good = OriginalEdition(
      hash: spec['hash'],
      name: 'River S01 2160p',
      size: 1,
      seeds: 1,
      pack: true,
      magnet: spec['link'],
    );
    final dead = OriginalEdition(
      hash: '1111111111111111111111111111111111111111',
      name: 'River S01 2160p',
      size: 1,
      seeds: 99,
      pack: true,
      magnet: 'magnet:?xt=urn:btih:1111111111111111111111111111111111111111',
    );
    final matches = OriginalMatches(work, [dead, good]);
    final engine = CinemaOriginalEngine.instance;
    final timer = Stopwatch()..start();
    final ready = await engine.openPlayable(
      (matches: matches, edition: dead),
      alternate: (matches: matches, edition: good),
      cancel: CancelToken(),
      budget: const Duration(seconds: 24),
    );
    if (ready.selection.edition.hash != good.hash ||
        !ready.stream.file.path.contains('S01E02')) {
      throw StateError('Wrong episode');
    }
    await player.open(Media(ready.stream.url.toString()));
    if (player is CinemaTVNativePlayer) {
      await player.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 22),
      );
    }
    Future<void> position(int from, double until) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end)) {
        final t = player.state.position.inMilliseconds / 1000;
        if (t >= from && t < until && !player.state.buffering) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError(
        'Seek failed ${player.state.position} ${player.state.buffering}',
      );
    }

    await position(1, 4.5);
    final first = timer.elapsedMilliseconds;
    final width = player.state.width, height = player.state.height;
    if (width != 3840 || height != 2160) {
      throw StateError('Decoded ${width}x$height');
    }
    await player.seek(const Duration(seconds: 5));
    await position(5, 7.9);
    await player.seek(const Duration(seconds: 1));
    await position(1, 4);
    debugPrint(
      'NAKU_ORIGINAL_DEVICE_OK tv=${NakuDevice.isTV} ${width}x$height firstMs=$first seeks=5,1 matched=S01E02',
    );
    await player.stop();
    await ready.stream.close();
    if (const bool.fromEnvironment('NAKU_ORIGINAL_LIVE_CHECK')) {
      final west = OriginalWork(
        names: ['Westworld', '西部世界'],
        years: {'2016'},
        season: 1,
        episode: 1,
      );
      final catalog = await fetch('west.json');
      final rows = catalog['streams'] as List;
      final editions = rows
          .whereType<Map>()
          .map((row) => parseOriginalStream(west, row))
          .whereType<OriginalEdition>()
          .toList();
      final live = OriginalMatches(west, editions);
      final tv = CinemaTVMediaEnvironment.instance;
      await tv.refresh();
      debugPrint(
        'NAKU_WEST_CAPS tv=${NakuDevice.isTV} avc=${tv.sizeFor('AVC')} hevc=${tv.sizeFor('HEVC')}',
      );
      final seen = <String>{};
      final clock = Stopwatch()..start();
      var played = false;
      for (
        var attempt = 0;
        attempt < 3 && !played && clock.elapsed.inSeconds < 36;
        attempt++
      ) {
        final eligible = NakuDevice.isTV ? tv.originalCompatibility : null;
        final selected = engine.preferred(
          live,
          excluding: seen,
          compatibility: eligible,
        );
        if (selected == null) break;
        final backup = engine.alternate(
          selected,
          excluding: seen,
          compatibility: eligible,
        );
        OriginalStream? stream;
        final livePlayer = NakuDevice.isTV ? CinemaTVNativePlayer() : Player();
        final view = livePlayer is CinemaTVNativePlayer
            ? CinemaTVNativeVideo(
                key: ValueKey(livePlayer.id),
                player: livePlayer,
              )
            : Video(
                key: ObjectKey(livePlayer),
                controller: VideoController(livePlayer),
                controls: NoVideoControls,
              );
        runApp(MaterialApp(home: Scaffold(body: view)));
        final errors = <String>[];
        final errorsSub = livePlayer.stream.error.listen(errors.add);
        try {
          await WidgetsBinding.instance.endOfFrame;
          final l = await engine.openPlayable(
            selected,
            alternate: backup,
            budget: Duration(
              milliseconds: (36000 - clock.elapsedMilliseconds).clamp(1, 18000),
            ),
            acceptsVideo: (v) {
              final ok =
                  (v.width >= 3840 || v.height >= 2160) &&
                  tv.supportsOriginalVideo(v);
              debugPrint(
                'NAKU_WEST_HEADER ${v.width}x${v.height} ${v.codec} supported=$ok',
              );
              return ok;
            },
            cancel: CancelToken(),
            onFailure: (s) => seen.add(s.edition.hash),
          );
          stream = l.stream;
          seen.add(l.selection.edition.hash);
          debugPrint(
            'NAKU_WEST_BYTES try=$attempt edition=${l.selection.edition.label} seeds=${l.selection.edition.seeds} length=${stream.file.length}',
          );
          await livePlayer.open(Media(stream.url.toString()));
          final end = DateTime.now().add(
            originalStartupTimeout(
              const Duration(seconds: 36) - clock.elapsed,
              const Duration(seconds: 22),
              decoding: true,
            ),
          );
          while (DateTime.now().isBefore(end)) {
            if (errors.isNotEmpty && livePlayer is CinemaTVNativePlayer) break;
            if (livePlayer.state.position.inMilliseconds > 700 &&
                (livePlayer.state.width ?? 0) > 0) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 120));
          }
          final state = livePlayer.state;
          debugPrint(
            'NAKU_WEST_STATE pos=${state.position.inMilliseconds} buffer=${state.buffer.inMilliseconds} dur=${state.duration.inSeconds} dim=${state.width}x${state.height} tracks=${state.tracks.video.map((x) => x.codec).toList()} audio=${state.tracks.audio.map((x) => x.codec).toList()} audioState=${state.audioParams} err=${errors.where((v) => !v.contains('://')).take(3).toList()}',
          );
          if (state.position.inMilliseconds < 700 || (state.width ?? 0) <= 0) {
            throw StateError('No moving picture');
          }
          if (livePlayer is CinemaTVNativePlayer) {
            await livePlayer.waitUntilFirstFrameRendered.timeout(
              const Duration(seconds: 3),
            );
          }
          played = true;
          debugPrint('NAKU_WEST_PLAYED ${state.width}x${state.height}');
        } catch (error) {
          seen.add(selected.edition.hash);
          debugPrint('NAKU_WEST_ATTEMPT try=$attempt ${error.runtimeType}');
        } finally {
          await errorsSub.cancel();
          await livePlayer.dispose();
          await stream?.close();
        }
      }
      if (!played && NakuDevice.isTV) {
        for (final url
            in (catalog['ordinary'] as List? ?? const []).whereType<String>()) {
          final ordinary = CinemaTVNativePlayer();
          runApp(
            MaterialApp(
              home: Scaffold(
                body: CinemaTVNativeVideo(
                  key: ValueKey(ordinary.id),
                  player: ordinary,
                ),
              ),
            ),
          );
          try {
            await WidgetsBinding.instance.endOfFrame;
            await ordinary.open(Media(url));
            await ordinary.waitUntilFirstFrameRendered.timeout(
              const Duration(seconds: 18),
            );
            await Future<void>.delayed(const Duration(seconds: 1));
            final state = ordinary.state;
            if ((state.width ?? 0) > 0 && state.position.inMilliseconds > 0) {
              debugPrint(
                'NAKU_WEST_FALLBACK ${state.width}x${state.height} pos=${state.position.inMilliseconds}',
              );
              played = true;
              break;
            }
          } catch (e) {
            debugPrint('NAKU_WEST_ORDINARY_ATTEMPT ${e.runtimeType}');
          } finally {
            await ordinary.dispose();
          }
        }
      }
      if (!played) {
        debugPrint(
          'NAKU_WEST_UNAVAILABLE count=${editions.length} tried=${seen.length}',
        );
      }
    }
  } catch (e, stack) {
    debugPrint('NAKU_ORIGINAL_DEVICE_ERROR $e\n$stack');
  } finally {
    await player.dispose();
  }
}
