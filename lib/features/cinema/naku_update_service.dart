import 'package:flutter/services.dart';

/// Sparkle owns update preferences and only accepts our signed release feed.
abstract final class NakuUpdateService {
  static const repositoryUrl = 'https://github.com/NakuTop/NAKU-Player';
  static const _channel = MethodChannel('naku/updater');

  static Future<Map<String, dynamic>> state() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('state') ?? {},
      );
  static Future<void> check() => _channel.invokeMethod<void>('check');
  static Future<void> configure({
    bool? automaticChecks,
    bool? automaticDownloads,
  }) => _channel.invokeMethod<void>('configure', {
    'automaticChecks': ?automaticChecks,
    'automaticDownloads': ?automaticDownloads,
  });
}
