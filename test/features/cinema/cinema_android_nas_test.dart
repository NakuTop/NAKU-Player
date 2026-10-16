import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_android_nas.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  set contentType(ContentType? value) {
    values['content-type'] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes, this.headers);
  final List<int> bytes;
  @override
  final HttpHeaders headers;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.url, this.transport);
  final Uri url;
  final _Client transport;
  final bytes = <int>[];
  @override
  final headers = _Headers();
  @override
  bool followRedirects = false;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async {
    transport.requests.add(this);
    final responseHeaders = _Headers();
    Map<String, dynamic> result = {'code': 200, 'data': <String, dynamic>{}};
    if (url.path.endsWith('/create/qrCode')) {
      result['data'] = {
        'qrCode': 'private-poll-id',
        'url': 'https://example.ugnas.com/scan',
      };
    } else if (url.path.endsWith('/oauth/token')) {
      result['code'] = transport.qrCode;
      result['data'] = {
        'user': {
          'scanType': 'localScan',
          'linkParams': jsonEncode({
            'token': 'encrypted-token',
            'token_safe': true,
            'public_key': 'test-public-key',
            if (transport.wrongQRAccount) 'username': 'mallory',
          }),
        },
      };
    } else if (url.path.endsWith('/current/user')) {
      result['data'] = {'username': 'alice', 'uid': 1000};
    } else if (url.path.endsWith('/machine/common')) {
      result['data'] = {
        'common': {'serial': 'TEST-NAS'},
      };
    } else if (url.path.endsWith('/verify/check')) {
      responseHeaders.set('X-Rsa-Token', 'test-public-key');
    } else if (url.path.endsWith('/verify/login')) {
      result['data'] = {
        'token': 'secret-token',
        'public_key': 'test-public-key',
        'sn': 'TEST-NAS',
        'nas_name': 'Test NAS',
      };
    } else if (url.path.endsWith('/priority_link')) {
      result['data'] = {
        'ipv4': ['192.168.8.4', '8.8.8.8'],
        'http_port': 9999,
      };
    } else if (url.path.endsWith('/verify/sn')) {
      result['data'] = {
        'sn': url.host == '192.168.8.4' ? 'wrong-device' : 'pinned-device',
      };
    } else if (url.path.endsWith('/web/info')) {
      result['data'] = {
        'transcodeable': [
          {'resolution': '1920x1080', 'name': '1080P'},
        ],
        'resolution': {'name': '1080P'},
        'audios': [
          {'id': 7, 'language': '中文', 'isDefault': 1},
        ],
        'subtitles': [
          {'id': 12, 'language': '简体中文', 'is_text': 1},
        ],
        'duration': 1500,
        'width': 1920,
        'height': 1080,
      };
    } else if (url.path.endsWith('/getHomeShare')) {
      result['data'] = {'path': '/home/alice'};
    } else if (url.path.endsWith('/getDirFileList')) {
      final path = (jsonDecode(utf8.decode(bytes)) as Map)['path'] as String;
      result['data'] = {
        'files': [
          for (final name in ['NakuPlayer', 'sync-v1']) {'name': name},
          if (path.endsWith('/sync-v1/')) {'name': transport.account},
          for (final name in transport.files.keys) {'name': name},
        ],
      };
    } else if (url.path.endsWith('/fileUpload')) {
      final text = utf8.decode(bytes);
      String field(String name) => RegExp(
        'name="$name"\\r\\n\\r\\n([^\\r]+)',
      ).firstMatch(text)!.group(1)!;
      if (field('first_request') == 'false') {
        final start =
            text.indexOf('Content-Type: application/octet-stream\r\n\r\n') +
            'Content-Type: application/octet-stream\r\n\r\n'.length;
        transport.files[field('filename')] = text.substring(
          start,
          text.lastIndexOf('\r\n--'),
        );
      }
    } else if (url.path.endsWith('/downloadFile')) {
      return _Response(
        utf8.encode(
          transport.files[url.queryParameters['paths']!.split('/').last]!,
        ),
        responseHeaders,
      );
    } else if (url.path.endsWith('/get_all')) {
      if (transport.expireOnce) {
        result['code'] = 9902;
        transport.expireOnce = false;
      }
      result['data'] = {
        'media_lib_arr': [
          {'id': 1},
        ],
      };
    }
    return _Response(utf8.encode(jsonEncode(result)), responseHeaders);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  final requests = <_Request>[];
  final files = <String, String>{};
  String account = "";
  bool expireOnce = false, wrongQRAccount = false;
  int qrCode = 81520;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(url, this);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client http;
  late CinemaAndroidNAS nas;
  String? saved;
  setUp(() {
    http = _Client();
    saved = null;
    nas = HttpOverrides.runZoned(
      () => CinemaAndroidNAS(),
      createHttpClient: (_) => http,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('naku/secure'), (
          call,
        ) async {
          final a = call.arguments as Map? ?? {};
          switch (call.method) {
            case 'qrKey':
              return 'ephemeral-public-key';
            case 'qrDecrypt':
              return 'decrypted-token';
            case 'rsa':
              return 'rsa-${a['text']}';
            case 'seal':
              return base64Encode(utf8.encode('${a['text']}'));
            case 'open':
              return utf8.decode(base64Decode('${a['text']}'));
            case 'write':
              saved = a['value'];
              return null;
            case 'read':
              return saved;
            case 'delete':
              saved = null;
              return null;
          }
          return null;
        });
  });
  Future<Map> login() async =>
      await nas.invoke('login', {
            'address': 'https://example.ug.link',
            'username': 'alice',
            'password': 'pass',
          })
          as Map;
  test(
    'QR waiting scanned authorization persists verified session and restores without password',
    () async {
      final qr = await nas.invoke('qrCreate', {
        'address': 'https://example.ug.link',
      });
      expect(qr, {'url': 'https://example.ugnas.com/scan'});
      final create = http.requests.firstWhere(
        (r) => r.url.path.endsWith('/create/qrCode'),
      );
      expect(jsonDecode(utf8.decode(create.bytes))['clientType'], 'Mac');
      expect(saved, isNull);
      expect(await nas.invoke('qrPoll'), {'state': 'waiting'});
      http.qrCode = 81308;
      expect(await nas.invoke('qrPoll'), {'state': 'scanned'});
      http.qrCode = 200;
      final session = await nas.invoke('qrPoll') as Map;
      expect(session['state'], 'authorized');
      expect(session.containsKey('token'), false);
      expect(jsonDecode(saved!)['token'], 'decrypted-token');
      expect(jsonDecode(saved!).containsKey('password'), false);
      await nas.invoke('logout');
      final restored = await nas.invoke('restore') as Map;
      expect(restored['namespace'], session['namespace']);
      expect(
        http.requests.any((r) => r.url.path.endsWith('/verify/login')),
        false,
      );
      await expectLater(
        nas.invoke('qrPoll'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  test(
    'QR rejects mismatched account without persisting and clears temporary key',
    () async {
      await nas.invoke('qrCreate', {'address': 'https://example.ug.link'});
      http.qrCode = 200;
      http.wrongQRAccount = true;
      await expectLater(
        nas.invoke('qrPoll'),
        throwsA(isA<PlatformException>()),
      );
      expect(saved, isNull);
      expect(await nas.invoke('currentSession'), isEmpty);
    },
  );
  test('cancel invalidates a queued QR poll before adoption', () async {
    await nas.invoke('qrCreate', {'address': 'https://example.ug.link'});
    http.qrCode = 200;
    final pending = nas.invoke('qrPoll');
    final assertion = expectLater(pending, throwsA(isA<PlatformException>()));
    await nas.invoke('qrCancel');
    await assertion;
    expect(saved, isNull);
    expect(await nas.invoke('currentSession'), isEmpty);
  });
  test('QR expiration and cancellation prevent further polling', () async {
    await nas.invoke('qrCreate', {'address': 'https://example.ug.link'});
    http.qrCode = 8058;
    expect(await nas.invoke('qrPoll'), {'state': 'expired'});
    await expectLater(nas.invoke('qrPoll'), throwsA(isA<PlatformException>()));
    await nas.invoke('qrCreate', {'address': 'https://example.ug.link'});
    await nas.invoke('qrCancel');
    await expectLater(nas.invoke('qrPoll'), throwsA(isA<PlatformException>()));
    expect(saved, isNull);
  });
  test(
    'login persists credentials only via secure store; page reentry makes no request',
    () async {
      final info = await login();
      expect(info['namespace'], hasLength(64));
      expect(info.containsKey('token'), false);
      expect(jsonDecode(saved!)['password'], 'pass');
      final count = http.requests.length;
      expect(await nas.invoke('currentSession'), info);
      expect(http.requests.length, count);
      final metadata = await nas.invoke('savedLogin') as Map;
      expect(metadata.keys, unorderedEquals(['address', 'username']));
      await nas.invoke('logout');
      expect(await nas.invoke('currentSession'), isEmpty);
      expect(saved, isNotNull);
      await nas.invoke('restore');
      expect(
        (await nas.invoke('currentSession') as Map)['namespace'],
        info['namespace'],
      );
      await nas.invoke('forget');
      expect(saved, isNull);
    },
  );
  test(
    'account mismatch refuses a media reference before sending request',
    () async {
      await login();
      final count = http.requests.length;
      await expectLater(
        nas.invoke('ensure', {'namespace': 'b' * 64}),
        throwsA(isA<PlatformException>()),
      );
      expect(http.requests.length, count);
    },
  );
  test('wrong LAN identity never receives session credentials', () async {
    final info = await login();
    final result =
        await nas.invoke('autoConnect', {
              'namespace': info['namespace'],
              'force': true,
            })
            as Map;
    expect(result['changed'], false);
    final local = http.requests
        .where((r) => r.url.host == '192.168.8.4')
        .toList();
    expect(local, isNotEmpty);
    for (final request in local) {
      expect(request.url.path, '/ugreen/v1/verify/sn');
      expect(request.url.query, '');
      expect(request.headers.value('x-ugreen-token'), isNull);
      expect(request.bytes, isEmpty);
    }
    expect(http.requests.any((r) => r.url.host == '8.8.8.8'), false);
  });
  test(
    'expired session renews once with the saved account and retries catalogue',
    () async {
      final info = await login();
      http.expireOnce = true;
      final libraries = await nas.invoke('libraries') as Map;
      expect(libraries['media_lib_arr'], isNotEmpty);
      expect(
        http.requests.where((r) => r.url.path.endsWith('/verify/login')).length,
        2,
      );
      expect(
        (await nas.invoke('currentSession') as Map)['namespace'],
        info['namespace'],
      );
    },
  );

  test(
    'NAS playback options preserve real track IDs and clean up the probe task',
    () async {
      final info = await login();
      final options =
          await nas.invoke('playbackOptions', {
                'namespace': info['namespace'],
                'id': 1,
                'library': 2,
                'path': '/Movies/example.mkv',
              })
              as Map;
      expect((options['audios'] as List).first['id'], 7);
      expect((options['subtitles'] as List).last['id'], 12);
      expect((options['subtitles'] as List).first['id'], -1);
      expect(options['durationMs'], 1500);
      final opened = http.requests.singleWhere(
        (r) => r.url.path.endsWith('/web/info'),
      );
      final closed = http.requests.singleWhere(
        (r) => r.url.path.endsWith('/web/close'),
      );
      expect(
        jsonDecode(utf8.decode(opened.bytes))['task_id'],
        jsonDecode(utf8.decode(closed.bytes))['task_id'],
      );
    },
  );

  test(
    'NAS sync uploads immutable two-phase revisions with readback and pulls latest writer',
    () async {
      final info = await login();
      http.account = info['namespace'] as String;
      final args = {
        'namespace': info['namespace'],
        'device': '11111111-1111-1111-1111-111111111111',
        'sequence': 1,
        'document': '{"version":1,"hello":"世界"}',
      };
      await nas.invoke('syncPush', args);
      expect(http.files.length, 1);
      final uploads = http.requests
          .where((r) => r.url.path.endsWith('/fileUpload'))
          .length;
      expect(uploads, 2);
      await nas.invoke('syncPush', args);
      expect(
        http.requests.where((r) => r.url.path.endsWith('/fileUpload')).length,
        uploads,
      );
      await expectLater(
        nas.invoke('syncPush', {...args, 'document': 'conflict'}),
        throwsA(isA<PlatformException>()),
      );
      final pulled =
          await nas.invoke('syncPull', {'namespace': info['namespace']}) as Map;
      expect(pulled['documents'], [args['document']]);
    },
  );

  test(
    'reject cleartext remote origins and ambiguous private addresses',
    () async {
      await expectLater(
        nas.invoke('login', {
          'address': 'http://public.example',
          'username': 'alice',
          'password': 'pass',
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(http.requests, isEmpty);
      for (final ip in [
        '127.0.0.1',
        '169.254.1.1',
        '192.168.01.1',
        '172.32.0.1',
        '8.8.8.8',
      ]) {
        expect(CinemaAndroidNAS.privateIPv4(ip), false);
      }
      for (final ip in ['10.1.2.3', '192.168.1.1', '172.16.0.1']) {
        expect(CinemaAndroidNAS.privateIPv4(ip), true);
      }
    },
  );
}
