import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/features/cinema/cinema_appearance.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

class _Appearance extends CinemaAppearance {
  _Appearance() : super(observeNativeAccessibility: false);
  bool opaque = false;
  @override
  double get effectiveBackgroundOpacity => opaque ? 1 : .47;
  @override
  bool get reduceTransparency => opaque;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> flush() async {}
  void setOpaque() {
    opaque = true;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  setUpAll(() async {
    if (Platform.environment['NAKU_QA_SCREENSHOTS'] == null) return;
    final fonts = FontLoader('.AppleSystemUIFont')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Light.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await fonts.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final fallback = FontLoader('MI_Sans_Regular')
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'));
    await fallback.load();
  });

  test(
    'macOS controls have neutral roles while other platforms retain their palette',
    () {
      final appearance = _Appearance();
      addTearDown(appearance.dispose);
      final mac = CinemaTheme.dataFor(
        appearance,
        platform: TargetPlatform.macOS,
      );
      expect(mac.platform, TargetPlatform.macOS);
      expect(mac.colorScheme.primary, CinemaTheme.controlTint);
      expect(mac.colorScheme.secondary, CinemaTheme.controlTint);
      expect(mac.colorScheme.tertiary, CinemaTheme.controlTint);
      expect(
        mac.checkboxTheme.fillColor!.resolve({WidgetState.selected}),
        CinemaTheme.controlTint,
      );
      expect(
        mac.checkboxTheme.checkColor!.resolve({WidgetState.selected}),
        CinemaTheme.controlInk,
      );
      expect(mac.sliderTheme.activeTrackColor, CinemaTheme.controlTint);
      expect(mac.progressIndicatorTheme.color, CinemaTheme.controlTint);
      expect(
        mac.switchTheme.trackColor!.resolve({WidgetState.selected}),
        isNot(CinemaTheme.copper),
      );
      final android = CinemaTheme.dataFor(
        appearance,
        platform: TargetPlatform.android,
      );
      expect(android.platform, TargetPlatform.android);
      expect(android.colorScheme.primary, CinemaTheme.copper);
      expect(
        android.filledButtonTheme.style!.backgroundColor!.resolve({}),
        CinemaTheme.copper,
      );
    },
  );

  for (final size in [const Size(360, 760), const Size(900, 760)]) {
    testWidgets(
      'settings override an old orange route and retain working controls at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final appearance = _Appearance();
        addTearDown(appearance.dispose);
        final legacy = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.orange,
            brightness: Brightness.dark,
          ),
          platform: TargetPlatform.macOS,
        );
        var hardware = true, autoplay = false, buffer = .5;
        ThemeData? effective;
        await tester.pumpWidget(
          MaterialApp(
            theme: legacy,
            home: RepaintBoundary(
              key: const ValueKey('qa-material-settings'),
              child: ColoredBox(
                color: CinemaTheme.background,
                child: CinemaAppearanceScope(
                  appearance: appearance,
                  child: Theme(
                    data: legacy,
                    child: StatefulBuilder(
                      builder: (context, setState) => SettingsPaneScope(
                        embedded: true,
                        showBackButton: false,
                        onBack: () {},
                        child: SettingsDetailScaffold(
                          title: const Text('播放设置'),
                          body: Builder(
                            builder: (context) {
                              effective = Theme.of(context);
                              return SettingsList(
                                sections: [
                                  SettingsSection(
                                    title: const Text('播放与画质'),
                                    tiles: [
                                      SettingsTile.switchTile(
                                        title: const Text('硬件解码'),
                                        description: const Text('保持清晰与流畅'),
                                        initialValue: hardware,
                                        onToggle: (value) => setState(
                                          () => hardware = value ?? !hardware,
                                        ),
                                      ),
                                      SettingsTile.switchTile(
                                        title: const Text('自动播放下一集'),
                                        initialValue: autoplay,
                                        onToggle: (value) => setState(
                                          () => autoplay = value ?? !autoplay,
                                        ),
                                      ),
                                      SettingsSliderTile(
                                        title: const Text('播放缓存'),
                                        value: buffer,
                                        valueLabel:
                                            '${(buffer * 256).round()} MB',
                                        min: 0,
                                        max: 1,
                                        onChanged: (value) =>
                                            setState(() => buffer = value),
                                      ),
                                    ],
                                  ),
                                  SettingsSection(
                                    title: const Text('弹幕来源'),
                                    tiles: [
                                      CheckboxListTile(
                                        title: const Text('人人视频'),
                                        value: true,
                                        onChanged: (_) {},
                                      ),
                                      CheckboxListTile(
                                        title: const Text('爱一帆'),
                                        value: true,
                                        onChanged: (_) {},
                                      ),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: FilledButton(
                                        onPressed: () {},
                                        child: const Text('完成'),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          DefaultTextStyle.of(tester.element(find.text('完成'))).style.color,
          CinemaTheme.controlInk,
        );
        expect(effective!.colorScheme.primary, CinemaTheme.controlTint);
        expect(
          effective!.colorScheme.primary,
          isNot(legacy.colorScheme.primary),
        );
        await tester.tap(find.text('自动播放下一集'));
        await tester.pumpAndSettle();
        expect(autoplay, true);
        expect(effective!.textTheme.bodyLarge!.color, isNotNull);
        expect(tester.takeException(), isNull);
        final folder = Platform.environment['NAKU_QA_SCREENSHOTS'];
        Future<void> capture(String suffix) async {
          if (folder == null) return;
          await tester.runAsync(() async {
            final boundary =
                tester
                        .element(
                          find.byKey(const ValueKey('qa-material-settings')),
                        )
                        .findRenderObject()
                    as RenderRepaintBoundary;
            final pixels = await boundary.toImage();
            final data = await pixels.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(folder).create(recursive: true);
            await File(
              '$folder/material-settings-${size.width.toInt()}$suffix.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            pixels.dispose();
          });
        }

        await capture('');
        appearance.setOpaque();
        await tester.pumpAndSettle();
        expect(effective!.colorScheme.surface.a, 1);
        expect(effective!.bottomSheetTheme.backgroundColor!.a, 1);
        expect(effective!.dialogTheme.backgroundColor!.a, 1);
        expect(effective!.colorScheme.onSurface, CinemaTheme.text);
        expect(tester.takeException(), isNull);
        await capture('-opaque');
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
