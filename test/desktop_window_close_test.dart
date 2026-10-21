import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/desktop_window_close.dart';

void main() {
  test(
    'Windows system close reaches choice before entering quit state',
    () async {
      var saves = 0, hides = 0, quits = 0, choices = 0;
      final actions = DesktopWindowCloseActions(
        beforeQuit: () async => saves++,
        terminate: () => quits++,
        hideWindow: () async => hides++,
      );
      Future<void> chooseHide() async {
        if (actions.isQuitting) return;
        choices++;
        await actions.hide();
      }

      final result = await actions.requestPlatformExit(
        windowClose: true,
        onWindowClose: chooseHide,
      );
      expect(choices, 1);
      expect(hides, 1);
      expect(saves, 0);
      expect(quits, 0);
      expect(actions.isQuitting, isFalse);
      expect(
        result,
        AppExitResponse.cancel,
        reason: 'Do not ask the engine to dispatch another WM_CLOSE.',
      );

      // A window hidden to the tray can be restored and closed normally again.
      await actions.requestPlatformExit(
        windowClose: true,
        onWindowClose: () async {
          if (!actions.isQuitting) await actions.quit();
        },
      );
      expect(saves, 1);
      expect(quits, 1);
    },
  );

  test('canceling Windows close permits the next close attempt', () async {
    var choices = 0, saves = 0;
    final actions = DesktopWindowCloseActions(
      beforeQuit: () async => saves++,
      terminate: () => fail('Cancelled close must not terminate.'),
      hideWindow: () async => fail('Cancelled close must not hide.'),
    );
    for (var i = 0; i < 2; i++) {
      expect(
        await actions.requestPlatformExit(
          windowClose: true,
          onWindowClose: () async {
            if (!actions.isQuitting) choices++;
          },
        ),
        AppExitResponse.cancel,
      );
    }
    expect(choices, 2);
    expect(saves, 0);
    expect(actions.isQuitting, isFalse);
  });

  test(
    'macOS application Quit bypasses the close choice and prepares once',
    () async {
      var saves = 0;
      final actions = DesktopWindowCloseActions(
        beforeQuit: () async => saves++,
        terminate: () {},
        hideWindow: () async {},
      );
      expect(
        await actions.requestPlatformExit(
          windowClose: false,
          onWindowClose: () async => fail('Cmd-Q is not a window close.'),
        ),
        AppExitResponse.exit,
      );
      await actions.prepareQuit();
      expect(saves, 1);
      expect(actions.isQuitting, isTrue);
    },
  );

  test(
    'hiding preserves playback and does not prepare an application exit',
    () async {
      var saves = 0, hides = 0, quits = 0;
      final actions = DesktopWindowCloseActions(
        beforeQuit: () async => saves++,
        terminate: () => quits++,
        hideWindow: () async => hides++,
      );
      await actions.hide();
      expect(hides, 1);
      expect(saves, 0);
      expect(quits, 0);
      expect(actions.isQuitting, isFalse);
    },
  );

  test(
    'explicit quit waits for final save and overrides a later hide choice',
    () async {
      final saved = Completer<void>();
      var saves = 0, hides = 0, quits = 0;
      final actions = DesktopWindowCloseActions(
        beforeQuit: () {
          saves++;
          return saved.future;
        },
        terminate: () => quits++,
        hideWindow: () async => hides++,
      );
      final first = actions.quit();
      final second = actions.quit();
      expect(actions.isQuitting, isTrue);
      await actions.hide();
      expect(
        hides,
        0,
        reason: 'A stale close dialog must not hide an explicit quit.',
      );
      expect(
        quits,
        0,
        reason: 'Progress must finish saving before termination.',
      );
      saved.complete();
      await Future.wait([first, second]);
      expect(saves, 1);
      expect(quits, 1);
    },
  );

  test('native Cmd-Q preparation and tray quit share one final save', () async {
    final saved = Completer<void>();
    var saves = 0, quits = 0;
    final actions = DesktopWindowCloseActions(
      beforeQuit: () {
        saves++;
        return saved.future;
      },
      terminate: () => quits++,
      hideWindow: () async => fail('Quit must never become a hide.'),
    );
    final nativeExit = actions.prepareQuit();
    expect(actions.isQuitting, isTrue);
    expect(quits, 0, reason: 'The system owns termination for a native quit.');
    final trayExit = actions.quit();
    saved.complete();
    await Future.wait([nativeExit, trayExit]);
    expect(saves, 1);
    expect(quits, 1);
  });

  test(
    'only active route owners save progress and re-registering replaces the hook',
    () async {
      final tasks = DesktopExitTasks();
      final active = Object(), disposed = Object();
      var old = 0, current = 0, removed = 0;
      tasks.register(active, () async => old++);
      tasks.register(active, () async => current++);
      tasks.register(disposed, () async => removed++);
      tasks.unregister(disposed);
      await tasks.prepare();
      expect(old, 0);
      expect(current, 1);
      expect(removed, 0);
    },
  );

  test(
    'a failed or stuck backend cannot block other final saves or quit forever',
    () async {
      final tasks = DesktopExitTasks();
      final hanging = Completer<void>();
      final errors = <Object>[];
      var completed = false;
      tasks.register(Object(), () async => throw StateError('backend failure'));
      tasks.register(Object(), () => hanging.future);
      tasks.register(Object(), () async => completed = true);
      await tasks.prepare(
        timeout: const Duration(milliseconds: 5),
        onError: (error, _) => errors.add(error),
      );
      expect(completed, isTrue);
      expect(errors.whereType<StateError>(), hasLength(1));
      expect(errors.whereType<TimeoutException>(), hasLength(1));
      hanging.complete();
    },
  );
}
