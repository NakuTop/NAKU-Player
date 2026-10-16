import 'package:flutter/material.dart';

/// Fixed touch targets keep essential controls visible on a portrait phone.
class CinemaMobilePlaybackBar extends StatelessWidget {
  const CinemaMobilePlaybackBar({
    super.key,
    required this.playing,
    required this.fullscreen,
    required this.position,
    required this.duration,
    this.onBackward,
    this.onPlay,
    this.onForward,
    this.onQuality,
    this.onTracks,
    this.onFullscreen,
  });
  final bool playing, fullscreen;
  final String position, duration;
  final VoidCallback? onBackward,
      onPlay,
      onForward,
      onQuality,
      onTracks,
      onFullscreen;
  Widget _button(String label, IconData icon, VoidCallback? action) =>
      SizedBox.square(
        dimension: 44,
        child: IconButton(
          tooltip: label,
          padding: EdgeInsets.zero,
          onPressed: action,
          icon: Icon(icon, size: 24),
          color: Colors.white,
        ),
      );
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Text(
            position,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const Spacer(),
          Text(
            duration,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _button('后退', Icons.replay_10_rounded, onBackward),
          _button(
            playing ? '暂停' : '播放',
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            onPlay,
          ),
          _button('快进', Icons.forward_10_rounded, onForward),
          _button('清晰度与播放设置', Icons.high_quality_outlined, onQuality),
          _button('字幕与音轨', Icons.closed_caption_outlined, onTracks),
          _button(
            fullscreen ? '退出全屏' : '全屏',
            fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onFullscreen,
          ),
        ],
      ),
    ],
  );
}
