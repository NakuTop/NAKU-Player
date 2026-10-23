import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_resource_availability.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  const path = String.fromEnvironment('NAKU_HOME_LIVE_SOURCE_FILE');
  const evidenceDir = String.fromEnvironment('NAKU_HOME_LIVE_OUTPUT');
  test(
    'real source availability, 4K selection and exact edition ratings',
    () async {
      const proxy = String.fromEnvironment('NAKU_TEST_PROXY');
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
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          if (proxy.isNotEmpty) client.findProxy = (_) => 'PROXY $proxy';
          return client;
        },
      );
      addTearDown(() => dio.close(force: true));
      final sources = (jsonDecode(await File(path).readAsString()) as List)
          .map((s) => CinemaSource.fromJson(Map<String, dynamic>.from(s)))
          .toList();
      final repo = CinemaRepository(dio: dio);
      final resources = CinemaResourceAvailabilityService(repo);
      addTearDown(resources.dispose);
      final directory = Directory(evidenceDir);
      await directory.create(recursive: true);
      final ratings = CinemaRatingsRepository(
        directory: Directory('${directory.path}/ratings-cache'),
      );
      final evidence = <Map<String, dynamic>>[];
      for (final (name, year, id) in [
        ('泰坦尼克号国语4K', '1997', '1292722'),
        ('星际穿越4K', '2014', '1889243'),
      ]) {
        final title = CinemaTitle(
          id: id,
          sourceId: 'douban-discovery',
          title: name,
          year: year,
          category: '电影',
          doubanId: id,
        );
        final found = await resources.check(title, sources);
        expect(found.state, CinemaResourceState.found);
        final selected = orderCinemaVariants(
          found.variants,
          sources.map((s) => s.id),
        ).first;
        if (found.has4K) expect(cinemaVariantQuality(selected), 1);
        final result = await ratings.loadForCard(title);
        expect(
          result.identity.imdbId,
          name.startsWith('泰坦尼克号') ? 'tt0120338' : 'tt0816692',
        );
        expect(result.ratings.where((r) => r.value != null).length, 3);
        expect(result.ratings.every((r) => r.verified), isTrue);
        final row = {
          'title': name,
          'resourceState': found.label,
          'variants': found.variants
              .map((t) => {'title': t.title, 'source': t.sourceId, 'id': t.id})
              .toList(),
          'preferred': selected.title,
          'identity': result.identity.toJson(),
          'message': result.message,
          'ratings': result.ratings.map((r) => r.toJson()).toList(),
        };
        evidence.add(row);
        debugPrint('LIVE_HOME: ${jsonEncode(row)}');
      }
      final discovery = DoubanRepository(dio: dio);
      final catalog = CinemaAggregateCatalogController(
        repository: repo,
        discoveryRepository: discovery,
      );
      addTearDown(catalog.dispose);
      await catalog.load(
        sources: sources,
        kind: CinemaAggregateKind.movies,
        sort: CinemaCatalogSort.popular,
      );
      final recent = catalog.snapshot.items.take(3).toList();
      expect(recent, isNotEmpty);
      final before = recent.map((t) => t.id).toList();
      for (final title in recent) {
        final availability = await resources.check(title, sources);
        final rated = await ratings.loadForCard(title);
        final row = {
          'hotTitle': title.title,
          'state': availability.label,
          'identity': rated.identity.toJson(),
          'message': rated.message,
          'ratings': rated.ratings.map((r) => r.toJson()).toList(),
        };
        evidence.add(row);
        debugPrint('LIVE_HOT_HOME: ${jsonEncode(row)}');
      }
      expect(catalog.snapshot.items.take(3).map((t) => t.id), before);
      await File('${directory.path}/live-evidence.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
          'scope':
              'Production public-source search/detail and official ratings HTTP; resource lines are not media playback verification',
          'results': evidence,
        }),
      );
    },
    skip: path.isEmpty || evidenceDir.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
