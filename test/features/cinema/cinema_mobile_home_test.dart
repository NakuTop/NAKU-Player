import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_navigation_preferences.dart';
import 'cinema_aggregated_search_test.dart'
    show CatalogueStub, RatingsStub, modu, sourceA;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  late CinemaNavigationPreferences navigation;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-mobile-home-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [modu, sourceA],
    );
    await store.load();
    navigation = CinemaNavigationPreferences(
      readValue: () => true,
      writeValue: (_) async {},
    );
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    navigation.dispose();
    await directory.delete(recursive: true);
  });
  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets(
      'mobile home returns from search and retains native entries at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final font = FontLoader('MI_Sans_Regular')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
        await tester.runAsync(font.load);
        await tester.runAsync(() async {
          await (FontLoader('Ahem')
                ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf')))
              .load();
          await (FontLoader('.AppleSystemUIFont')
                ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf')))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: CinemaTheme.data.copyWith(
              platform: TargetPlatform.android,
              textTheme: CinemaTheme.data.textTheme.apply(
                fontFamily: 'MI_Sans_Regular',
              ),
            ),
            home: RepaintBoundary(
              key: const ValueKey('capture-home'),
              child: CinemaHomePage(
                mobileLayout: true,
                store: store,
                repository: CatalogueStub(),
                ratingsRepository: RatingsStub(),
                enableSearchDiscovery: false,
                enableWatchTogether: false,
                navigationPreferences: navigation,
                animePageBuilder: (_, active) =>
                    const Center(child: Text('动漫内容')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('cinema-mobile-shell')),
          findsOneWidget,
        );
        for (final label in ['Home Display', '下载内容', '检查更新']) {
          expect(find.byTooltip(label), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('catalog-sort-latest')));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('mobile-search-field'));
        await tester.enterText(field, '星际穿越');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.byTooltip('返回主页'), findsOneWidget);
        await tester.tap(find.byTooltip('返回主页'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('返回主页'), findsNothing);
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['NAKU_MOBILE_SCREENSHOTS'];
        if (output != null) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture-home')),
          );
          final image = (await tester.runAsync(
            () => boundary.toImage(pixelRatio: 1),
          ))!;
          final data = await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.png),
          );
          await tester.runAsync(() async {
            await Directory(output).create(recursive: true);
            await File(
              '$output/home-${size.width.toInt()}.png',
            ).writeAsBytes(data!.buffer.asUint8List());
          });
          image.dispose();
        }
        expect(
          find.byKey(const ValueKey('mobile-destination-anime')),
          findsNothing,
        );
        await tester.tap(find.byTooltip('更多功能'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('NAS 影视'),
          120,
          scrollable: find
              .descendant(
                of: find.byType(Drawer),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.text('NAS 影视'), findsWidgets);
        expect(
          find.byKey(const ValueKey('cinema-destination-anime')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
