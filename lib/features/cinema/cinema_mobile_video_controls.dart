import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// Touch controls stay in the Flutter player in portrait and landscape.
class CinemaMobileVideoControls extends StatefulWidget {
  const CinemaMobileVideoControls({
    super.key,
    required this.player,
    required this.toggle,
    required this.topBar,
    required this.bottomBar,
    required this.onSeek,
    this.hideAfter = const Duration(seconds: 4),
  });
  final Player player;
  final Listenable toggle;
  final List<Widget> topBar, bottomBar;
  final ValueChanged<Duration> onSeek;
  final Duration hideAfter;
  @override
  State<CinemaMobileVideoControls> createState() =>
      _CinemaMobileVideoControlsState();
}

class _CinemaMobileVideoControlsState extends State<CinemaMobileVideoControls> {
  bool _visible = true;
  bool _controlsMounted = true;
  double? _drag;
  Timer? _timer;
  StreamSubscription<bool>? _playing;

  void _observePlayer() {
    _playing?.cancel();
    _playing = widget.player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing) {
        _scheduleHide();
      } else {
        _timer?.cancel();
        setState(() => _visible = _controlsMounted = true);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    widget.toggle.addListener(_toggle);
    _observePlayer();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(CinemaMobileVideoControls old) {
    super.didUpdateWidget(old);
    if (old.player != widget.player) {
      _drag = null;
      _visible = _controlsMounted = true;
      _observePlayer();
      _scheduleHide();
    }
    if (old.toggle != widget.toggle) {
      old.toggle.removeListener(_toggle);
      widget.toggle.addListener(_toggle);
    }
  }

  void _scheduleHide() {
    _timer?.cancel();
    if (!widget.player.state.playing || !_visible) return;
    _timer = Timer(widget.hideAfter, () {
      if (mounted &&
          _drag == null &&
          ModalRoute.of(context)?.isCurrent != false) {
        setState(() => _visible = false);
      }
    });
  }

  void _toggle() {
    setState(() {
      _visible = !_visible;
      if (_visible) _controlsMounted = true;
    });
    if (_visible) _scheduleHide();
  }

  @override
  void dispose() {
    _playing?.cancel();
    widget.toggle.removeListener(_toggle);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_visible,
    child: AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      onEnd: () {
        if (!_visible && _controlsMounted) {
          setState(() => _controlsMounted = false);
        }
      },
      child: !_controlsMounted
          ? const SizedBox.expand()
          : Listener(
              onPointerDown: (_) {
                _timer?.cancel();
              },
              onPointerUp: (_) => _scheduleHide(),
              onPointerCancel: (_) => _scheduleHide(),
              child: Column(
                children: [
                  Container(
                    height: 44,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x99000000), Color(0x00000000)],
                      ),
                    ),
                    child: Row(children: widget.topBar),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xB3000000)],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StreamBuilder<Duration>(
                          stream: widget.player.stream.position,
                          initialData: widget.player.state.position,
                          builder: (context, position) {
                            final end = widget
                                .player
                                .state
                                .duration
                                .inMilliseconds
                                .toDouble();
                            final value =
                                (_drag ??
                                        position.data!.inMilliseconds
                                            .toDouble())
                                    .clamp(0.0, end > 0 ? end : 1.0);
                            return SizedBox(
                              height: 28,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                ),
                                child: Slider(
                                  key: const ValueKey('mobile-video-seek'),
                                  value: value,
                                  max: end > 0 ? end : 1,
                                  onChangeStart: end <= 0
                                      ? null
                                      : (v) {
                                          _timer?.cancel();
                                          setState(() => _drag = v);
                                        },
                                  onChanged: end <= 0
                                      ? null
                                      : (v) => setState(() => _drag = v),
                                  onChangeEnd: end <= 0
                                      ? null
                                      : (v) {
                                          widget.onSeek(
                                            Duration(milliseconds: v.round()),
                                          );
                                          setState(() => _drag = null);
                                          _scheduleHide();
                                        },
                                ),
                              ),
                            );
                          },
                        ),
                        Row(children: widget.bottomBar),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    ),
  );
}
