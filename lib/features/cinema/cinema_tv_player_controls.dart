import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cinema_theme.dart';
import 'cinema_tv_motion.dart';

/// A two-row remote path, independent of spacing and native video surfaces.
class CinemaTVControlNavigation extends StatefulWidget {
  const CinemaTVControlNavigation({
    super.key,
    required this.timeline,
    required this.actions,
    required this.onActivity,
    required this.child,
  });
  final FocusNode timeline;
  final List<FocusNode> actions;
  final VoidCallback onActivity;
  final Widget child;
  @override
  State<CinemaTVControlNavigation> createState() => _TVControlNavigationState();
}

class _TVControlNavigationState extends State<CinemaTVControlNavigation> {
  int _lastAction = 0;
  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        widget.onActivity();
        final nodes = widget.actions.where((n) => n.canRequestFocus).toList();
        if (nodes.isEmpty) return KeyEventResult.ignored;
        final index = nodes.indexWhere((node) => node.hasFocus),
            key = event.logicalKey;
        if (widget.timeline.hasFocus) {
          if (key == LogicalKeyboardKey.arrowDown) {
            nodes[_lastAction.clamp(0, nodes.length - 1)].requestFocus();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        if (index < 0) return KeyEventResult.ignored;
        _lastAction = index;
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) {
          _lastAction = (index + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1))
              .clamp(0, nodes.length - 1);
          nodes[_lastAction].requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          widget.timeline.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
        if (event is KeyDownEvent &&
            (key == LogicalKeyboardKey.gameButtonA ||
                key == LogicalKeyboardKey.numpadEnter)) {
          final target = nodes[index].context;
          if (target != null) {
            Actions.maybeInvoke(target, const ActivateIntent());
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    ),
  );
}

class CinemaTVSeekPreview extends ChangeNotifier {
  Duration? _target;
  Duration? get target => _target;
  bool get active => _target != null;
  void preview(Duration position, Duration duration, int seconds) {
    _target = Duration(
      milliseconds: ((_target ?? position).inMilliseconds + seconds * 1000)
          .clamp(0, duration.inMilliseconds),
    );
    notifyListeners();
  }

  Duration? take() {
    final result = _target;
    cancel();
    return result;
  }

  void cancel() {
    if (_target == null) return;
    _target = null;
    notifyListeners();
  }
}

/// A focusable progress bar with reversible, explicit remote seeking.
class CinemaTVTimeline extends StatelessWidget {
  const CinemaTVTimeline({
    super.key,
    required this.position,
    required this.duration,
    required this.preview,
    required this.focusNode,
    required this.onCommit,
    required this.onActivity,
    this.compact = false,
  });
  final Duration position, duration;
  final CinemaTVSeekPreview preview;
  final FocusNode focusNode;
  final ValueChanged<Duration> onCommit;
  final VoidCallback onActivity;
  final bool compact;
  static String time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 999999);
    final h = seconds ~/ 3600, m = seconds % 3600 ~/ 60, s = seconds % 60;
    return '${h > 0 ? '$h:' : ''}${h > 0 ? '$m'.padLeft(2, '0') : m}:${'$s'.padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([preview, focusNode]),
    builder: (context, _) {
      final target = preview.target ?? position;
      final fraction = duration.inMilliseconds <= 0
          ? 0.0
          : (target.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      return Focus(
        focusNode: focusNode,
        onFocusChange: (focused) {
          if (!focused) preview.cancel();
        },
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          onActivity();
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight) {
            preview.preview(
              position,
              duration,
              (key == LogicalKeyboardKey.arrowLeft ? -1 : 1) *
                  (event is KeyRepeatEvent ? 30 : 10),
            );
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.gameButtonA) {
            final selection = preview.take();
            if (selection != null) onCommit(selection);
            return KeyEventResult.handled;
          }
          if (preview.active &&
              (key == LogicalKeyboardKey.escape ||
                  key == LogicalKeyboardKey.goBack)) {
            preview.cancel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          label: '播放进度 ${time(target)}，左右预览，确定跳转，返回取消',
          slider: true,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: compact ? 4 : 12,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focusNode.hasFocus ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      time(target),
                      style: TextStyle(fontSize: compact ? 14 : 17),
                    ),
                    Text(
                      '−${time(duration - target)}',
                      style: TextStyle(
                        fontSize: compact ? 14 : 17,
                        color: CinemaTheme.muted,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 5 : 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: compact ? 3 : 5,
                    color: focusNode.hasFocus
                        ? CinemaTheme.copper
                        : Colors.white,
                    backgroundColor: Colors.white24,
                  ),
                ),
                if (preview.active)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '确定跳转 · 返回取消',
                      style: TextStyle(fontSize: 15, color: CinemaTheme.copper),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// A compact, unblurred bottom scrim keeps the picture visible above controls.
class CinemaTVControlSurface extends StatelessWidget {
  const CinemaTVControlSurface({super.key, required this.child});
  final Widget child;
  static const subtitleClearance = 168.0;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: CinemaTVMotion.duration(context, CinemaTVMotion.panel),
    curve: CinemaTVMotion.curve,
    builder: (_, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - value)),
        child: child,
      ),
    ),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xE609090B)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 12, 28, 14),
        child: child,
      ),
    ),
  );
}

class CinemaTVEpisodePicker extends StatefulWidget {
  const CinemaTVEpisodePicker({
    super.key,
    required this.labels,
    required this.current,
    required this.onSelected,
  });
  final List<String> labels;
  final int current;
  final ValueChanged<int> onSelected;
  @override
  State<CinemaTVEpisodePicker> createState() => _CinemaTVEpisodePickerState();
}

class _CinemaTVEpisodePickerState extends State<CinemaTVEpisodePicker> {
  late final nodes = List.generate(
    widget.labels.length,
    (i) => FocusNode(debugLabel: 'TV episode ${i + 1}'),
  );
  late int selected = widget.current.clamp(0, widget.labels.length - 1);
  late final scroll = ScrollController(initialScrollOffset: selected * 66.0);
  void reveal(int index) {
    selected = index.clamp(0, nodes.length - 1);
    if (scroll.hasClients) {
      scroll.jumpTo(
        (selected * 66.0).clamp(0, scroll.position.maxScrollExtent),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) nodes[selected].requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reveal(selected);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    for (final node in nodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        reveal(selected + 1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        reveal(selected - 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '选集',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          '片源自动优选，切换集数后重新匹配字幕与弹幕',
          style: TextStyle(fontSize: 16, color: CinemaTheme.muted),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView.builder(
            controller: scroll,
            itemExtent: 66,
            itemCount: widget.labels.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.fromLTRB(5, 4, 5, 4),
              child: OutlinedButton(
                focusNode: nodes[i],
                autofocus: i == selected,
                onFocusChange: (focus) {
                  if (focus) selected = i;
                },
                onPressed: () => widget.onSelected(i),
                style: ButtonStyle(
                  side: WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color: states.contains(WidgetState.focused)
                          ? Colors.white
                          : i == widget.current
                          ? CinemaTheme.copper
                          : CinemaTheme.border,
                      width: states.contains(WidgetState.focused) ? 2 : 1,
                    ),
                  ),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.labels[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 19,
                      color: i == widget.current
                          ? CinemaTheme.copper
                          : CinemaTheme.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '返回键关闭',
          style: TextStyle(color: CinemaTheme.muted, fontSize: 15),
        ),
      ],
    ),
  );
}
