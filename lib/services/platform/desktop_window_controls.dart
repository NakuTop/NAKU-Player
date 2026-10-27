import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:window_manager/window_manager.dart';

/// Values shared with NakuDesktopWindowController.swift. The native registrar
/// reports conflicts instead of silently replacing another application's key.
const desktopHideShortcuts = <String, String>{
  'control-option-b': '⌃⌥B',
  'command-shift-h': '⌘⇧H',
  'command-b': '⌘B',
  'f8': 'F8',
  'f9': 'F9',
};

class DesktopWindowPreferences {
  const DesktopWindowPreferences({
    this.hotkeyEnabled = true,
    this.shortcut = 'command-b',
    this.pauseOnHide = true,
    this.translucent = false,
    this.opacity = .8,
  });

  static const minimumOpacity = .3;
  final bool hotkeyEnabled, pauseOnHide, translucent;
  final String shortcut;
  final double opacity;

  factory DesktopWindowPreferences.decode(String encoded) {
    try {
      final data = jsonDecode(encoded);
      if (data is! Map) return const DesktopWindowPreferences();
      final opacity = data['opacity'];
      return DesktopWindowPreferences(
        hotkeyEnabled: data['hotkeyEnabled'] is bool
            ? data['hotkeyEnabled'] as bool
            : true,
        shortcut: desktopHideShortcuts.containsKey(data['shortcut'])
            ? data['shortcut'] as String
            : 'command-b',
        pauseOnHide: data['pauseOnHide'] is bool
            ? data['pauseOnHide'] as bool
            : true,
        translucent: data['translucent'] == true,
        opacity: opacity is num && opacity.isFinite
            ? opacity.toDouble().clamp(minimumOpacity, 1.0)
            : .8,
      );
    } catch (_) {
      return const DesktopWindowPreferences();
    }
  }

  DesktopWindowPreferences copyWith({
    bool? hotkeyEnabled,
    String? shortcut,
    bool? pauseOnHide,
    bool? translucent,
    double? opacity,
  }) {
    final value = opacity ?? this.opacity;
    final key = shortcut ?? this.shortcut;
    return DesktopWindowPreferences(
      hotkeyEnabled: hotkeyEnabled ?? this.hotkeyEnabled,
      shortcut: desktopHideShortcuts.containsKey(key) ? key : 'command-b',
      pauseOnHide: pauseOnHide ?? this.pauseOnHide,
      translucent: translucent ?? this.translucent,
      opacity: value.isFinite ? value.clamp(minimumOpacity, 1.0) : this.opacity,
    );
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'hotkeyEnabled': hotkeyEnabled,
    'shortcut': shortcut,
    'pauseOnHide': pauseOnHide,
    'translucent': translucent,
    'opacity': opacity,
  };
}

typedef WindowVisibilityCallback = Future<void> Function(bool hidden);

/// One application-wide owner for native shortcuts and window opacity. Route
/// owners subscribe to visibility, so movies and anime share the same policy.
class DesktopWindowControls extends ChangeNotifier {
  DesktopWindowControls({
    bool? supported,
    MethodChannel? channel,
    String Function()? read,
    Future<void> Function(String)? save,
  }) : supported = supported ?? Platform.isMacOS,
       _channel = channel ?? const MethodChannel('naku/desktop-controls'),
       _read =
           read ??
           (() => GStorage.getSetting(SettingsKeys.desktopWindowControls)),
       _save =
           save ??
           ((value) =>
               GStorage.putSetting(SettingsKeys.desktopWindowControls, value));

  static final instance = DesktopWindowControls();
  final bool supported;
  final MethodChannel _channel;
  final String Function() _read;
  final Future<void> Function(String) _save;
  final _listeners = <Object, WindowVisibilityCallback>{};
  DesktopWindowPreferences _preferences = const DesktopWindowPreferences();
  DesktopWindowPreferences get preferences => _preferences;
  Future<void>? _initializing;
  Future<void>? _refreshingVisibility;
  int _visibilityRevision = 0;
  bool hidden = false, saving = false, registered = false;
  bool reduceTransparency = false;
  bool _disposed = false;
  String? error;

  /// Also guards a video that finishes opening or receives a remote Play after
  /// the user has hidden the window. Showing never calls Play automatically.
  bool get blocksPlayback => supported && hidden && _preferences.pauseOnHide;

  void register(Object owner, WindowVisibilityCallback callback) {
    _listeners[owner] = callback;
    if (blocksPlayback) _dispatch(owner, callback, true);
  }

