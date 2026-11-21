import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'compact title resolves exact Dangal film sources through their detail IDs',
    () async {
      final repository = CinemaRepository();
      const ids = {'maccms-juliang', 'maccms-haohua', 'maccms-ruyi'};
      final sources = {
        ...bundledCinemaSources,
        ...cinema030SourcePack.sources,
      }.where((s) => ids.contains(s.id)).toList();
      const anchor = CinemaTitle(
        id: '26387939',
        sourceId: 'douban-discovery',
        title: '摔跤吧！爸爸',
        year: '2016',
        doubanId: '26387939',
        category: '电影',
      );
      final pages = await Future.wait(
        sources.map((s) => repository.search(s, '摔跤吧爸爸')),
      );
      final group = groupCinemaTitles([
        anchor,
        ...pages.expand((page) => page.items),
      ]).first;
      for (final source in sources) {
        final entries = group.variants.where((v) => v.sourceId == source.id);
        expect(entries, isNotEmpty, reason: source.name);
        final detail = await repository.detail(source, entries.first);
        expect(detail.routes.any((r) => r.episodes.isNotEmpty), isTrue);
        expect(detail.category, isNot(contains('解说')));
        stdout.writeln(
          'SEARCH ${source.name} ${detail.title} ${detail.year} · ${entries.length} 条目 · ${detail.routes.length} 线路',
        );
      }
      expect(sources.map((s) => s.id).toSet(), ids);
    },
    skip: Platform.environment['NAKU_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'live Chinese English titles and actor aliases resolve real public credits',
    () async {
      final proxy = Uri.tryParse(Platform.environment['HTTPS_PROXY'] ?? '');
      if (proxy != null && proxy.host.isNotEmpty) {
        MacOSSystemProxy.setConfiguration({
          'HTTPSEnable': 1,
          'HTTPSProxy': proxy.host,
          'HTTPSPort': proxy.port,
        });
      }
      final repository = CinemaSearchDiscoveryRepository();
      final evidence = <Map<String, Object?>>[];
      for (final query in [
        'Interstellar',
        '星际穿越',
        'Jason Statham',
        '杰森斯坦森',
        '杰森·斯坦森',
        'Tom Hanks',
        '汤姆·汉克斯',
        'Leonardo DiCaprio',
      ]) {
        final watch = Stopwatch()..start();
        final result = await repository.search(query);
        evidence.add({
          'query': query,
          'actorId': result.celebrityId,
          'actor': result.celebrityName,
          'count': result.titles.length,
          'nextStart': result.nextStart,
          'hasMore': result.hasMore,
          'message': result.message,
          'elapsedMs': watch.elapsedMilliseconds,
          'titles': result.titles
              .map(
                (t) => {
                  'id': t.id,
                  'title': t.title,
                  'year': t.year,
                  'score': t.score,
                  'aliases': t.metadata.aliases,
                },
              )
              .toList(),
        });
        // Persist partial observations too, so a later upstream failure remains explicit.
        await File(
          '../search-1.5-live.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        debugPrint(
          '$query: ${result.celebrityId} ${result.titles.length} titles; ${result.message}',
        );
        if (['Interstellar', '星际穿越'].contains(query)) {
          final title = result.titles.singleWhere((t) => t.id == '1889243');
          expect(title.title, '星际穿越');
          expect(title.year, '2014');
          expect(title.metadata.aliases, contains('Interstellar'));
          if (title.metadata.sourceDoubanScore == null) {
            expect(result.message, contains('评分将在稍后重试'));
          } else {
            expect(title.metadata.sourceDoubanScore, greaterThan(0));
          }
        } else {
          expect(result.titles, isNotEmpty, reason: query);
          expect(result.celebrityId, isNotEmpty, reason: query);
          if (query.contains('斯坦森') || query == 'Jason Statham') {
            expect(result.celebrityName, '杰森·斯坦森');
            expect(result.celebrityId, anyOf('1049484', 'wikidata:Q169963'));
          }
        }
      }
      final actor = await repository.search('Jason Statham');
      final more = await repository.actorWorks(
        actor.celebrityId,
        actor.celebrityName,
        start: actor.nextStart,
      );
      expect(more.nextStart, greaterThan(actor.nextStart));
      expect(more.titles, isNotEmpty);
    },
    skip: Platform.environment['NAKU_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
