import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_subtitle_clock.dart';

/// TV uses Android's MediaCodec/AudioTrack pipeline and a real SurfaceView.
/// Implementing Player avoids constructing a libmpv player or GPU texture.
class CinemaTVNativePlayer extends PlatformPlayer
    implements Player, CinemaSubtitlePlaybackClock {
  CinemaTVNativePlayer({
    super.configuration = const PlayerConfiguration(),
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting Stream<dynamic>? events,
  }) : id = _nextId++,
       _channel = channel ?? const MethodChannel('naku/tv-player') {
    _subscription = (events ?? _nativeEvents).listen(
      _event,
      onError: (_) {
        if (!_disposed) errorController.add('Android TV 视频桥接连接中断');
      },
    );
    _creation = _channel.invokeMethod<void>('create', {'id': id}).then((_) {
      if (!completer.isCompleted) completer.complete();
    });
  }

  static int _nextId = 1;
  static final Stream<dynamic> _nativeEvents = const EventChannel(
    'naku/tv-player/events',
  ).receiveBroadcastStream().asBroadcastStream();
  final int id;
  String? mediaMimeType;
  Uri? httpProxy;
  final MethodChannel _channel;
  late final Future<void> _creation;
  late final StreamSubscription<dynamic> _subscription;
  final Completer<void> _firstFrame = Completer<void>();
  bool _disposed = false;
  double _captionBottomFraction = .08;
  List<Map<Object?, Object?>>? _lastTrackRows;

  Future<void> get waitUntilFirstFrameRendered => _firstFrame.future;
  @override
  PlatformPlayer get platform => this;
  @override
  set platform(PlatformPlayer? value) {
    if (!identical(value, this)) {
      throw UnsupportedError('Android TV owns its native Media3 player');
    }
  }

  @override
  PlayerStream get streams => stream;
  @override
  Future<int> get handle async => id;

  Future<void> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    await _creation;
    if (_disposed) return;
    await _channel.invokeMethod<void>(method, {'id': id, ...args});
  }

  /// Only changes SubtitleView placement; never resizes/reopens video output.
  Future<void> setSubtitleBottomFraction(double fraction) async {
    final value = fraction.isFinite ? fraction.clamp(.08, .45).toDouble() : .08;
    if (_captionBottomFraction == value) return;
    _captionBottomFraction = value;
    await _call('captionInset', {'fraction': value});
  }

  void _event(dynamic raw) {
    if (_disposed || raw is! Map || raw['id'] != id) return;
    if (raw['firstFrame'] == true && !_firstFrame.isCompleted) {
      _firstFrame.complete();
    }
    if (raw['error'] is String) {
      errorController.add(raw['error'] as String);
    }
    final before = state;
    Duration durationValue(String key, Duration previous) {
      final value = raw[key];
      if (value is! num || value.toInt() == previous.inMilliseconds) {
        return previous;
      }
      return Duration(milliseconds: value.toInt());
    }

    final position = durationValue('positionMs', before.position);
    final duration = durationValue('durationMs', before.duration);
    final buffer = durationValue('bufferMs', before.buffer);
    final playing = raw['playing'] is bool
        ? raw['playing'] as bool
        : before.playing;
    final buffering = raw['buffering'] is bool
        ? raw['buffering'] as bool
        : before.buffering;
    final completed = raw['completed'] is bool
        ? raw['completed'] as bool
        : before.completed;
    final width = raw['width'] is num
        ? (raw['width'] as num).toInt()
        : before.width;
    final height = raw['height'] is num
        ? (raw['height'] as num).toInt()
        : before.height;
    var subtitle = before.subtitle;
    if (raw['cues'] case final List cues) {
      if (!listEquals(cues, subtitle)) {
        subtitle = cues.whereType<String>().toList();
      }
    }
    Tracks? nextTracks;
    Track? nextTrack;
    var tracksChanged = false;
    if (raw['tracks'] case final List rows) {
      if (!_sameTrackRows(rows)) {
        final video = <VideoTrack>[VideoTrack.auto(), VideoTrack.no()];
        final audio = <AudioTrack>[AudioTrack.auto(), AudioTrack.no()];
        final subtitle = <SubtitleTrack>[
          SubtitleTrack.auto(),
          SubtitleTrack.no(),
        ];
        var selected = before.track;
        for (final row in rows.whereType<Map>()) {
          final trackId = '${row['id']}';
          final label = row['label']?.toString();
          final language = row['language']?.toString();
          switch (row['type']) {
            case 'video':
              final track = VideoTrack(
                trackId,
                label,
                language,
                codec: row['codec']?.toString(),
                w: row['width'] as int?,
                h: row['height'] as int?,
              );
              video.add(track);
              if (row['selected'] == true) {
                selected = selected.copyWith(video: track);
              }
            case 'audio':
              final track = AudioTrack(
                trackId,
                label,
                language,
                codec: row['codec']?.toString(),
                channelscount: row['channels'] as int?,
              );
              audio.add(track);
              if (row['selected'] == true) {
                selected = selected.copyWith(audio: track);
              }
            case 'subtitle':
              final track = SubtitleTrack(trackId, label, language);
              subtitle.add(track);
              if (row['selected'] == true && !before.track.subtitle.data) {
                selected = selected.copyWith(subtitle: track);
              }
          }
        }
        nextTracks = Tracks(video: video, audio: audio, subtitle: subtitle);
        nextTrack = selected;
        tracksChanged = true;
        _lastTrackRows = [
          for (final row in rows.whereType<Map>())
            Map<Object?, Object?>.of(row),
        ];
      }
    }
    if (position == before.position &&
        duration == before.duration &&
        buffer == before.buffer &&
        playing == before.playing &&
        buffering == before.buffering &&
        completed == before.completed &&
        width == before.width &&
        height == before.height &&
        identical(subtitle, before.subtitle) &&
        !tracksChanged) {
      return;
    }

    // One coherent state allocation per changed packet. Every listener sees
    // the complete snapshot, even when Media3 reports several changes at once.
    state = before.copyWith(
      position: position,
      duration: duration,
      buffer: buffer,
      playing: playing,
      buffering: buffering,
      completed: completed,
      width: width,
      height: height,
      subtitle: subtitle,
      tracks: nextTracks,
      track: nextTrack,
    );
    if (position != before.position) positionController.add(position);
    if (duration != before.duration) durationController.add(duration);
    if (buffer != before.buffer) bufferController.add(buffer);
    if (playing != before.playing) playingController.add(playing);
    if (buffering != before.buffering) bufferingController.add(buffering);
    if (completed != before.completed) completedController.add(completed);
    if (width != before.width) widthController.add(width);
    if (height != before.height) heightController.add(height);
    if (!identical(subtitle, before.subtitle)) subtitleController.add(subtitle);
    if (tracksChanged) tracksController.add(nextTracks!);
    if (nextTrack != null && nextTrack != before.track) {
      trackController.add(nextTrack);
    }
  }

  bool _sameTrackRows(List<dynamic> rows) {
    final previous = _lastTrackRows;
    if (previous == null || previous.length != rows.length) return false;
    for (var index = 0; index < previous.length; index++) {
      final row = rows[index];
      if (row is! Map || !mapEquals(previous[index], row)) return false;
    }
    return true;
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    _lastTrackRows = null;
    final queue = playable is Playlist
        ? playable
        : Playlist([playable as Media]);
    if (queue.medias.isEmpty) return stop();
    final index = queue.index.clamp(0, queue.medias.length - 1);
    final media = queue.medias[index];
    state = state.copyWith(
      playlist: queue,
      completed: false,
      position: media.start ?? Duration.zero,
      buffering: true,
      playing: play,
    );
    playlistController.add(queue);
    completedController.add(false);
    bufferingController.add(true);
    playingController.add(play);
    await _call('open', {
      'url': media.uri,
      'mimeType': mediaMimeType,
      'proxy': cinemaTVNativeProxyArguments(Uri.parse(media.uri), httpProxy),
      'headers': media.httpHeaders ?? const <String, String>{},
      'positionMs': media.start?.inMilliseconds ?? 0,
      'play': play,
    });
  }

  @override
  Future<void> play() => _call('play');
  @override
  Future<void> pause() => _call('pause');
  @override
  Future<void> playOrPause() => state.playing ? pause() : play();
  @override
  Future<void> stop() => _call('stop');
  @override
  Future<void> seek(Duration duration) =>
      _call('seek', {'positionMs': duration.inMilliseconds.clamp(0, 1 << 53)});
  @override
  Future<void> setVolume(double volume) async {
    final value = volume.clamp(0, 100).toDouble();
    state = state.copyWith(volume: value);
    volumeController.add(value);
    await _call('volume', {'value': value / 100});
  }

  @override
  Future<void> setRate(double rate) async {
    final value = rate.clamp(.25, 3).toDouble();
    state = state.copyWith(rate: value);
    rateController.add(value);
    await _call('rate', {'value': value});
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    final selected = state.track.copyWith(subtitle: track);
    state = state.copyWith(track: selected);
    trackController.add(selected);
    // Existing CinemaExternalSubtitleState renders normalized external data
    // above the SurfaceView; suppress native text to avoid double subtitles.
    await _call('track', {
      'type': 'subtitle',
      'track': track.data || track.uri ? 'no' : track.id,
    });
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) =>
      _call('track', {'type': 'audio', 'track': track.id});
  @override
  Future<void> setVideoTrack(VideoTrack track) =>
      _call('track', {'type': 'video', 'track': track.id});
  @override
  Future<void> setAudioDevice(AudioDevice audioDevice) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<void> setShuffle(bool shuffle) async {}
  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {
    state = state.copyWith(playlistMode: playlistMode);
    playlistModeController.add(playlistMode);
  }

  @override
  Future<void> add(Media media) async {
    state = state.copyWith(
      playlist: state.playlist.copyWith(
        medias: [...state.playlist.medias, media],
      ),
    );
    playlistController.add(state.playlist);
  }

  @override
  Future<void> remove(int index) async {
    final media = [...state.playlist.medias];
    if (index < 0 || index >= media.length) return;
    media.removeAt(index);
    state = state.copyWith(playlist: Playlist(media));
    playlistController.add(state.playlist);
  }

  @override
  Future<void> jump(int index) async {
    if (index < 0 || index >= state.playlist.medias.length) return;
    await open(state.playlist.copyWith(index: index));
  }

  @override
  Future<void> next() => jump(state.playlist.index + 1);
  @override
  Future<void> previous() => jump(state.playlist.index - 1);
  @override
  Future<void> move(int from, int to) async {
    final media = [...state.playlist.medias];
    if (from < 0 || from >= media.length || to < 0 || to >= media.length) {
      return;
    }
    media.insert(to, media.removeAt(from));
    state = state.copyWith(playlist: Playlist(media));
    playlistController.add(state.playlist);
  }

  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async => null;
  @override
  Future<Uint8List?> safeScreenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async => null;
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await _creation;
    _disposed = true;
    await _subscription.cancel();
    try {
      await _channel.invokeMethod<void>('dispose', {'id': id});
    } finally {
      await super.dispose();
    }
  }
}

