import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:ech_http/ech_http.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_service.dart';

class MirrorAdapter implements HttpClientAdapter {
  final calls = <Uri>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    calls.add(o.uri);
    if (o.uri.host == 'api.bgm.tv') return ResponseBody.fromString('ok', 200);
    throw DioException.connectionError(requestOptions: o, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

class FailingImages extends BangumiEchImageService {
  FailingImages(this.code) : super(proxyForUrl: (_) => null);
  final int code;
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async => throw EchException('transport', nativeCode: code);
}

void main() {
  test(
    'mirror transport failure retries the original public URI once',
    () async {
      final fallback = MirrorAdapter();
      final adapter = BangumiEchAdapter(
        fallback: fallback,
        config: const NetworkConfig(),
      );
      final response = await adapter.fetch(
        RequestOptions(
          path: 'https://api.kazumi.fyi/v0/subjects/899',
          extra: {
            'bangumiOriginalRead': 'https://api.bgm.tv/v0/subjects/899?x=1',
          },
        ),
        null,
        null,
      );
      expect(response.statusCode, 200);
      expect(fallback.calls.map((e) => e.toString()), [
        'https://api.kazumi.fyi/v0/subjects/899',
        'https://api.bgm.tv/v0/subjects/899?x=1',
      ]);
      adapter.close();
    },
  );
  test(
    'mirror fallback rejects signed requests even with stale retry metadata',
    () async {
      final fallback = MirrorAdapter();
      final adapter = BangumiEchAdapter(
        fallback: fallback,
        config: const NetworkConfig(),
      );
      await expectLater(
        adapter.fetch(
          RequestOptions(
            path: 'https://api.kazumi.fyi/v0/subjects/899',
            headers: {'X-Signature': 'signature'},
            extra: {
              'bangumiOriginalRead': 'https://api.bgm.tv/v0/subjects/899',
            },
          ),
          null,
          null,
        ),
        throwsA(isA<DioException>()),
      );
      expect(fallback.calls, hasLength(1));
      adapter.close();
    },
  );
  test(
    'image connection failure uses original image client; certificates stay final',
    () async {
      for (final code in [7, 60]) {
        var calls = 0;
        final service = ImageFileService(
          acceleration: () => ImageAcceleration.ech,
          echService: FailingImages(code),
          clientFactory: () => MockClient((request) async {
            calls++;
            expect(request.url.host, 'lain.bgm.tv');
            return http.Response('image', 200);
          }),
        );
        try {
          final request = service.get('https://lain.bgm.tv/pic/cover/l/a.jpg');
          if (code == 60) {
            await expectLater(request, throwsA(isA<EchException>()));
            expect(calls, 0);
          } else {
            final response = await request;
            expect(response.statusCode, 200);
            await response.content.drain<void>();
            expect(calls, 1);
          }
        } finally {
          service.close();
        }
      }
    },
  );
}
