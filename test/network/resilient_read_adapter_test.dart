import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/resilient_read_adapter.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

class Adapter implements HttpClientAdapter {
  Adapter(this.read);
  final Future<ResponseBody> Function(RequestOptions) read;
  int calls = 0, closes = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    calls++;
    return read(o);
  }

  @override
  void close({bool force = false}) {
    closes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RequestOptions options({
    String method = 'GET',
    Map<String, dynamic>? headers,
  }) => RequestOptions(
    path: 'https://api.example/data',
    method: method,
    headers: headers,
  );
  Future<ResponseBody> networkFail(RequestOptions o) async =>
      throw DioException.connectionError(requestOptions: o, reason: 'offline');
  test(
    'dead system proxy falls back to direct and reuses the successful route',
    () async {
      var refreshes = 0;
      final proxy = Adapter(networkFail),
          direct = Adapter((_) async => ResponseBody.fromString('ok', 200));
      final adapter = ResilientReadAdapter(
        primaryFactory: () => proxy,
        directFactory: () => direct,
        revision: () => 0,
        proxy: (_) => Uri.parse('http://localhost:7897'),
        refresh: () async {
          refreshes++;
        },
        encryptedRead: (_, _) async => fail('ECH must not run'),
      );
      await adapter.fetch(options(), null, null);
      await adapter.fetch(options(), null, null);
      expect(proxy.calls, 1);
      expect(direct.calls, 2);
      expect(refreshes, 1);
      adapter.close();
    },
  );
  test(
    'public direct failure tries encrypted DNS and learns the working route',
    () async {
      var encrypted = 0;
      final primary = Adapter(networkFail);
      final adapter = ResilientReadAdapter(
        primaryFactory: () => primary,
        revision: () => 0,
        proxy: (_) => null,
        refresh: () async {},
        encryptedRead: (_, _) async {
          encrypted++;
          return ResponseBody.fromString('ok', 200);
        },
      );
      await adapter.fetch(options(), null, null);
      await adapter.fetch(options(), null, null);
      expect(primary.calls, 1);
      expect(encrypted, 2);
      adapter.close();
    },
  );
  test(
    'learned public route never applies to authenticated reads or writes',
    () async {
      var encrypted = 0;
      final p = Adapter(networkFail);
      final a = ResilientReadAdapter(
        primaryFactory: () => p,
        revision: () => 0,
        proxy: (_) => null,
        refresh: () async {},
        encryptedRead: (_, _) async {
          encrypted++;
          return ResponseBody.fromString('ok', 200);
        },
      );
      await a.fetch(options(), null, null);
      for (final request in [
        options(method: 'POST'),
        options(headers: {'Authorization': 'secret'}),
      ]) {
        await expectLater(
          a.fetch(request, null, null),
          throwsA(isA<DioException>()),
        );
      }
      expect(encrypted, 1);
      expect(p.calls, 3);
      a.close();
    },
  );
  test(
    'network configuration revision retires stale pools and route preferences',
    () async {
      var rev = 0;
      final pools = <Adapter>[];
      final adapter = ResilientReadAdapter(
        primaryFactory: () {
          final p = Adapter((_) async => ResponseBody.fromString('ok', 200));
          pools.add(p);
          return p;
        },
        revision: () => rev,
      );
      await adapter.fetch(options(), null, null);
      rev++;
      await adapter.fetch(options(), null, null);
      expect(pools, hasLength(2));
      expect(pools.first.closes, 1);
      adapter.close();
    },
  );
  test(
    'writes, credentials, private hosts, certificates and cancellation are never retried',
    () async {
      for (final o in [
        options(method: 'POST'),
        options(headers: {'Authorization': 'secret'}),
        options(headers: {'Cookie': 'session'}),
        options(headers: {'X-Signature': 'signature'}),
        RequestOptions(path: 'https://api.example/data?access_token=secret'),
        RequestOptions(path: 'http://192.168.1.2/data'),
        RequestOptions(path: 'https://nas.local/a'),
      ]) {
        expect(ResilientReadAdapter.eligible(o), false);
        final p = Adapter(networkFail);
        final adapter = ResilientReadAdapter(
          primaryFactory: () => p,
          encryptedRead: (_, _) async => fail('unsafe retry'),
        );
        await expectLater(
          adapter.fetch(o, null, null),
          throwsA(isA<DioException>()),
        );
        expect(p.calls, 1);
        adapter.close();
      }
      for (final type in [
        DioExceptionType.badCertificate,
        DioExceptionType.badResponse,
        DioExceptionType.cancel,
      ]) {
        final p = Adapter(
          (o) async => throw DioException(requestOptions: o, type: type),
        );
        final a = ResilientReadAdapter(
          primaryFactory: () => p,
          encryptedRead: (_, _) async => fail('unsafe retry'),
        );
        await expectLater(
          a.fetch(options(), null, null),
          throwsA(isA<DioException>()),
        );
        expect(p.calls, 1);
        a.close();
      }
    },
  );
  test(
    'equivalent snapshots do not repeatedly reset pools, proxy removal notifies once',
    () {
      var calls = 0;
      void changed() {
        calls++;
      }

      MacOSSystemProxy.changes.addListener(changed);
      MacOSSystemProxy.setConfiguration({
        'HTTPEnable': 1,
        'ExceptionsList': ['localhost'],
      });
      MacOSSystemProxy.setConfiguration({
        'ExceptionsList': ['localhost'],
        'HTTPEnable': 1,
      });
      MacOSSystemProxy.setConfiguration({});
      expect(calls, 2);
      MacOSSystemProxy.changes.removeListener(changed);
    },
  );
  testWidgets(
    'monitor refreshes proxy removal and retains snapshot on bridge errors',
    (tester) async {
      const channel = MethodChannel('yingchuan/network');
      var snapshot = <String, dynamic>{
        'HTTPEnable': 1,
        'HTTPProxy': '127.0.0.1',
        'HTTPPort': 7897,
      };
      var broken = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (broken) throw PlatformException(code: 'temporary');
            return snapshot;
          });
      addTearDown(() {
        MacOSSystemProxy.stopMonitoring();
        MacOSSystemProxy.setConfiguration({});
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await tester.runAsync(MacOSSystemProxy.initialize);
      final uri = Uri.parse('http://example.com');
      expect(MacOSSystemProxy.proxyFor(uri)?.port, 7897);
      broken = true;
      await tester.runAsync(MacOSSystemProxy.initialize);
      expect(MacOSSystemProxy.proxyFor(uri)?.port, 7897);
      broken = false;
      snapshot = {};
      MacOSSystemProxy.startMonitoring();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(MacOSSystemProxy.proxyFor(uri), isNull);
      MacOSSystemProxy.stopMonitoring();
    },
  );
}
