import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'official exact Mutiny 2026 score, metadata, star distribution and recommendations',
    () async {
      if (Platform.isMacOS) {
        final process = await Process.run('/usr/sbin/scutil', ['--proxy']);
        if (process.exitCode != 0) {
          throw StateError('Could not read system proxy');
        }
        final text = process.stdout.toString();
        final config = <String, dynamic>{};
        for (final key in [
          'HTTPEnable',
          'HTTPProxy',
          'HTTPPort',
          'HTTPSEnable',
          'HTTPSProxy',
          'HTTPSPort',
          'ExcludeSimpleHostnames',
        ]) {
          final value = RegExp(
            '^\\s*$key : (.+)\$',
            multiLine: true,
          ).firstMatch(text)?.group(1)?.trim();
          if (value != null) config[key] = int.tryParse(value) ?? value;
        }
        MacOSSystemProxy.setConfiguration(config);
      }
      final temp = await Directory.systemTemp.createTemp('naku-douban-live-');
      try {
        final catalogue = CinemaRepository();
        final source = bundledCinemaSources.firstWhere(
          (s) => s.id == 'maccms-haohua',
        );
        final search = await catalogue.search(source, '怒之杀');
        final candidate = search.items.singleWhere(
          (t) => t.title == '怒之杀' && t.year == '2026',
        );
        final title = await catalogue.detail(source, candidate);
        expect(title.doubanId, '36889088');
        final repository = CinemaRatingsRepository(directory: temp);
        final scores = await repository.loadForCard(title);
        final douban = scores.ratings.singleWhere((r) => r.provider == '豆瓣');
        final details = await repository.loadDoubanDetails(title);
        expect(douban.verified, isTrue);
        expect(douban.value, inExclusiveRange(0, 10));
        expect(details.doubanId, '36889088');
        expect(details.title, '怒之杀');
        expect(details.year, '2026');
        expect(details.originalTitle, 'Mutiny');
        expect(details.ratingCount, greaterThan(0));
        expect(details.durations, contains('95分钟'));
        expect(details.aliases, contains('反叛'));
        expect(
          details.releaseDates.any((s) => s.startsWith('2026-09-04')),
          isTrue,
        );
        expect(details.stars.map((s) => s.stars), [5, 4, 3, 2, 1]);
        expect(details.recommendations, isNotEmpty);
        expect(
          details.recommendations.every((r) => r.doubanId != details.doubanId),
          isTrue,
        );
        await File('../ratings-1.2-live-verification.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'checkedAt': DateTime.now().toUtc().toIso8601String(),
            'scope':
                'Production Dart HTTP, public source and official Douban; no cookies, private key, browser verification or playback claim',
            'source': {
              'sourceId': title.sourceId,
              'id': title.id,
              'title': title.title,
              'year': title.year,
              'doubanId': title.doubanId,
              'reportedScore': title.sourceDoubanScore,
            },
            'rating': douban.toJson(),
            'details': details.toJson(),
          }),
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('CINEMA_DOUBAN_DETAILS_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
