import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A separate device-local Keychain item. Never carries official AppSecret.
class LogvarConfiguration {
  LogvarConfiguration({required String baseUrl, required this.token})
    : baseUrl = _validateAddress(baseUrl) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(token)) {
      throw const FormatException('请输入 8–256 位的服务访问令牌');
    }
  }

  final Uri baseUrl;
  final String token;

  static Uri _validateAddress(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        value.length > 1024 ||
        uri.path.contains('..') ||
        RegExp(r'[\r\n]').hasMatch(value)) {
      throw const FormatException('请填写有效的服务地址，访问令牌单独填写');
    }
    if (uri.scheme == 'http' && !isPrivateHost(uri.host)) {
      throw const FormatException('远程服务请使用 HTTPS，局域网可使用 HTTP');
    }
    return uri.replace(path: uri.path.replaceAll(RegExp(r'/+$'), ''));
  }

  static bool isPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.local') || h == '::1') return true;
    final parts = h.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((n) => n == null || n < 0 || n > 255)) {
      return h.startsWith('fd') && h.contains(':');
    }
    return parts[0] == 10 ||
        parts[0] == 127 ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31);
  }

  Uri endpoint(String path, [Map<String, dynamic>? query]) => baseUrl.replace(
    path: '${baseUrl.path}/$token/api/v2/$path',
    queryParameters: query?.map((key, value) => MapEntry(key, '$value')),
  );

  @override
  String toString() =>
      'LogvarConfiguration(${baseUrl.origin}, token: [hidden])';
}

class LogvarCredentialStore {
  LogvarCredentialStore({this.provisioningFile});
  static const channel = MethodChannel('naku/logvar-credentials');
  static final instance = LogvarCredentialStore();
  final Future<File?> Function()? provisioningFile;
  Future<LogvarConfiguration?>? _reading;
  int _revision = 0;

  Future<File?> _pendingFile() async {
    if (provisioningFile != null) return provisioningFile!();
    try {
      final directory = await getApplicationSupportDirectory().timeout(
        const Duration(seconds: 2),
      );
      return File('${directory.path}/cinema/logvar-provision-v1.json');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _removePending() async {
    final file = await _pendingFile();
    if (file != null && await file.exists()) await file.delete();
  }

  Future<LogvarConfiguration?> _nativeRead() async {
    final value = await channel.invokeMapMethod<String, String>('read');
    if (value == null) return null;
    return LogvarConfiguration(
      baseUrl: value['id'] ?? '',
      token: value['secret'] ?? '',
    );
  }

  Future<LogvarConfiguration?> read() {
    if (_reading != null) return _reading!;
    late Future<LogvarConfiguration?> pending;
    pending = _read(_revision).whenComplete(() {
      if (identical(_reading, pending)) _reading = null;
    });
    return _reading = pending;
  }

  Future<LogvarConfiguration?> _read(int revision) async {
    try {
      PlatformException? inaccessible;
      try {
        final existing = await _nativeRead();
        if (existing != null) {
          if (revision == _revision) await _removePending();
          return existing;
        }
      } on PlatformException catch (error) {
        inaccessible = error;
      }
      // A locally provisioned one-use file lets a newly signed personal build
      // create its own Keychain item. The token is never included in the app.
      // A valid existing/manual configuration remains authoritative.
      final file = await _pendingFile();
      if (file != null && await file.exists()) {
        if (await file.length() > 8192) {
          throw const FormatException('NAS预配置文件过大');
        }
        final json = jsonDecode(await file.readAsString());
        if (json is! Map || json['version'] != 1) {
          throw const FormatException('NAS预配置文件无效');
        }
        final config = LogvarConfiguration(
          baseUrl: json['baseUrl'] is String ? json['baseUrl'] : '',
          token: json['token'] is String ? json['token'] : '',
        );
        if (revision != _revision) return null;
        if (inaccessible != null) {
          await channel
              .invokeMethod<void>('clear', {'nonInteractive': 'true'})
              .timeout(const Duration(seconds: 5));
        }
        if (revision != _revision) return null;
        await channel
            .invokeMethod<void>('save', {
              'id': config.baseUrl.toString(),
              'secret': config.token,
              'nonInteractive': 'true',
            })
            .timeout(const Duration(seconds: 5));
        final saved = await _nativeRead();
        if (saved?.baseUrl != config.baseUrl || saved?.token != config.token) {
          throw const FormatException('NAS预配置尚未保存成功，请重试');
        }
        if (revision == _revision && await file.exists()) await file.delete();
        return saved;
      }
      if (inaccessible != null) throw inaccessible;
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      throw const FormatException('无法读取 NAS 服务令牌，请在配置服务中移除旧配置后重新保存');
    }
  }

  Future<void> save(LogvarConfiguration value) async {
    _revision++;
    _reading = null;
    await channel.invokeMethod<void>('save', {
      'id': value.baseUrl.toString(),
      'secret': value.token,
    });
    await _removePending();
  }

  Future<void> clear() async {
    _revision++;
    _reading = null;
    await channel.invokeMethod<void>('clear');
    await _removePending();
  }
}
