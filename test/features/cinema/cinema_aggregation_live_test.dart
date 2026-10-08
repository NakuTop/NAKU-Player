import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'live multi-source movies and series group without dropping variants',
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
      final evidence = <Map<String, dynamic>>[];
      for (final keyword in ['星际穿越', '流人']) {
        final items = <CinemaTitle>[];
        final failures = <String>[];
        for (final id in [
          'maccms-modu',
          'maccms-jisu',
          'maccms-ruyi',
          'maccms-360',
        ]) {
          final source = bundledCinemaSources.firstWhere((s) => s.id == id);
          try {
            final page = await repository.search(source, keyword);
            items.addAll(page.items);
          } catch (error) {
            failures.add('${source.name}: $error');
          }
        }
        final groups = groupCinemaTitles(items);
        evidence.add({
          'keyword': keyword,
          'rawItems': items.length,
          'cards': groups.length,
          'sourceFailures': failures,
          'groups': groups
              .map(
                (g) => {
                  'title': g.representative.title,
                  'preferredSource': g.representative.sourceId,
                  'variants': g.variants
                      .map(
                        (v) => {
                          'title': v.title,
                          'source': v.sourceId,
                          'id': v.id,
                          'year': v.year,
                          'category': v.category,
                          'doubanId': v.doubanId,
                        },
                      )
                      .toList(),
                },
              )
              .toList(),
        });
        expect(
          groups.expand((g) => g.variants).length,
          items.map((v) => v.key).toSet().length,
        );
        final work = groups
            .where(
              (g) => keyword == '星际穿越'
                  ? g.representative.doubanId == '1889243' &&
                        !g.representative.category.contains('解说')
                  : g.representative.title
                        .replaceAll(' ', '')
                        .contains('流人第一季'),
            )
            .toList();
        await File(
          '../aggregation-live-partial.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        expect(work, hasLength(1), reason: keyword);
        expect(work.single.variants.length, greaterThanOrEqualTo(3));
        expect(work.single.representative.sourceId, 'maccms-modu');
      }
      await File('../aggregation-live-verification.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'at': DateTime.now().toUtc().toIso8601String(),
          'scope': 'Production search and grouping only; not UI/playback proof',
          'queries': evidence,
        }),
      );
    },
    skip: !const bool.fromEnvironment('CINEMA_GROUPING_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
