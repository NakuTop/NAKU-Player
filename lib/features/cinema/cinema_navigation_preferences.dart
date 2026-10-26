import 'package:flutter/foundation.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Device-only display preference. Intentionally absent from SettingsKeys.all,
/// portable settings and CinemaStore exports/NAS synchronization.
class CinemaNavigationPreferences extends ChangeNotifier {
  CinemaNavigationPreferences({
    bool Function()? readValue,
    Future<void> Function(bool)? writeValue,
  }) : _writeValue = writeValue {
    try {
      _showAnime = readValue?.call() ?? GStorage.getSetting(storageKey);
    } catch (_) {
      // Standalone hosts may be mounted before local storage is initialized.
      _showAnime = false;
    }
  }

  static final instance = CinemaNavigationPreferences();
  static const storageKey = SettingKey<bool>(
    'cinemaShowAnimeNavigation',
    false,
    group: SettingGroup.interface,
  );

  final Future<void> Function(bool)? _writeValue;
  bool _showAnime = false, _saving = false, _disposed = false;
  String? _error;

  bool get showAnime => _showAnime;
  bool get saving => _saving;
  String? get error => _error;

  Future<void> setShowAnime(bool value) async {
    if (_disposed || _saving || value == _showAnime) return;
    _saving = true;
    _error = null;
    _notify();
    try {
      await (_writeValue?.call(value) ??
          GStorage.putSetting(storageKey, value));
      _showAnime = value;
    } catch (_) {
      _error = '入口设置未保存，请重试。';
    } finally {
      _saving = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
