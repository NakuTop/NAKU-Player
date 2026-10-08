import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';

/// Read-only snapshot of the user's macOS HTTP proxies. TLS validation stays on.
/// Refresh on launch/resume; no shell environment or fixed local port is needed.
abstract final class MacOSSystemProxy {
  static const _channel = MethodChannel('yingchuan/network');
  static Map<String, dynamic> _settings = {};

  static Future<void> initialize() async {
    if (!Platform.isMacOS) return;
    try {
      final value = await _channel
          .invokeMapMethod<String, dynamic>('systemProxy')
          .timeout(const Duration(seconds: 3));
      setConfiguration(value ?? {});
    } on MissingPluginException {
      // Unit-test runners do not own the application's native channel.
    } on PlatformException {
      _settings = {};
    } on TimeoutException {
      _settings = {};
    }
  }

  static void setConfiguration(Map<String, dynamic> value) {
    _settings = Map.of(value);
  }

  static bool _enabled(Object? value) => value == 1 || value == true;

  static Uri? proxyFor(Uri url) {
    if (!['http', 'https'].contains(url.scheme) || _bypasses(url.host)) {
      return null;
    }
    final prefix = url.scheme == 'https' ? 'HTTPS' : 'HTTP';
    if (!_enabled(_settings['${prefix}Enable'])) return null;
    final host = _settings['${prefix}Proxy']?.toString() ?? '';
    final port = int.tryParse(_settings['${prefix}Port']?.toString() ?? '');
    if (host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        RegExp(r'[\s/@]').hasMatch(host)) {
      return null;
    }
    return Uri(scheme: 'http', host: host, port: port);
  }

  static String findProxy(Uri url) {
    final proxy = proxyFor(url);
    return proxy == null ? 'DIRECT' : 'PROXY ${proxy.authority}';
  }

  static String get description {
    if (_enabled(_settings['HTTPEnable']) ||
        _enabled(_settings['HTTPSEnable'])) {
      return '跟随 macOS 系统代理 · 保留证书校验';
    }
    if (_enabled(_settings['ProxyAutoConfigEnable'])) {
      return '系统使用 PAC；本版请在系统中配置 HTTP/HTTPS 代理';
    }
    return '直接连接 · 跟随 macOS 系统 HTTP/HTTPS 代理设置';
  }

  static bool _bypasses(String hostname) {
    final host = hostname.toLowerCase();
    if (host == 'localhost' || host == '::1' || host.startsWith('127.')) {
      return true;
    }
    if (_enabled(_settings['ExcludeSimpleHostnames']) && !host.contains('.')) {
      return true;
    }
    final exceptions = _settings['ExceptionsList'];
    if (exceptions is! List) return false;
    for (final value in exceptions) {
      final pattern = value.toString().toLowerCase();
      if (pattern == '<local>' && !host.contains('.')) return true;
      if (pattern.contains('/')) {
        final parts = pattern.split('/');
        final address = InternetAddress.tryParse(host);
        final network = InternetAddress.tryParse(parts.first);
        final bits = parts.length == 2 ? int.tryParse(parts.last) : null;
        if (address == null ||
            network == null ||
            bits == null ||
            address.rawAddress.length != network.rawAddress.length ||
            bits < 0 ||
            bits > address.rawAddress.length * 8) {
          continue;
        }
        var matches = true;
        for (var i = 0; i < address.rawAddress.length; i++) {
          final remaining = (bits - i * 8).clamp(0, 8);
          final mask = remaining == 0 ? 0 : (255 << (8 - remaining)) & 255;
          if ((address.rawAddress[i] & mask) !=
              (network.rawAddress[i] & mask)) {
            matches = false;
            break;
          }
        }
        if (matches) return true;
      } else if (RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
      ).hasMatch(host)) {
        return true;
      }
    }
    return false;
  }
}
