import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_mobile_video_controls.dart';
import 'package:kazumi/features/cinema/cinema_mobile_playback_bar.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration()) {
    state = state.copyWith(
      duration: const Duration(minutes: 30),
      position: const Duration(minutes: 2),
    );
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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  for (final width in [288.0, 358.0, 740.0]) {
    testWidgets(
      'touch controls hide, reopen and seek with source/danmaku actions at $width',
      (tester) async {
        final backend = _Backend(), toggle = ValueNotifier(0);
        final calls = <String>[];
        Duration? sought;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: width * 9 / 16,
                  child: CinemaMobileVideoControls(
                    player: _Player(backend),
                    toggle: toggle,
                    onSeek: (value) => sought = value,
                    topBar: [
                      IconButton(
                        tooltip: '返回',
                        onPressed: () {},
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '线路与选集',
                        onPressed: () => calls.add('sources'),
                        icon: const Icon(Icons.list),
                      ),
                      IconButton(
                        tooltip: '弹幕',
                        onPressed: () => calls.add('danmaku'),
                        icon: const Icon(Icons.comment),
                      ),
                    ],
                    bottomBar: [
                      Expanded(
                        child: CinemaMobilePlaybackBar(
                          playing: true,
                          fullscreen: true,
                          position: '02:00',
                          duration: '30:00',
                          resolution: '1920 × 1080',
                          onPlay: () => calls.add('pause'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('线路与选集'));
        await tester.tap(find.byTooltip('弹幕'));
        await tester.tap(find.byTooltip('暂停'));
        expect(calls, ['sources', 'danmaku', 'pause']);
        expect(find.text('1920 × 1080'), findsOneWidget);
        await tester.drag(
          find.byKey(const ValueKey('mobile-video-seek')),
          const Offset(80, 0),
        );
        await tester.pump();
        expect(sought, isNotNull);
        expect(sought!, greaterThan(const Duration(minutes: 2)));
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          tester
              .widget<IgnorePointer>(find.byType(IgnorePointer).last)
              .ignoring,
          true,
        );
        toggle.value++;
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('弹幕'));
        expect(calls.last, 'danmaku');
        await tester.pumpWidget(const SizedBox());
        toggle.dispose();
        await backend.dispose();
      },
    );
  }
}
