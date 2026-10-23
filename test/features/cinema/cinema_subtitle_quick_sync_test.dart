import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_auto_sync.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_sync_panel.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _Player implements Player {
  Duration position = const Duration(seconds: 20);
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state =>
      PlayerState(position: position, playing: true, rate: 1.5);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync extends CinemaSubtitleAutoSync {
  _Sync(super.player) : super(media: () => '');
  int runs = 0, cancels = 0;
  @override
  Future<void> run({CinemaSubtitleCue? anchorCue}) async {
    runs++;
  }

  @override
  void cancel() {
    cancels++;
    super.cancel();
  }
}

void main() {
  for (final width in [360.0, 680.0]) {
    testWidgets(
      'visible quick calibration and searchable dialogue work at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final player = _Player(), saved = <CinemaSubtitleTiming>[];
        final session = cinemaExternalSubtitleState(player);
        session.select(
          '1\n00:00:10,000 --> 00:00:12,000\n第一句自写对白\nFirst spoken line\n\n'
              '2\n00:00:20,000 --> 00:00:23,000\n第二句自写对白\nSecond spoken line\n\n'
              '3\n00:00:30,000 --> 00:00:33,000\n第三句自写对白\nThird spoken line\n',
          'fixture.srt',
          '1',
          0,
        );
        session.saveTiming = (_, timing) async {
          saved.add(timing);
        };
        final sync = _Sync(player);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: CinemaSubtitleQuickSyncPanel(
                  player: player,
                  autoSync: sync,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('subtitle-quick-auto')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('subtitle-quick-earlier')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('subtitle-quick-later')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('subtitle-quick-auto')));
        await tester.pump();
        expect(sync.runs, 1);
        await tester.tap(find.byKey(const ValueKey('subtitle-quick-earlier')));
        await tester.pump();
        expect(session.delay, -.5);
        expect(saved.last.offsetSeconds, -.5);
        await tester.tap(find.byKey(const ValueKey('subtitle-quick-later')));
        await tester.pump();
        expect(session.delay, 0);
        expect(saved.last.offsetSeconds, 0);
        await tester.enterText(
          find.byKey(const ValueKey('subtitle-quick-search')),
          'first spoken',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('subtitle-quick-cue-0')));
        await tester.pump();
        final align = find.byKey(const ValueKey('subtitle-quick-align-cue'));
        await tester.ensureVisible(align);
        await tester.tap(align);
        await tester.pump();
        expect(session.delay, 10);
        expect(saved.last.offsetSeconds, 10);
        expect(player.state.position, const Duration(seconds: 20));
        expect(player.state.playing, true);
        expect(player.state.rate, 1.5);
        expect(session.firstSyncAnchor?.subtitle, const Duration(seconds: 10));
        expect(sync.cancels, greaterThanOrEqualTo(3));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        sync.dispose();
        await session.close();
      },
    );
  }
  testWidgets('sample slider selects and saves 5 through 20 seconds', (
    tester,
  ) async {
    final player = _Player();
    cinemaExternalSubtitleState(player).select(
      '1\n00:00:01,000 --> 00:00:03,000\nself authored line\n',
      'fixture.srt',
      '1',
      0,
    );
    int? saved;
    final sync = CinemaSubtitleAutoSync(
      player,
      media: () => '',
      onSampleSecondsChanged: (value) async {
        saved = value;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CinemaSubtitleQuickSyncPanel(player: player, autoSync: sync),
          ),
        ),
      ),
    );
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('subtitle-sample-seconds')),
    );
    expect(slider.min, 5);
    expect(slider.max, 20);
    expect(slider.divisions, 15);
    slider.onChanged!(20);
    slider.onChangeEnd!(20);
    await tester.pump();
    expect(sync.sampleSeconds, 20);
    expect(saved, 20);
    expect(find.text('20 秒'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    sync.dispose();
    await closeCinemaExternalSubtitles(player);
  });
}
