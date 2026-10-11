import 'dart:io';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

/// Holds only idle system sleep while a queue has actual work. Display sleep,
/// explicit system sleep, lid close and the user's global settings stay intact.
class DownloadSleepGuard {
  DownloadSleepGuard({Future<void> Function(bool)? apply, bool? supported})
    : _apply = apply ?? _native,
      _supported = supported ?? Platform.isMacOS;

  static final instance = DownloadSleepGuard();
  static const _channel = MethodChannel('naku/download-power');
  static Future<void> _native(bool active) =>
      _channel.invokeMethod<void>('setActive', active);

  final Future<void> Function(bool) _apply;
  bool _supported;
  bool _hasWork = false, _enabled = true, _active = false;
  final _queue = AsyncSerialQueue();

  bool get active => _active;

  Future<void> update({bool? hasWork, bool? enabled}) {
    if (hasWork != null) _hasWork = hasWork;
    if (enabled != null) _enabled = enabled;
    return _queue.run(_sync);
  }

  Future<void> _sync() async {
    while (_supported && _active != (_hasWork && _enabled)) {
      final next = _hasWork && _enabled;
      try {
        await _apply(next);
        _active = next;
      } on MissingPluginException {
        _supported = false;
      } catch (error) {
        KazumiLogger().w('下载防休眠设置未生效', error: error);
        return;
      }
    }
  }
}
