import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'live production aggregation includes multiple catalogues and actual 2020 metadata',
    () async {
      final proxy = Uri.tryParse(Platform.environment['HTTPS_PROXY'] ?? '');
      if (proxy != null && proxy.host.isNotEmpty) {
        MacOSSystemProxy.setConfiguration({
          'HTTPSEnable': 1,
          'HTTPSProxy': proxy.host,
          'HTTPSPort': proxy.port,
        });
      }
      final sources = bundledCinemaSources
          .where(
            (source) => const {
              'maccms-modu',
              'maccms-haohua',
              'maccms-jisu',
              'maccms-360',
            }.contains(source.id),
          )
          .toList();
      final controller = CinemaAggregateCatalogController(
        repository: CinemaRepository(),
      );
      addTearDown(controller.dispose);
      final evidence = <String, dynamic>{};
      var progressiveUpdates = 0;
      controller.addListener(() {
        if (controller.snapshot.loading &&
            controller.snapshot.items.isNotEmpty) {
          progressiveUpdates++;
        }
      });
      for (final kind in CinemaAggregateKind.values) {
        for (final year in ['', '2020']) {
          await controller.load(
            sources: sources,
            kind: kind,
            filters: CinemaFilters(year: year),
          );
          final snapshot = controller.snapshot;
          final playable = snapshot.items
              .where((item) => item.sourceId != 'douban-discovery')
              .toList();
          final key = '${kind.name}-${year.isEmpty ? 'latest' : year}';
          evidence[key] = {
            'items': snapshot.items.length,
            'groups': snapshot.groups.length,
            'sourceVariants': playable.length,
            'metadataCards': snapshot.items.length - playable.length,
            'sourceIds': playable.map((item) => item.sourceId).toSet().toList(),
            'years': playable.map((item) => item.year).toSet().toList(),
            'hasMore': snapshot.hasMore,
            'statuses': [
              for (final status in snapshot.sources)
                {
                  'id': status.source.id,
                  'count': status.loadedCount,
                  'error': status.error,
                  'yearUnsupported': status.yearUnsupported,
                },
            ],
            'error': snapshot.error,
          };
          await File('../aggregate-catalog-live.json').writeAsString(
            const JsonEncoder.withIndent(
              '  ',
            ).convert({...evidence, 'progressiveUpdates': progressiveUpdates}),
          );
          expect(
            playable.map((item) => item.sourceId).toSet().length,
            greaterThanOrEqualTo(2),
            reason: '$key: ${jsonEncode(evidence[key])}',
          );
          expect(
            playable.every(
              (item) =>
                  cinemaOrdinaryCategory('${item.category} ${item.genres}'),
            ),
            isTrue,
          );
          if (year.isNotEmpty) {
            expect(playable.every((item) => item.year == year), isTrue);
          }
        }
      }
      expect(progressiveUpdates, greaterThan(4));
    },
    skip: Platform.environment['NAKU_LIVE_CATALOG'] != '1',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
