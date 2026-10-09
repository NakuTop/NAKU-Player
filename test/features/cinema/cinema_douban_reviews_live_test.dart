import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test('live movie long reviews and explicit TV access status', () async {
    final proxy = Uri.tryParse(Platform.environment['HTTPS_PROXY'] ?? '');
    if (proxy != null && proxy.host.isNotEmpty) {
      MacOSSystemProxy.setConfiguration({
        'HTTPSEnable': 1,
        'HTTPSProxy': proxy.host,
        'HTTPSPort': proxy.port,
      });
    }
    final repo = CinemaDoubanReviewsRepository();
    final results = <Map<String, dynamic>>[];
    for (final id in ['1292052', '36889088', '1393859']) {
      final result = await repo.load(id);
      results.add({
        'subjectId': id,
        'status': result.status.name,
        'count': result.items.length,
        'fetchedAt': result.fetchedAt?.toIso8601String(),
        'items': [
          for (final review in result.items)
            {
              'id': review.id,
              'url': review.url,
              'authorPresent': review.author.isNotEmpty,
              'rating': review.rating,
              'excerptCharacters': review.excerpt.runes.length,
            },
        ],
      });
      await File(
        '../douban-reviews-1.4-live.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
      if (id == '1393859' &&
          result.status == CinemaDoubanReviewsStatus.restricted) {
        // An upstream access restriction is an observed limitation, not proof
        // that TV reviews loaded. Verify the honest fallback separately.
        expect(result.items, isEmpty);
        expect(result.fetchedAt, isNull);
        expect(result.message, contains('官网'));
        expect(result.url, 'https://movie.douban.com/subject/1393859/reviews');
        continue;
      }
      expect(
        result.status,
        CinemaDoubanReviewsStatus.available,
        reason: '$id: ${result.message}',
      );
      expect(result.items, isNotEmpty);
      expect(result.items.length, lessThanOrEqualTo(6));
      expect(
        result.items.every((review) => review.excerpt.runes.length <= 120),
        isTrue,
      );
      expect(
        result.items.every(
          (review) => Uri.parse(review.url).host == 'movie.douban.com',
        ),
        isTrue,
      );
    }
    await File(
      '../douban-reviews-1.4-live.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  }, skip: Platform.environment['NAKU_LIVE_TESTS'] != '1');
}
