import 'dart:async';
import 'dart:ui' show AppExitResponse;

/// Route-owned players register only their final local progress save. Hiding a
/// window is handled separately by the shared opt-in pause-on-hide policy.
class DesktopExitTasks {
  static final instance = DesktopExitTasks();
  final _tasks = <Object, Future<void> Function()>{};

  void register(Object owner, Future<void> Function() save) =>
      _tasks[owner] = save;

  void unregister(Object owner) => _tasks.remove(owner);

  Future<void> prepare({
    Duration timeout = const Duration(seconds: 5),
    void Function(Object, StackTrace)? onError,
  }) async {
    await Future.wait([
      for (final save in List.of(_tasks.values))
        (() async {
          try {
            await Future<void>.sync(save).timeout(timeout);
          } catch (error, stack) {
            onError?.call(error, stack);
          }
        })(),
    ]);
  }
}

/// Explicit Quit bypasses close-button preferences and wins over an already
/// open confirmation dialog. Preparation is shared by menu and platform quits.
class DesktopWindowCloseActions {
  DesktopWindowCloseActions({
    required this.beforeQuit,
    required this.terminate,
    required this.hideWindow,
  });

  final Future<void> Function() beforeQuit;
  final void Function() terminate;
  final Future<void> Function() hideWindow;
  bool _quitting = false;
  Future<void>? _preparation, _quit;
  bool get isQuitting => _quitting;

  /// Windows sends caption Close and Alt-F4 through Flutter's exit request
  /// before window_manager receives WM_CLOSE. Treating that request as Quit
  /// sets [isQuitting] too early: the re-dispatched WM_CLOSE is then ignored,
  /// while window_manager still prevents the native window from closing.
  /// Handle the window choice here and consume the engine's duplicate close.
  /// macOS application Quit remains an explicit exit, independent of Hide.
  Future<AppExitResponse> requestPlatformExit({
    required bool windowClose,
    required Future<void> Function() onWindowClose,
  }) async {
    if (windowClose) {
      await onWindowClose();
      return AppExitResponse.cancel;
    }
    await prepareQuit();
    return AppExitResponse.exit;
  }

  Future<void> prepareQuit() {
    _quitting = true;
    return _preparation ??= Future<void>.sync(beforeQuit);
  }

  Future<void> quit() {
    _quitting = true;
    return _quit ??= (() async {
      await prepareQuit();
      terminate();
    })();
  }

  Future<void> hide() async {
    if (!_quitting) await hideWindow();
  }
}
