import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_invitation.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_tools_settings.dart';
import 'package:kazumi/features/cinema/cinema_tracks_sheet.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_controller.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';

class _Tracks extends PlatformPlayer {
  _Tracks() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      tracks: const Tracks(
        audio: [
          AudioTrack('auto', null, null),
          AudioTrack('1', '中文音轨', 'zh'),
          AudioTrack('2', 'English', 'en'),
        ],
        subtitle: [
          SubtitleTrack('no', null, null),
          SubtitleTrack('3', '中文字幕', 'zh'),
        ],
      ),
    );
  }
  int pauses = 0;
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    state = state.copyWith(
      track: Track(audio: track, subtitle: state.track.subtitle),
    );
    trackController.add(state.track);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    state = state.copyWith(
      track: Track(audio: state.track.audio, subtitle: track),
    );
    trackController.add(state.track);
  }

  @override
  Future<void> pause() async {
    pauses++;
  }
}

class _Player implements Player {
  _Player(this.backend);
  final _Tracks backend;
  @override
  PlatformPlayer? get platform => backend;
  @override
  PlayerState get state => backend.state;
  @override
  PlayerStream get stream => backend.stream;
  @override
  Future<void> setAudioTrack(AudioTrack track) => backend.setAudioTrack(track);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      backend.setSubtitleTrack(track);
  @override
  Future<void> dispose() => backend.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  final directory = Platform.environment['NAKU_QA_SCREENSHOTS'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        tester.element(find.byKey(const ValueKey('qa'))).findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    final font = FontLoader('.AppleSystemUIFont')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Light.ttc',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '../toolchains/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await icons.load();
  });
  late Directory temp;
  late CinemaStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('naku-controls-');
    store = CinemaStore(file: File('${temp.path}/library.json'), defaults: []);
    await store.load();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await temp.delete(recursive: true);
  });
  for (final width in [360.0, 1180.0]) {
    testWidgets('2.0 settings and invitation remain usable at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('qa'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: CinemaTheme.data,
            home: CinemaToolsSettingsPage(store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('粘贴 JSON'), findsOneWidget);
      for (final tab in ['视频缓存', '备份与迁移']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _snapshot(tester, 'settings-$tab-${width.toInt()}');
      }
      final context = tester.element(find.byType(CinemaToolsSettingsPage));
      final title = const CinemaTitle(
        id: '1',
        sourceId: 'a',
        title: '测试邀请',
        category: '电影',
      );
      showCinemaInvitation(
        context,
        CinemaInvitation(
          media: CinemaSyncMedia.fromSelection(
            title,
            const CinemaEpisode(name: '正片', url: ''),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('复制链接'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _snapshot(tester, 'invitation-${width.toInt()}');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final width in [360.0, 680.0]) {
    testWidgets('subtitle menu stays compact and usable at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _Tracks();
      final player = _Player(backend);
      final automation = CinemaSeasonSubtitleController(
        player: player,
        store: store,
        seriesIdentity: 'qa',
        mediaIdentity: 'qa',
        query: const CinemaSubtitleQuery('自写测试影片', 'movie', 1, 1),
      );
      automation.status.value = '已恢复本视频字幕及对齐设置';
      final autoSync = CinemaSubtitleAutoSync(player, media: () => '');
      cinemaExternalSubtitleState(player).select(
        '1\n00:00:01,000 --> 00:00:04,000\n这是自写的字幕预览\nSelf-authored subtitle preview\n\n'
            '2\n00:00:05,000 --> 00:00:08,000\n选中听到的这句对白\nSelect the dialogue you hear\n\n'
            '3\n00:00:10,000 --> 00:00:13,000\n再对齐到当前画面\nAlign it to the current picture\n',
        'qa.srt',
        'qa',
        0,
        title: '测试影片.简体中文.srt',
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('qa'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: CinemaTheme.data,
            home: Scaffold(
              body: CinemaTracksPanel(
                player: player,
                store: store,
                automation: automation,
                autoSync: autoSync,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自动字幕 · 中文优先'), findsNothing);
      expect(
        find.byKey(const ValueKey('subtitle-current-file')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('subtitle-quick-auto')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-quick-earlier')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subtitle-quick-later')),
        findsOneWidget,
      );
      expect(find.text('字幕文件内容'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('subtitle-quick-auto'))).dy,
        lessThan(300),
      );
      cinemaExternalSubtitleState(player).saveTiming = null;
      await tester.tap(find.byKey(const ValueKey('subtitle-quick-earlier')));
      await tester.pump();
      expect(cinemaExternalSubtitleState(player).delay, -.5);
      await tester.tap(find.byKey(const ValueKey('subtitle-quick-later')));
      await tester.pump();
      expect(cinemaExternalSubtitleState(player).delay, 0);
      expect(find.byKey(const ValueKey('subtitle-cue-search')), findsNothing);
      expect(tester.takeException(), isNull);
      await _snapshot(tester, 'subtitles-${width.toInt()}');
      for (final tab in ['音轨', '显示']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _snapshot(tester, 'tracks-$tab-${width.toInt()}');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      automation.close();
      autoSync.dispose();
      await closeCinemaExternalSubtitles(player);
      await player.dispose();
    });
  }

  testWidgets('film danmaku button only exposes display styles and switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(680, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('naku/danmaku-credentials'),
          (_) async => null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('naku/danmaku-credentials'),
            null,
          ),
    );
    final player = _Player(_Tracks());
    late CinemaDanmakuController controller;

    await tester.runAsync(() async {
      controller = CinemaDanmakuController(player, store, 'qa-danmaku');
      await controller.ready;
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('qa'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CinemaTheme.data,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showCinemaDanmakuSheet(
                    context,
                    controller,
                    title: '自写测试影片',
                  ),
                  child: const Text('打开弹幕'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开弹幕'));
    await tester.pumpAndSettle();

    expect(find.text('显示弹幕'), findsOneWidget);
    for (final label in ['字号', '不透明度', '显示区域', '滚动时长']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(TextField), findsNothing);
    expect(find.text('配置弹弹play'), findsNothing);
    expect(find.text('配置 NAS'), findsNothing);
    expect(find.text('重新自动匹配'), findsNothing);
    expect(tester.takeException(), isNull);
    await _snapshot(tester, 'danmaku-styles');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('cinema-danmaku-enabled')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await store.flush();
    });
    await tester.pumpAndSettle();
    expect(controller.enabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await controller.close();
      await player.dispose();
    });
  });

  testWidgets('changing subtitle and audio tracks does not pause playback', (
    tester,
  ) async {
    final backend = _Tracks();
    final player = _Player(backend);
    await tester.pumpWidget(
      MaterialApp(
        theme: CinemaTheme.data,
        home: Scaffold(
          body: CinemaTracksPanel(player: player, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('音轨'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English · en · '));
    await tester.pumpAndSettle();
    expect(player.state.track.audio.id, '2');
    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();
    final subtitle = find.text('中文字幕 · zh');
    await tester.ensureVisible(subtitle);
    await tester.tap(subtitle);
    await tester.pumpAndSettle();
    expect(player.state.track.subtitle.id, '3');
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    final appearance = find.byKey(const ValueKey('subtitle-font-size'));
    await tester.ensureVisible(appearance);
    final slider = tester.widget<Slider>(appearance);
    slider.onChanged!(48);
    await tester.pump();
    await tester.runAsync(() async {
      await (tester.widget<Slider>(appearance).onChangeEnd as dynamic)(48.0);
    });
    await tester.pumpAndSettle();
    expect((store.extras['subtitleAppearance'] as Map)['fontSize'], 48);
    expect(backend.pauses, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}
