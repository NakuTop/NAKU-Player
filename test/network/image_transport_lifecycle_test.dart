import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_service.dart';
import 'package:kazumi/services/network/resilient_image_client.dart';

class Images extends http.BaseClient {
  bool closed = false;
  final requests = <http.BaseRequest>[];
  final bodies = <StreamController<List<int>>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = StreamController<List<int>>();
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200);
  }

  @override
  void close() {
    closed = true;
  }
}

class StalledBody implements HttpClientAdapter {
  final body = StreamController<Uint8List>();
  bool cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? request,
    Future<void>? cancel,
  ) async {
    cancel?.then((_) => cancelled = true);
    return ResponseBody(body.stream, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'posters reuse a client; reset retires it after both downloads complete',
    () async {
      final created = <Images>[];
      final service = ImageFileService(
        acceleration: () => ImageAcceleration.direct,
        clientFactory: () {
          final client = Images();
          created.add(client);
          return client;
        },
        echService: BangumiEchImageService(proxyForUrl: (_) => null),
      );
      addTearDown(service.close);
      final first = await service.get('https://img9.doubanio.com/a.jpg');
      final second = await service.get('https://images.example/b.jpg');
      expect(created, hasLength(1));
      expect(
        created.single.requests.first.headers['user-agent'],
        'NAKUPlayer/1.5.0',
      );
      expect(
        created.single.requests.first.headers['referer'],
        'https://m.douban.com/',
      );
      expect(
        created.single.requests.last.headers.containsKey('referer'),
        isFalse,
      );
      final firstDone = first.content.drain<void>();
      final secondDone = second.content.drain<void>();
      await created.first.bodies[0].close();
      await firstDone;
      expect(created.first.closed, isFalse);
      service.resetNetworkClients();
      expect(
        created.first.closed,
        isFalse,
        reason: 'second download still owns this client',
      );
      final third = await service.get(
        'https://img9.doubanio.com/c.jpg',
        headers: {
          'User-Agent': 'Caller/1',
          'Referer': 'https://caller.example/',
        },
      );
      expect(created, hasLength(2));
      expect(created.last.requests.single.headers['user-agent'], 'Caller/1');
      await created.first.bodies[1].close();
      await secondDone;
      expect(created.first.closed, isTrue);
      final thirdDone = third.content.drain<void>();
      await created.last.bodies.single.close();
      await thirdDone;
      expect(created.last.closed, isFalse);
      service.close();
      expect(created.last.closed, isTrue);
    },
  );
  test(
    'stalled image body times out and releases the underlying request',
    () async {
      final adapter = StalledBody();
      final client = ResilientImageClient(
        adapter: adapter,
        bodyIdleTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(client.close);
      final response = await client.send(
        http.Request('GET', Uri.parse('https://images.example/a.jpg')),
      );
      await expectLater(
        response.stream.drain<void>(),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(adapter.cancelled, isTrue);
      await adapter.body.close();
    },
  );
}
