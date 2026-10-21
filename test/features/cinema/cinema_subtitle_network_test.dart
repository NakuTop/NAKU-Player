import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_network.dart';

class _Route implements HttpClientAdapter {
  int calls = 0;
  Object? failure;
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (failure case final error?) throw error;
    return ResponseBody.fromString('public data', status);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  RequestOptions request(
    String url, {
    String method = 'GET',
    Map<String, dynamic>? headers,
  }) => RequestOptions(path: url, method: method, headers: headers);
  test(
    'system proxy TLS failure recovers Chinese source and remembers route',
    () async {
      final primary = _Route()
        ..failure = const HandshakeException('proxy closed');
      final direct = _Route();
      var route = 'PROXY system.invalid:7890';
      final adapter = CinemaSubtitleNetworkAdapter(
        primary: primary,
        direct: direct,
        systemProxy: (_) => route,
      );
      final options = request('https://assrt.net/download/675334/public.zip');
      expect((await adapter.fetch(options, null, null)).statusCode, 200);
      expect((await adapter.fetch(options, null, null)).statusCode, 200);
      expect(primary.calls, 1);
      expect(direct.calls, 2);
      expect(adapter.recoveredHosts, {'assrt.net'});
      route = 'DIRECT';
      await expectLater(
        adapter.fetch(options, null, null),
        throwsA(isA<HandshakeException>()),
      );
      expect(direct.calls, 2);
    },
  );
  test(
    'proxy gateway failure retries anonymously but does not replay 403',
    () async {
      final primary = _Route()..status = 502;
      final direct = _Route();
      final adapter = CinemaSubtitleNetworkAdapter(
        primary: primary,
        direct: direct,
        systemProxy: (_) => 'PROXY system.invalid:7890',
      );
      expect(
        (await adapter.fetch(
          request('https://assrt.net/sub/'),
          null,
          null,
        )).statusCode,
        200,
      );
      primary.status = 403;
      expect(
        (await adapter.fetch(
          request('https://www.subhd.tv/search/x'),
          null,
          null,
        )).statusCode,
        403,
      );
      expect(direct.calls, 1);
    },
  );
  test(
    'private, credentialed, non-GET and cancelled requests never fail over',
    () async {
      final primary = _Route()
        ..failure = const HandshakeException('proxy closed');
      final direct = _Route();
      final adapter = CinemaSubtitleNetworkAdapter(
        primary: primary,
        direct: direct,
        systemProxy: (_) => 'PROXY system.invalid:7890',
      );
      final cancelled = request('https://assrt.net/sub/')
        ..cancelToken = (CancelToken()..cancel());
      for (final options in [
        request('https://nas.local/private'),
        request('https://192.168.1.2/private'),
        request('https://assrt.net/sub/?token=secret'),
        request('https://assrt.net/sub/', headers: {'Authorization': 'secret'}),
        request('https://assrt.net/sub/', method: 'POST'),
        cancelled,
      ]) {
        await expectLater(
          adapter.fetch(options, null, null),
          throwsA(isA<HandshakeException>()),
        );
      }
      expect(direct.calls, 0);
    },
  );
}
