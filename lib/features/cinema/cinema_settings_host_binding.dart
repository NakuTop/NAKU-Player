import 'package:flutter/foundation.dart';

/// A navigation bridge to the mounted home page, never a second settings store.
/// The home callback reveals its existing route before opening source editing.
class CinemaSettingsHostBinding {
  static final instance = CinemaSettingsHostBinding();

  Object? _owner;
  VoidCallback? _onSources, _onFavorites, _onHistory;
  int Function()? _enabledSourceCount;
  int Function()? _sourceCount;

  void bind(
    Object owner, {
    required VoidCallback onSources,
    VoidCallback? onFavorites,
    VoidCallback? onHistory,
    required int Function() enabledSourceCount,
    required int Function() sourceCount,
  }) {
    _owner = owner;
    _onSources = onSources;
    _onFavorites = onFavorites;
    _onHistory = onHistory;
    _enabledSourceCount = enabledSourceCount;
    _sourceCount = sourceCount;
  }

  void unbind(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _onSources = null;
    _onFavorites = null;
    _onHistory = null;
    _enabledSourceCount = null;
    _sourceCount = null;
  }

  bool get hasHost => _owner != null;
  int? get enabledSourceCount => _enabledSourceCount?.call();
  int? get sourceCount => _sourceCount?.call();

  bool openLibrary({required bool history}) {
    final action = history ? _onHistory : _onFavorites;
    if (action == null) return false;
    action();
    return true;
  }

  bool openSources() {
    final action = _onSources;
    if (action == null) return false;
    action();
    return true;
  }
}
