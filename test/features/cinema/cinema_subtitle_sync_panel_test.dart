import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_appearance.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_sync_panel.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _Player implements Player {
  Duration position = const Duration(seconds: 90);
  double rate = 1.25;
  bool playing = false;
  final seeks = <Duration>[];
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state =>
      PlayerState(position: position, rate: rate, playing: playing);
  @override
  Future<void> play() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    position = value;
  }

  @override
  Future<void> setRate(double value) async => rate = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _fixture =
    '1\n00:00:01,000 --> 00:00:04,000\n第一处对白\nFirst spoken line\n'
    '\n2\n00:01:01,000 --> 00:01:04,000\n第二处对白\nSecond spoken line\n'
    '\n3\n00:02:01,000 --> 00:02:04,000\n第三处对白\nThird spoken line\n';

Widget _host(_Player player, {bool showPanel = true}) => MaterialApp(
  home: Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (showPanel)
          SingleChildScrollView(child: CinemaSubtitleSyncPanel(player: player)),
        CinemaExternalSubtitleOverlay(
          player: player,
          appearance: const CinemaSubtitleAppearance(),
        ),
      ],
    ),
  ),
);

CinemaExternalSubtitleState _select(_Player player) {
  final session = cinemaExternalSubtitleState(player);
  session.select(_fixture, 'self-authored.srt', '1', 0);
  return session;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _searchAndSelect(
  WidgetTester tester,
  String query,
  String line,
) async {
  final search = find.byKey(const ValueKey('subtitle-cue-search'));
  await tester.ensureVisible(search);
  await tester.enterText(search, query);
  await tester.pump();
  final row = find.ancestor(
    of: find.text(line),
    matching: find.byType(ListTile),
  );
  expect(row, findsOneWidget);
  await _tap(tester, row);
}

Finder _rendered(String text) => find.descendant(
  of: find.byType(CinemaExternalSubtitleOverlay),
  matching: find.text(text),
);

void main() {
  testWidgets(
    'searching a dialogue and aligning it moves captions to the current picture',
    (tester) async {
      final player = _Player();
      final session = _select(player);
      await tester.pumpWidget(_host(player));
      expect(_rendered('第一处对白\nFirst spoken line'), findsNothing);

      await _searchAndSelect(
        tester,
        'FIRST SPOKEN',
        '第一处对白\nFirst spoken line',
      );
      await _tap(tester, find.text('对齐到当前画面'));

      expect(session.delay, 89);
      expect(session.firstSyncAnchor?.subtitle, const Duration(seconds: 1));
      expect(session.firstSyncAnchor?.media, const Duration(seconds: 90));
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      session.updatePosition(const Duration(seconds: 93));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsNothing);
      session.updatePosition(const Duration(seconds: 90, milliseconds: 250));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );

  testWidgets(
    'slow replay aligns to its adjusted start after listening has ended',
    (tester) async {
      // The viewer heard the first words before pausing at 90 seconds.
      final player = _Player();
      final session = _select(player);
      await tester.pumpWidget(_host(player));
      await _searchAndSelect(
        tester,
        'First spoken',
        '第一处对白\nFirst spoken line',
      );
      final align = find.byKey(const ValueKey('subtitle-replay-align'));
      expect(tester.widget<FilledButton>(align).onPressed, isNull);

      await _tap(tester, find.byKey(const ValueKey('subtitle-replay-play')));
      expect(player.seeks, [const Duration(seconds: 87)]);
      expect(player.rate, .75);
      expect(player.playing, isTrue);
      expect(find.text('重听这段'), findsOneWidget);

      await _tap(tester, find.text('起点延后 0.25 秒'));
      expect(player.seeks.last, const Duration(milliseconds: 87250));
      expect(player.rate, .75);
      expect(player.playing, isTrue);
      await tester.pump(const Duration(milliseconds: 60));
      player.position = const Duration(seconds: 90);
      session.updatePosition(player.position);
      await tester.pump(const Duration(milliseconds: 60));
      expect(player.playing, isFalse);
      expect(player.rate, 1.25);
      expect(player.position, const Duration(seconds: 90));

      await _tap(tester, align);
      expect(session.delay, 86.25);
      expect(session.firstSyncAnchor?.subtitle, const Duration(seconds: 1));
      expect(
        session.firstSyncAnchor?.media,
        const Duration(milliseconds: 87250),
      );
      expect(player.position, const Duration(seconds: 90));
      expect(player.playing, isFalse);
      expect(player.rate, 1.25);
      session.updatePosition(const Duration(milliseconds: 87249));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsNothing);
      session.updatePosition(const Duration(milliseconds: 87250));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );

  testWidgets(
    'closing the panel preserves the first anchor for later drift calibration',
    (tester) async {
      final player = _Player();
      final session = _select(player);
      await tester.pumpWidget(_host(player));
      await _searchAndSelect(
        tester,
        'First spoken',
        '第一处对白\nFirst spoken line',
      );
      await _tap(tester, find.text('对齐到当前画面'));
      final firstAnchor = session.firstSyncAnchor;

      await tester.pumpWidget(_host(player, showPanel: false));
      player.position = const Duration(seconds: 147, milliseconds: 600);
      session.updatePosition(player.position);
      await tester.pumpWidget(_host(player));
      expect(session.firstSyncAnchor, firstAnchor);
      await _searchAndSelect(tester, '第二处', '第二处对白\nSecond spoken line');
      final secondButton = find.widgetWithText(OutlinedButton, '第二处校正漂移');
      expect(tester.widget<OutlinedButton>(secondButton).onPressed, isNotNull);
      await _tap(tester, secondButton);

      expect(session.timing.value.scale, closeTo(.96, 1e-12));
      expect(session.delay, closeTo(89.04, 1e-9));
      expect(session.firstSyncAnchor, firstAnchor);
      expect(_rendered('第二处对白\nSecond spoken line'), findsOneWidget);
      session.updatePosition(const Duration(seconds: 90));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      session.updatePosition(const Duration(seconds: 205, milliseconds: 200));
      await tester.pump();
      expect(_rendered('第三处对白\nThird spoken line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );

  testWidgets(
    'reset restores the source timeline and clears the saved anchor',
    (tester) async {
      final player = _Player();
      final session = _select(player);
      session.firstSyncAnchor = (
        subtitle: const Duration(seconds: 1),
        media: const Duration(seconds: 90),
      );
      session.setTiming(
        const CinemaSubtitleTiming(scale: .96, offsetSeconds: 89.04),
      );
      await tester.pumpWidget(_host(player));
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      await _tap(tester, find.text('重置对齐'));
      expect(session.firstSyncAnchor, isNull);
      expect(session.timing.value.scale, 1);
      expect(session.delay, 0);
      expect(_rendered('第一处对白\nFirst spoken line'), findsNothing);
      final secondButton = find.widgetWithText(OutlinedButton, '第二处校正漂移');
      expect(tester.widget<OutlinedButton>(secondButton).onPressed, isNull);
      session.updatePosition(const Duration(seconds: 1));
      await tester.pump();
      expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );

  testWidgets('a failed alignment leaves no invalid first anchor behind', (
    tester,
  ) async {
    final player = _Player()..position = const Duration(hours: 7);
    final session = _select(player);
    await tester.pumpWidget(_host(player));
    await _searchAndSelect(tester, 'First spoken', '第一处对白\nFirst spoken line');
    await _tap(tester, find.text('对齐到当前画面'));
    expect(find.text('字幕偏移应在前后 6 小时以内'), findsOneWidget);
    expect(session.firstSyncAnchor, isNull);
    expect(session.delay, 0);
    final secondButton = find.widgetWithText(OutlinedButton, '第二处校正漂移');
    expect(tester.widget<OutlinedButton>(secondButton).onPressed, isNull);

    player.position = const Duration(seconds: 90);
    session.updatePosition(player.position);
    await _tap(tester, find.text('对齐到当前画面'));
    final validAnchor = session.firstSyncAnchor;
    expect(validAnchor?.media, const Duration(seconds: 90));
    expect(session.delay, 89);
    player.position = const Duration(hours: 7);
    session.updatePosition(player.position);
    await _tap(tester, find.text('对齐到当前画面'));
    expect(find.text('字幕偏移应在前后 6 小时以内'), findsOneWidget);
    expect(session.firstSyncAnchor, validAnchor);
    expect(session.delay, 89);
    expect(session.timing.value.scale, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await session.close();
  });

  testWidgets(
    'invalid whole offsets display an error without changing captions or timing',
    (tester) async {
      final player = _Player();
      final session = _select(player);
      session.setDelay(89);
      await tester.pumpWidget(_host(player));
      for (final input in ['not seconds', '', 'NaN', '21600.1', '-21600.1']) {
        final field = find.byType(TextField).first;
        await tester.ensureVisible(field);
        await tester.enterText(field, input);
        await _tap(tester, find.byTooltip('应用偏移'));
        expect(
          find.text(
            input.isEmpty || input == 'not seconds'
                ? '请输入秒数'
                : '字幕偏移应在前后 6 小时以内',
          ),
          findsOneWidget,
        );
        expect(
          session.delay,
          89,
          reason: 'Input $input must not modify timing',
        );
        expect(session.timing.value.scale, 1);
        expect(_rendered('第一处对白\nFirst spoken line'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await session.close();
    },
  );
}
