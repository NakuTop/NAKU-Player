// Native macOS regression. Use a separate QA bundle ID and a loopback HTTP
// fixture serving three distinct 320x180 MP4s, each at least 20 seconds long.
// Delay the headers for the second and third MP4 by one second to model buffering.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_entrance.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_player_preferences.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_source_health.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

// AppKit sometimes delivers one last frame during the minimize animation.
// Exercise the stricter ordering where no new layout occurs before returning.
class _TestBinding extends WidgetsFlutterBinding {
  bool occluded = false;
  @override
  void drawFrame() {
    if (!occluded) super.drawFrame();
  }
}

T? _find<T extends Widget>(bool Function(T) matches) {
  T? found;
  void visit(Element e) {
    if (found != null) return;
    final widget = e.widget;
    if (widget is T && matches(widget)) found = widget;
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> _until(bool Function() ready, String failure) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed > const Duration(seconds: 10))
      throw StateError(failure);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  final binding = _TestBinding();
  final root = Uri.parse(
    const String.fromEnvironment('NAKU_BACKGROUND_FIXTURE'),
  );
  if (!Platform.isMacOS ||
      root.host != '127.0.0.1' ||
      (await PackageInfo.fromPlatform()).packageName ==
          'com.shenminghao.yingchuan') {
    throw StateError('Use a macOS QA bundle and a loopback fixture URL.');
  }
  final appearance = await const MethodChannel('naku/appearance')
      .invokeMapMethod<String, bool>('state');
  if (appearance?['reduceTransparency'] == null ||
      appearance?['reduceMotion'] == null) {
    throw StateError('Initial AppKit accessibility settings were unavailable.');
  }
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  await Hive.initFlutter('${support.path}/hive');
  await GStorage.init();
  await windowManager.setSize(const Size(1140, 740));
  await windowManager.show();
  final source = CinemaSource(
    id: 'fixture',
    name: 'Fixture',
    kind: CinemaSourceKind.maccms,
    url: root.toString(),
  );
  final title = CinemaTitle(
    id: 'test',
    sourceId: source.id,
    title: '测试视频',
    routes: [
      CinemaRoute(
        name: '测试',
        episodes: [
          for (final (index, name) in ['one', 'two', 'three'].indexed)
            CinemaEpisode(
              name: '第${index + 1}集',
              url: root.resolve('$name.mp4').toString(),
            ),
        ],
      ),
    ],
  );
  final directory = await Directory.systemTemp.createTemp('background-episode');
  final store = CinemaStore(
    file: File('${directory.path}/store.json'),
    defaults: [source],
  );
  await store.load();
  final players = <Player>[];
  final prefs = CinemaPlayerPreferences.read(
    readSetting: <T>(SettingKey<T> key) =>
        (const {
                  'autoPlay': true,
                  'backgroundPlayback': true,
                  'privateMode': true,
                  'autoPlayNext': false,
                  'defaultVolume': 0.0,
                }[key.name] ??
                key.defaultValue)
            as T,
    isMetered: false,
  );
  runApp(
    MaterialApp(
      home: CinemaPlayerPage(
        title: title,
        source: source,
        store: store,
        autoSelectBestRoute: false,
        preferences: prefs,
        createPlayer: (config) {
          final player = Player(configuration: config);
          players.add(player);
          return player;
        },
      ),
    ),
  );
  try {
    await _until(
      () => _find<CinemaPlayerEntrance>((w) => w.ready) != null,
      'First episode did not render',
    );
    for (final index in [1, 2]) {
      final next = _find<IconButton>(
        (w) => w.tooltip == '下一集' && w.onPressed != null,
      )!;
      binding.occluded = true;
      next.onPressed!();
      if (index == 1) {
        await windowManager.minimize();
      } else {
        await windowManager.hide();
      }
      await _until(() => players.length == index + 1, 'Missing episode player');
      final player = players.last;
      await _until(
        () =>
            player.state.width == 320 &&
            player.state.height == 180 &&
            player.state.position.inMilliseconds > 500,
        'No native video while hidden',
      );
      if (index == 2) await player.pause();
      final position = player.state.position;
      binding.occluded = false;
      if (index == 1) {
        await windowManager.restore();
      } else {
        await windowManager.show();
      }
      await windowManager.focus();
      binding.scheduleFrame();
      await _until(
        () =>
            _find<CinemaPlayerEntrance>((w) => w.ready) != null &&
            _find<Video>((w) => identical(w.controller.player, player)) != null,
        'Returned window did not reveal the current episode',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      stdout.writeln('CAPTURE episode ${index + 1}');
      await Future<void>.delayed(const Duration(seconds: 2));
      if (players.length != index + 1 ||
          (index == 2 && player.state.playing) ||
          (index == 1 && player.state.position <= position)) {
        throw StateError(
          'Lost the current player, playback progress, or pause state',
        );
      }
    }
    final frames = CinemaSourceHealth.instance
        .history(source, media: true)
        .where((record) => record.ok && record.firstFrameMs != null);
    if (frames.length != 3) {
      throw StateError(
        'Expected one first-frame measurement for each of the three episodes, got ${frames.length}',
      );
    }
    stdout.writeln('Background episode regression passed');
    exit(0);
  } catch (error, trace) {
    stderr.writeln('$error\n$trace');
    exit(1);
  }
}
