import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:kazumi/features/cinema/douban/douban_image_headers.dart';
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_service.dart';

void main() {
  test(
    'Douban recommendation poster loads through the production image service',
    () async {
      // Follow the explicitly supplied test network configuration; keep TLS
      // verification enabled and never load or alter application preferences.
      final proxyValue = Platform.environment['HTTPS_PROXY'];
      final proxy = proxyValue == null ? null : Uri.parse(proxyValue);
      final service = ImageFileService(
        acceleration: () => ImageAcceleration.ech,
        clientFactory: () {
          final client = HttpClient();
          if (proxy != null) {
            client.findProxy = (_) => 'PROXY ${proxy.authority}';
          }
          return IOClient(client);
        },
        echService: BangumiEchImageService(proxyForUrl: (_) => proxy),
      );
      try {
        final response = await service
            .get(
              'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2929018970.jpg',
              headers: doubanImageHeaders,
            )
            .timeout(const Duration(seconds: 15));
        expect(response.statusCode, 200);
        final bytes = await response.content
            .expand((chunk) => chunk)
            .toList()
            .timeout(const Duration(seconds: 15));
        expect(bytes.length, greaterThan(1000));
        expect(bytes.take(3), [0xff, 0xd8, 0xff]);
      } finally {
        service.close();
      }
    },
    skip: Platform.environment['NAKU_LIVE_POSTERS'] != '1',
  );
}
