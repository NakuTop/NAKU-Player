import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_direct_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';

void main() {
  const enabled = bool.fromEnvironment('NAKU_DIRECT_DANMAKU_LIVE');
  const proxy = String.fromEnvironment('NAKU_TEST_PROXY');
  test(
    'player directly resolves a real film and distinct TV episodes without NAS or Dandan',
    () async {
      final reports = <Map<String, dynamic>>[];
      for (final q in [
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
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        dio.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            final client = HttpClient();
            if (proxy.isNotEmpty) client.findProxy = (_) => 'PROXY $proxy';
            return client;
          },
        );
        final hosts = <String>{};
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              hosts.add(o.uri.host);
              h.next(o);
            },
          ),
        );
        final c = CinemaDirectDanmakuClient(dio: dio);
        final watch = Stopwatch()..start();
        try {
          final result = await c
              .match(q, onProgress: (m) => debugPrint('DIRECT_PHASE: $m'))
              .timeout(const Duration(seconds: 100));
          expect(result, isNotNull, reason: q.label);
          expect(result!.entries.length, greaterThan(50));
          expect(
            hosts.any(
              (h) =>
                  h.contains('dandan') ||
                  h.contains('ug.link') ||
                  h.startsWith('192.168.') ||
                  h == 'danmu.zxz.ee',
            ),
            isFalse,
          );
          expect(result.episode.number, q.episode);
          final row = {
            'query': q.label,
            'provider': result.provider,
            'count': result.entries.length,
            'partial': result.partial,
            'seconds': watch.elapsedMilliseconds / 1000,
            'hosts': hosts.toList(),
            'fingerprint': result.entries
                .take(100)
                .map((e) => '${e.time}:${e.message}')
                .join('|')
                .hashCode,
          };
          reports.add(row);
          debugPrint('DIRECT_RESULT: ${jsonEncode(row)}');
        } finally {
          c.close();
        }
      }
      expect(reports[0]['fingerprint'], isNot(reports[1]['fingerprint']));
      final path = Platform.environment['NAKU_DIRECT_EVIDENCE'];
      if (path != null) await File(path).writeAsString(jsonEncode(reports));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
  test(
    'native segmented adapters read real iQiyi, Mango and Bilibili payloads',
    () async {
      for (final page in [
        'https://v.qq.com/x/cover/mzc002008v8rka3/d0046v4pddg.html',
        'https://www.iqiyi.com/v_1yzsojq1cg8.html',
        'https://www.mgtv.com/b/353601/18642419.html',
        'https://www.bilibili.com/bangumi/play/ep744327',
      ]) {
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        dio.httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () {
            final client = HttpClient();
            if (proxy.isNotEmpty) client.findProxy = (_) => 'PROXY $proxy';
            return client;
          },
        );
        final client = CinemaDirectDanmakuClient(dio: dio);
        try {
          final watch = Stopwatch()..start();
          final first = await client
              .loadPage(page)
              .timeout(const Duration(seconds: 50));
          expect(first.timeline, isNotNull);
          expect(first.entries.length, inInclusiveRange(10, 6000));
          final next = await first.timeline!
              .window(1200)
              .timeout(const Duration(seconds: 50));
          expect(next.entries, isNotEmpty);
          expect(
            next.entries.every((e) => e.time >= 1170 && e.time <= 1380),
            isTrue,
          );
          debugPrint(
            'LIVE_DIRECT_ADAPTER: ${Uri.parse(page).host} first=${first.entries.length} seek=${next.entries.length} seconds=${watch.elapsedMilliseconds / 1000} partial=${first.partial || next.partial}',
          );
        } finally {
          client.close();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
