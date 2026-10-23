import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_sync_panel.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => PlayerState(
    duration: const Duration(minutes: 10),
    position: const Duration(seconds: 20),
    playing: false,
    rate: 1.5,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StuckDisposal extends _Player {
  final released = Completer<void>();
  int disposals = 0;
  @override
  Future<void> dispose() {
    disposals++;
    return released.future;
  }
}

const _timing = CinemaSubtitleTiming(offsetSeconds: -5);
CinemaVoiceWindow _window(double start) =>
    CinemaVoiceWindow(start, Uint8List(3750));
Future<CinemaAutoSyncResult> _matched(
  List<CinemaSubtitleCue> cues,
  List<CinemaVoiceWindow> windows,
  CinemaSubtitleTiming timing,
) async => const CinemaAutoSyncResult(_timing, .8, '偏移 -5.00 秒');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    for (final entry in {
      '.AppleSystemUIFont': '/System/Library/Fonts/STHeiti Light.ttc',
      'MaterialIcons':
          '../toolchains/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            File(entry.value).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  Future<void> snapshot(WidgetTester tester, String name) async {
    final output = Platform.environment['NAKU_QA_SCREENSHOTS'];
    if (output == null) return;
    await tester.runAsync(() async {
      final boundary =
          tester
                  .element(find.byKey(const ValueKey('sync-qa')))
                  .findRenderObject()
              as RenderRepaintBoundary;
      final picture = await boundary.toImage();
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      picture.dispose();
    });
  }

  late _Player player;
  late CinemaExternalSubtitleState session;
  final controllers = <CinemaSubtitleAutoSync>[];
  setUp(() {
    player = _Player();
    session = cinemaExternalSubtitleState(player);
    session.select(
      [
        for (var i = 1; i <= 20; i++)
          '$i\n00:${(i ~/ 3).toString().padLeft(2, '0')}:${(i % 3 * 20).toString().padLeft(2, '0')},000 --> '
              '00:${(i ~/ 3).toString().padLeft(2, '0')}:${(i % 3 * 20 + 3).toString().padLeft(2, '0')},000\n自写对白 $i\n',
      ].join('\n'),
      'fixture.srt',
      '1',
      0,
    );
  });
  tearDown(() async {
    for (final sync in controllers) {
      sync.dispose();
    }
    controllers.clear();
    await session.close();
  });
  CinemaSubtitleAutoSync make({
    Future<CinemaVoiceWindow> Function(double)? extract,
    Future<CinemaAutoSyncResult> Function(
      List<CinemaSubtitleCue>,
      List<CinemaVoiceWindow>,
      CinemaSubtitleTiming,
    )?
    match,
    Duration timeout = const Duration(seconds: 110),
    Player Function()? createWorker,
  }) {
    final sync = CinemaSubtitleAutoSync(
      player,
      media: () => '/self-authored.wav',
      timeout: timeout,
      cleanupTimeout: const Duration(milliseconds: 20),
      extractWindow: createWorker == null
          ? extract ?? (start) async => _window(start)
          : null,
      matchVoice: match ?? _matched,
      createWorker: createWorker,
    );
    controllers.add(sync);
    return sync;
  }

  test('only one nearby clip is read and retries reuse it', () async {
    final starts = <double>[];
    final sync = make(
      extract: (start) async {
        starts.add(start);
        return _window(start);
      },
    );
    await sync.run();
    await sync.run();
    expect(starts, [18]);
    expect(sync.outcome, CinemaSubtitleSyncOutcome.succeeded);
    expect(player.state.position.inSeconds, 20);
  });

  test('completion is explicit and waits for the timing save', () async {
    final saving = Completer<void>();
    session.saveTiming = (_, timing) => saving.future;
    final sync = make();
    final pending = sync.run();
    await Future<void>.delayed(Duration.zero);
    expect(sync.busy, true);
    expect(sync.phase, contains('保存'));
    saving.complete();
    await pending;
    expect(sync.busy, false);
    expect(sync.outcome, CinemaSubtitleSyncOutcome.succeeded);
    expect(sync.message, contains('已保存'));
    expect(session.delay, -5);
    expect(player.state.rate, 1.5);
    expect(player.state.playing, false);
  });

  test(
    'a never-ending extraction reaches a terminal timeout and a late result cannot retime',
    () async {
      final gate = Completer<CinemaVoiceWindow>();
      final sync = make(
        extract: (_) => gate.future,
        timeout: const Duration(milliseconds: 40),
      );
      await sync.run();
      expect(sync.busy, false);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.timedOut);
      expect(sync.message, contains('5 秒音频'));
      expect(session.delay, 0);
      gate.complete(_window(0));
      await Future<void>.delayed(Duration.zero);
      expect(session.delay, 0);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.timedOut);
    },
  );

  test(
    'cancel returns immediately and a new run owns its own results',
    () async {
      final gate = Completer<CinemaVoiceWindow>();
      var calls = 0;
      final sync = make(
        extract: (start) =>
            calls++ == 0 ? gate.future : Future.value(_window(start)),
      );
      final pending = sync.run();
      await Future<void>.delayed(Duration.zero);
      sync.cancel();
      expect(sync.busy, false);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.cancelled);
      await pending.timeout(const Duration(seconds: 1));
      await sync.run();
      expect(sync.outcome, CinemaSubtitleSyncOutcome.succeeded);
      gate.complete(_window(0));
      await Future<void>.delayed(Duration.zero);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.succeeded);
      expect(session.delay, -5);
    },
  );

  test(
    'low confidence is terminal and preserves the original timing',
    () async {
      final sync = make(
        match: (_, _, _) async =>
            const CinemaAutoSyncResult(null, .1, '置信度不足，保留原对齐'),
      );
      await sync.run();
      expect(sync.busy, false);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.noMatch);
      expect(session.delay, 0);
    },
  );

  test('matching failure stops the spinner and allows retry', () async {
    var attempts = 0;
    final sync = make(
      match: (c, w, t) => attempts++ == 0
          ? Future.error(StateError('fixture failure'))
          : _matched(c, w, t),
    );
    await sync.run();
    expect(sync.outcome, CinemaSubtitleSyncOutcome.failed);
    expect(sync.busy, false);
    await sync.run();
    expect(sync.outcome, CinemaSubtitleSyncOutcome.succeeded);
  });

  test('a stuck decoder release cannot keep the UI busy forever', () async {
    final worker = _StuckDisposal(), sync = make(createWorker: () => worker);
    await sync.run().timeout(const Duration(seconds: 1));
    expect(sync.busy, false);
    expect(sync.outcome, CinemaSubtitleSyncOutcome.timedOut);
    expect(worker.disposals, 1);
    worker.released.complete();
  });

  test(
    'saving timeout reports applied-but-unsaved rather than success',
    () async {
      final saving = Completer<void>();
      session.saveTiming = (_, _) => saving.future;
      final sync = make(timeout: const Duration(milliseconds: 40));
      await sync.run();
      expect(session.delay, -5);
      expect(sync.outcome, CinemaSubtitleSyncOutcome.saveFailed);
      expect(sync.busy, false);
      expect(sync.message, contains('保存超时'));
      saving.complete();
      await session.flush();
    },
  );

  testWidgets(
    'the panel displays phase, cancel, and a clear completed result',
    (tester) async {
      tester.view.physicalSize = const Size(680, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalText = session.normalizedSubtitle;
      await tester.runAsync(session.close);
      player = _Player();
      session = cinemaExternalSubtitleState(player);
      session.select(originalText, 'fixture.srt', '1', 0);
      session.saveTiming = (_, _) async {};
      final gate = Completer<CinemaVoiceWindow>();
      var calls = 0;
      final sync = make(
        extract: (start) =>
            calls++ == 0 ? gate.future : Future.value(_window(start)),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('sync-qa'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: CinemaTheme.data,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: CinemaSubtitleQuickSyncPanel(
                  player: player,
                  autoSync: sync,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-quick-auto')));
      await tester.pump();
      expect(find.text('读取当前对白附近的 5 秒音频'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-auto-sync-cancel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subtitle-auto-sync-elapsed')),
        findsOneWidget,
      );
      await snapshot(tester, 'subtitle-align-working');
      gate.complete(_window(0));
      for (var i = 0; i < 20 && sync.busy; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();
      await snapshot(tester, 'subtitle-align-completed');
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('重新对齐'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.byKey(const ValueKey('subtitle-auto-sync-cancel')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );
  testWidgets('cancel and timeout both stop the spinner and expose retry', (
    tester,
  ) async {
    final gate = Completer<CinemaVoiceWindow>();
    final sync = make(
      extract: (_) => gate.future,
      timeout: const Duration(milliseconds: 40),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CinemaSubtitleQuickSyncPanel(player: player, autoSync: sync),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('subtitle-quick-auto')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('subtitle-auto-sync-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('subtitle-quick-auto')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('已超时'), findsOneWidget);
    expect(find.text('重试自动对齐'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    gate.complete(_window(0));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });
}
