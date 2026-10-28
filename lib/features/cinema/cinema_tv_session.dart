import 'package:flutter/foundation.dart';

/// Playback intent shared with the TV idle host, including startup/buffering.
/// Owners release independently so disposing an old route cannot hide a new one.
class CinemaTVPlaybackActivity extends ChangeNotifier {
  static final instance = CinemaTVPlaybackActivity();
  final Set<Object> _watching = {};
  bool get isWatching => _watching.isNotEmpty;

  void setWatching(Object owner, bool watching) {
    final before = isWatching;
    if (watching) {
      _watching.add(owner);
    } else {
      _watching.remove(owner);
    }
    if (before != isWatching) notifyListeners();
  }

  void release(Object owner) => setWatching(owner, false);
}
