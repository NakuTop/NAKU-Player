import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Background density only: foreground content never gets a window-wide alpha.
/// The saved preference is retained while macOS Reduce Transparency is enabled.
class CinemaAppearance extends ChangeNotifier {
  CinemaAppearance({
    File? settingsFile,
    MethodChannel? nativeChannel,
    bool? observeNativeAccessibility,
    this.saveDelay = const Duration(milliseconds: 220),
  }) : _file = settingsFile,
       _channel = nativeChannel ?? const MethodChannel('naku/appearance'),
       _observeNative =
           observeNativeAccessibility ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  static final instance = CinemaAppearance();
  static const defaultBackgroundOpacity = 120 / 255;
  static const minimumBackgroundOpacity = .22;
  final Duration saveDelay;
  final MethodChannel _channel;
  final bool _observeNative;
  File? _file;
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  Timer? _saveTimer;
  int _revision = 0, _nativeRevision = 0, _savedRevision = 0;
  bool _disposed = false, _nativeAttached = false;
  double _backgroundOpacity = defaultBackgroundOpacity;
  bool _reduceTransparency = false, _reduceMotion = false;
  String? _error;

  double get backgroundOpacity => _backgroundOpacity;
  double get effectiveBackgroundOpacity =>
      _reduceTransparency ? 1 : _backgroundOpacity;
  bool get reduceTransparency => _reduceTransparency;
  bool get reduceMotion => _reduceMotion;
  String? get error => _error;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    final revision = _revision;
    // Both reads are independent: a settings-disk failure must not suppress the
    // system accessibility override, nor may a missing native bridge stop playback.
    await Future.wait([_readPreferences(revision), _readAccessibility()]);
  }

  Future<void> _readPreferences(int revision) async {
    try {
      final file = _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/appearance-v1.json',
      );
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['backgroundOpacity'] is! num) {
        throw const FormatException('外观设置格式无效');
      }
      final value = (raw['backgroundOpacity'] as num).toDouble();
      if (!value.isFinite || value < minimumBackgroundOpacity || value > 1) {
        throw const FormatException('透明度设置无效');
      }
      if (_disposed || revision != _revision || _revision > 0) return;
      _backgroundOpacity = value;
      _notify();
    } catch (_) {
      if (_disposed || revision != _revision || _revision > 0) return;
      _error = '暂时无法读取外观设置，正在使用默认外观。';
      _notify();
    }
  }

  Future<void> _readAccessibility() async {
    if (!_observeNative || _disposed) return;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'accessibilityChanged') {
          ++_nativeRevision;
          _applyAccessibility(call.arguments);
        }
      });
      _nativeAttached = true;
      final revision = _nativeRevision;
      final state = await _channel.invokeMethod<Object?>('state');
      if (revision == _nativeRevision) _applyAccessibility(state);
    } on MissingPluginException {
      // Other platforms and older app binaries have no AppKit bridge.
    } on PlatformException {
      // Native fallback still honors macOS accessibility independently.
    } catch (_) {
      // A test/runtime without an initialized platform messenger is nonfatal.
    }
  }

  void _applyAccessibility(Object? raw) {
    if (_disposed || raw is! Map) return;
    final transparency = raw['reduceTransparency'],
        motion = raw['reduceMotion'];
    if (transparency is! bool || motion is! bool) return;
    if (_reduceTransparency == transparency && _reduceMotion == motion) return;
    _reduceTransparency = transparency;
    _reduceMotion = motion;
    _notify();
  }

  void setBackgroundOpacity(double value) {
    if (_disposed || !value.isFinite) return;
    final opacity = value.clamp(minimumBackgroundOpacity, 1.0).toDouble();
    if (_backgroundOpacity == opacity) return;
    _backgroundOpacity = opacity;
    ++_revision;
    _error = null;
    _notify();
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  void restoreDefault() {
    if (_disposed) return;
    setBackgroundOpacity(defaultBackgroundOpacity);
    unawaited(retrySave());
  }

  Future<void> retrySave() {
    if (_disposed) return Future.value();
    ++_revision;
    return flush();
  }

  /// Serial, atomic snapshots. A stale asynchronous save never clears the dirty
  /// flag/error belonging to a newer slider value. UI errors stay in this model.
  Future<void> flush() async {
    _saveTimer?.cancel();
    await initialize();
    if (_revision == _savedRevision) return _writes;
    final revision = _revision, opacity = _backgroundOpacity;
    final task = _writes
        .then((_) async {
          final file = _file ??= File(
            '${(await getApplicationSupportDirectory()).path}/cinema/appearance-v1.json',
          );
          await file.parent.create(recursive: true);
          final temp = File('${file.path}.tmp');
          await temp.writeAsString(
            jsonEncode({'version': 1, 'backgroundOpacity': opacity}),
            flush: true,
          );
          await temp.rename(file.path);
          _savedRevision = revision;
          if (revision == _revision) _error = null;
        })
        .catchError((Object _) {
          if (revision == _revision) _error = '外观已预览，但未能保存；请检查磁盘空间后重试。';
        });
    _writes = task;
    await task;
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _saveTimer?.cancel();
    if (_revision != _savedRevision) unawaited(flush());
    _disposed = true;
    if (_nativeAttached) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
