import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Android implementation of the existing NAS channel contract. Credentials
/// remain encrypted by Android Keystore; persisted media use stable NAS IDs.
class CinemaAndroidNAS {
  static final instance = CinemaAndroidNAS();
  static const _secure = MethodChannel('naku/secure');
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final _random = Random.secure();
  Future<void> _tail = Future.value();
  String _base = '', _token = '', _key = '', _staticToken = '', _auth = 'url';
  String _namespace = '', _username = '', _name = '', _remote = '', _hint = '';
  final Set<String> _lan = {};
  bool _ugk = false, _discovered = false;
  DateTime _lastProbe = DateTime(2000);
  final String _clientID = '${DateTime.now().microsecondsSinceEpoch}Android';
  WebSocket? _socket;
  Timer? _heartbeat;
  String _task = '';
  int _qrGeneration = 0;
  String _qrCode = '', _qrOrigin = '', _qrHint = '';

  Uri? _closeURL;
  Map<String, dynamic>? _closeBody;
  Map<String, String>? _closeHeaders;

  // Serialize account changes with requests, so responses cannot adopt another
  // account's data after logout. The socket heartbeat runs independently.
  Future<dynamic> invoke(String method, [Map<String, dynamic>? arguments]) {
    if (method == 'qrCancel' || method == 'qrCreate') _qrGeneration++;
    final requestedQRGeneration = _qrGeneration;
    final completed = Completer<dynamic>();
    _tail = _tail.then((_) async {
      try {
        if ((method == 'qrCreate' || method == 'qrPoll') &&
            requestedQRGeneration != _qrGeneration) {
          _fail('扫码登录已取消。');
        }
        final expected = _namespace;
        dynamic value;
        try {
          value = await _handle(method, arguments ?? {});
        } on PlatformException catch (error) {
          if (error.code != 'nas_expired' ||
              expected.isEmpty ||
              {
                'qrCreate',
                'qrPoll',
                'qrCancel',
                'login',
                'restore',
                'logout',
                'forget',
                'savedLogin',
                'currentSession',
              }.contains(method)) {
            rethrow;
          }
          await _restore();
          if (_namespace != expected) {
            await _logout();
            _fail();
          }
          value = await _handle(method, arguments ?? {});
        }
        completed.complete(value);
      } catch (error) {
        completed.completeError(
          error is PlatformException
              ? error
              : PlatformException(
                  code: 'nas',
                  message: 'NAS 请求失败，请检查地址、网络、证书和账号权限。',
                ),
        );
      }
    });
    return completed.future;
  }

