import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

/// Opt-in acceptance for the production card path only. No fetch fixtures,
/// title-detail calls or full-rating calls are used by this test.
void main() {
  test(
    'live card-only initial ratings and exact identity resolution',
    () async {
      await _readSystemProxy();
      final directory = await Directory.systemTemp.createTemp(
        'naku-card-ratings-live-',
      );
      final dataset = File('../ratings-live-cache/title.ratings.tsv.gz');
      DateTime? datasetDate;
      if (await dataset.exists()) {
        datasetDate = await dataset.lastModified();
        final copy = await dataset.copy(
          '${directory.path}/title.ratings.tsv.gz',
        );
        // Preserve provenance/freshness; copying must not make yesterday's
        // official dataset look as though it was downloaded just now.
        await copy.setLastModified(datasetDate);
      }
      final repository = CinemaRatingsRepository(directory: directory);
      final samples = <Map<String, Object?>>[];
      final start = DateTime.now();
      try {
        for (final (name, title) in [
          (
            'interstellar_douban_id_only',
            const CinemaTitle(
              id: 'interstellar',
              sourceId: 'live-card-acceptance',
              title: '星际穿越',
              year: '2014',
              doubanId: '1889243',
            ),
          ),
          (
            'interstellar_known_exact_provider_ids',
            const CinemaTitle(
              id: 'interstellar-explicit',
              sourceId: 'live-card-acceptance',
              title: '星际穿越',
              year: '2014',
              doubanId: '1889243',
              imdbId: 'tt0816692',
              rottenTomatoesId: 'm/interstellar_2014',
            ),
          ),
          (
            'mutiny_douban_id_only',
            const CinemaTitle(
              id: 'mutiny',
              sourceId: 'live-card-acceptance',
              title: '怒之杀',
              year: '2026',
              doubanId: '36889088',
            ),
          ),
        ]) {
          final watch = Stopwatch()..start();
          final stages = <Map<String, Object?>>[];
          String? previous;
          void observe() {
            final result = repository.peek(title);
            if (result == null) return;
            final values = {
              for (final rating in result.ratings)
                rating.provider: rating.value,
            };
            final key = jsonEncode(values);
            if (key == previous) return;
            previous = key;
            stages.add({
              'elapsedMs': watch.elapsedMilliseconds,
              'values': values,
            });
          }

          repository.changes.addListener(observe);
          final sample = <String, Object?>{
            'case': name,
            'input': {
              'title': title.title,
              'year': title.year,
              'doubanId': title.doubanId,
              'imdbId': title.imdbId,
              'rottenTomatoesId': title.rottenTomatoesId,
            },
          };
          try {
            final result = await repository.loadForCard(title);
            sample.addAll({
              'identity': result.identity.toJson(),
              'ratings': result.ratings.map((r) => r.toJson()).toList(),
              'message': result.message,
            });
          } catch (error) {
            sample['error'] = error.toString();
          } finally {
            repository.changes.removeListener(observe);
            watch.stop();
            sample.addAll({
              'elapsedMs': watch.elapsedMilliseconds,
              'stages': stages,
            });
            samples.add(sample);
          }
        }
        await File('../ratings-card-1.4-live.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'checkedAt': DateTime.now().toUtc().toIso8601String(),
            'elapsedMs': DateTime.now().difference(start).inMilliseconds,
            'scope':
                'Production loadForCard only, real HTTP and official IMDb dataset; no UI/navigation/playback assertion and no source-score fallback',
            'initialProviderRatingCache': 'empty',
            'initialCrosswalkCache': 'empty',
            'proxy': MacOSSystemProxy.description,
            'copiedOfficialImdbDataset': datasetDate != null,
            'datasetLastModified': datasetDate?.toUtc().toIso8601String(),
            'samples': samples,
          }),
        );
        for (final sample in samples) {
          expect(sample['error'], isNull, reason: sample['case'].toString());
          final ratings = (sample['ratings'] as List).cast<Map>();
          final douban = ratings.singleWhere((r) => r['provider'] == '豆瓣');
          expect(douban['verified'], isTrue, reason: jsonEncode(sample));
          expect(douban['value'], inExclusiveRange(0, 10));
        }
        final exact = (samples[1]['ratings'] as List).cast<Map>();
        for (final provider in ['IMDb', '烂番茄']) {
          final value = exact.singleWhere((r) => r['provider'] == provider);
          expect(value['verified'], isTrue, reason: jsonEncode(samples[1]));
          expect(value['value'], isNotNull);
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('CINEMA_CARD_RATINGS_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _readSystemProxy() async {
  if (!Platform.isMacOS) return;
  final process = await Process.run('/usr/sbin/scutil', ['--proxy']);
  if (process.exitCode != 0) throw StateError('Could not read system proxy');
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
  final exceptions =
      RegExp(
        r'ExceptionsList : <array> \{([^}]+)\}',
        dotAll: true,
      ).firstMatch(text)?.group(1) ??
      '';
  config['ExceptionsList'] = RegExp(
    r'^\s*\d+ : (.+)$',
    multiLine: true,
  ).allMatches(exceptions).map((match) => match.group(1)!.trim()).toList();
  MacOSSystemProxy.setConfiguration(config);
}
