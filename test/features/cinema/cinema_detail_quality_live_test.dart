import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  const path = String.fromEnvironment('NAKU_DETAIL_QUALITY_LIVE');
  test(
    'bounded detail probes read live source dimensions before playback',
    () async {
      final rows = jsonDecode(await File(path).readAsString()) as List;
      final router = CinemaMediaRouter(
        configuration: () =>
            const NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 7897),
        enabled: () => true,
      );
      addTearDown(router.close);
      final transport = CinemaMediaTransport(router: router);
      addTearDown(() => transport.dio.close(force: true));
      final probe = CinemaMediaProbe.detail(transport: transport);
      for (final row in rows) {
        final result = await probe.measure(
          row['url'],
          {},
          hls: true,
          timeout: const Duration(seconds: 5),
        );
        debugPrint(
          'DETAIL_QUALITY: ${jsonEncode({'source': row['source'], 'ok': result.ok, 'width': result.width, 'height': result.height, 'elapsedMs': result.elapsedMs, 'reason': result.reason})}',
        );
        expect(result.width, greaterThan(0), reason: row['source']);
        expect(result.height, greaterThan(0), reason: row['source']);
      }
    },
    skip: path.isEmpty,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
