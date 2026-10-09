import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/services/player/timed_shutdown_service.dart';

Future<void> mountApp(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: rootNavigatorKey,
    scaffoldMessengerKey: rootScaffoldMessengerKey,
    navigatorObservers: [KazumiDialog.observer],
    home: const Scaffold(body: Text('home')),
  ));
  await tester.pumpAndSettle();
}

Future<void> pushPage(WidgetTester tester) async {
  unawaited(rootNavigatorKey.currentState!.push<void>(MaterialPageRoute(
    builder: (_) => const Scaffold(body: Text('new page')),
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('observer navigation and scoped toasts work without global keys',
      (tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [KazumiDialog.observer],
      home: Builder(builder: (context) {
        pageContext = context;
        return const Scaffold(body: Text('home'));
      }),
    ));
    await tester.pumpAndSettle();
    final result = KazumiDialog.show<bool>(
      builder: (_) => const AlertDialog(title: Text('operation')),
    );
    await tester.pumpAndSettle();
    expect(find.text('operation'), findsOneWidget);
    KazumiDialog.dismiss(popWith: true);
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    KazumiDialog.showToast(context: pageContext, message: 'scoped result');
    await tester.pumpAndSettle();
    expect(find.text('scoped result'), findsOneWidget);
  });

  testWidgets('dismiss removes the tracked dialog beneath a newer page',
      (tester) async {
    await mountApp(tester);
    final result = KazumiDialog.show<bool>(
      builder: (_) => const AlertDialog(title: Text('operation')),
    );
    await tester.pumpAndSettle();
    await pushPage(tester);

    KazumiDialog.dismiss(popWith: true);
    await tester.pumpAndSettle();

    expect(await result, isTrue);
    expect(find.text('new page'), findsOneWidget);
    expect(KazumiDialog.observer.hasKazumiDialog, isFalse);
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('handles preserve another dialog and return the correct type',
      (tester) async {
    await mountApp(tester);
    final first = KazumiDialogHandle<bool>();
    final firstResult = KazumiDialog.show<bool>(
      handle: first,
      builder: (_) => const AlertDialog(title: Text('first')),
    );
    await tester.pumpAndSettle();
    final second = KazumiDialogHandle<int>();
    final secondResult = KazumiDialog.show<int>(
      handle: second,
      builder: (_) => const AlertDialog(title: Text('second')),
    );
    await tester.pumpAndSettle();

    first.dismiss(popWith: true);
    await tester.pumpAndSettle();
    expect(await firstResult, isTrue);
    expect(second.isActive, isTrue);
    expect(find.text('second'), findsOneWidget);
    first.dismiss();
    expect(second.isActive, isTrue);
    second.dismiss(popWith: 42);
    await tester.pumpAndSettle();
    expect(await secondResult, 42);
  });

  testWidgets('a dialog can finish before its builder is first called',
      (tester) async {
    await mountApp(tester);
    final dialog = KazumiDialogHandle<int>();
    final result = KazumiDialog.show<int>(
      handle: dialog,
      builder: (_) => const AlertDialog(title: Text('fast operation')),
    );
    expect(dialog.isActive, isTrue);
    dialog.dismiss(popWith: 7);
    await tester.pumpAndSettle();
    expect(await result, 7);
    expect(dialog.isActive, isFalse);
    expect(find.text('fast operation'), findsNothing);
  });

  testWidgets('context dismissal targets its own dialog beneath another',
      (tester) async {
    await mountApp(tester);
    late BuildContext firstContext;
    final first = KazumiDialog.show<bool>(builder: (context) {
      firstContext = context;
      return const AlertDialog(title: Text('first'));
    });
    await tester.pumpAndSettle();
    final second = KazumiDialogHandle<int>();
    final secondResult = KazumiDialog.show<int>(
      handle: second,
      builder: (_) => const AlertDialog(title: Text('second')),
    );
    await tester.pumpAndSettle();
    KazumiDialog.dismiss(context: firstContext, popWith: true);
    await tester.pumpAndSettle();
    expect(await first, isTrue);
    expect(second.isActive, isTrue);
    second.dismiss();
    await tester.pumpAndSettle();
    await secondResult;
  });

  testWidgets('back invalidates a handle immediately and awaits cleanup once',
      (tester) async {
    await mountApp(tester);
    final dialog = KazumiDialogHandle<void>();
    final cleanup = Completer<void>();
    var cleanupCalls = 0;
    var finished = false;
    final result = KazumiDialog.show<void>(
      handle: dialog,
      builder: (_) => const AlertDialog(title: Text('operation')),
      onDismiss: () async {
        cleanupCalls++;
        await cleanup.future;
      },
    ).then((_) => finished = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await rootNavigatorKey.currentState!.maybePop();
    expect(dialog.isActive, isFalse);
    await tester.pumpAndSettle();
    expect(cleanupCalls, 1);
    expect(finished, isFalse);
    cleanup.complete();
    await result;
    dialog.dismiss();
    expect(cleanupCalls, 1);
  });

  testWidgets('reusing an active handle does not orphan the first dialog',
      (tester) async {
    await mountApp(tester);
    final dialog = KazumiDialogHandle<void>();
    final result = KazumiDialog.show<void>(
      handle: dialog,
      builder: (_) => const AlertDialog(title: Text('first')),
    );
    await tester.pumpAndSettle();
    await expectLater(
      KazumiDialog.show<void>(handle: dialog, builder: (_) => const SizedBox()),
      throwsStateError,
    );
    expect(dialog.isActive, isTrue);
    dialog.dismiss();
    await tester.pumpAndSettle();
    await result;
  });

  testWidgets('a toast posted after closing a dialog remains visible',
      (tester) async {
    await mountApp(tester);
    final dialog = KazumiDialog.show<void>(
      builder: (_) => const AlertDialog(title: Text('share rule')),
    );
    await tester.pumpAndSettle();
    KazumiDialog.dismiss();
    KazumiDialog.showToast(message: 'rule copied');
    await tester.pumpAndSettle();
    await dialog;
    expect(find.text('rule copied'), findsOneWidget);
  });

  testWidgets('page pop clears its old toast', (tester) async {
    await mountApp(tester);
    await pushPage(tester);
    KazumiDialog.showToast(message: 'old page');
    await tester.pumpAndSettle();
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('old page'), findsNothing);
  });

  testWidgets('page pop preserves a toast posted after navigation',
      (tester) async {
    await mountApp(tester);
    await pushPage(tester);
    KazumiDialog.showToast(message: 'old page');
    await tester.pumpAndSettle();
    rootNavigatorKey.currentState!.pop();
    KazumiDialog.showToast(message: 'new result');
    await tester.pumpAndSettle();
    expect(find.text('new result'), findsOneWidget);
  });

  testWidgets('an action can replace its toast with progress feedback',
      (tester) async {
    await mountApp(tester);
    KazumiDialog.showToast(
      message: 'updates available',
      showActionButton: true,
      actionLabel: 'update all',
      onActionPressed: () => KazumiDialog.showToast(message: 'updating'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('update all'));
    await tester.pumpAndSettle();
    expect(find.text('updating'), findsOneWidget);
  });

  testWidgets('action toast stays five seconds then fades out', (tester) async {
    await mountApp(tester);
    KazumiDialog.showToast(
      message: 'deleted',
      showActionButton: true,
      actionLabel: 'undo',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.persist, isFalse);
    expect(snackBar.duration, const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 4900));
    expect(find.text('undo'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(FadeTransition),
    ));
    expect(fade.opacity.value, allOf(greaterThan(0), lessThan(1)));
    await tester.pump(const Duration(milliseconds: 110));
    expect(find.text('deleted'), findsNothing);
    expect(find.text('undo'), findsNothing);
  });

  testWidgets('undo is still actionable just before five seconds', (tester) async {
    await mountApp(tester);
    var undone = 0;
    KazumiDialog.showToast(
      message: 'deleted',
      showActionButton: true,
      actionLabel: 'undo',
      onActionPressed: () => undone++,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 4900));
    await tester.tap(find.text('undo'));
    await tester.pumpAndSettle();
    expect(undone, 1);
    expect(find.text('deleted'), findsNothing);
  });

  testWidgets('a new toast discards queued stale feedback', (tester) async {
    await mountApp(tester);
    final messenger = rootScaffoldMessengerKey.currentState!;
    messenger.showSnackBar(SnackBar(
      content: const Text('old persistent result'),
      action: SnackBarAction(label: 'old undo', onPressed: () {}),
    ));
    messenger.showSnackBar(const SnackBar(content: Text('old queued result')));
    await tester.pumpAndSettle();
    KazumiDialog.showToast(message: 'latest result');
    await tester.pumpAndSettle();
    expect(find.text('latest result'), findsOneWidget);
    expect(find.text('old persistent result'), findsNothing);
    expect(find.text('old queued result'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('rapid toasts leave only the latest and no hidden queue',
      (tester) async {
    await mountApp(tester);
    for (var i = 0; i < 4; i++) {
      KazumiDialog.showToast(message: 'result $i');
    }
    await tester.pumpAndSettle();
    expect(find.text('result 3'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toast margins let pointer clicks reach the page', (tester) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var clicked = 0;
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      home: Scaffold(body: Stack(children: [
        Positioned(
          left: 0,
          bottom: 20,
          width: 60,
          height: 48,
          child: TextButton(
            onPressed: () => clicked++,
            child: const Text('behind'),
          ),
        ),
      ])),
    ));
    KazumiDialog.showToast(message: 'result');
    await tester.pumpAndSettle();
    await tester.tap(find.text('behind'));
    expect(clicked, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('behind'));
    expect(clicked, 2);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('accessibility mode still expires feedback without animation',
      (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          accessibleNavigation: true,
          disableAnimations: true,
        );
    addTearDown(tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      home: const Scaffold(body: Text('home')),
    ));
    KazumiDialog.showToast(
      message: 'accessible result',
      showActionButton: true,
      actionLabel: 'undo',
    );
    await tester.pumpAndSettle();
    expect(find.text('undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('toast expiry leaves an important confirmation dialog open',
      (tester) async {
    await mountApp(tester);
    final dialog = KazumiDialog.show<bool>(
      clickMaskDismiss: false,
      builder: (_) => const AlertDialog(title: Text('confirm deletion')),
    );
    await tester.pumpAndSettle();
    KazumiDialog.showToast(message: 'status only');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('status only'), findsNothing);
    expect(find.text('confirm deletion'), findsOneWidget);
    KazumiDialog.dismiss(popWith: false);
    await tester.pumpAndSettle();
    expect(await dialog, isFalse);
  });

  testWidgets('cancelling a timer only closes its own expiry dialog',
      (tester) async {
    await mountApp(tester);
    final timer = TimedShutdownService();
    timer.start(1);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('定时关闭'), findsOneWidget);

    final second = KazumiDialogHandle<int>();
    final result = KazumiDialog.show<int>(
      handle: second,
      builder: (_) => const AlertDialog(title: Text('unrelated')),
    );
    await tester.pumpAndSettle();
    timer.cancel();
    await tester.pumpAndSettle();
    expect(second.isActive, isTrue);
    expect(find.text('unrelated'), findsOneWidget);
    second.dismiss();
    await tester.pumpAndSettle();
    await result;
  });

  testWidgets('repeating the timer preserves its duration and expiry callback',
      (tester) async {
    await mountApp(tester);
    final timer = TimedShutdownService();
    addTearDown(timer.cancel);
    var expirations = 0;
    timer.start(1, onExpired: () => expirations++);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(expirations, 1);
    await tester.tap(find.text('重复'));
    await tester.pumpAndSettle();
    expect(timer.isActive, isTrue);
    expect(timer.setMinutes, 1);
    expect(find.text('重复'), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(expirations, 2);
    expect(find.text('重复'), findsOneWidget);
    timer.cancel();
    await tester.pumpAndSettle();
  });
}
