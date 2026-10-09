import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_rating_title_resolver.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'current homepage sample rating coverage, hydration and detail comparison',
    () async {
      MacOSSystemProxy.setConfiguration({
        'HTTPSEnable': 1,
        'HTTPSProxy': '127.0.0.1',
        'HTTPSPort': 7897,
      });
      final phase = Platform.environment['NAKU_RATINGS_PHASE'] ?? 'before';
      final raw = jsonDecode(
        await File('../ratings-home-sources.json').readAsString(),
      );
      final sources = (raw['sources'] as List)
          .map((s) => CinemaSource.fromJson(Map<String, dynamic>.from(s)))
          .where((s) => s.enabled && s.kind == CinemaSourceKind.maccms)
          .toList();
      final catalogue = CinemaRepository();
      final groups = <Map<String, dynamic>>[];
      if (phase == 'after') {
        final before = jsonDecode(
          await File('../ratings-home-before.json').readAsString(),
        );
        groups.addAll(
          (before['samples'] as List).map(
            (item) => Map<String, dynamic>.from(item),
          ),
        );
      } else {
        final controller = CinemaAggregateCatalogController(
          repository: catalogue,
        );
        try {
          for (final kind in CinemaAggregateKind.values) {
            await controller.load(sources: sources, kind: kind);
            for (final group in controller.snapshot.groups.take(6)) {
              groups.add({
                'kind': kind.name,
                'title': group.representative.copyWith(routes: []).toJson(),
                'variants': group.variants
                    .map((t) => t.copyWith(routes: []).toJson())
                    .toList(),
              });
            }
          }
        } finally {
          controller.dispose();
        }
      }
      final directory = await Directory.systemTemp.createTemp(
        'naku-ratings-catalog-',
      );
      final dataset = File('../ratings-live-cache/title.ratings.tsv.gz');
      if (await dataset.exists()) {
        final copied = await dataset.copy(
          '${directory.path}/title.ratings.tsv.gz',
        );
        await copied.setLastModified(await dataset.lastModified());
      }
      final ratings = CinemaRatingsRepository(directory: directory);
      final discovery = CinemaSearchDiscoveryRepository();
      final identityDiscovery = <String, dynamic>{};
      final identitySearch = CinemaRatingIdentitySearch(
        search: (query) async {
          final result = await discovery.search(query);
          identityDiscovery[query] = {
            'message': result.message,
            'candidates': [
              for (final item in result.titles)
                {
                  'id': item.id,
                  'title': item.title,
                  'originalTitle': item.originalTitle,
                  'aliases': item.aliases,
                  'year': item.year,
                  'kind': item.kind,
                  'identityVerified': item.identityVerified,
                },
            ],
          };
          return result;
        },
      );
      final resolver = CinemaRatingTitleResolver(
        repository: catalogue,
        discoverTitle: phase == 'after' ? identitySearch.resolve : null,
        sourceFor: (id) => sources.where((s) => s.id == id).firstOrNull,
      );
      final watch = Stopwatch()..start();
      final rows = <Map<String, dynamic>>[];
      final timers = <Timer>[];
      final checkpoints = <Map<String, dynamic>>[];
      final firstVisible = <String, Map<String, int>>{};
      final titles = groups
          .map(
            (g) => CinemaTitle.fromJson(Map<String, dynamic>.from(g['title'])),
          )
          .toList();
      void observe() {
        for (final title in titles) {
          final result = ratings.peek(title);
          if (result == null) continue;
          final first = firstVisible.putIfAbsent(title.key, () => {});
          for (final score in result.ratings) {
            if (score.value != null) {
              first.putIfAbsent(
                score.provider,
                () => watch.elapsedMilliseconds,
              );
            }
          }
        }
      }

      Map<String, dynamic> counts() => {
        for (final provider in ['豆瓣', 'IMDb', '烂番茄'])
          provider: titles
              .where((t) => ratings.scoreFor(t, provider) != null)
              .length,
      };
      Future<void> save() => File('../ratings-home-$phase.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'phase': phase,
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
          'scope':
              'First six actual aggregate homepage groups from movies and series; installed enabled-source configuration; production HTTP, cold ratings/identity cache, only official IMDb gzip reused with original timestamp',
          'enabledSourceIds': sources.map((s) => s.id).toList(),
          'samples': groups,
          'elapsedMs': watch.elapsedMilliseconds,
          'checkpoints': checkpoints,
          'cardCoverage': counts(),
          'identityDiscovery': identityDiscovery,
          'rows': rows,
        }),
      );
      ratings.changes.addListener(observe);
      for (final seconds in [1, 3, 10, 30, 60]) {
        timers.add(
          Timer(
            Duration(seconds: seconds),
            () => checkpoints.add({
              'elapsedMs': watch.elapsedMilliseconds,
              ...counts(),
            }),
          ),
        );
      }
      try {
        // Model mounted visible cards: requests start together, repository gates
        // source and provider work. Do not select only high-coverage classics.
        await Future.wait(
          titles.map((title) async {
            final row = <String, dynamic>{
              'key': title.key,
              'title': title.title,
              'year': title.year,
              'source': title.sourceId,
              'category': title.category,
              'inputIds': [
                title.doubanId,
                title.imdbId,
                title.rottenTomatoesId,
              ],
              'sourceScore': title.sourceDoubanScore,
            };
            try {
              final result = await ratings.loadForCard(
                title,
                resolveTitle: (item) async {
                  final hydrated = await resolver.resolve(item);
                  row['hydratedIds'] = [
                    hydrated.doubanId,
                    hydrated.imdbId,
                    hydrated.rottenTomatoesId,
                  ];
                  return hydrated;
                },
              );
              row.addAll({
                'card': {
                  'identity': result.identity.toJson(),
                  'message': result.message,
                  'ratings': result.ratings.map((r) => r.toJson()).toList(),
                },
                'cardCompletedMs': watch.elapsedMilliseconds,
                'firstScoreMs': firstVisible[title.key],
              });
            } catch (error) {
              row['cardError'] = error.toString();
            }
            rows.add(row);
            await save();
          }),
        );
        checkpoints.add({
          'elapsedMs': watch.elapsedMilliseconds,
          'complete': true,
          ...counts(),
        });
        // Check the exact source-detail path only after initial card coverage has
        // been captured, to reveal IDs/cache publication differences honestly.
        var next = 0;
        Future<void> detailWorker() async {
          while (next < titles.length) {
            final title = titles[next++];
            final row = rows.singleWhere((r) => r['key'] == title.key);
            try {
              final source = sources.singleWhere((s) => s.id == title.sourceId);
              final detail = await catalogue.detail(source, title);
              final result = await ratings.load(detail);
              row['detail'] = {
                'inputIds': [
                  detail.doubanId,
                  detail.imdbId,
                  detail.rottenTomatoesId,
                ],
                'identity': result.identity.toJson(),
                'message': result.message,
                'ratings': result.ratings.map((r) => r.toJson()).toList(),
              };
            } catch (error) {
              row['detailError'] = error.toString();
            }
            await save();
          }
        }

        await Future.wait([detailWorker(), detailWorker()]);
        await save();
        expect(rows.length, titles.length);
        expect(rows.length, greaterThan(0));
      } finally {
        for (final timer in timers) {
          timer.cancel();
        }
        ratings.changes.removeListener(observe);
        resolver.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['NAKU_RATINGS_CATALOG_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
