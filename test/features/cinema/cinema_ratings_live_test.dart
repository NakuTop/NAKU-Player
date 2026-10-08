import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'new presets and exact real movie ratings',
    () async {
      if (Platform.isMacOS) {
        final process = await Process.run('/usr/sbin/scutil', ['--proxy']);
        if (process.exitCode != 0) {
          throw StateError('scutil failed: ${process.stderr}');
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
            '^\\s*$key : (.+)'
            r'$',
            multiLine: true,
          ).firstMatch(text)?.group(1)?.trim();
          if (value != null) config[key] = int.tryParse(value) ?? value;
        }
        final exceptionText =
            RegExp(
              r'ExceptionsList : <array> \{([^}]+)\}',
              dotAll: true,
            ).firstMatch(text)?.group(1) ??
            '';
        config['ExceptionsList'] = RegExp(r'^\s*\d+ : (.+)$', multiLine: true)
            .allMatches(exceptionText)
            .map((match) => match.group(1)!.trim())
            .toList();
        MacOSSystemProxy.setConfiguration(config);
      }

      final repository = CinemaRepository();
      final ratings = CinemaRatingsRepository(
        directory: Directory('../ratings-live-cache'),
      );
      final entries = <Map<String, dynamic>>[];
      CinemaTitle? selected;
      for (final id in ['maccms-jisu', 'maccms-ruyi', 'maccms-360']) {
        final source = bundledCinemaSources.firstWhere((s) => s.id == id);
        final result = await repository.search(source, '星际穿越');
        final item = result.items.firstWhere(
          (s) =>
              s.id ==
              const {
                'maccms-jisu': '14306',
                'maccms-ruyi': '16389',
                'maccms-360': '60387',
              }[id],
        );
        final detail = await repository.detail(source, item);
        expect(detail.routes, isNotEmpty);
        expect(detail.doubanId, '1889243');
        selected ??= detail;
        entries.add({
          'source': source.name,
          'id': detail.id,
          'title': detail.title,
          'doubanId': detail.doubanId,
          'sourceDoubanScore': detail.sourceDoubanScore,
          'hits': detail.sourceHits,
          'updated': detail.sourceUpdatedAt?.toIso8601String(),
          'routeCount': detail.routes.length,
        });
      }
      final result = await ratings.load(selected!);
      final evidence = {
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'scope':
            'Real provider HTTP + production parser, no UI or playback assertion',
        'sources': entries,
        'identity': result.identity.toJson(),
        'message': result.message,
        'ratings': result.ratings.map((r) => r.toJson()).toList(),
      };
      await File(
        '../ratings-live-verification.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      expect(result.identity.imdbId, 'tt0816692');
      expect(result.identity.rottenTomatoesId, 'm/interstellar_2014');
      expect(result.ratings[1].verified, isTrue);
      expect(result.ratings[1].value, inInclusiveRange(0, 10));
      expect(result.ratings[2].verified, isTrue);
      expect(result.ratings[2].value, inInclusiveRange(0, 100));
    },
    skip: !const bool.fromEnvironment('CINEMA_RATINGS_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
