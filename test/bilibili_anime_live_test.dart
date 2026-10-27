import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/bilibili_anime_matcher.dart';

class _LiveDanmakuBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _LiveDanmakuBinding();
  final liveEntries = <DanmakuEntry>[];
  String? firstPool;
  test(
    'public anime metadata automatically supplies two different episode pools',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'naku-bili-live-',
      );
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            debugPrint(
              'public anime ${response.requestOptions.uri.path}: ${response.statusCode}',
            );
            handler.next(response);
          },
          onError: (error, handler) {
            debugPrint(
              'public anime ${error.requestOptions.uri.path}: ${error.response?.statusCode}',
            );
            handler.next(error);
          },
        ),
      );
      addTearDown(dio.close);
      addTearDown(() => directory.delete(recursive: true));
      final client = BilibiliDanmakuClient(dio: dio);
      final matcher = BilibiliAnimeMatcher(
        client: client,
        directory: directory,
        mappingLoader: () async {
          final data =
              jsonDecode(
                    await File(
                      'assets/data/bangumi_bilibili.json',
                    ).readAsString(),
                  )
                  as Map;
          return (data['subjects'] as Map).map(
            (key, value) => MapEntry('$key', List<String>.from(value as List)),
          );
        },
      );
      final subject = BangumiItem.fromJson({
        'id': 328609,
        'name': 'ぼっち・ざ・ろっく！',
        'name_cn': '孤独摇滚！',
        'date': '2022-10-08',
        'images': <String, String>{},
        'rating': <String, dynamic>{},
      });
      final matches = await matcher.discover(subject);
      expect(matches.automatic?.reference, 'md28339735');
      final video = await matcher.video(matches.automatic!.reference);
      final first = BilibiliAnimeMatcher.episode(video, 1);
      final second = BilibiliAnimeMatcher.episode(video, 2);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!.cid, isNot(second!.cid));
      for (final episode in [1, 2]) {
        final entries = await matcher.load(subject, episode);
        expect(entries, isNotEmpty);
        expect(entries.every((entry) => entry.source == '[BiliBili]'), isTrue);
        final content = jsonEncode([
          for (final e in entries) [e.time, e.message],
        ]);
        if (episode == 1) {
          firstPool = content;
          liveEntries.addAll(entries);
        } else {
          expect(
            content,
            isNot(firstPool),
            reason: 'Different episodes must not reuse one pool',
          );
        }
        debugPrint(
          'Matched ${subject.nameCn} episode $episode: ${entries.length} comments',
        );
      }
      final unavailable = Dio();
      addTearDown(unavailable.close);
      unavailable.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 412),
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );
      final fallback = await BilibiliDanmakuClient(
        dio: unavailable,
      ).searchAnime('葬送的芙莉莲');
      expect(
        fallback.any((row) => row.title == '葬送的芙莉莲' && row.year == 2023),
        isTrue,
      );
      debugPrint(
        'Real bundled title index remains searchable when remote search returns 412',
      );
      final found = await client.searchAnime('葬送的芙莉莲');
      expect(found.any((candidate) => candidate.title == '葬送的芙莉莲'), isTrue);
    },
    skip: Platform.environment['NAKU_BILIBILI_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'real matched comments visibly paint on the player danmaku canvas',
    (tester) async {
      expect(
        liveEntries,
        isNotEmpty,
        reason: 'Requires the preceding actual network match',
      );
      final loader = FontLoader('MI_Sans_Regular')
        ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
      await tester.runAsync(loader.load);
      final boundary = GlobalKey();
      late canvas.DanmakuController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: RepaintBoundary(
              key: boundary,
              child: SizedBox(
                width: 960,
                height: 540,
                child: canvas.DanmakuScreen(
                  createdController: (value) => controller = value,
                  option: const canvas.DanmakuOption(
                    fontFamily: 'MI_Sans_Regular',
                    fontSize: 24,
                    duration: 8,
                    opacity: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final entry in liveEntries.where((e) => e.type == 1).take(8)) {
        controller.addDanmaku(
          canvas.DanmakuContentItem(entry.message, color: Colors.white),
        );
      }
      await tester.pump();
      // The first tick establishes each glyph's draw time; a subsequent frame
      // advances it into the visible viewport instead of sampling at x=width.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(seconds: 2));
      expect(controller.scrollDanmaku, isNotEmpty);
      final image = (await tester.runAsync(
        () =>
            (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(),
      ))!;
      final pixels = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      var painted = 0;
      for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
        if (pixels.getUint8(i) > 40 && pixels.getUint8(i + 1) > 40) painted++;
      }
      expect(
        painted,
        greaterThan(100),
        reason: 'Actual comment glyphs must appear, not just a loaded count',
      );
      final output = Platform.environment['NAKU_ANIME_RENDER_PNG'];
      if (output != null) {
        final png = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        await tester.runAsync(
          () => File(output).writeAsBytes(png!.buffer.asUint8List()),
        );
      }
      debugPrint(
        'Real danmaku canvas: ${controller.scrollDanmaku.length} comments, $painted visible pixels',
      );
      image.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.environment['NAKU_BILIBILI_LIVE_TESTS'] != '1',
  );
}
