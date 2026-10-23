import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
}

class _Player implements Player {
  _Player(this.backend);
  final _Backend backend;
  @override
  PlayerStream get stream => backend.stream;
  @override
  PlayerState get state => backend.state;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Matcher implements CinemaDanmakuMatcher {
  _Matcher(this.queries);
  final List<CinemaLogvarQuery> queries;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery q, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    queries.add(q);
    return CinemaLogvarSelection(
      CinemaLogvarWork(id: 1, title: q.title),
      CinemaLogvarEpisode(q.episode, '正片', q.episode),
      [
        DanmakuEntry(
          message: '自写测试弹幕',
          time: 1,
          type: 1,
          color: Colors.white,
          source: 'fixture',
        ),
      ],
      7200,
      provider: '测试',
    );
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    final fonts = FontLoader('.AppleSystemUIFont')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Light.ttc',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await fonts.load();
  });

  late Directory temp;
  late CinemaStore store;
  late _Backend backend;
  final controllers = <CinemaDanmakuController>[];
  final queries = <CinemaLogvarQuery>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('naku-danmaku-match-');
    store = CinemaStore(
      file: File('${temp.path}/library.json'),
      defaults: const [],
    );
    await store.load();
    backend = _Backend();
    queries.clear();
  });
  tearDown(() async {
    for (final c in controllers) {
      await c.close();
    }
    controllers.clear();
    await backend.dispose();
    await store.flush();
    store.dispose();
    await temp.delete(recursive: true);
  });
  CinemaDanmakuController make(
    String identity,
    String title, {
    String year = '1997',
    int episode = 1,
    bool series = false,
  }) {
    final c = CinemaDanmakuController(
      _Player(backend),
      store,
      identity,
      autoQuery: CinemaLogvarQuery(
        title: title,
        year: year,
        episode: episode,
        series: series,
      ),
      directClientFactory: () => _Matcher(queries),
    );
    controllers.add(c);
    return c;
  }

  test(
    'a correction survives reopening and applies to another 4K source, but not another year',
    () async {
      final first = make('source-one', '泰坦尼克号国语4K');
      await first.changeMatchQuery(
        const CinemaLogvarQuery(title: 'Titanic', year: '1997'),
      );
      expect(queries.last.title, 'Titanic');
      await first.close();
      final second = make('source-two', '泰坦尼克号 4K');
      await second.loadAutomatic();
      expect(queries.last.title, 'Titanic');
      expect(second.hasMatchOverride, isTrue);
      final remake = make('source-three', '泰坦尼克号4K', year: '2012');
      expect(remake.matchQuery!.title, '泰坦尼克号4K');
      await second.changeMatchQuery(null);
      expect(second.hasMatchOverride, isFalse);
      expect(queries.last.title, '泰坦尼克号 4K');
    },
  );
  test(
    'a series keyword correction preserves the next episode number',
    () async {
      final first = make('e1', '自写剧4K', series: true, episode: 1);
      await first.changeMatchQuery(
        const CinemaLogvarQuery(title: '自写连续剧', year: '1997'),
      );
      final second = make('e2', '自写剧4K', series: true, episode: 2);
      await second.loadAutomatic();
      expect(queries.last.title, '自写连续剧');
      expect(queries.last.episode, 2);
      expect(queries.last.series, isTrue);
    },
  );
  for (final width in [360.0, 680.0]) {
    testWidgets(
      'correction dialog accepts a search term without overflow at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late CinemaDanmakuController c;
        await tester.runAsync(() async {
          c = make('widget', '泰坦尼克号国语4K');
          await c.ready;
        });
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('qa-dialog'),
            child: MaterialApp(
              theme: CinemaTheme.data,
              home: Scaffold(body: CinemaDanmakuStylePanel(controller: c)),
            ),
          ),
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('danmaku-correct-match')));
        });
        await tester.pumpAndSettle();
        expect(find.text('更正弹幕匹配'), findsOneWidget);
        final folder = Platform.environment['NAKU_QA_SCREENSHOTS'];
        if (folder != null) {
          await tester.runAsync(() async {
            final boundary =
                tester
                        .element(find.byKey(const ValueKey('qa-dialog')))
                        .findRenderObject()
                    as RenderRepaintBoundary;
            final pixels = await boundary.toImage();
            final bytes = await pixels.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(folder).create(recursive: true);
            await File(
              '$folder/danmaku-match-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            pixels.dispose();
          });
        }

        final field = find.byKey(const ValueKey('danmaku-match-title'));
        expect(tester.widget<TextField>(field).controller!.text, '泰坦尼克号');
        await tester.enterText(field, 'Titanic');
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('danmaku-match-submit')));
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (queries.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pumpAndSettle();
        expect(queries.single.title, 'Titanic');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
