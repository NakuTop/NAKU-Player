/// Monotonic idle policy shared by manual and automatic TV screensavers.
class CinemaTVIdleController {
  CinemaTVIdleController({this.timeout = const Duration(minutes: 10)});
  final Duration timeout;
  Duration _lastInput = Duration.zero;
  Duration? _notWatchingSince = Duration.zero;
  bool _wasWatching = false, _foreground = true;
  bool active = false;

  void activity(Duration now) => _lastInput = now;
  void manual() => active = true;
  void wake(Duration now) {
    active = false;
    _lastInput = now;
    _notWatchingSince = now;
  }

  bool poll(Duration now, {required bool watching, bool foreground = true}) {
    if (!foreground || !_foreground) {
      _foreground = foreground;
      _lastInput = now;
      _notWatchingSince = watching ? null : now;
      _wasWatching = watching;
      return false;
    }
    if (watching) {
      _wasWatching = true;
      _notWatchingSince = null;
      return false;
    }
    if (_wasWatching || _notWatchingSince == null) {
      _wasWatching = false;
      _notWatchingSince = now;
    }
    final since = _lastInput > _notWatchingSince!
        ? _lastInput
        : _notWatchingSince!;
    if (active || now - since < timeout) return false;
    active = true;
    return true;
  }
}