  void unregister(Object owner) => _listeners.remove(owner);

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'visibilityChanged' && call.arguments is Map) {
        final value = (call.arguments as Map)['hidden'];
        if (value is bool) _visibility(value);
      } else if (call.method == 'stateChanged' && call.arguments is Map) {
        _nativeState(call.arguments as Map);
        notifyListeners();
      }
    });
    try {
      _preferences = DesktopWindowPreferences.decode(_read());
      await _configure(_preferences);
    } catch (e) {
      error = _message(e);
      // A shortcut conflict must not prevent a saved opacity from loading.
      try {
        await _configure(_preferences.copyWith(hotkeyEnabled: false));
      } catch (_) {}
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _configure(DesktopWindowPreferences preferences) async {
    final state = await _channel.invokeMapMethod<String, dynamic>(
      'configure',
      preferences.toJson(),
    );
    if (state != null) _nativeState(state);
  }

  void _nativeState(Map state) {
    registered = state['registered'] == true;
    reduceTransparency = state['reduceTransparency'] == true;
    if (state['hidden'] is bool) _visibility(state['hidden'] as bool);
  }

  Future<bool> update(
    DesktopWindowPreferences value, {
    bool retryHotkey = false,
  }) async {
    await initialize();
    if (!supported || saving || _disposed) return false;
    final old = _preferences;
    saving = true;
    error = null;
    notifyListeners();
    try {
      try {
        await _configure(value);
      } on PlatformException catch (e) {
        // A pending startup conflict does not lock the unrelated pause/opacity
        // controls. Keep the desired key for an explicit retry after it is free.
        if (!retryHotkey &&
            !registered &&
            value.hotkeyEnabled &&
            value.hotkeyEnabled == old.hotkeyEnabled &&
            value.shortcut == old.shortcut) {
          await _configure(value.copyWith(hotkeyEnabled: false));
          error = _message(e);
        } else {
          rethrow;
        }
      }
      await _save(jsonEncode(value.toJson()));
      _preferences = value;
      if (hidden) _notifyVisibility();
      return true;
    } catch (e) {
      error = _message(e);
      try {
        await _configure(old);
      } catch (_) {}
      return false;
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> previewOpacity(double opacity) async {
    if (!supported || saving) return;
    try {
      await _channel.invokeMethod<void>(
        'previewOpacity',
        opacity.clamp(DesktopWindowPreferences.minimumOpacity, 1.0),
      );
    } catch (e) {
      error = _message(e);
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> hide() async {
    if (supported) {
      await initialize();
      await _channel.invokeMethod<void>('hide');
    } else {
      await windowManager.hide();
    }
  }

  Future<void> show() async {
    if (supported) {
      await initialize();
      await _channel.invokeMethod<void>('show');
    } else {
      await windowManager.show();
    }
  }

  /// A foreground restoration may arrive without a didUnhide notification.
  /// Query the native application's actual state before a manual Play rather
  /// than letting a stale cached Hide silently reject the user's action.
  Future<void> refreshVisibility() {
    if (!supported || _disposed) return Future<void>.value();
    return _refreshingVisibility ??= _refreshVisibility();
  }

  Future<void> _refreshVisibility() async {
    try {
      await initialize();
      final revision = _visibilityRevision;
      final state = await _channel.invokeMapMethod<String, dynamic>('state');
      if (!_disposed && state != null && revision == _visibilityRevision) {
        _nativeState(state);
      }
    } catch (e, stack) {
      KazumiLogger().w(
        'Window: visibility refresh failed',
        error: e,
        stackTrace: stack,
      );
    } finally {
      _refreshingVisibility = null;
    }
  }

  void _visibility(bool value) {
    // A duplicate native Hide is still newer evidence than an in-flight query.
    _visibilityRevision++;
    if (hidden == value) return;
    hidden = value;
    _notifyVisibility();
    if (!_disposed) notifyListeners();
  }

  void _notifyVisibility() {
    for (final entry in List.of(_listeners.entries)) {
      _dispatch(entry.key, entry.value, hidden);
    }
  }

  void _dispatch(Object owner, WindowVisibilityCallback callback, bool value) {
    unawaited(
      Future<void>.sync(() {
        if (!_disposed &&
            identical(_listeners[owner], callback) &&
            hidden == value) {
          return callback(value);
        }
      }).catchError((Object error, StackTrace stack) {
        KazumiLogger().w(
          'Window: visibility playback callback failed',
          error: error,
          stackTrace: stack,
        );
      }),
    );
  }

  String _message(Object e) =>
      e is PlatformException ? e.message ?? '窗口设置未生效，请重试。' : '窗口设置未保存或未生效，请重试。';

  @override
  void dispose() {
    _disposed = true;
    _listeners.clear();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
