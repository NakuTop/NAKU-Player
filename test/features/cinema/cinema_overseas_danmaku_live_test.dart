import 'dart:convert';
import 'dart:io';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/features/cinema/cinema_overseas_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/plugins/plugins.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('NAKU_OVERSEAS_DANMAKU_LIVE');
  Directory? storage;
  final oldPaths = PathProviderPlatform.instance;
  final oldHttp = HttpOverrides.current;
  if (enabled) {
    setUpAll(() async {
      storage = await Directory.systemTemp.createTemp('naku-overseas-live-');
      PathProviderPlatform.instance = _Paths(storage!.path);
      HttpOverrides.global = _RealHttp();
      Hive.init(storage!.path);
      await GStorage.init();
      await GStorage.putSetting(SettingsKeys.proxyEnable, false);
    });
    tearDownAll(() async {
      await Hive.close();
      PathProviderPlatform.instance = oldPaths;
      HttpOverrides.global = oldHttp;
      await storage?.delete(recursive: true);
    });
  }
  test(
    'native overseas clients retrieve distinct confirmed foreign TV episodes',
    () async {
      if (Platform.isMacOS) {
        final p = await Process.run('/usr/sbin/scutil', ['--proxy']);
        final raw = p.stdout.toString();
        String? value(String k) => RegExp(
          '^\\s*$k'
          r'\s*:\s*(.+)$',
          multiLine: true,
        ).firstMatch(raw)?.group(1)?.trim();
        MacOSSystemProxy.setConfiguration({
          for (final k in [
            'HTTPEnable',
            'HTTPPort',
            'HTTPProxy',
            'HTTPSEnable',
            'HTTPSPort',
            'HTTPSProxy',
          ])
            if (value(k) != null) k: int.tryParse(value(k)!) ?? value(k)!,
        });
      }
      final results = <Map<String, dynamic>>[];
      for (final source in ['aiyifan', 'renren']) {
        final dio = DioFactory.createForConfig(
          const NetworkConfig(
            connectTimeout: Duration(seconds: 5),
            receiveTimeout: Duration(seconds: 8),
            enableLog: false,
          ),
        );
        final client = CinemaOverseasDanmakuClient(dio: dio);
        final watch = Stopwatch()..start();
        try {
          final q = source == 'aiyifan'
              ? const CinemaLogvarQuery(
                  title: '绝命毒师',
                  series: true,
                  season: 1,
                  episode: 1,
                  year: '2008',
                )
              : const CinemaLogvarQuery(
                  title: '行尸走肉：外面的世界',
                  series: true,
                  season: 1,
                  episode: 1,
                  year: '2020',
                );
          final r = source == 'aiyifan'
              ? await client.matchAiyifan(q)
              : await client.matchRenren(q);
          expect(r, isNotNull, reason: source);
          expect(r!.entries.length, greaterThan(10), reason: source);
          expect(r.episode.number, q.episode);
          final next = CinemaLogvarQuery(
            title: q.title,
            series: true,
            season: q.season,
            episode: 2,
            year: q.year,
          );
          final r2 = source == 'aiyifan'
              ? await client.matchAiyifan(next)
              : await client.matchRenren(next);
          expect(r2, isNotNull, reason: '$source episode 2');
          expect(r2!.entries.length, greaterThan(10));
          expect(
            r.entries.take(20).map((e) => e.message).join('|'),
            isNot(r2.entries.take(20).map((e) => e.message).join('|')),
          );
          final report = {
            'source': source,
            'title': r.work.title,
            'year': r.work.year,
            'episode1': r.entries.length,
            'episode2': r2.entries.length,
            'seconds': watch.elapsedMilliseconds / 1000,
          };
          results.add(report);
          debugPrint('NAKU_OVERSEAS_LIVE: ${jsonEncode(report)}');
        } finally {
          client.close();
        }
      }
      final out = Platform.environment['NAKU_OVERSEAS_EVIDENCE'];
      if (out != null) {
        await File(out).writeAsString(
          jsonEncode({
            'retrieved_at': DateTime.now().toUtc().toIso8601String(),
            'results': results,
          }),
        );
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'bundled anime rules can search and list episodes using native engine',
    () async {
      final reports = <Map<String, dynamic>>[];
      for (final name in ['AGE', 'MXdm', 'akianime']) {
        final p = Plugin.fromJson(
          jsonDecode(await File('assets/plugins/$name.json').readAsString()),
        );
        final clock = Stopwatch()..start();
        try {
          final r = await p
              .queryBangumi('葬送的芙莉莲', shouldRethrow: true)
              .timeout(const Duration(seconds: 18));
          expect(r.data, isNotEmpty);
          final roads = await p
              .queryChapterRoads(r.data.first.src)
              .timeout(const Duration(seconds: 18));
          expect(roads, isNotEmpty);
          final report = {
            'name': name,
            'status': 'ok',
            'search_results': r.data.length,
            'roads': roads.length,
            'seconds': clock.elapsedMilliseconds / 1000,
          };
          reports.add(report);
          debugPrint('NAKU_ANIME_LIVE: ${jsonEncode(report)}');
        } catch (e) {
          final report = {
            'name': name,
            'status': 'blocked',
            'error_type': e.runtimeType.toString(),
          };
          reports.add(report);
          debugPrint('NAKU_ANIME_LIVE: ${jsonEncode(report)}');
        }
      }
      final out = Platform.environment['NAKU_ANIME_EVIDENCE'];
      if (out != null) {
        await File(out).writeAsString(
          jsonEncode({
            'retrieved_at': DateTime.now().toUtc().toIso8601String(),
            'results': reports,
          }),
        );
      }
      expect(
        reports.any((r) => r['status'] == 'ok'),
        isTrue,
        reason:
            'At least one bundled source must pass live search and episode listing',
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
