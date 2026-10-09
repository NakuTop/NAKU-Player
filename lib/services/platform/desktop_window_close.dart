import 'dart:async';

/// Route-owned players register only their final local progress save. Hiding a
/// window leaves playback and the existing background-playback policy intact.
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
