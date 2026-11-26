import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_show_picker.dart';
import 'package:kazumi/features/cinema/cinema_variety_episode.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

CinemaSource source(CinemaTitle t) => CinemaSource(
  id: t.sourceId,
  name: t.sourceId,
  kind: CinemaSourceKind.maccms,
  url: 'https://${t.sourceId}.example',
);
CinemaTitle guide(String id, List<String> labels, {bool extra = false}) =>
    CinemaTitle(
      id: 'one',
      sourceId: id,
      title: extra ? '旅行节目第四季（加更版）' : '旅行节目第四季',
      category: '大陆综艺',
      year: '2026',
      routes: [
        CinemaRoute(
          name: 'HLS',
          episodes: [
            for (final (i, e) in labels.indexed)
              CinemaEpisode(name: e, url: 'https://$id.example/$i'),
          ],
        ),
      ],
    );
final terse = guide('terse', ['第7期上', '第7期上纯享', '第7期上纯享', '第8期上纯享', '第8期上纯享']);
final dated = guide('dated', [
  '20261121上',
  '20261121上纯享·辨方向',
  '20261121上纯享·猜地名',
  '20261121下纯享·辨方向',
]);
final supplement = guide('bonus', [
  '2026-11-21第七期上纯享·猜地名',
  '20261121第7期上·辨方向纯享',
  '20261121上纯享·猜地名',
  '第7期加更',
  '第7期花絮',
], extra: true);
final bridge = guide('bridge', ['20261121第7期上', '20261121第7期下']);
final works = [terse, dated, supplement, bridge];
final rows = CinemaShowGuide().build(works, source);
final catalogue = CinemaPlaybackCatalogue(
  title: terse,
  source: source(terse),
  variants: works,
  sources: works.map(source),
  repository: CinemaRepository(),
);
void main() {
  test(
    'same-name cuts are resolved by segment, date and part across editions',
    () {
      final cuts = rows
          .where((r) => r.info.section == CinemaShowSection.pure)
          .toList();
      expect(cuts.where((r) => r.label.contains('猜地名')).length, 1);
      expect(cuts.where((r) => r.label.contains('辨方向')).length, 2);
      expect(cuts.any((r) => r.label == '第7期上纯享'), false);
      expect(
        cuts
            .where((r) => r.label.startsWith('第8期上纯享'))
            .map((r) => r.label)
            .toSet()
            .length,
        2,
      );
      final pick = cuts.singleWhere((r) => r.label.contains('猜地名'));
      expect(pick.label, contains('第7期上'));
      final alternatives = catalogue.matching(pick.candidate);
      expect(
        alternatives.map((r) => r.episode.url),
        unorderedEquals([
          'https://dated.example/2',
          'https://bonus.example/0',
          'https://bonus.example/2',
        ]),
      );
      expect(
        catalogue
            .matching(
              cuts.firstWhere((r) => r.label.contains('片段 2')).candidate,
            )
            .length,
        1,
      );
    },
  );
  test('only an evidenced broadcast date maps a numbered half to a date-only source', () {
    final ep = CinemaPlaybackCandidate(
      title: terse,
      source: source(terse),
      routeIndex: 0,
      episodeIndex: 0,
    );
    final matches = catalogue.matching(ep);
    expect(
      matches.where((c) => c.title.key == dated.key).single.episodeIndex,
      0,
    );
    expect(
      matches.any(
        (c) => c.episode.name.contains('下') || c.episode.name.contains('纯享'),
      ),
      false,
    );
  });
  testWidgets(
    'filters, cross-section search and selections keep original source indexes',
    (tester) async {
      CinemaPlaybackCandidate? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaShowPicker(choices: rows, select: (v) => selected = v),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '纯享'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('猜地名').last);
      expect(selected!.episode.name, contains('猜地名'));
      await tester.enterText(find.byType(TextField), '第七期 辨方向');
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      expect(selected!.episode.url, 'https://dated.example/1');
      await tester.tap(find.widgetWithText(ChoiceChip, '正片'));
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的期数或片段'), findsOneWidget);
    },
  );
}
