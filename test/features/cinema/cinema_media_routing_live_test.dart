import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  const path = String.fromEnvironment('NAKU_MEDIA_ROUTING_LIVE');
  test(
    'real current episode and another CDN automatically choose a working network path',
    () async {
      final data = jsonDecode(await File(path).readAsString()) as Map;
      final router = CinemaMediaRouter(
        configuration: () =>
            const NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 7897),
        enabled: () => true,
      );
      addTearDown(router.close);
      final transport = CinemaMediaTransport(router: router);
      addTearDown(() => transport.dio.close(force: true));
      final reports = <Map<String, dynamic>>[];
      for (final row in data['sources'] as List) {
        try {
          final watch = Stopwatch()..start();
          var uri = Uri.parse(row['url']);
          final doc = await transport.document(uri, {});
          uri = doc.uri;
          final lines = doc.text.split('\n');
          final urls = lines
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();
          expect(doc.text, startsWith('#EXTM3U'));
          final segment = uri.resolve(urls[(urls.length * .6).floor()]);
          final response = await router.open(segment, {});
          var bytes = 0;
          await for (final part in response.data!.stream) {
            bytes += part.length;
          }
          expect(bytes, greaterThan(32768));
          final result = {
            'name': row['name'],
            'manifestRoute': router.labelFor(uri, metadata: true),
            'segmentRoute': response.extra['cinemaRoute'],
            'bytes': bytes,
            'seconds': watch.elapsedMilliseconds / 1000,
          };
          reports.add(result);
          debugPrint('LIVE_ROUTING: ${jsonEncode(result)}');
        } on DioException catch (e) {
          throw TestFailure(
            'Source ${row['name']} failed: ${e.type}, status ${e.response?.statusCode}',
          );
        }
      }
      final output = Platform.environment['NAKU_ROUTING_EVIDENCE'];
      if (output != null) await File(output).writeAsString(jsonEncode(reports));
    },
    skip: path.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
