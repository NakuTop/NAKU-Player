import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_detail_comparison.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'live detail probes every available source before creating any player',
    () async {
      final process = await Process.run('/usr/sbin/scutil', ['--proxy']);
      final config = <String, dynamic>{};
      for (final key in [
        'HTTPEnable',
        'HTTPProxy',
        'HTTPPort',
        'HTTPSEnable',
        'HTTPSProxy',
        'HTTPSPort',
      ]) {
        final value = RegExp(
          '^\\s*$key : (.+)\$',
          multiLine: true,
        ).firstMatch(process.stdout.toString())?.group(1)?.trim();
        if (value != null) config[key] = int.tryParse(value) ?? value;
      }
      MacOSSystemProxy.setConfiguration(config);
      final repository = CinemaRepository();
      final query = Platform.environment['NAKU_DETAIL_QUERY'] ?? '生化危机：爆发夜';
      final sources = bundledCinemaSources
          .where(
            (s) => const {
              'maccms-juliang',
              'maccms-haohua',
              'maccms-jisu',
              'maccms-guangsu',
              'maccms-zuid',
            }.contains(s.id),
          )
          .toList();
      final titles = <CinemaTitle>[];
      final searchErrors = <String, String>{};
      await Future.wait(
        sources.map((source) async {
          try {
            final page = await repository.search(source, query);
            final matches = page.items
                .where(
                  (t) =>
                      t.title.contains(query.split('：').last) &&
                      !t.title.contains('解说'),
                )
                .toList();
            if (matches.isNotEmpty) titles.add(matches.first);
          } catch (error) {
            searchErrors[source.id] = error.runtimeType.toString();
          }
        }),
      );
      expect(titles.length, greaterThanOrEqualTo(3));
      final first = titles.firstWhere(
        (t) => t.sourceId == 'maccms-juliang',
        orElse: () => titles.first,
      );
      final comparison = CinemaDetailComparison(
        title: first,
        source: sources.firstWhere((s) => s.id == first.sourceId),
        variants: titles,
        sources: sources,
        repository: repository,
      );
      addTearDown(comparison.dispose);
      final watch = Stopwatch()..start();
      await comparison.start();
      final rows = [
        for (final title in comparison.catalogue.variants)
          {
            'source': title.sourceId,
            'category': comparison.catalogue.loaded(title)?.category,
            'labels': comparison.catalogue
                .loaded(title)
                ?.routes
                .map((r) => r.episodes.map((e) => e.name).toList())
                .toList(),
            'routes': comparison.candidates
                .where((c) => c.title.key == title.key)
                .length,
            'attempted': comparison.candidates
                .where(
                  (c) =>
                      c.title.key == title.key &&
                      comparison.results.containsKey(c.key),
                )
                .length,
            'displayed': comparison.forVariant(title) == null
                ? null
                : {
                    'ok': comparison
                        .results[comparison.forVariant(title)!.key]
                        ?.ok,
                    'width': comparison
                        .results[comparison.forVariant(title)!.key]
                        ?.width,
                    'height': comparison
                        .results[comparison.forVariant(title)!.key]
                        ?.height,
                    'mbps': comparison
                        .results[comparison.forVariant(title)!.key]
                        ?.mbps,
                    'reason': comparison
                        .results[comparison.forVariant(title)!.key]
                        ?.reason,
                  },
            'catalogueError': comparison.catalogue.errors[title.key],
          },
      ];
      final evidence = {
        'elapsedMs': watch.elapsedMilliseconds,
        'searchErrors': searchErrors,
        'sources': rows,
      };
      final output = Platform.environment['NAKU_DETAIL_PROBE_REPORT'];
      if (output != null) {
        await File(
          output,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      }
      // ignore: avoid_print
      print(jsonEncode(evidence));
      expect(
        rows.every(
          (row) =>
              (row['attempted'] as int) > 0 || row['catalogueError'] != null,
        ),
        isTrue,
      );
      expect(
        rows
            .where((row) => (row['displayed'] as Map?)?['width'] != null)
            .length,
        greaterThanOrEqualTo(3),
      );
    },
    skip: Platform.environment['NAKU_LIVE_DETAIL_PROBE'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
