import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const fixtures = String.fromEnvironment('NAKU_LOGVAR_NATIVE_FIXTURES');
  testWidgets(
    'native Keychain, NAS automatic matching, MPV clock and Canvas rendering work together',
    (tester) async {
      final config =
          jsonDecode(await File('$fixtures/config.json').readAsString()) as Map;
      final configuration = LogvarConfiguration(
        baseUrl: config['baseUrl'],
        token: config['token'],
      );
      await windowManager.ensureInitialized();
      await windowManager.show();
      await windowManager.focus();
      debugPrint(
        'NATIVE_STAGE: consume one-use local configuration into Keychain',
      );
      final pendingFile = File('$fixtures/one-use-configuration.json');
      await pendingFile.writeAsString(
        jsonEncode({
          'version': 1,
          'baseUrl': configuration.baseUrl.toString(),
          'token': configuration.token,
        }),
      );
      final credentials = LogvarCredentialStore(
        provisioningFile: () async => pendingFile,
      );
      final saved = await credentials.read().timeout(
        const Duration(seconds: 10),
      );
      expect(saved?.baseUrl, configuration.baseUrl);
      expect(saved?.token == configuration.token, isTrue);
      expect(await pendingFile.exists(), false);
      debugPrint('NATIVE_STAGE: create store');
      final store = CinemaStore(
        file: File('$fixtures/library.json'),
        defaults: const [],
      );
      await store.load();
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      final duration = player.stream.duration.firstWhere(
        (d) => d.inSeconds > 100,
      );
      await player.open(Media('$fixtures/dialogue.wav'), play: false);
      await duration.timeout(const Duration(seconds: 15));
      CinemaDanmakuController? current;
      final reports = <Map<String, dynamic>>[];
      try {
        for (final query in [
          const CinemaLogvarQuery(
            title: '甄嬛传',
            series: true,
            episode: 1,
            year: '2011',
          ),
          const CinemaLogvarQuery(
            title: '甄嬛传',
            series: true,
            episode: 2,
            year: '2011',
          ),
          const CinemaLogvarQuery(title: '流浪地球2', year: '2023'),
        ]) {
          await current?.close();
          final c = CinemaDanmakuController(
            player,
            store,
            'native-${query.label}',
            autoQuery: query,
          );
          current = c;
          debugPrint('NATIVE_STAGE: matching ${query.label}');
          await c
              .loadAutomatic(force: true)
              .timeout(const Duration(seconds: 100));
          debugPrint(
            'NATIVE_STAGE: matched ${c.entries.length} ${c.matchMessage}',
          );
          expect(c.matching, isFalse, reason: c.matchMessage);
          expect(c.entries.length, greaterThan(50), reason: c.matchMessage);
          expect(c.enabled, isTrue);
          debugPrint('NATIVE_STAGE: mount overlay');
          await tester.pumpWidget(
            MaterialApp(
              theme: CinemaTheme.data,
              home: Scaffold(
                body: RepaintBoundary(
                  key: const ValueKey('native-danmu-preview'),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: ColoredBox(color: Color(0xff161921)),
                      ),
                      Positioned(
                        left: 24,
                        top: 24,
                        child: Text(
                          '${query.label}\n${c.entries.length} 条真实弹幕',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      Positioned.fill(
                        child: CinemaDanmakuOverlay(controller: c),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final item = c.entries.firstWhere(
            (e) =>
                e.type == 1 &&
                e.time > 10 &&
                e.time < 80 &&
                e.message.length < 80,
          );
          debugPrint('NATIVE_STAGE: seek');
          await player.seek(
            Duration(milliseconds: ((item.time - .25) * 1000).round()),
          );
          debugPrint('NATIVE_STAGE: play');
          await player.play();
          var visible = 0;
          for (var i = 0; i < 45; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            visible = tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .where((w) => w.painter is BaseDanmakuPainter)
                .fold(
                  0,
                  (n, w) =>
                      n +
                      (w.painter! as BaseDanmakuPainter).danmakuItems.length,
                );
            if (visible > 0) break;
          }
          await tester.pump(const Duration(milliseconds: 1200));
          debugPrint('NATIVE_STAGE: pause, visible=$visible');
          await player.pause();
          expect(
            visible,
            greaterThan(0),
            reason: 'Real timed comments must reach the Canvas painter',
          );
          final row = {
            'query': query.label,
            'source': c.source,
            'entries': c.entries.length,
            'visible': visible,
            'terminal': c.matchMessage,
          };
          reports.add(row);
          debugPrint('NATIVE_LOGVAR: ${jsonEncode(row)}');
          final boundary =
              tester
                      .element(
                        find.byKey(const ValueKey('native-danmu-preview')),
                      )
                      .findRenderObject()
                  as RenderRepaintBoundary;
          await tester.pump();
          final picture = await boundary.toImage();
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '$fixtures/preview-${reports.length}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
          if (query.series && query.episode == 1) {
            await c.setEnabled(false);
            final restored = CinemaDanmakuController(
              player,
              store,
              'native-${query.label}',
              autoQuery: query,
            );
            await restored.loadAutomatic();
            expect(restored.enabled, isFalse);
            expect(restored.entries.length, c.entries.length);
            await restored.close();
          }
        }
        await File('$fixtures/result.json').writeAsString(jsonEncode(reports));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await current?.close();
        await player.dispose();
        await store.flush();
        store.dispose();
        // Leave the new production account empty so the final signed release
        // creates its own item from the private one-use provisioning file.
        await credentials.clear().timeout(const Duration(seconds: 5));
      }
    },
    skip: fixtures.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
