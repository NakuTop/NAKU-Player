import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

/// Explicit opt-in only:
/// flutter test --dart-define=CINEMA_LIVE_TEST=true test/features/cinema/cinema_live_smoke_test.dart
/// Verifies live catalogue data, not video playback or rights/quality claims.
void main() {
  // This is an opt-in network test, not a widget test. Initializing the
  // widget binding would replace HttpClient with its synthetic HTTP 400 stub.
  const enabled = bool.fromEnvironment('CINEMA_LIVE_TEST');
  test(
    'live presets expose categories, movie/series search and playable-route metadata',
    () async {
      // Flutter's test runner has no Runner native channel. Read the same
      // current OS proxy configuration without modifying network settings.
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
      final evidence = <Map<String, dynamic>>[];
      final failures = <String>[];
      for (final source in bundledCinemaSources.where(
        (item) => item.kind == CinemaSourceKind.maccms,
      )) {
        final record = <String, dynamic>{
          'source': source.name,
          'url': source.url,
        };
        try {
          final categories = await repository.categories(source);
          expect(categories, isNotEmpty);
          record['categories'] = categories.length;
          record['categoryExamples'] = categories
              .take(4)
              .map(
                (item) => {
                  'id': item.id,
                  'name': item.name,
                  'parentId': item.parentId,
                },
              )
              .toList();
          final searches = <Map<String, dynamic>>[];
          for (final keyword in ['星际穿越', '怪奇物语']) {
            final result = await repository.search(source, keyword);
            expect(
              result.items,
              isNotEmpty,
              reason: '${source.name}: $keyword',
            );
            final item = result.items.firstWhere(
              (item) =>
                  !RegExp('解说|预告|科学').hasMatch(item.title) &&
                  (keyword != '怪奇物语' || item.category.contains('剧')),
            );
            final details = await repository.detail(source, item);
            expect(details.routes, isNotEmpty, reason: '${source.name}详情无播放路线');
            expect(
              details.routes.any((route) => route.episodes.isNotEmpty),
              isTrue,
            );
            searches.add({
              'keyword': keyword,
              'resultCount': result.total,
              'selectedTitle': details.title,
              'id': details.id,
              'category': details.category,
              'sourceRemarks': details.remarks,
              'routes': details.routes
                  .map(
                    (route) => {
                      'name': route.name,
                      'episodes': route.episodes.length,
                      'firstEpisodeHost': Uri.parse(
                        route.episodes.first.url,
                      ).host,
                      'firstEpisodeDirect': route.episodes.first.isDirect,
                    },
                  )
                  .toList(),
            });
          }
          record['searches'] = searches;
          record['status'] = 'passed';
        } catch (error) {
          record['status'] = 'failed';
          record['error'] = '$error';
          failures.add('${source.name}: $error');
        }
        evidence.add(record);
      }
      final file = File('../cinema-live-smoke.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'verifiedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'networkMode': Platform.isMacOS
              ? MacOSSystemProxy.description
              : 'environment proxy/default transport',
          'scope':
              'HTTP catalogue/category/search/detail metadata only; no video playback assertion',
          'results': evidence,
        }),
      );
      expect(failures, isEmpty, reason: failures.join('\n'));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
