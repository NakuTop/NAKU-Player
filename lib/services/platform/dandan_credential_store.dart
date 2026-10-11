import 'package:flutter/services.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

/// Credentials stay in the macOS Keychain, outside Hive, WebDAV and exports.
class DandanCredentialStore {
  static const channel = MethodChannel('naku/danmaku-credentials');
  static final instance = DandanCredentialStore();

  Future<DandanCredentials> read() async {
    try {
      final value = await channel.invokeMapMethod<String, String>('read');
      if (value != null) {
        final credentials = DandanCredentials(
          id: value['id'] ?? '',
          secret: value['secret'] ?? '',
        );
        if (credentials.isConfigured) return credentials;
      }
    } on MissingPluginException {
      // Other platforms may still provide the publisher's build credentials.
    }
    return dandanCredentials;
  }

  Future<void> save(DandanCredentials value) async {
    if (!value.isConfigured ||
        value.id.length > 256 ||
        value.secret.length > 1024 ||
        RegExp(r'[\r\n]').hasMatch(value.id + value.secret)) {
      throw const FormatException('请填写有效的 AppId 和 AppSecret');
    }
    await channel.invokeMethod<void>('save', {
      'id': value.id.trim(),
      'secret': value.secret.trim(),
    });
  }

  Future<void> clear() => channel.invokeMethod<void>('clear');
}
