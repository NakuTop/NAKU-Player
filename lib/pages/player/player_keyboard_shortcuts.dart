import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';

typedef PlayerShortcutAction = FutureOr<void> Function();

class PlayerLongPressShortcutActions {
  const PlayerLongPressShortcutActions({
    required this.onRepeat,
    required this.onRelease,
    this.onCancel,
    this.holdDelay,
  });

  final PlayerShortcutAction onRepeat;
  final PlayerShortcutAction onRelease;
  final PlayerShortcutAction? onCancel;

  /// A timed hold does not depend on the operating system's key repeat setting.
  final Duration? holdDelay;
}

/// Dispatches player shortcuts while preserving focused controls' own keys.
///
/// [focusScopeNode] must be attached to a stable ancestor of the player area.
/// Dialog routes and explicitly blocked overlay interactions keep their normal
/// key handling. Active long-press shortcuts are always released, even after
/// focus leaves the player or this widget is disposed.
class PlayerKeyboardShortcuts extends StatefulWidget {
  const PlayerKeyboardShortcuts({
    super.key,
    required this.focusScopeNode,
    required this.actions,
    this.longPressActions = const <String, PlayerLongPressShortcutActions>{},
    this.isBlocked,
    this.shortcuts,
  });

  final FocusNode focusScopeNode;
  final Map<String, PlayerShortcutAction> actions;
  final Map<String, PlayerLongPressShortcutActions> longPressActions;
  final bool Function()? isBlocked;
  final Map<String, List<String>>? shortcuts;

  @override
  State<PlayerKeyboardShortcuts> createState() =>
      _PlayerKeyboardShortcutsState();
}

class _PlayerKeyboardShortcutsState extends State<PlayerKeyboardShortcuts>
    with WidgetsBindingObserver {
  late Map<String, List<String>> _shortcuts;
  final Map<LogicalKeyboardKey, PlayerLongPressShortcutActions>
  _activeLongPressKeys = <LogicalKeyboardKey, PlayerLongPressShortcutActions>{};
  final _holdTimers = <LogicalKeyboardKey, Timer>{};
  final _timedHolds = <LogicalKeyboardKey>{};

  @override
  void initState() {
    super.initState();
    _shortcuts = widget.shortcuts ?? _loadShortcuts();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKeyEvent);
    FocusManager.instance.addListener(_focusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(PlayerKeyboardShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shortcuts != oldWidget.shortcuts) {
      _shortcuts = widget.shortcuts ?? _loadShortcuts();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKeyEvent);
    FocusManager.instance.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    _releaseAllLongPressShortcuts(cancel: true);
    super.dispose();
  }

  Map<String, List<String>> _loadShortcuts() {
    return <String, List<String>>{
      for (final entry in defaultShortcuts.entries)
        entry.key: GStorage.getStringListSettingByName(
          'shortcut_${entry.key}',
          defaultValue: entry.value,
        ),
    };
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is KeyUpEvent) {
      _holdTimers.remove(event.logicalKey)?.cancel();
      _timedHolds.remove(event.logicalKey);
      final longPressActions = _activeLongPressKeys.remove(event.logicalKey);
      if (longPressActions != null) {
        _invokeAction(longPressActions.onRelease);
        return KeyEventResult.handled;
      }
    }

    if (!_shouldHandleShortcut(event.logicalKey)) {
      return KeyEventResult.ignored;
    }

    final keyLabel = event.logicalKey.keyLabel.isNotEmpty
        ? event.logicalKey.keyLabel
        : event.logicalKey.debugName ?? '';
    final actionName = _findActionName(keyLabel);
    if (actionName == null) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      final action = widget.actions[actionName];
      if (action == null) {
        return KeyEventResult.ignored;
      }
      final longPressActions = widget.longPressActions[actionName];
      if (longPressActions != null) {
        if (longPressActions.holdDelay != null &&
            _activeLongPressKeys.isNotEmpty) {
          _releaseAllLongPressShortcuts(cancel: true);
        }
        _activeLongPressKeys[event.logicalKey] = longPressActions;
        if (longPressActions.holdDelay case final delay?) {
          _holdTimers[event.logicalKey] = Timer(delay, () {
            _holdTimers.remove(event.logicalKey);
            if (!_shouldHandleShortcut(event.logicalKey)) {
              _releaseAllLongPressShortcuts(cancel: true);
              return;
            }
            if (_activeLongPressKeys.containsKey(event.logicalKey) &&
                _timedHolds.add(event.logicalKey)) {
              _invokeAction(longPressActions.onRepeat);
            }
          });
        }
      }
      _invokeAction(action);
      return KeyEventResult.handled;
    }

    if (event is KeyRepeatEvent) {
      final longPressActions = _activeLongPressKeys[event.logicalKey];
      if (longPressActions == null) {
        return KeyEventResult.ignored;
      }
      if (longPressActions.holdDelay == null ||
          _timedHolds.add(event.logicalKey)) {
        _holdTimers.remove(event.logicalKey)?.cancel();
        _invokeAction(longPressActions.onRepeat);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _shouldHandleShortcut(LogicalKeyboardKey key) {
    if (widget.isBlocked?.call() ?? false) {
      return false;
    }

    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return false;
    }

    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null ||
        (primaryFocus != widget.focusScopeNode &&
            !primaryFocus.ancestors.contains(widget.focusScopeNode))) {
      return false;
    }

    final focusContext = primaryFocus.context;
    if (focusContext == null) {
      return true;
    }
    if (focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }

    if (!_controlKeys.contains(key)) return true;
    var controlHasFocus = _ownsControlKeys(focusContext.widget);
    focusContext.visitAncestorElements((element) {
      if (controlHasFocus || element == widget.focusScopeNode.context) {
        return false;
      }
      controlHasFocus = _ownsControlKeys(element.widget);
      return !controlHasFocus;
    });
    return !controlHasFocus;
  }

  static const _controlKeys = [
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  ];

  bool _ownsControlKeys(Widget candidate) =>
      candidate is ButtonStyleButton ||
      candidate is IconButton ||
      candidate is DropdownButton ||
      candidate is PopupMenuButton ||
      candidate is MenuItemButton ||
      candidate is SubmenuButton ||
      candidate is Slider ||
      candidate is RangeSlider ||
      candidate is Checkbox ||
      candidate is Radio ||
      candidate is Switch;

  String? _findActionName(String keyLabel) {
    for (final entry in _shortcuts.entries) {
      if (entry.value.contains(keyLabel)) {
        return entry.key;
      }
    }
    return null;
  }

  void _focusChanged() {
    if (_activeLongPressKeys.keys.any((key) => !_shouldHandleShortcut(key))) {
      _releaseAllLongPressShortcuts(cancel: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _releaseAllLongPressShortcuts(cancel: true);
    }
  }

  void _releaseAllLongPressShortcuts({bool cancel = false}) {
    final actions = _activeLongPressKeys.values.toSet();
    _activeLongPressKeys.clear();
    for (final timer in _holdTimers.values) {
      timer.cancel();
    }
    _holdTimers.clear();
    _timedHolds.clear();
    for (final action in actions) {
      _invokeAction(
        cancel ? action.onCancel ?? action.onRelease : action.onRelease,
      );
    }
  }

  void _invokeAction(PlayerShortcutAction action) {
    unawaited(_runAction(action));
  }

  Future<void> _runAction(PlayerShortcutAction action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'player keyboard shortcuts',
          context: ErrorDescription('while invoking a player shortcut'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
