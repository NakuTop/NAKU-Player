import 'dart:async';

import 'cinema_models.dart';
import 'cinema_nas_media.dart';

typedef CinemaTVCastConfirmation =
    Future<bool> Function(
      CinemaTitle title,
      CinemaSource source,
      int routeIndex,
      int episodeIndex,
      int positionSeconds,
    );
typedef CinemaTVCastPlayback =
    FutureOr<void> Function(
      CinemaTitle title,
      CinemaSource source,
      int routeIndex,
      int episodeIndex,
      int positionSeconds,
    );

/// Confirmation gate after CinemaLanCast's authenticated decryption and replay
/// guard. This does not replace or weaken that transport-level validation.
class CinemaTVCastReceiver {
  CinemaTVCastReceiver({
    required this.client,
    required this.confirm,
    required this.play,
    this.wakeScreensaver,
    bool Function()? isActive,
  }) : isActive = isActive ?? (() => true);

  final CinemaNASClient client;
  final CinemaTVCastConfirmation confirm;
  final CinemaTVCastPlayback play;
  final Future<void> Function()? wakeScreensaver;
  final bool Function() isActive;
  bool _promptPending = false;

  bool _active() {
    try {
      return isActive();
    } catch (_) {
      return false;
    }
  }

  String? _namespace(Map<String, dynamic> session) {
    final value = session['namespace'];
    return value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
        ? value
        : null;
  }

  void _validate(
    CinemaTitle title,
    CinemaSource source,
    int route,
    int episode,
    int position,
  ) {
    source.validate();
    if (title.sourceId != source.id ||
        title.id.isEmpty ||
        title.title.trim().isEmpty ||
        route < 0 ||
        route >= title.routes.length ||
        episode < 0 ||
        episode >= title.routes[route].episodes.length ||
        position < 0 ||
        position > 604800) {
      throw const FormatException('Invalid television playback request');
    }
  }

  void _validateReferences(
    CinemaTitle title,
    CinemaSource source,
    String namespace,
  ) {
    final nasSource = source.id == cinemaNASSource.id;
    for (final episode in title.routes.expand((route) => route.episodes)) {
      requireHttpUrl(episode.url);
      if (nasSource || isNASMediaReference(episode.url)) {
        if (!nasSource ||
            parseNASMediaReference(episode.url)['nas'] != namespace) {
          throw const FormatException('NAS playback identity changed');
        }
      }
    }
  }

  /// Same signature as CinemaLanCast.onPlay. Invalid, cancelled, stale and
  /// inactive requests are ignored without an unhandled asynchronous error.
  Future<void> receive(
    CinemaTitle title,
    CinemaSource source,
    int routeIndex,
    int episodeIndex,
    int positionSeconds,
  ) async {
    if (_promptPending || !_active()) return;
    _promptPending = true;
    var accepted = false;
    try {
      _validate(title, source, routeIndex, episodeIndex, positionSeconds);
      final receipt = _namespace(await client.call('currentSession'));
      if (receipt == null || !_active()) return;
      _validateReferences(title, source, receipt);
      await wakeScreensaver?.call();
      if (!_active() ||
          !await confirm(
            title,
            source,
            routeIndex,
            episodeIndex,
            positionSeconds,
          )) {
        return;
      }
      final current = _namespace(await client.call('currentSession'));
      if (current != receipt || !_active()) return;
      _validateReferences(title, source, current!);
      accepted = true;
    } catch (_) {
      // No request fields, private NAS identity or credentials enter logs.
    } finally {
      _promptPending = false;
    }
    if (!accepted || !_active()) return;
    // The prompt lock ends before dispatch, including when a caller returns a
    // Future for a player route. A whole movie must not block the next prompt.
    try {
      await Future<void>.sync(
        () => play(title, source, routeIndex, episodeIndex, positionSeconds),
      );
    } catch (_) {
      // The host player owns visible playback errors and retry behavior.
    }
  }
}
