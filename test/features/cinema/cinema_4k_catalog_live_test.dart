import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';

void main() {
  const path = String.fromEnvironment('NAKU_4K_LIVE_SOURCE_FILE');
  Dio client() {
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    const proxy = String.fromEnvironment('NAKU_TEST_PROXY');
    d.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final h = HttpClient();
        if (proxy.isNotEmpty) h.findProxy = (_) => 'PROXY $proxy';
        return h;
      },
    );
    return d;
  }

  test(
    'real 4K sources, normalized rating identity and official recent-hot feeds',
    () async {
      final dio = client();
      addTearDown(() => dio.close(force: true));
      final sources = (jsonDecode(await File(path).readAsString()) as List)
          .map((r) => CinemaSource.fromJson(Map<String, dynamic>.from(r)))
          .toList();
      final discovery = DoubanRepository(dio: dio);
      final catalogue = CinemaAggregateCatalogController(
        repository: CinemaRepository(dio: dio),
        discoveryRepository: discovery,
      );
      addTearDown(catalogue.dispose);
      await catalogue.load(sources: sources, kind: CinemaAggregateKind.ultraHd);
      expect(catalogue.snapshot.items, isNotEmpty);
      debugPrint(
        'LIVE_4K: count=${catalogue.snapshot.items.length} sources=${catalogue.snapshot.items.map((t) => t.sourceId).toSet()} titles=${catalogue.snapshot.items.take(4).map((t) => t.title)}',
      );
      final search = CinemaSearchDiscoveryRepository(dio: dio);
      final ratings = CinemaRatingIdentitySearch(
        search: search.searchForIdentity,
      );
      final title = const CinemaTitle(
        id: 'fixture',
        sourceId: 'fixture',
        title: '泰坦尼克号国语4K',
        year: '1997',
        category: '4K电影',
      );
      final rated = await ratings.resolve(title);
      expect(rated.doubanId, '1292722');
      debugPrint('LIVE_4K_RATING: ${rated.title} douban=${rated.doubanId}');
      for (final kind in [
        CinemaAggregateKind.movies,
        CinemaAggregateKind.series,
      ]) {
        await catalogue.load(
          sources: sources,
          kind: kind,
          sort: CinemaCatalogSort.popular,
        );
        expect(catalogue.snapshot.items, isNotEmpty);
        final direct = await discovery.browse(
          kind: kind == CinemaAggregateKind.movies
              ? DoubanKind.movie
              : DoubanKind.tv,
          sort: 'U',
        );
        expect(
          catalogue.snapshot.items.take(5).map((t) => t.id),
          direct.items.take(5).map((t) => t.id),
        );
        debugPrint(
          'LIVE_HOT: $kind ${catalogue.snapshot.items.take(3).map((t) => t.title)}',
        );
      }
    },
    skip: path.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
