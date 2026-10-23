import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';

void main() {
  const path = String.fromEnvironment('NAKU_LOGVAR_CONFIG_PATH');
  test(
    'deployed NAS resolves a real movie and two distinct TV episodes without official credentials',
    () async {
      final config = jsonDecode(await File(path).readAsString()) as Map;
      final client = CinemaLogvarClient(
        LogvarConfiguration(baseUrl: config['baseUrl'], token: config['token']),
      );
      addTearDown(client.close);
      final ids = <int>[];
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
        CinemaLogvarSelection? result;
        try {
          result = await client.match(
            q,
            onProgress: (p) => debugPrint('LIVE_LOGVAR_PHASE: $p'),
          );
        } on DioException catch (e) {
          throw TestFailure(
            'NAS HTTP failed: status=${e.response?.statusCode}, type=${e.type}',
          );
        }
        expect(result, isNotNull, reason: q.label);
        expect(result!.entries.length, greaterThan(50));
        expect(
          result.entries.every(
            (e) => e.message.isNotEmpty && e.time.isFinite && e.time >= 0,
          ),
          isTrue,
        );
        expect(result.episode.number, q.episode);
        expect(result.work.source, isNot(contains('dandan')));
        ids.add(result.episode.id);
        final row = {
          'query': q.label,
          'work': result.work.title,
          'source': result.work.source,
          'episode': result.episode.title,
          'id': result.episode.id,
          'count': result.entries.length,
          'duration': result.duration,
        };
        reports.add(row);
        debugPrint('LIVE_LOGVAR: ${jsonEncode(row)}');
      }
      expect(ids[0], isNot(ids[1]));
      final output = Platform.environment['NAKU_LOGVAR_EVIDENCE'];
      if (output != null) await File(output).writeAsString(jsonEncode(reports));
    },
    skip: path.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
