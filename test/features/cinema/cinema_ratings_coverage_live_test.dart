import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  const output = String.fromEnvironment('NAKU_RATINGS_AUDIT_OUTPUT');
  const seed = String.fromEnvironment('NAKU_RATINGS_AUDIT_DATASET');
  const inputs = String.fromEnvironment('NAKU_RATINGS_AUDIT_INPUT');
  const proxy = String.fromEnvironment('NAKU_TEST_PROXY');
  test(
    'audit real recent films and series with official rating requests',
    () async {
      if (proxy.isNotEmpty) {
        final parts = proxy.split(':');
        MacOSSystemProxy.setConfiguration({
          'HTTPEnable': 1,
          'HTTPProxy': parts.first,
          'HTTPPort': int.parse(parts.last),
          'HTTPSEnable': 1,
          'HTTPSProxy': parts.first,
          'HTTPSPort': int.parse(parts.last),
        });
      }
      final directory = Directory(output)..createSync(recursive: true);
      final cache = Directory('${directory.path}/ratings-cache')
        ..createSync(recursive: true);
      if (seed.isNotEmpty &&
          !File('${cache.path}/title.ratings.tsv.gz').existsSync()) {
        final source = File(seed);
        final copied = await source.copy('${cache.path}/title.ratings.tsv.gz');
        await copied.setLastModified(await source.lastModified());
      }
      final titles = <CinemaTitle>[];
      if (inputs.isNotEmpty) {
        titles.addAll(
          (jsonDecode(await File(inputs).readAsString()) as List).map(
            (r) => CinemaTitle.fromJson(Map<String, dynamic>.from(r)),
          ),
        );
        // Replaying a frozen homepage sample still loads today's real feeds,
        // as the app does, so official feed fallback is exercised honestly.
        final discovery = DoubanRepository();
        for (final kind in DoubanKind.values) {
          await discovery.browse(kind: kind, sort: 'U', count: 12);
        }
      } else {
        final discovery = DoubanRepository();
        for (final kind in DoubanKind.values) {
          final feed = await discovery.browse(kind: kind, sort: 'U', count: 12);
          titles.addAll(
            feed.items.map(
              (t) => CinemaTitle(
                id: t.id,
                sourceId: 'douban-discovery',
                title: t.title,
                year: t.year,
                aliases: t.originalTitle,
                category: kind == DoubanKind.movie ? '电影' : '电视剧',
                doubanId: t.id,
                sourceDoubanScore: t.score,
              ),
            ),
          );
        }
        await File('${directory.path}/inputs.json').writeAsString(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(titles.map((t) => t.toJson()).toList()),
        );
      }
      final requests = <Map<String, dynamic>>[];
      final ratings = CinemaRatingsRepository(
        directory: cache,
        fetch: (uri, limit) async {
          try {
            final bytes = await CinemaRatingsRepository.fetchOfficial(
              uri,
              limit,
            );
            if (uri.host == 'm.douban.com' &&
                uri.path.startsWith('/rexxar/api/v2/movie/')) {
              final data = jsonDecode(utf8.decode(bytes)) as Map;
              requests.add({
                'url': uri.toString(),
                'id': data['id'],
                'type': data['type'],
                'subjectUrl': data['url'],
                'year': data['year'],
              });
            }
            return bytes;
          } catch (error) {
            requests.add({'url': uri.toString(), 'error': error.toString()});
            rethrow;
          }
        },
      );
      final rows = <Map<String, dynamic>>[];
      final watch = Stopwatch()..start();
      Future<void>
      save() => File('${directory.path}/evidence.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
          'scope':
              'Production official provider HTTP; exact input identities; IMDb gzip reused with its original timestamp when supplied',
          'elapsedMs': watch.elapsedMilliseconds,
          'requests': requests,
          'results': rows,
        }),
      );
      // Two complete work requests at a time, mirroring the bounded poster queue.
      for (var i = 0; i < titles.length; i += 2) {
        await Future.wait(
          titles.skip(i).take(2).map((title) async {
            final result = await ratings.load(title);
            rows.add({
              'title': title.title,
              'year': title.year,
              'category': title.category,
              'input': title.toJson(),
              'identity': result.identity.toJson(),
              'message': result.message,
              'ratings': result.ratings.map((r) => r.toJson()).toList(),
            });
            debugPrint(
              'RATINGS_AUDIT: ${title.title} | ${result.ratings.map((r) => '${r.provider}:${r.value ?? r.note}').join(' / ')} | ${result.message}',
            );
          }),
        );
        await save();
      }
      expect(rows.length, titles.length);
      expect(rows, isNotEmpty);
    },
    skip: output.isEmpty,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
