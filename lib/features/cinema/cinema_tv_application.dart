import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'cinema_home_display_page.dart';
import 'cinema_nas_media.dart';
import 'cinema_tv_idle.dart';
import 'cinema_tv_home_display.dart';
import 'cinema_tv_session.dart';
import 'cinema_tv_motion.dart';

/// The existing cinema pages keep their artwork, caches and transitions inside
/// one TV navigator. Idle observation also covers players and nested dialogs.
class CinemaTVApplication extends StatefulWidget {
  const CinemaTVApplication({
    super.key,
    required this.home,
    this.client,
    this.screensaverBuilder,
    this.idleTimeout = const Duration(minutes: 10),
    this.now,
  });
  final Widget home;
  final CinemaNASClient? client;
  final Widget Function(VoidCallback onWake)? screensaverBuilder;
  final Duration idleTimeout;
  final Duration Function()? now;

  static CinemaTVApplicationState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<CinemaTVApplicationState>();

  @override
  State<CinemaTVApplication> createState() => CinemaTVApplicationState();
}

class CinemaTVApplicationState extends State<CinemaTVApplication>
    with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  final _clock = Stopwatch()..start();
  final _wakeKeys = <PhysicalKeyboardKey>{};
  late final _idle = CinemaTVIdleController(timeout: widget.idleTimeout);
  late final _observer = _TVRouteActivity(activity);
  final _playback = CinemaTVPlaybackActivity.instance;
  Timer? _timer;
  Route<void>? _saverRoute;
  Completer<void>? _saverClosed;
  FocusNode? _savedFocus;
  bool _foreground = true, _restorePending = false;
  Duration get _now => widget.now?.call() ?? _clock.elapsed;
  bool get screensaverVisible => _saverRoute != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_key);
    _playback.addListener(checkIdle);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => checkIdle());
  }

  void activity() => _idle.activity(_now);

  void checkIdle() {
    if (_idle.poll(
      _now,
      watching: _playback.isWatching,
      foreground: _foreground,
    )) {
      unawaited(showScreensaver(manual: false));
    }
  }

  KeyEventResult _key(KeyEvent event) {
    if (event is KeyUpEvent && _wakeKeys.remove(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    if (_wakeKeys.contains(event.physicalKey)) return KeyEventResult.handled;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (screensaverVisible) {
        _wakeKeys.add(event.physicalKey);
        unawaited(dismissScreensaver());
        return KeyEventResult.handled;
      }
      activity();
    }
    return KeyEventResult.ignored;
  }

  void _pageWake() {
    _wakeKeys.addAll(HardwareKeyboard.instance.physicalKeysPressed);
    _idle.wake(_now);
  }

  Future<void> showScreensaver({bool manual = true}) async {
    if (!mounted || !_foreground || screensaverVisible) return;
    if (_playback.isWatching) {
      _idle.wake(_now);
      return;
    }
    if (manual) _idle.manual();
    _savedFocus = FocusManager.instance.primaryFocus;
    final closed = Completer<void>();
    _saverClosed = closed;
    final route = PageRouteBuilder<void>(
      settings: const RouteSettings(name: '/tv/screensaver'),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) =>
          widget.screensaverBuilder?.call(_pageWake) ??
          (Platform.isAndroid
              ? CinemaTVHomeDisplay(client: widget.client, onWake: _pageWake)
              : CinemaHomeDisplayPage(
                  client: widget.client,
                  screensaver: true,
                  onWake: _pageWake,
                )),
    );
    _saverRoute = route;
    try {
      await _navigator.currentState!.push(route);
    } finally {
      if (identical(_saverRoute, route)) _saverRoute = null;
      _idle.wake(_now);
      if (!closed.isCompleted) closed.complete();
      if (mounted) {
        _restorePending = true;
        if (_foreground) _restoreFocus();
      }
    }
  }

  Future<void> dismissScreensaver() async {
    final route = _saverRoute;
    if (route == null) return;
    _pageWake();
    final finished = _saverClosed?.future;
    // No exit animation or PopScope side effect should turn a wake key into a
    // second navigation command. Disposal still closes the embedded WebView.
    _navigator.currentState?.removeRoute(route);
    if (finished != null) await finished;
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_foreground || !_restorePending) return;
      _restorePending = false;
      final node = _savedFocus;
      if (node?.context != null && node!.canRequestFocus) node.requestFocus();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _wakeKeys.clear();
    if (!_foreground && screensaverVisible) unawaited(dismissScreensaver());
    _idle.poll(_now, watching: _playback.isWatching, foreground: _foreground);
    if (_foreground && _restorePending) _restoreFocus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock.stop();
    _playback.removeListener(checkIdle);
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => activity(),
    onPointerSignal: (_) => activity(),
    child: MediaQuery(
      data: MediaQuery.of(context),
      child: Theme(
        data: Theme.of(context).copyWith(
          splashFactory: NoSplash.splashFactory,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: CinemaTVPageTransitions(),
              TargetPlatform.linux: CinemaTVPageTransitions(),
              TargetPlatform.macOS: CinemaTVPageTransitions(),
              TargetPlatform.windows: CinemaTVPageTransitions(),
              TargetPlatform.iOS: CinemaTVPageTransitions(),
              TargetPlatform.fuchsia: CinemaTVPageTransitions(),
            },
          ),
        ),
        child: NavigatorPopHandler<void>(
          onPopWithResult: (_) {
            if (screensaverVisible) {
              unawaited(dismissScreensaver());
            } else {
              _navigator.currentState?.maybePop();
            }
          },
          child: Navigator(
            key: _navigator,
            observers: [_observer],
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/tv/home'),
              builder: (_) => widget.home,
            ),
          ),
        ),
      ),
    ),
  );
}

class _TVRouteActivity extends NavigatorObserver {
  _TVRouteActivity(this.onActivity);
  final VoidCallback onActivity;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onActivity();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onActivity();
}
