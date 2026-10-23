import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  const output = String.fromEnvironment('NAKU_V2_RELEASE_LIVE_OUTPUT');
  test(
    'real unnumbered US series, season subtitles, ratings and reviews',
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
      final root = Directory(output)..createSync(recursive: true);
      final cache = Directory('$output/ratings-cache')
        ..createSync(recursive: true);
      const seed = String.fromEnvironment('NAKU_IMDB_SEED');
      if (seed.isNotEmpty) {
        final source = File(seed);
        final target = await source.copy('${cache.path}/title.ratings.tsv.gz');
        await target.setLastModified(await source.lastModified());
      }
      final discovery = CinemaSearchDiscoveryRepository();
      final identities = CinemaRatingIdentitySearch(
        search: discovery.searchForIdentity,
      );
      final ratings = CinemaRatingsRepository(directory: cache);
      final reviews = CinemaDoubanReviewsRepository();
      final rows = <Map<String, dynamic>>[];
      for (final (name, year, id, provided) in [
        ('老友记', '1994', '1393859', false),
        ('权力的游戏', '2011', '3016187', false),
        ('怪奇物语', '2016', '26359270', false),
        ('美国恐怖故事：双面 第十季', '2021', '30301247', true),
        ('老友记 第十季', '2003', '3286552', true),
        ('黑袍纠察队 第四季', '2024', '35926862', true),
      ]) {
        final watch = Stopwatch()..start();
        final source = CinemaTitle(
          id: id,
          sourceId: 'public-source-shaped',
          title: name,
          year: year,
          category: '欧美剧',
          doubanId: provided ? id : '',
        );
        final bound = await identities.resolve(source);
        final result = await ratings.load(bound);
        final publicReviews = bound.doubanId.isEmpty
            ? null
            : await reviews.load(bound.doubanId);
        rows.add({
          'title': name,
          'year': year,
          'provided_id': provided,
          'resolved_id': bound.doubanId,
          'expected_id': id,
          'elapsed_ms': watch.elapsedMilliseconds,
          'identity': result.identity.toJson(),
          'ratings': result.ratings.map((r) => r.toJson()).toList(),
          'review_status': publicReviews?.status.name,
          'review_count': publicReviews?.items.length,
          'review_ids': publicReviews?.items.map((r) => r.id).toList(),
        });
        await File('${root.path}/evidence.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'checkedAt': DateTime.now().toUtc().toIso8601String(),
            'results': rows,
          }),
        );
        debugPrint(
          'LIVE_V2: $name id=${bound.doubanId} scores=${result.ratings.map((r) => r.value).toList()} reviews=${publicReviews?.items.length}',
        );
        expect(
          bound.doubanId,
          id,
          reason:
              'The actual source-shaped title must resolve without manual binding',
        );
        expect(
          result.ratings.every((r) => r.value != null && r.verified),
          isTrue,
          reason: '$name: ${result.message}',
        );
        expect(
          publicReviews?.items,
          isNotEmpty,
          reason: '$name: ${publicReviews?.message}',
        );
      }
    },
    skip: output.isEmpty,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
