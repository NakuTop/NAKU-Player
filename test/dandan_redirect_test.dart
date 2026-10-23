import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.target);
  final String target;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    if (requests.length == 1)
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [target],
        },
      );
    return ResponseBody.fromString(
      jsonEncode({'comments': []}),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const credentials = DandanCredentials(
    id: 'fixture-app',
    secret: 'fixture-secret',
  );
  test(
    'official comment accelerator receives no app credentials or signature',
    () async {
      final adapter = _Adapter(
        'https://comment-cdn.example.org/signed-data.json',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      await DanmakuClient(
        credentials: credentials,
        dio: dio,
      ).get('https://api.dandanplay.net/api/v2/comment/1');
      expect(adapter.requests, hasLength(2));
      final redirected = adapter.requests.last.headers.map(
        (key, value) => MapEntry(key.toLowerCase(), value),
      );
      for (final name in [
        'x-appid',
        'x-appsecret',
        'x-signature',
        'x-timestamp',
        'authorization',
      ]) {
        expect(redirected, isNot(contains(name)));
      }
    },
  );
  test(
    'an untrusted initial URL is rejected before obtaining credentials',
    () async {
      var reads = 0;
      final client = DanmakuClient(
        credentialProvider: () async {
          reads++;
          return credentials;
        },
      );
      await expectLater(
        client.get('https://other.example/api/v2/comment/1'),
        throwsFormatException,
      );
      expect(reads, 0);
    },
  );
  for (final url in [
    'http://cdn.example.org/x',
    'https://127.0.0.1/x',
    'https://host.local/x',
    'https://user:pass@example.org/x',
  ]) {
    test('unsafe accelerator target is rejected: $url', () async {
      final adapter = _Adapter(url);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      await expectLater(
        DanmakuClient(
          credentials: credentials,
          dio: dio,
        ).get('https://api.dandanplay.net/api/v2/comment/1'),
        throwsA(isA<DanmakuServiceException>()),
      );
      expect(adapter.requests, hasLength(1));
    });
  }
}
