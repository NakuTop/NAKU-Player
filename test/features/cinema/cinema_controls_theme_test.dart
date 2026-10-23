import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/utils/dispose_safe_notifer.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> setRate(double value) async {
    state = state.copyWith(rate: value);
    rateController.add(value);
  }
}

class _Player implements Player {
  _Player(this.backend);
  final _Backend backend;
  @override
  PlayerState get state => backend.state;
  @override
  PlayerStream get stream => backend.stream;
  @override
  Future<void> setRate(double value) => backend.setRate(value);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Controller implements VideoController {
  _Controller(this.player);
  @override
  final Player player;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoState implements VideoState {
  _VideoState(Player player) : widget = Video(controller: _Controller(player));
  @override
  final Video widget;
  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      'test video state';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Toolbar extends StatelessWidget {
  const _Toolbar();
  @override
  Widget build(BuildContext context) => Row(
    children: MaterialDesktopVideoControlsTheme.of(
      context,
    ).normal.bottomButtonBar,
  );
}

void main() {
  testWidgets('an open speed menu survives desktop controls hiding', (
    tester,
  ) async {
    final backend = _Backend();
    final player = _Player(backend);
    final video = _VideoState(player);
    final contextNotifier = DisposeSafeNotifier<BuildContext?>(null);
    final parameters = ValueNotifier(
      VideoViewParameters(
        width: null,
        height: null,
        fit: BoxFit.contain,
        fill: Colors.black,
        alignment: Alignment.center,
        aspectRatio: null,
        filterQuality: FilterQuality.low,
        controls: NoVideoControls,
        subtitleViewConfiguration: const SubtitleViewConfiguration(),
      ),
    );
    final theme = MaterialDesktopVideoControlsThemeData(
      visibleOnMount: true,
      controlsHoverDuration: const Duration(seconds: 1),
      shiftSubtitlesOnControlsVisibilityChange: false,
      displaySeekBar: false,
      automaticallyImplySkipNextButton: false,
      automaticallyImplySkipPreviousButton: false,
      primaryButtonBar: const [],
      bottomButtonBar: [
        PopupMenuButton<double>(
          tooltip: '实际桌面倍速',
          onSelected: player.setRate,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 1, child: Text('正常速度')),
            PopupMenuItem(value: 2, child: Text('测试两倍速')),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MaterialDesktopVideoControlsTheme(
            normal: theme,
            fullscreen: theme,
            child: VideoStateInheritedWidget(
              state: video,
              contextNotifier: contextNotifier,
              videoViewParametersNotifier: parameters,
              child: MaterialDesktopVideoControls(video),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('实际桌面倍速'));
    await tester.pumpAndSettle();
    // The real controls remove their toolbar after the hover deadline. A
    // mock toolbar cannot expose the lost PopupMenuButton callback.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byTooltip('实际桌面倍速'), findsOneWidget);
    await tester.tap(find.text('测试两倍速'));
    await tester.pumpAndSettle();
    expect(backend.state.rate, 2);
    await tester.pumpWidget(const SizedBox());
    contextNotifier.dispose();
    parameters.dispose();
    await backend.dispose();
  });

  testWidgets(
    'mounted toolbar updates enabled episodes and selected speed without replacing video',
    (tester) async {
      var ready = false;
      var rate = 1.0;
      var episodes = 0;
      late StateSetter update;
      const toolbar = _Toolbar();
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              final theme = MaterialDesktopVideoControlsThemeData(
                bottomButtonBar: [
                  IconButton(
                    tooltip: '下一集',
                    onPressed: ready ? () => episodes++ : null,
                    icon: const Icon(Icons.skip_next),
                  ),
                  Text('$rate×'),
                ],
              );
              return MaterialDesktopVideoControlsTheme(
                normal: theme,
                fullscreen: theme,
                child: toolbar,
              );
            },
          ),
        ),
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.skip_next),
            )
            .onPressed,
        isNull,
      );
      update(() {
        ready = true;
        rate = 1.5;
      });
      await tester.pump();
      expect(find.text('1.5×'), findsOneWidget);
      await tester.tap(find.byTooltip('下一集'));
      expect(episodes, 1);
    },
  );
}
