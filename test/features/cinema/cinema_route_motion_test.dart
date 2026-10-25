import 'package:flutter/cupertino.dart' show CupertinoPageTransition;
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/features/cinema/cinema_route_motion.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/pages/download/download_page_module.dart';

class _EmptyDownloads implements DownloadController {
  int refreshes = 0;
  @override
  final recordKeys = ObservableList<String>();
  @override
  void refreshRecords() => refreshes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'real Modular download route reveals softly and preserves home on return',
    (tester) async {
      final downloads = _EmptyDownloads();
      final input = TextEditingController(text: '保留搜索状态');
      addTearDown(input.dispose);
      final module = createModule(
        register: (c) {
          c.addInstance<DownloadController>(downloads);
          c.route(
            '/',
            child: (context, state) => Scaffold(
              body: Column(
                children: [
                  TextField(controller: input),
                  TextButton(
                    onPressed: () => context.pushNamed('/settings/download/'),
                    child: const Text('打开下载'),
                  ),
                ],
              ),
            ),
          );
          c.module(
            createModule(
              path: '/settings',
              register: (s) => s.module(downloadModule),
            ),
          );
        },
      );
      await tester.pumpWidget(
        ModularApp(
          module: module,
          child: Builder(
            builder: (context) => MaterialApp.router(
              theme: CinemaTheme.data,
              routerConfig: ModularApp.routerConfigOf(context),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 45));
      expect(find.byType(DownloadPage), findsOneWidget);
      expect(find.byType(CinemaRouteMotion), findsOneWidget);
      expect(find.byType(CupertinoPageTransition), findsNothing);
      expect(find.byType(SlideTransition), findsNothing);
      expect(
        tester
            .widget<ImageFiltered>(
              find.descendant(
                of: find.byType(CinemaRouteMotion),
                matching: find.byType(ImageFiltered),
              ),
            )
            .enabled,
        isTrue,
      );
      expect(downloads.refreshes, 1);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageFiltered>(
              find.descendant(
                of: find.byType(CinemaRouteMotion),
                matching: find.byType(ImageFiltered),
              ),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadPage), findsNothing);
      expect(find.text('保留搜索状态'), findsOneWidget);
      expect(downloads.refreshes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets('reduced motion keeps the same child state and no active blur', (
    tester,
  ) async {
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 260),
    );
    addTearDown(animation.dispose);
    var taps = 0;
    Future<void> show(bool reduced) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: CinemaRouteMotion(
            animation: animation,
            child: TextButton(onPressed: () => taps++, child: const Text('继续')),
          ),
        ),
      ),
    );
    await show(false);
    animation.forward();
    await tester.pump(const Duration(milliseconds: 40));
    await show(true);
    expect(
      tester.widget<ImageFiltered>(find.byType(ImageFiltered)).enabled,
      isFalse,
    );
    await tester.tap(find.text('继续'));
    expect(taps, 1);
    await tester.pumpAndSettle();
    final frames = tester.binding.transientCallbackCount;
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, frames);
    await tester.pumpWidget(const SizedBox());
  });
}
