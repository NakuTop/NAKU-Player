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
    await tester.tap(find.text('English · en · '));
    await tester.pumpAndSettle();
    expect(player.state.track.audio.id, '2');
    final subtitle = find.text('中文字幕 · zh');
    await tester.ensureVisible(subtitle);
    await tester.tap(subtitle);
    await tester.pumpAndSettle();
    expect(player.state.track.subtitle.id, '3');
    expect(backend.pauses, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}
