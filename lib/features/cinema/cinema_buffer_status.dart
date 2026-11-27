import 'dart:async';
import 'cinema_native_cache_state.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

@immutable
class CinemaBufferSnapshot {
  const CinemaBufferSnapshot({
    this.bytes = 0,
    this.mediaSeconds = 0,
    this.bytesPerSecond = 0,
    this.idle = false,
  });
  final int bytes;
  final double mediaSeconds, bytesPerSecond;
  final bool idle;
  String label(int capacity, double rate) {
    final seconds = (mediaSeconds / (rate > 0 ? rate : 1)).round();
    final downloaded =
        '${(bytes / 1048576).toStringAsFixed(1)} / ${(capacity / 1048576).round()} MB';
    final speed = bytesPerSecond > 1024
        ? ' · ${(bytesPerSecond / 1048576).toStringAsFixed(2)} MB/s'
        : '';
    return '前向缓存 $downloaded · 可播 $seconds 秒${idle ? ' · 已预读完成' : speed}';
  }
}

/// MPV keeps filling its cache even when playback position is paused. Poll the
/// native cache facts independently of position events so the UI stays live.
class CinemaBufferMonitor extends ValueNotifier<CinemaBufferSnapshot> {
  CinemaBufferMonitor(this.player) : super(const CinemaBufferSnapshot());
  final Player player;
  Timer? _timer;
  bool _closed = false, _reading = false, _ready = false;
  void start() {
    _ready = true;
    _startIfObserved();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _startIfObserved();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startIfObserved() {
    if (!_ready ||
        !hasListeners ||
        _timer != null ||
        _closed ||
        player.platform is! NativePlayer) {
      return;
    }
    unawaited(sample());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(sample()),
    );
  }

  Future<void> sample() async {
    if (_closed || _reading || player.platform is! NativePlayer) return;
    _reading = true;
    try {
      final native = player.platform as NativePlayer;
      Future<String> read(String key) async {
        try {
          return await native
              .getProperty(key)
              .timeout(const Duration(seconds: 1));
        } catch (_) {
          return '';
        }
      }

      final state = cinemaNativeCacheState(native);
      Future<num> metric(String field, String fallback) async {
        final available = state[field];
        if (available != null) return available;
        final number = double.tryParse(await read(fallback));
        return number != null && number.isFinite && number >= 0 ? number : 0;
      }

      final metrics = await Future.wait([
        metric('fw-bytes', 'demuxer-cache-state/fw-bytes'),
        metric('cache-duration', 'demuxer-cache-duration'),
        metric('raw-input-rate', 'cache-speed'),
      ]);
      if (_closed || !hasListeners) return;
      final idle = await read('demuxer-cache-idle');
      if (_closed) return;
      value = CinemaBufferSnapshot(
        bytes: metrics[0].round(),
        mediaSeconds: metrics[1].toDouble(),
        bytesPerSecond: metrics[2].toDouble(),
        idle: idle == 'yes',
      );
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}

class CinemaBufferStatus extends StatelessWidget {
  const CinemaBufferStatus({
    super.key,
    required this.monitor,
    required this.capacity,
    required this.rate,
    this.routeLabel,
  });
  final CinemaBufferMonitor monitor;
  final int capacity;
  final double rate;
  final String Function()? routeLabel;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<CinemaBufferSnapshot>(
    valueListenable: monitor,
    builder: (context, snapshot, _) => Flexible(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '${routeLabel?.call().isNotEmpty == true ? '自动${routeLabel!()} · ' : ''}${snapshot.label(capacity, rate)}',
          key: const ValueKey('cinema-buffer-status'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Color(0xffb3b0b5)),
        ),
      ),
    ),
  );
}