  Never _fail([String message = 'NAS 资源或账号身份不匹配，请重新登录。']) =>
      throw PlatformException(code: 'nas', message: message);
  String _hex(int size) => List.generate(
    size,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  List<Map<String, dynamic>> _rows(dynamic value) =>
      value is List ? value.whereType<Map>().map(_map).toList() : [];
  int _int(dynamic value) => int.tryParse('$value') ?? 0;
  Future<String> _crypto(String method, String text, String key) async =>
      (await _secure.invokeMethod<String>(method, {'text': text, 'key': key}))!;
  Map<String, String> get _headers => {
    'UG-Agent': 'PC/WEB',
    'User-Feature': 'Android',
    'UG-Client-Id': _clientID,
    'Client-Id': _clientID,
    'Client-Version-Str': '1.20.0',
    'Client-Version': '78579',
    'X-Specify-Language': 'zh-CN',
    'Accept-Language': 'zh-CN',
  };
  static bool privateIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4 ||
        parts.any((p) => !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(p))) {
      return false;
    }
    final n = parts.map(int.parse).toList();
    return n.every((v) => v <= 255) &&
        (n[0] == 10 ||
            n[0] == 192 && n[1] == 168 ||
            n[0] == 172 && n[1] >= 16 && n[1] <= 31);
  }

  Uri _origin(String value) {
    final u = Uri.parse(value);
    if (!['http', 'https'].contains(u.scheme) ||
        u.host.isEmpty ||
        u.userInfo.isNotEmpty ||
        u.hasQuery ||
        u.hasFragment ||
        !['', '/'].contains(u.path) ||
        u.scheme == 'http' && !privateIPv4(u.host)) {
      _fail('请输入 HTTPS 远程地址、局域网地址或 UGlink 别名。');
    }
    return u.replace(path: '');
  }

  Future<({List<int> bytes, HttpHeaders headers, int status})> _request(
    Uri url, {
    String method = 'GET',
    dynamic body,
    Map<String, String> headers = const {},
    int limit = 8388608,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = await _http.openUrl(method, url).timeout(timeout);
    request.followRedirects = false;
    ({..._headers, ...headers}).forEach(request.headers.set);
    if (body != null) {
      if (body is List<int>) {
        request.add(body);
      } else {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
    }
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      if ([401, 403].contains(response.statusCode)) {
        throw PlatformException(code: 'nas_expired', message: 'NAS 会话失效或权限不足。');
      }
      _fail('NAS 网络请求未成功（${response.statusCode}）。');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > limit) _fail('NAS 返回的数据超出安全大小限制。');
    }
    return (
      bytes: bytes,
      headers: response.headers,
      status: response.statusCode,
    );
  }

  Map<String, dynamic> _decode(List<int> bytes) =>
      _map(jsonDecode(utf8.decode(bytes)));
  void _check(Map<String, dynamic> object) {
    final code = _int(object['code']);
    if ([401, 403, 9902].contains(code)) {
      throw PlatformException(code: 'nas_expired', message: 'NAS 会话失效或权限不足。');
    }
    if (code != 200) {
      _fail(code == 1003 ? '账号或密码不正确。' : 'NAS 返回错误（$code）；请检查账号权限或验证要求。');
    }
  }

  Future<String> _resolve(String address) async {
    if (!address.contains('://') &&
        RegExp(r'^[a-zA-Z0-9-]{1,63}$').hasMatch(address)) {
      final r = _decode(
        (await _request(
          Uri.parse('https://api.ugnas.com/api/p2p/v2/ta/nodeInfo/byAlias'),
          method: 'POST',
          body: {'alias': address},
        )).bytes,
      );
      _check(r);
      final data = _map(r['data']),
          domain = '${_map(r['data'])['relayDomain']}',
          alias = '${_map(r['data'])['alias']}';
      if (!(domain == 'ug.link' || domain.endsWith('.ug.link')) ||
          !RegExp(r'^[a-zA-Z0-9-]{1,63}$').hasMatch(alias) ||
          data.isEmpty) {
        _fail();
      }
      return _origin('https://$alias.$domain').toString();
    }
    return _origin(address).toString();
  }

  Future<Map<String, dynamic>> _saved() async {
    final raw = await _secure.invokeMethod<String>('read');
    return raw == null ? {} : _map(jsonDecode(raw));
  }

  Map<String, dynamic> _current() => _namespace.isEmpty
      ? {}
      : {
          'namespace': _namespace,
          'name': _name,
          'username': _username,
          'address': _base,
        };
  Future<void> _logout() async {
    await _close();
    _base = '';
    _token = '';
    _key = '';
    _namespace = '';
    _username = '';
    _name = '';
    _remote = '';
    _hint = '';
    _lan.clear();
    _discovered = false;
  }

  Future<Map<String, dynamic>> _login(
    Map<String, dynamic> args, {
    bool save = true,
  }) async {
    await _logout();
    final address = '${args['address'] ?? ''}',
        username = '${args['username'] ?? ''}',
        password = '${args['password'] ?? ''}';
    if (username.isEmpty || password.isEmpty) _fail('请输入 NAS 账号和密码。');
    final origin = await _resolve(address);
    final challenge = await _request(
      Uri.parse('$origin/ugreen/v1/verify/check'),
      method: 'POST',
      body: {'username': username},
    );
    final pk = challenge.headers.value('X-Rsa-Token');
    if (pk == null) _fail();
    final response = _decode(
      (await _request(
        Uri.parse('$origin/ugreen/v1/verify/login'),
        method: 'POST',
        body: {
          'username': username,
          'password': await _crypto('rsa', password, pk),
          'keepalive': false,
          'otp': true,
          'is_simple': true,
        },
      )).bytes,
    );
    _check(response);
    final d = _map(response['data']);
    if ('${d['token'] ?? ''}'.isEmpty ||
        '${d['public_key'] ?? ''}'.isEmpty ||
        '${d['sn'] ?? ''}'.isEmpty) {
      _fail('NAS 需要额外验证，或未返回设备身份。');
    }
    _base = origin;
    _token = d['token'];
    _key = d['public_key'];
    _staticToken = d['static_token'] ?? _token;
    _auth = d['auth_type'] ?? 'url';
    _ugk = d['is_ugk'] == true;
    _username = username;
    _name = d['nas_name'] ?? 'NAS';
    _namespace = _digest('${d['sn']}|$username');
    _capture(d);
    if (save) {
      await _secure.invokeMethod<void>('write', {
        'value': jsonEncode({
          'address': address,
          'username': username,
          'password': password,
        }),
      });
    }
    return _current();
  }

  Future<Map<String, dynamic>> _restore() async {
    final saved = await _saved();
    var address = '${saved['address'] ?? ''}';
    final cache = _map(saved['routes']);
    final hint = '${cache['hint'] ?? ''}';
    if (hint.isNotEmpty) {
      for (final group in [cache['lan'], cache['remote']]) {
        if (group is! List) continue;
        final results = await Future.wait(
          group.whereType<String>().take(12).map((u) => _probe(u, hint)),
        );
        final selected = results.whereType<String>().firstOrNull;
        if (selected != null) {
          address = selected;
          break;
        }
      }
    }
    final result = saved['qr'] == true
        ? await _adoptQR({...saved, 'address': address}, save: false)
        : await _login({...saved, 'address': address}, save: false);
    if (cache['namespace'] != null && cache['namespace'] != _namespace) {
      await _logout();
      _fail();
    }
    if (cache['lan'] is List) {
      _lan.addAll((cache['lan'] as List).whereType<String>());
    }
    if (cache['remote'] is List) {
      _remote =
          (cache['remote'] as List).whereType<String>().firstOrNull ?? _remote;
    }
    _hint = hint;
    return result;
  }

  // LOCAL_LOGIN uses the registered desktop wire profile, even on an Android
  // display. Creating a QR with 'Android' succeeds, but the scanner rejects
  // that profile as an unknown client type in the LOCAL_LOGIN workflow.
  Map<String, String> get _qrIdentity => {
    'platform': 'Mac',
    'clientType': 'Mac',
    'model': 'Android',
    'osVer': Platform.operatingSystemVersion,
    'bid': _clientID,
    'alias': 'Naku Player',
  };

  Future<void> _clearQR() async {
    _qrCode = '';
    _qrOrigin = '';
    _qrHint = '';
    await _secure.invokeMethod<void>('qrClear');
  }

  Future<String> _deviceHint(String origin) async {
    final r = _decode(
      (await _request(Uri.parse('$origin/ugreen/v1/verify/sn'))).bytes,
    );
    _check(r);
    final hint = '${_map(r['data'])['sn'] ?? ''}';
    if (hint.isEmpty) _fail('NAS 未返回设备身份，请检查连接。');
    return hint;
  }

  Future<Map<String, dynamic>> _createQR(String address) async {
    final attempt = _qrGeneration;
    await _clearQR();
    try {
      final origin = await _resolve(address);
      final hint = await _deviceHint(origin);
      final publicKey = await _secure.invokeMethod<String>('qrKey');
      final r = _decode(
        (await _request(
          Uri.parse('https://api.ugnas.com/api/user/v3/sa/create/qrCode'),
          method: 'POST',
          body: {
            ..._qrIdentity,
            'qrType': 'LOCAL_LOGIN',
            'ak': 'UG8FKSDUGREEN001',
            'public_key': publicKey,
            'sn': hint,
          },
        )).bytes,
      );
      if (attempt != _qrGeneration) _fail('扫码登录已取消。');
      _check(r);
      final d = _map(r['data']),
          url = Uri.tryParse('${_map(r['data'])['url']}');
      if (url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          '${d['qrCode'] ?? ''}'.isEmpty) {
        _fail('无法创建二维码，请刷新重试。');
      }
      _qrCode = d['qrCode'];
      _qrOrigin = origin;
      _qrHint = hint;
      return {'url': url.toString()};
    } catch (_) {
      await _clearQR();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _pollQR() async {
    if (_qrCode.isEmpty) _fail('二维码已失效，请刷新。');
    final attempt = _qrGeneration, origin = _qrOrigin, hint = _qrHint;
    final boundary = 'NakuQR-${_hex(16)}';
    final fields = {..._qrIdentity, 'grant_type': 'qrcode', 'qrcode': _qrCode};
    final body =
        '${fields.entries.map((e) => '--$boundary\r\nContent-Disposition: form-data; name="${e.key}"\r\n\r\n${e.value}\r\n').join()}--$boundary--\r\n';
    final r = _decode(
      (await _request(
        Uri.parse('https://api.ugnas.com/api/oauth/token'),
        method: 'POST',
        body: utf8.encode(body),
        headers: {'Content-Type': 'multipart/form-data; boundary=$boundary'},
      )).bytes,
    );
    if (attempt != _qrGeneration) _fail('扫码登录已取消。');
    switch (_int(r['code'])) {
      case 81520:
        return {'state': 'waiting'};
      case 81308:
        return {'state': 'scanned'};
      case 8058:
        await _clearQR();
        return {'state': 'expired'};
      case 200:
        break;
      default:
        await _clearQR();
        _fail('扫码登录未成功（${_int(r['code'])}），请刷新重试。');
    }
    try {
      final user = _map(_map(r['data'])['user']);
      if (user['scanType'] != 'localScan') _fail('请使用绿联云 App 扫码授权 NAS 登录。');
      final p = _map(jsonDecode('${user['linkParams']}'));
      if (p['token_safe'] == true || p['token_safe'] == 1) {
        p['token'] = await _secure.invokeMethod<String>('qrDecrypt', {
          'text': p['token'],
        });
      }
      if (await _deviceHint(origin) != hint || attempt != _qrGeneration) {
        _fail('NAS 设备身份发生变化，请刷新二维码。');
      }
      final result = await _adoptQR({
        ...p,
        'address': origin,
      }, attempt: attempt);
      return {...result, 'state': 'authorized'};
    } finally {
      await _clearQR();
    }
  }

  Future<Map<String, dynamic>> _adoptQR(
    Map<String, dynamic> p, {
    bool save = true,
    int? attempt,
  }) async {
    await _logout();
    try {
      _base = _origin('${p['address']}').toString();
      _token = '${p['token'] ?? ''}';
      _key = '${p['public_key'] ?? ''}';
      if (_token.isEmpty || _key.isEmpty) _fail('扫码响应缺少 NAS 登录会话。');
      _staticToken = '${p['static_token'] ?? _token}';
      _auth = '${p['auth_type'] ?? 'url'}';
      _ugk = p['is_ugk'] == true;
      final current = await _api('v1/user/current/user');
      final username = '${current['username'] ?? ''}',
          uid = int.tryParse('${current['uid']}');
      if (username.isEmpty ||
          uid == null ||
          uid < 0 ||
          ('${p['username'] ?? ''}'.isNotEmpty && p['username'] != username) ||
          (p['uid'] != null && int.tryParse('${p['uid']}') != uid)) {
        _fail('扫码账号与 NAS 返回的账号不一致。');
      }
      final machine = await _api('v1/sysinfo/machine/common', {'basic': '1'});
      final serial = '${_map(machine['common'])['serial'] ?? ''}';
      if (serial.isEmpty ||
          ('${p['sn'] ?? ''}'.isNotEmpty && p['sn'] != serial)) {
        _fail('扫码授权的 NAS 与当前地址不一致。');
      }
      if (attempt != null && attempt != _qrGeneration) _fail('扫码登录已取消。');
      _username = username;
      _name = '${p['nas_name'] ?? '我的 NAS'}';
      _namespace = _digest('$serial|$username');
      _capture({});
      if (save) {
        await _secure.invokeMethod<void>('write', {
          'value': jsonEncode({
            'qr': true,
            'address': _base,
            'token': _token,
            'public_key': _key,
            'static_token': _staticToken,
            'auth_type': _auth,
            'is_ugk': _ugk,
            'username': username,
            'uid': uid,
            'sn': serial,
            'nas_name': _name,
          }),
        });
      }
      if (attempt != null && attempt != _qrGeneration) {
        if (save) await _secure.invokeMethod<void>('delete');
        _fail('扫码登录已取消。');
      }
      return _current();
    } catch (_) {
      await _logout();
      rethrow;
    }
  }

  Future<void> _ensure(String expected) async {
    if (_namespace.isEmpty) await _restore();
    if (expected.isEmpty || expected != _namespace) _fail();
  }

  Future<Map<String, dynamic>> _api(
    String route, [
    Map<String, String> params = const {},
    String? at,
  ]) async {
    if (_token.isEmpty) _fail('请先登录 NAS。');
    final key = _hex(16),
        p = {...params},
        h = {
          ..._headers,
          'X-Ugreen-Security-Key': md5.convert(utf8.encode(_token)).toString(),
          'X-Ugreen-Security-Code': await _crypto('rsa', key, _key),
        };
    if (_auth == 'header') {
      h['X-Ugreen-Token'] = await _crypto('rsa', _token, _key);
    } else {
      p['token'] = _token;
    }
    final names = p.keys.toList()..sort();
    final query = names
        .map((k) => '${Uri.encodeComponent(k)}=${Uri.encodeComponent(p[k]!)}')
        .join('&');
    final url = Uri.parse('${at ?? _base}/ugreen/$route').replace(
      queryParameters: {'encrypt_query': await _crypto('seal', query, key)},
    );
    var r = _decode((await _request(url, headers: h)).bytes);
    if (r['encrypt_resp_body'] is String) {
      r = _map(jsonDecode(await _crypto('open', r['encrypt_resp_body'], key)));
    }
    _check(r);
    return _map(r['data']);
  }

  Future<({Uri url, Map<String, String> headers})> _authorized(
    String route, [
    Map<String, String> params = const {},
  ]) async {
    if (_token.isEmpty) _fail('请先登录 NAS。');
    final p = {...params},
        h = {
          ..._headers,
          'X-Ugreen-Security-Key': md5.convert(utf8.encode(_token)).toString(),
        };
    if (_auth == 'header') {
      h['X-Ugreen-Token'] = await _crypto('rsa', _token, _key);
    } else {
      p['token'] = _token;
    }
    return (
      url: Uri.parse('$_base/ugreen/$route').replace(queryParameters: p),
      headers: h,
    );
  }

  Future<Map<String, dynamic>> _file(
    String route, {
    String method = 'GET',
    Map<String, String> params = const {},
    dynamic body,
  }) async {
    final auth = await _authorized(route, params);
    final r = _decode(
      (await _request(
        auth.url,
        headers: auth.headers,
        method: method,
        body: body,
      )).bytes,
    );
    _check(r);
    return r;
  }

  void _capture(Map<String, dynamic> d) {
    final hosts = <String>[
      for (final k in ['ipv_4', 'ipv4'])
        if (d[k] is List) ...List<String>.from(d[k]),
      for (final r in _rows(d['network_info'])) '${r['ip']}',
      if (d['ip'] is String) d['ip'],
    ];
    for (final host in hosts.where(privateIPv4)) {
      for (final scheme in ['https', 'http']) {
        final port = _int(d['${scheme}_port']);
        if (port > 0 && port <= 65535) _lan.add('$scheme://$host:$port');
      }
    }
    final u = Uri.parse(_base);
    if (privateIPv4(u.host)) {
      _lan.add(_base);
    } else if (u.scheme == 'https' && u.host.endsWith('.ug.link')) {
      _remote = _base;
    }
  }

  Future<Map<String, dynamic>> _connections({bool refresh = false}) async {
    if (!_discovered || refresh) {
      try {
        final d = _map((await _file('v1/user/priority_link'))['data']);
        _capture(d);
        _discovered = true;
        final advertised = '${d['uglink_domain'] ?? ''}';
        if (advertised.isNotEmpty && _remote.isEmpty) {
          final u = Uri.parse(
            advertised.contains('://') ? advertised : 'https://$advertised',
          );
          if (u.host == 'ug.link' && u.pathSegments.length == 1) {
            _remote = await _resolve(u.pathSegments.first);
          } else if (u.scheme == 'https' && u.host.endsWith('.ug.link')) {
            _remote = _origin(u.toString()).toString();
          }
        }
      } catch (_) {
        /* Manual address remains usable on older firmware. */
      }
    }
    return {
      'namespace': _namespace,
      'currentAddress': _base,
      'remoteAddress': _remote,
      'lanCandidates': _lan.toList(),
      'mode': privateIPv4(Uri.parse(_base).host) ? 'local' : 'remote',
    };
  }

  Future<String?> _probe(String target, String hint) async {
    try {
      final u = _origin(target);
      if (!privateIPv4(u.host) &&
          !(u.scheme == 'https' && u.host.endsWith('.ug.link'))) {
        return null;
      }
      final r = _decode(
        (await _request(
          u.replace(path: '/ugreen/v1/verify/sn'),
          limit: 65536,
          timeout: Duration(milliseconds: privateIPv4(u.host) ? 1200 : 3000),
        )).bytes,
      );
      return r['code'] == 200 && _map(r['data'])['sn'] == hint ? target : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _auto({bool force = false}) async {
    final before = _base;
    if (_namespace.isEmpty) _fail('请先登录 NAS。');
    if (!force && DateTime.now().difference(_lastProbe).inSeconds < 15) {
      return {
        'namespace': _namespace,
        'changed': false,
        'currentAddress': _base,
      };
    }
    _lastProbe = DateTime.now();
    await _connections();
    if (_hint.isEmpty) {
      final r = _decode(
        (await _request(
          Uri.parse('$_base/ugreen/v1/verify/sn'),
          limit: 65536,
        )).bytes,
      );
      _check(r);
      _hint = '${_map(r['data'])['sn'] ?? ''}';
    }
    if (_hint.isEmpty) _fail();
    String? selected;
    for (final group in [
      _lan.take(12).toList(),
      if (_remote.isNotEmpty) [_remote],
    ]) {
      final results = await Future.wait(group.map((u) => _probe(u, _hint)));
      selected = results.whereType<String>().firstOrNull;
      if (selected != null) break;
    }
    if (selected != null && selected != _base) {
      final user = await _api('v1/user/current/user', {}, selected),
          machine = await _api('v1/sysinfo/machine/common', {
            'basic': '1',
          }, selected);
      if (_digest('${_map(machine['common'])['serial']}|${user['username']}') !=
          _namespace) {
        _fail();
      }
      _base = selected;
    }
    final saved = await _saved();
    if (saved.isNotEmpty) {
      await _secure.invokeMethod<void>('write', {
        'value': jsonEncode({
          ...saved,
          'routes': {
            'namespace': _namespace,
            'hint': _hint,
            'lan': _lan.toList(),
            'remote': [_remote].where((v) => v.isNotEmpty).toList(),
          },
        }),
      });
    }
    return {
      'namespace': _namespace,
      'changed': before != _base,
      'currentAddress': _base,
    };
  }

  Future<List<Map<String, dynamic>>> _list(String path) async {
    final rows = <Map<String, dynamic>>[];
    for (var page = 1; page <= 100; page++) {
      final r = await _file(
        'v1/filemgr/getDirFileList',
        method: 'POST',
        body: {
          'path': '$path/',
          'isOnlyFolder': false,
          'as_dir': false,
          'limit': 200,
          'page': page,
          'reverse': false,
          'sort_type': 1,
        },
      );
      final value = _map(r['data'])['files'];
      if (value is! List) _fail();
      final files = _rows(value);
      rows.addAll(files);
      if (files.length < 200) return rows;
    }
    _fail('NAS 同步目录过大。');
  }

  Future<String> _directory() async {
    var path =
        '${_map((await _file('v1/filemgr/getHomeShare'))['data'])['path'] ?? ''}';
    if (!path.startsWith('/') || path.split('/').contains('..')) _fail();
    for (final name in ['NakuPlayer', 'sync-v1', _namespace]) {
      final files = await _list(path);
      final next = '$path/$name';
      if (!files.any((r) => r['name'] == name)) {
        await _file(
          'v2/filemgr/createFolder',
          method: 'POST',
          body: {'path': next, 'no_recursive_creation': true},
        );
      }
      path = next;
    }
    return path;
  }

  Future<List<int>> _read(String path) async => (await _request(
    Uri.parse('$_base/ugreen/v1/filemgr/downloadFile').replace(
      queryParameters: {'paths': path, 'token': _token, 'coding': 'true'},
    ),
    headers: {'Range': 'bytes=0-8388607'},
  )).bytes;
  Future<void> _upload(String directory, String name, List<int> bytes) async {
    if (!RegExp(r'^[a-zA-Z0-9-]+\.json$').hasMatch(name) ||
        bytes.length > 8388608) {
      _fail();
    }
    final boundary = 'Naku${_hex(16)}',
        uuid = _hex(16),
        auth = await _authorized('v1/filemgr/fileUpload');
    for (final first in [true, false]) {
      final content = first ? <int>[] : bytes, body = <int>[];
      final fields = {
        'uuid': uuid,
        'dir': directory,
        'action_type': '0',
        'size': '${bytes.length}',
        'begin_size': '0',
        'current_size': '${content.length}',
        'change_time': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        'filename': name,
        'resume': 'true',
        'first_request': '$first',
      };
      for (final e in fields.entries) {
        body.addAll(
          utf8.encode(
            '--$boundary\r\nContent-Disposition: form-data; name="${e.key}"\r\n\r\n${e.value}\r\n',
          ),
        );
      }
      body.addAll(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$name"\r\nContent-Type: application/octet-stream\r\n\r\n',
        ),
      );
      body.addAll(content);
      body.addAll(utf8.encode('\r\n--$boundary--\r\n'));
      _check(
        _decode(
          (await _request(
            auth.url,
            method: 'POST',
            headers: {
              ...auth.headers,
              'Content-Type': 'multipart/form-data; boundary=$boundary',
            },
            body: body,
          )).bytes,
        ),
      );
    }
    if (base64Encode(await _read('$directory/$name')) != base64Encode(bytes)) {
      _fail('NAS 写入后的校验失败，请重试。');
    }
  }

  Future<Map<String, dynamic>> _pull(String expected) async {
    await _ensure(expected);
    final dir = await _directory(),
        files = await _list(dir),
        latest = <String, String>{};
    for (final row in files) {
      final name = '${row['name']}';
      if (!RegExp(r'^[a-f0-9-]{36}-[0-9]{12}\.json$').hasMatch(name)) continue;
      final device = name.substring(0, 36);
      if (name.compareTo(latest[device] ?? '') > 0) latest[device] = name;
    }
    if (latest.length > 100) _fail();
    final docs = <String>[];
    for (final name in latest.values) {
      docs.add(utf8.decode(await _read('$dir/$name')));
    }
    return {'documents': docs, 'path': dir};
  }

  Future<Map<String, dynamic>> _push(Map<String, dynamic> a) async {
    await _ensure('${a['namespace']}');
    final device = '${a['device']}', sequence = _int(a['sequence']);
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(device) ||
        sequence <= 0 ||
        sequence >= 1000000000000) {
      _fail();
    }
    final dir = await _directory(),
        name = '$device-${'$sequence'.padLeft(12, '0')}.json',
        bytes = utf8.encode('${a['document']}');
    if ((await _list(dir)).any((r) => r['name'] == name)) {
      if (base64Encode(await _read('$dir/$name')) != base64Encode(bytes)) {
        _fail();
      }
    } else {
      await _upload(dir, name, bytes);
    }
    return {'path': '$dir/$name'};
  }

  Map<String, dynamic> _playParams(String task) => {
    'task_id': task,
    'timestamp': '${DateTime.now().millisecondsSinceEpoch}',
    'src_type': 2,
  };
  Map<String, String> _playQuery(String task) =>
      _playParams(task).map((k, v) => MapEntry(k, '$v'));
  Uri _playURL(String route, [Map<String, String> params = const {}]) =>
      Uri.parse(
        '$_base/ugreen/$route',
      ).replace(queryParameters: {...params, 'token': _token});
  Future<void> _close() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _socket?.close();
    _socket = null;
    final url = _closeURL, body = _closeBody, headers = _closeHeaders;
    _task = '';
    _closeURL = null;
    _closeBody = null;
    _closeHeaders = null;
    if (url != null) {
      try {
        await _request(url, method: 'POST', body: body, headers: headers ?? {});
      } catch (_) {}
    }
  }

  List<Map<String, dynamic>> _tracks(
    dynamic input, {
    bool subtitles = false,
  }) => [
    if (subtitles)
      {
        'id': -1,
        'label': '关闭字幕',
        'language': '',
        'isDefault': false,
        'isText': true,
      },
    for (final row in _rows(input).take(256))
      if (_int(row['id']) >= 0)
        {
          'id': _int(row['id']),
          'label': row['title'] ?? row['language'] ?? '轨道 ${row['id']}',
          'language': row['raw_language'] ?? '',
          'isDefault': row['isDefault'] == true || row['isDefault'] == 1,
          'isText': !subtitles || row['is_text'] == true || row['is_text'] == 1,
        },
  ];
  Future<Map<String, dynamic>> _play(
    Map<String, dynamic> a, {
    required bool start,
  }) async {
    await _ensure('${a['namespace']}');
    final path = '${a['path']}';
    if (_int(a['id']) <= 0 ||
        _int(a['library']) <= 0 ||
        !path.startsWith('/') ||
        path.split('/').contains('..') ||
        path.contains('\x00')) {
      _fail();
    }
    final task = _hex(16),
        closeURL = _playURL('v2/stream/transcode/web/close'),
        closeBody = _playParams(task),
        closeHeaders = _headers;
    var adopted = false;
    try {
      final info = _map(
        (await _file(
          'v2/stream/transcode/web/info',
          method: 'POST',
          body: {
            ..._playParams(task),
            'video_path': path,
            'is_net_disk_direct': false,
          },
        ))['data'],
      );
      final profiles = [
        for (final r in _rows(info['transcodeable']))
          {
            'id': r['resolution'],
            'label': r['name'],
            'isOriginal': r['name'] == _map(info['resolution'])['name'],
          },
      ];
      if (profiles.isEmpty ||
          profiles.length > 32 ||
          profiles.any(
            (r) => !RegExp(r'^[0-9]{1,5}x[0-9]{1,5}$').hasMatch('${r['id']}'),
          )) {
        _fail();
      }
      final audios = _tracks(info['audios']),
          subtitles = _tracks(info['subtitles'], subtitles: true);
      if (!start) {
        return {
          'profiles': profiles,
          'audios': audios,
          'subtitles': subtitles,
          'durationMs': _int(info['duration']),
          'width': _int(info['width']),
          'height': _int(info['height']),
          'originHost': Uri.parse(_base).host,
          'isRelayOrigin': Uri.parse(_base).host.endsWith('.ug.link'),
        };
      }
      final resolution = a['resolution'] ?? profiles.last['id'],
          audio =
              a['audio'] ??
              audios.where((r) => r['isDefault'] == true).firstOrNull?['id'] ??
              audios.firstOrNull?['id'] ??
              -1,
          subtitle = a['subtitle'] ?? -1;
      if (!profiles.any((r) => r['id'] == resolution) ||
          a['audio'] != null && !audios.any((r) => r['id'] == audio) ||
          !subtitles.any((r) => r['id'] == subtitle)) {
        _fail();
      }
      final name =
          Uri.parse('${info['redir_link']}').queryParameters['video_name'] ??
          '';
      if (name.isEmpty ||
          name.length >= 1024 ||
          name.contains('/') ||
          name.contains('\\') ||
          name.contains('..')) {
        _fail();
      }
      final file = '${name}_$resolution.m3u8',
          query = {..._playQuery(task), 'm3u8_file': file};
      final response = await _file(
        'v2/stream/transcode/web/play',
        params: {
          ...query,
          'regen': '1',
          'subtitle_index': '$subtitle',
          'audio_index': '$audio',
          'prefer_h265': 'false',
        },
      );
      final media = _playURL('v2/stream/transcode/web/m3u8', query),
          socketURI = _playURL('v2/stream/transcode/ws');
      final socket = await WebSocket.connect(
        socketURI
            .replace(scheme: socketURI.scheme == 'https' ? 'wss' : 'ws')
            .toString(),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      socket.listen((_) {}, onError: (_) {}, onDone: () {});
      await _close();
      _socket = socket;
      _task = task;
      _closeURL = closeURL;
      _closeBody = closeBody;
      _closeHeaders = closeHeaders;
      adopted = true;
      void ping() {
        try {
          socket.add(
            jsonEncode({
              'cmd': 'ping',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'task_id': task,
              'data': {},
            }),
          );
        } catch (_) {}
      }

      ping();
      _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) => ping());
      return {
        'url': media.toString(),
        'headers': <String, String>{},
        'taskId': task,
        'resolution': resolution,
        'audio': audio,
        'subtitle': subtitle,
        'bitrateBps': _map(response['data'])['bitrate_bps'] ?? 0,
        'source': 'nas-hls',
      };
    } finally {
      if (!adopted) {
        try {
          await _request(
            closeURL,
            method: 'POST',
            body: closeBody,
            headers: closeHeaders,
          );
        } catch (_) {}
      }
    }
  }

  Future<dynamic> _handle(String method, Map<String, dynamic> a) async {
    if ([
          'libraries',
          'catalog',
          'details',
          'collection',
          'playbackOptions',
          'syncPull',
          'syncPush',
          'asset',
        ].contains(method) &&
        _namespace.isNotEmpty) {
      try {
        await _auto();
      } catch (_) {}
    }
    switch (method) {
      case 'qrCreate':
        return _createQR('${a['address'] ?? ''}');
      case 'qrPoll':
        return _pollQR();
      case 'qrCancel':
        await _clearQR();
        return null;
      case 'login':
        return _login(a);
      case 'currentSession':
        return _current();
      case 'savedLogin':
        final s = await _saved();
        return s.isEmpty
            ? {}
            : {'address': s['address'], 'username': s['username']};
      case 'restore':
        return _namespace.isNotEmpty ? _current() : await _restore();
      case 'logout':
        await _logout();
        return null;
      case 'forget':
        await _logout();
        await _secure.invokeMethod<void>('delete');
        return null;
      case 'ensure':
        await _ensure('${a['namespace']}');
        return _current();
      case 'connectionInfo':
        if (a['namespace'] != null && a['namespace'] != _namespace) _fail();
        return _connections(refresh: a['refresh'] == true);
      case 'autoConnect':
        await _ensure('${a['namespace']}');
        return _auto(force: a['force'] == true);
      case 'restoreAt':
        await _ensure('${a['namespace']}');
        final target = await _resolve('${a['address']}');
        if (_hint.isEmpty) await _auto(force: true);
        if (await _probe(target, _hint) == null) _fail();
        final user = await _api('v1/user/current/user', {}, target),
            machine = await _api('v1/sysinfo/machine/common', {
              'basic': '1',
            }, target);
        if (_digest(
              '${_map(machine['common'])['serial']}|${user['username']}',
            ) !=
            _namespace) {
          _fail();
        }
        _base = target;
        return _current();
      case 'libraries':
        return _api('v1/video/media_lib/get_all', {
          'mediaLib_get_all_req_type': '1',
          'language': 'zh-CN',
        });
      case 'catalog':
        final page = max(1, _int(a['page'])),
            lib = _int(a['library']),
            keyword = '${a['keyword'] ?? ''}';
        if (keyword.isNotEmpty) {
          final r = await _api('v1/video/search', {
            'search_type': '1',
            'offset': '${(page - 1) * 40}',
            'limit': '40',
            'keyword': keyword,
            'language': 'zh-CN',
          });
          final groups = [_map(r['movies_list']), _map(r['tv_list'])];
          return {
            'video_arr': groups.expand((g) => _rows(g['video_arr'])).toList(),
            'total_num': groups.fold<int>(
              0,
              (n, g) => n + _int(g['total_num']),
            ),
            'is_last_page': groups.every((g) => g['is_last_page'] != false),
          };
        }
        return _api(
          lib > 0 ? 'v2/video/mediaLibSet/poster-wall' : 'v1/video/all',
          {
            'media_lib_set_id': '$lib',
            'page': '$page',
            'page_size': '40',
            'language': 'zh-CN',
            'classification': '${lib > 0 ? lib : -101}',
            'sort_type': '2',
            'order_type': '2',
            'release_date_begin': '-9999999999',
            'release_date_end': '-9999999999',
            'identify_status': '0',
            'watch_status': '-1',
            'ug_style_id': '0',
            'ug_country_id': '0',
            'clarity': '-1',
          },
        );
      case 'details':
        if (_int(a['id']) <= 0 || _int(a['library']) <= 0) _fail();
        return _api(
          a['tv'] == true
              ? 'v2/video/details/getTV'
              : 'v1/video/details/getMovie',
          a['tv'] == true
              ? {'ug_video_info_id': '${a['id']}'}
              : {
                  'id': '${a['id']}',
                  'media_lib_set_id': '${a['library']}',
                  'fileVersion': 'true',
                },
        );
      case 'collection':
        final rows = <Map<String, dynamic>>[];
        String? previous;
        for (var page = 1; page <= 500; page++) {
          final r = await _api('v1/video/collection/getCollectionContent', {
            'collection_id': '${a['id']}',
            'media_lib_set_id': '${a['library']}',
            'sort_type': '0',
            'order_type': '2',
            'page': '$page',
            'page_size': '200',
          });
          final raw = _rows(r['video_arr']), fingerprint = jsonEncode(raw);
          if (previous == fingerprint) _fail();
          previous = fingerprint;
          rows.addAll(raw.map((r) => _map(r['video_info'])));
          if (raw.isEmpty ||
              r['is_last_page'] == true ||
              r['total_num'] != null && rows.length >= _int(r['total_num']) ||
              r['total_num'] == null && raw.length < 200) {
            return {'video_arr': rows, 'total_num': rows.length};
          }
        }
        _fail();
      case 'asset':
        if (_token.isEmpty) _fail();
        final poster = a['poster'] == true;
        return Uri.parse(
              '$_base/ugreen/${poster ? 'v2/video/getImaStream' : 'v1/video/details/downloadOriginalFile'}',
            )
            .replace(
              queryParameters: {
                if (poster) ...{
                  'app_name': 'web',
                  'name': '${a['path']}',
                  'size': '1',
                  'id': '${a['id']}',
                } else ...{
                  'paths': '${a['path']}',
                  'id': '${a['id']}',
                  'media_lib_set_id': '${a['library']}',
                },
                poster && _ugk ? 'ugk' : 'token': poster && _ugk
                    ? _staticToken
                    : _token,
              },
            )
            .toString();
      case 'pairingIdentity':
        if (_namespace.isEmpty) await _restore();
        final current = await _api('v1/user/current/user');
        if (current['username'] != _username) _fail();
        const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        var code = '${a['code'] ?? ''}'.toUpperCase().replaceAll(
          RegExp(r'[\s-]'),
          '',
        );
        if (code.isEmpty) {
          code = List.generate(
            10,
            (_) => alphabet[_random.nextInt(alphabet.length)],
          ).join();
        }
        if (code.length != 10 ||
            code.split('').any((c) => !alphabet.contains(c))) {
          _fail();
        }
        return {
          'namespace': _namespace,
          'account': _username,
          'pairingCode': code,
          'room': 'NP-$code',
          'username': 'N-${_namespace.substring(0, 8)}-${_hex(2)}',
        };
      case 'castPublish':
        await _ensure('${a['namespace']}');
        final id = '${a['id']}', secret = '${a['secret']}';
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(secret)) {
          _fail();
        }
        final dir = await _directory();
        await _upload(
          dir,
          'cast-$id.json',
          utf8.encode(
            jsonEncode({
              'secret': secret,
              'namespace': _namespace,
              'expires': DateTime.now()
                  .add(const Duration(hours: 12))
                  .millisecondsSinceEpoch,
            }),
          ),
        );
        return {};
      case 'castSecret':
        await _ensure('${a['namespace']}');
        final id = '${a['id']}';
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) _fail();
        final dir = await _directory(),
            r = _decode(await _read('$dir/cast-$id.json'));
        if (r['namespace'] != _namespace ||
            _int(r['expires']) < DateTime.now().millisecondsSinceEpoch ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch('${r['secret']}')) {
          _fail();
        }
        return r;
      case 'syncPull':
        return _pull('${a['namespace']}');
      case 'syncPush':
        return _push(a);
      case 'playbackOptions':
        return _play(a, start: false);
      case 'startPlayback':
        return _play(a, start: true);
      case 'closePlayback':
        if (a['taskId'] == _task &&
            (a['namespace'] == null || a['namespace'] == _namespace)) {
          await _close();
        }
        return {};
      default:
        throw PlatformException(code: 'unsupported', message: '此平台暂不支持该操作。');
    }
  }
}
