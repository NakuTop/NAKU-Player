import 'package:flutter/foundation.dart';
import 'cinema_nas_sync.dart';
import 'package:kazumi/modules/download/download_module.dart';

/// A navigation bridge to the mounted home page, never a second settings store.
/// The home callback reveals its existing route before opening source editing.
class CinemaSettingsHostBinding {
  static final instance = CinemaSettingsHostBinding();

  Object? _owner;
  VoidCallback? _onSources,
      _onFavorites,
      _onHistory,
      _onNASAccount,
      _onLibraryBackup;
  CinemaNASSync? Function()? _accountSync;
  int Function()? _enabledSourceCount;
  int Function()? _sourceCount;
  void Function(DownloadRecord, DownloadEpisode)? _onOfflinePlayback;

  void bind(
    Object owner, {
    required VoidCallback onSources,
    VoidCallback? onFavorites,
    VoidCallback? onHistory,
    VoidCallback? onNASAccount,
    VoidCallback? onLibraryBackup,
    CinemaNASSync? Function()? accountSync,
    void Function(DownloadRecord, DownloadEpisode)? onOfflinePlayback,
    required int Function() enabledSourceCount,
    required int Function() sourceCount,
  }) {
    _owner = owner;
    _onSources = onSources;
    _onFavorites = onFavorites;
    _onHistory = onHistory;
    _onNASAccount = onNASAccount;
    _onLibraryBackup = onLibraryBackup;
    _accountSync = accountSync;
    _onOfflinePlayback = onOfflinePlayback;
    _enabledSourceCount = enabledSourceCount;
    _sourceCount = sourceCount;
  }

  void unbind(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _onSources = null;
    _onFavorites = null;
    _onHistory = null;
    _onNASAccount = null;
    _onLibraryBackup = null;
    _accountSync = null;
    _onOfflinePlayback = null;
    _enabledSourceCount = null;
    _sourceCount = null;
  }

  bool get hasHost => _owner != null;
  CinemaNASSync? get accountSync => _accountSync?.call();
  bool openNASAccount() {
    final action = _onNASAccount;
    if (action == null) return false;
    action();
    return true;
  }

  bool openLibraryBackup() {
    final action = _onLibraryBackup;
    if (action == null) return false;
    action();
    return true;
  }

  bool playOffline(DownloadRecord record, DownloadEpisode episode) {
    final action = _onOfflinePlayback;
    if (action == null) return false;
    action(record, episode);
    return true;
  }

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