/// Expensive Android view explicitly selects hybrid composition. A normal
/// AndroidView may use a virtual display and lose HDR/output frame timing.
class CinemaTVNativeVideo extends StatelessWidget {
  const CinemaTVNativeVideo({
    super.key,
    required this.player,
    this.subtitleBottomInset = 0,
  });
  final CinemaTVNativePlayer player;
  final double subtitleBottomInset;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final fraction = bounds.maxHeight > 0 && bounds.maxHeight.isFinite
          ? (subtitleBottomInset / bounds.maxHeight).clamp(.08, .45).toDouble()
          : .08;
      if (player._captionBottomFraction != fraction) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            unawaited(
              player
                  .setSubtitleBottomFraction(fraction)
                  .catchError((Object _) {}),
            );
          }
        });
      }
      return PlatformViewLink(
        viewType: 'naku/tv-video',
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        ),
        onCreatePlatformView: (params) =>
            PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: 'naku/tv-video',
                layoutDirection: TextDirection.ltr,
                creationParams: {'playerId': player.id},
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create(),
      );
    },
  );
}

/// Local streams never leave the home network, including cache loopback URLs.
@visibleForTesting
bool cinemaTVNativeBypassesProxy(Uri uri) {
  var host = uri.host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  if (host.startsWith('::ffff:')) host = host.substring(7);
  if (host.isEmpty ||
      !host.contains('.') && !host.contains(':') ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host == '::1' ||
      host == '::' ||
      host.startsWith('fc') && host.contains(':') ||
      host.startsWith('fd') && host.contains(':') ||
      RegExp(r'^fe[89ab]', caseSensitive: false).hasMatch(host) &&
          host.contains(':')) {
    return true;
  }
  final bytes = host.split('.').map(int.tryParse).toList();
  if (bytes.length != 4 || bytes.any((v) => v == null || v < 0 || v > 255)) {
    return false;
  }
  final first = bytes[0]!, second = bytes[1]!;
  return first == 0 ||
      first == 10 ||
      first == 127 ||
      first == 169 && second == 254 ||
      first == 172 && second >= 16 && second <= 31 ||
      first == 192 && second == 168 ||
      first == 100 && second >= 64 && second <= 127;
}

@visibleForTesting
Map<String, Object>? cinemaTVNativeProxyArguments(Uri media, Uri? proxy) {
  if (proxy == null || cinemaTVNativeBypassesProxy(media)) return null;
  if (!{'http', 'socks', 'socks5'}.contains(proxy.scheme) ||
      proxy.host.isEmpty ||
      proxy.port <= 0 ||
      proxy.port > 65535 ||
      proxy.userInfo.isNotEmpty ||
      proxy.path.isNotEmpty && proxy.path != '/' ||
      proxy.hasQuery ||
      proxy.hasFragment) {
    throw const FormatException('电视播放器不支持当前代理，请使用无认证的 HTTP 或 SOCKS5 代理');
  }
  return {'scheme': proxy.scheme, 'host': proxy.host, 'port': proxy.port};
}
