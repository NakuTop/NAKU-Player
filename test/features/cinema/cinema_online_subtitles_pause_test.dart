import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:media_kit/media_kit.dart';

class _Player implements Player {
  final events = <String>[];
  Completer<void>? pauseGate;
  int? failPauseAt;
  bool failApply = false;
  int pauses = 0;

  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => const PlayerState();

  @override
  Future<void> pause() async {
    events.add('pause');
    if (++pauses == failPauseAt) throw StateError('pause unavailable');
    await pauseGate?.future;
  }

  @override
  Future<void> play() async => events.add('play');

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    events.add('apply');
    if (failApply) throw const FormatException('native subtitle rejected');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends CinemaOnlineSubtitles {
  _Client(this.events) : super(dio: Dio(), useFallbackCatalog: false);
  final List<String> events;
  Completer<void>? aggregateGate;
  Completer<void>? downloadGate;
  final row = <String, dynamic>{
    'url': 'https://example.com/subtitle.srt',
    'subtitleFileName': 'Test bilingual subtitle.srt',
    'lang': 'zh',
    'bilingual': true,
  };
  int searches = 0;

  @override
  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    events.add('search');
    ++searches;
    onVerified?.call([row]);
    await aggregateGate?.future;
    return CinemaSubtitleCatalogResult([row], {'test': 'verified'});
  }

  @override
  Future<String> download(String url, {String? archiveEntry}) async {
    await downloadGate?.future;
    return '1\n00:00:01,000 --> 00:00:02,000\n中文字幕 English\n';
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Player player,
  _Client client, {
  Future<void> Function(CinemaOnlineSubtitleSelection selection)? onApplied,
  String title = 'Original Show 第十季',
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: CinemaOnlineSubtitlesPanel(
        player: player,
        client: client,
        title: title,
        category: '电视剧',
        episodeName: 'S10E02',
        imdbId: 'tt1844624',
        onApplied: onApplied,
      ),
    ),
  ),
);

Future<void> _search(WidgetTester tester) async {
  await tester.ensureVisible(find.text('聚合搜索字幕'));
  await tester.tap(find.text('聚合搜索字幕'));
  await tester.pump();
  await tester.pump();
}

Future<void> _select(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Test bilingual subtitle.srt'));
  await tester.tap(find.text('Test bilingual subtitle.srt'));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'opening awaits pause; dismissing search never resumes playback',
    (tester) async {
      final player = _Player()..pauseGate = Completer<void>();
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  await showCinemaOnlineSubtitles(context, player);
                  dismissed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(player.events, ['pause']);
      expect(find.byType(CinemaOnlineSubtitlesPanel), findsNothing);
      player.pauseGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CinemaOnlineSubtitlesPanel), findsOneWidget);
      Navigator.of(
        tester.element(find.byType(CinemaOnlineSubtitlesPanel)),
      ).pop();
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
      expect(player.events, ['pause', 'pause']);
    },
  );

  testWidgets('direct panel pauses on open and again before aggregate', (
    tester,
  ) async {
    final player = _Player();
    final client = _Client(player.events);
    addTearDown(client.close);
    await _mount(tester, player, client);
    await tester.pump();
    expect(player.events, ['pause']);
    await _search(tester);
    expect(player.events, ['pause', 'pause', 'search']);
    expect(
      find.byKey(const ValueKey('subtitle-apply-to-season')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    expect(player.events, isNot(contains('play')));
  });

  testWidgets('pause failure stops catalog requests and reports its cause', (
    tester,
  ) async {
    final player = _Player()..failPauseAt = 2;
    final client = _Client(player.events);
    addTearDown(client.close);
    await _mount(tester, player, client);
    await _search(tester);
    expect(client.searches, 0);
    expect(find.textContaining('pause unavailable'), findsOneWidget);
  });

  testWidgets(
    'verified row is selectable during search and callback keeps searched episode snapshot',
    (tester) async {
      final player = _Player();
      final client = _Client(player.events)
        ..aggregateGate = Completer<void>()
        ..downloadGate = Completer<void>();
      addTearDown(client.close);
      final selected = <CinemaOnlineSubtitleSelection>[];
      await _mount(
        tester,
        player,
        client,
        onApplied: (selection) async => selected.add(selection),
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('subtitle-apply-to-season')),
            )
            .value,
        isTrue,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Different Show S04E07',
      );
      await _search(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await _select(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // Fields may change while the chosen subtitle downloads; the selection
      // retains the request that produced its already-verified result.
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(
        find.byType(TextField).first,
        'Changed Later S01E01',
      );
      client.downloadGate!.complete();
      await tester.pumpAndSettle();
      expect(selected, hasLength(1));
      expect(selected.single.query.title, 'Different Show');
      expect(selected.single.query.type, 'series');
      expect(selected.single.query.season, 4);
      expect(selected.single.query.episode, 7);
      expect(selected.single.imdbId, isEmpty);
      expect(selected.single.applyToSeason, isTrue);
      expect(selected.single.row['lang'], 'zh');
      expect(player.events, isNot(contains('play')));
      client.aggregateGate!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unchecked season option is preserved in successful callback', (
    tester,
  ) async {
    final player = _Player();
    final client = _Client(player.events);
    addTearDown(client.close);
    final selected = <CinemaOnlineSubtitleSelection>[];
    await _mount(
      tester,
      player,
      client,
      onApplied: (selection) async => selected.add(selection),
    );
    final checkbox = find.byKey(const ValueKey('subtitle-apply-to-season'));
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await _search(tester);
    await _select(tester);
    await tester.pumpAndSettle();
    expect(selected.single.applyToSeason, isFalse);
    expect(selected.single.imdbId, 'tt1844624');
    expect(selected.single.query.episode, 2);
  });

  testWidgets('failed player apply never saves a season policy', (
    tester,
  ) async {
    final player = _Player()..failApply = true;
    final client = _Client(player.events);
    addTearDown(client.close);
    final selected = <CinemaOnlineSubtitleSelection>[];
    await _mount(
      tester,
      player,
      client,
      onApplied: (selection) async => selected.add(selection),
    );
    await _search(tester);
    await _select(tester);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.textContaining('native subtitle rejected'), findsOneWidget);
    expect(player.events, isNot(contains('play')));
  });

  testWidgets('late catalog completion cannot update a dismissed panel', (
    tester,
  ) async {
    final player = _Player();
    final client = _Client(player.events)..aggregateGate = Completer<void>();
    addTearDown(client.close);
    await _mount(tester, player, client);
    await _search(tester);
    await tester.pumpWidget(const SizedBox());
    client.aggregateGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(player.events, isNot(contains('play')));
  });
}
