import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/request/core/network_config.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.proxy, this.requests, {this.preferProxy});
  final bool Function()? preferProxy;
  final bool proxy;
  final List<({bool proxy, RequestOptions request})> requests;
  bool failActual = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add((proxy: proxy, request: o));
    if (failActual && !o.headers.containsValue('bytes=0-262143')) {
      throw DioException.connectionError(
        requestOptions: o,
        reason: 'fixture network down',
      );
    }
    final proxyFast =
        preferProxy?.call() ??
        (o.uri.host.startsWith('proxy') ||
            (o.uri.host == 'shared.example' &&
                !o.uri.path.endsWith('.m3u8') &&
                !o.uri.path.endsWith('init.ts')));
    final fast = proxy == proxyFast;
    await Future<void>.delayed(Duration(milliseconds: fast ? 4 : 50));
    return ResponseBody(
      Stream.value(
        Uint8List(o.uri.path.endsWith('init.ts') ? 1024 : 262144)..[0] = 0x47,
      ),
      200,
      headers: {
        'content-type': ['video/mp2t'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const config = NetworkConfig(proxyHost: '127.0.0.1', proxyPort: 7897);

  test(
    'same CDN and proxy are remeasured after moving from home Wi-Fi to hotel Wi-Fi',
    () async {
      var network = 'home';
      var proxyFast = true;
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        networkIdentity: () => network,
        clientFactory: (r) => Dio()
          ..httpClientAdapter = _Adapter(
            r.proxy != null,
            requests,
            preferProxy: () => proxyFast,
          ),
      );
      addTearDown(router.close);
      final uri = Uri.parse('https://same-cdn.example/episode.ts');
      expect((await router.select(uri, {})).proxy, isNotNull);
      expect((await router.select(uri, {})).proxy, isNotNull);
      expect(requests, hasLength(2));
      network = 'hotel';
      proxyFast = false;
      expect(router.labelFor(uri), '');
      expect((await router.select(uri, {})).proxy, isNull);
      expect(requests, hasLength(4));
      network = 'home';
      proxyFast = true;
      expect((await router.select(uri, {})).proxy, isNotNull);
      expect(requests, hasLength(6));
    },
  );

  test(
    'an old network race cannot return its route after the network changes',
    () async {
      var network = 'home';
      var proxyFast = true;
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        networkIdentity: () => network,
        clientFactory: (r) => Dio()
          ..httpClientAdapter = _Adapter(
            r.proxy != null,
            requests,
            preferProxy: () => proxyFast,
          ),
      );
      addTearDown(router.close);
      final pending = router.select(
        Uri.parse('https://same-cdn.example/episode.ts'),
        {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 1));
      network = 'hotel';
      proxyFast = false;
      expect((await pending).proxy, isNull);
      expect(requests, hasLength(4));
    },
  );
  test(
    'a tiny initialization segment cannot poison the shared video decision',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      expect(
        (await router.select(
          Uri.parse('https://shared.example/init.ts'),
          {},
        )).proxy,
        isNull,
      );
      expect(
        (await router.select(
          Uri.parse('https://shared.example/full.ts'),
          {},
        )).proxy,
        isNotNull,
      );
      expect(requests, hasLength(4));
    },
  );
  test(
    'a fast manifest never decides the video route on the same CDN',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      final manifest = Uri.parse('https://shared.example/index.m3u8');
      final segment = Uri.parse('https://shared.example/one.ts');
      expect((await router.select(manifest, {}, metadata: true)).proxy, isNull);
      expect((await router.select(segment, {})).proxy, isNotNull);
      expect(router.labelFor(manifest, metadata: true), '直连');
      expect(router.labelFor(segment), '代理');
      expect(requests, hasLength(4));
    },
  );
  test(
    'different CDN origins independently choose direct or proxy and reuse the result',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      expect(
        (await router.select(
          Uri.parse('https://direct.example/one.ts'),
          {},
        )).proxy,
        isNull,
      );
      expect(
        (await router.select(
          Uri.parse('https://proxy.example/one.ts'),
          {},
        )).proxy,
        isNotNull,
      );
      final before = requests.length;
      await router.select(Uri.parse('https://proxy.example/two.ts'), {});
      expect(requests.length, before);
      final response = await router.open(
        Uri.parse('https://direct.example/two.ts'),
        {},
      );
      await response.data!.stream.drain<void>();
      expect(response.extra['cinemaRoute'], '直连');
      expect(
        requests.where(
          (r) => r.request.headers.containsValue('bytes=0-262143'),
        ),
        hasLength(4),
      );
    },
  );
  test(
    'an in-flight decision is shared and private NAS addresses are never probed',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      await Future.wait([
        router.select(Uri.parse('https://direct.example/a.ts'), {}),
        router.select(Uri.parse('https://direct.example/b.ts'), {}),
      ]);
      expect(requests, hasLength(2));
      expect(
        (await router.select(Uri.parse('http://192.168.1.10:9321/video'), {
          'Authorization': 'private-fixture',
        })).proxy,
        isNull,
      );
      expect(requests, hasLength(2));
    },
  );
  test(
    'failure on the remembered path retries the alternate once and updates the hint',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final adapters = <bool, _Adapter>{};
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) {
          final a = _Adapter(r.proxy != null, requests);
          adapters[r.proxy != null] = a;
          return Dio()..httpClientAdapter = a;
        },
      );
      addTearDown(router.close);
      final uri = Uri.parse('https://direct.example/a.ts');
      await router.select(uri, {});
      adapters[false]!.failActual = true;
      final response = await router.open(uri, {});
      await response.data!.stream.drain<void>();
      expect(response.extra['cinemaRoute'], '代理');
      expect(router.labelFor(uri), '代理');
      expect(
        requests.where(
          (r) => !r.request.headers.containsValue('bytes=0-262143'),
        ),
        hasLength(2),
      );
    },
  );
  test(
    'proxy configuration changes invalidate the previous comparison naturally',
    () async {
      var configuration = config;
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => configuration,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      final uri = Uri.parse('https://direct.example/a.ts');
      await router.select(uri, {});
      configuration = const NetworkConfig(
        proxyHost: '127.0.0.1',
        proxyPort: 7898,
      );
      await router.select(uri, {});
      expect(requests, hasLength(4));
    },
  );
  test(
    'caller cancellation prevents an actual media request after comparison',
    () async {
      final requests = <({bool proxy, RequestOptions request})>[];
      final router = CinemaMediaRouter(
        configuration: () => config,
        enabled: () => true,
        clientFactory: (r) =>
            Dio()..httpClientAdapter = _Adapter(r.proxy != null, requests),
      );
      addTearDown(router.close);
      final cancel = CancelToken();
      final result = router.open(
        Uri.parse('https://direct.example/a.ts'),
        {},
        cancel: cancel,
      );
      cancel.cancel('fixture close');
      await expectLater(result, throwsA(isA<DioException>()));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        requests.every(
          (r) => r.request.headers.containsValue('bytes=0-262143'),
        ),
        isTrue,
      );
    },
  );
}
