import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_reviews.dart';

Map<String, dynamic> review(
  String id, {
  String subject = '1292052',
  String type = 'movie',
}) => {
  'id': id,
  'type': 'review',
  'subject': {'id': subject, 'type': type},
  'title': '影评$id',
  'user': {'name': '作者$id'},
  'abstract': '这是一段测试长影评摘要。',
  'rating': {'max': 5, 'value': 4},
};
List<int> response(List<Object> reviews) =>
    utf8.encode(jsonEncode({'reviews': reviews}));

void main() {
  test(
    'only exact-subject long reviews are displayed with bounded plain excerpts and safe links',
    () {
      final parsed = CinemaDoubanReviewsRepository.parse(
        '1292052',
        jsonEncode({
          'reviews': [
            {...review('1'), 'type': 'interest'},
            review('2', subject: '1393859'),
            {...review('3'), 'title': ''},
            {
              ...review('3'),
              'url': 'https://foreign.example/stolen',
              'abstract': '<b>摘要</b> <script>不应显示</script> ${'😀' * 150}',
              'is_spoiler': true,
            },
            review('3'),
            review('4', type: 'tv'),
            {
              ...review('5'),
              'rating': {'max': 10, 'value': 8},
            },
            {
              ...review('6'),
              'rating': {'max': 5, 'value': 0},
            },
            {
              ...review('7'),
              'rating': {'max': 5, 'value': 7},
            },
            review('8'),
            review('9'),
          ],
        }),
      );
      expect(parsed.items.map((r) => r.id), ['3', '4', '5', '6', '7', '8']);
      expect(parsed.items.first.url, 'https://movie.douban.com/review/3/');
      expect(parsed.items.first.author, '作者3');
      expect(parsed.items.first.rating, 4);
      expect(parsed.items.first.spoiler, isTrue);
      expect(parsed.items.first.excerpt.runes.length, 120);
      expect(parsed.items.first.excerpt, endsWith('…'));
      expect(parsed.items.first.excerpt, isNot(contains('不应显示')));
      expect(
        parsed.items.skip(2).take(3).every((r) => r.rating == null),
        isTrue,
      );
      expect(parsed.status, CinemaDoubanReviewsStatus.available);
      expect(parsed.url, 'https://movie.douban.com/subject/1292052/reviews');
    },
  );

  test(
    'genuine empty, malformed response and a different subject are distinct',
    () {
      expect(
        CinemaDoubanReviewsRepository.parse('1292052', '{"reviews":[]}').status,
        CinemaDoubanReviewsStatus.empty,
      );
      for (final body in [
        '{"interests":[]}',
        '{"reviews":[{"type":"interest"}]}',
        jsonEncode({
          'reviews': [review('1', subject: '1393859')],
        }),
      ]) {
        expect(
          () => CinemaDoubanReviewsRepository.parse('1292052', body),
          throwsA(
            isA<CinemaDoubanReviewsException>().having(
              (e) => e.status,
              'status',
              CinemaDoubanReviewsStatus.invalidResponse,
            ),
          ),
        );
      }
      for (final body in ['<html>请输入验证码</html>', '{"msg":"login required"}']) {
        expect(
          () => CinemaDoubanReviewsRepository.parse('1292052', body),
          throwsA(
            isA<CinemaDoubanReviewsException>().having(
              (e) => e.status,
              'status',
              CinemaDoubanReviewsStatus.restricted,
            ),
          ),
        );
      }
    },
  );

  test('invalid IDs never request a guessed title or arbitrary URL', () {
    var calls = 0;
    final repo = CinemaDoubanReviewsRepository(
      fetch: (_, _) async {
        calls++;
        return response([]);
      },
    );
    for (final id in [
      '',
      'Movie Title',
      '../1292052',
      '1292052?x=1',
      'https://example.com',
      '01292052',
    ]) {
      expect(() => repo.load(id), throwsFormatException);
    }
    expect(calls, 0);
  });

  test(
    'one bounded review endpoint is coalesced and cached independently of detail metadata',
    () async {
      var calls = 0;
      final pending = Completer<List<int>>();
      final repo = CinemaDoubanReviewsRepository(
        fetch: (uri, maxBytes) {
          calls++;
          expect(uri.host, 'm.douban.com');
          expect(uri.path, '/rexxar/api/v2/movie/1292052/reviews');
          expect(uri.queryParameters, {'start': '0', 'count': '6'});
          expect(maxBytes, 512 * 1024);
          return pending.future;
        },
      );
      final first = repo.load('1292052');
      final second = repo.load('1292052', force: true);
      expect(calls, 1);
      pending.complete(response([review('1')]));
      expect(identical(await first, await second), isTrue);
      await repo.load('1292052');
      expect(calls, 1);
    },
  );

  test(
    'refresh failure retains old reviews and original fetched time, with a failure cooldown',
    () async {
      var now = DateTime.utc(2026, 10, 9);
      var fail = false, calls = 0;
      final repo = CinemaDoubanReviewsRepository(
        now: () => now,
        fetch: (_, _) async {
          calls++;
          if (fail) {
            throw const CinemaDoubanReviewsException(
              CinemaDoubanReviewsStatus.restricted,
              '公开访问受限',
            );
          }
          return response([review('1')]);
        },
      );
      final old = await repo.load('1292052');
      now = now.add(const Duration(hours: 7));
      fail = true;
      final stale = await repo.load('1292052');
      expect(stale.items.single.id, '1');
      expect(stale.status, CinemaDoubanReviewsStatus.restricted);
      expect(stale.stale, isTrue);
      expect(stale.fetchedAt, old.fetchedAt);
      expect(stale.message, contains('保留上次影评'));
      await repo.load('1292052');
      expect(calls, 2);
      now = now.add(const Duration(minutes: 6));
      fail = false;
      final restored = await repo.load('1292052');
      expect(restored.stale, isFalse);
      expect(restored.fetchedAt, now);
      expect(calls, 3);
    },
  );

  test(
    'empty results expire after thirty minutes and explicit force bypasses cache',
    () async {
      var now = DateTime.utc(2026, 10, 9), calls = 0;
      final repo = CinemaDoubanReviewsRepository(
        now: () => now,
        fetch: (_, _) async {
          calls++;
          return response([]);
        },
      );
      final empty = await repo.load('1292052');
      expect(empty.status, CinemaDoubanReviewsStatus.empty);
      await repo.load('1292052');
      expect(calls, 1);
      now = now.add(const Duration(minutes: 31));
      await repo.load('1292052');
      expect(calls, 2);
      await repo.load('1292052', force: true);
      expect(calls, 3);
    },
  );

  test(
    'failed loading is unavailable rather than a fake empty review list',
    () async {
      for (final error in [
        const SocketException('offline'),
        TimeoutException('timeout'),
      ]) {
        var calls = 0;
        final repo = CinemaDoubanReviewsRepository(
          fetch: (_, _) async {
            calls++;
            throw error;
          },
        );
        final result = await repo.load('1292052');
        expect(result.status, CinemaDoubanReviewsStatus.unavailable);
        expect(result.items, isEmpty);
        expect(result.fetchedAt, isNull);
        expect(result.message, isNotEmpty);
        await repo.load('1292052');
        expect(calls, 1);
      }
    },
  );

  test('oversized body is rejected before parsing', () async {
    final repo = CinemaDoubanReviewsRepository(
      fetch: (_, limit) async => List.filled(limit + 1, 32),
    );
    final result = await repo.load('1292052');
    expect(result.status, CinemaDoubanReviewsStatus.invalidResponse);
    expect(result.items, isEmpty);
  });

  test(
    'different subjects have at most two in-flight review requests',
    () async {
      var active = 0, peak = 0, calls = 0;
      final repo = CinemaDoubanReviewsRepository(
        fetch: (uri, _) async {
          active++;
          calls++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 3));
          active--;
          return response([review('1', subject: uri.pathSegments[4])]);
        },
      );
      final results = await Future.wait([
        for (var i = 1000; i < 1010; i++) repo.load('$i'),
      ]);
      expect(peak, 2);
      expect(calls, 10);
      expect(
        results.every(
          (result) => result.status == CinemaDoubanReviewsStatus.available,
        ),
        isTrue,
      );
    },
  );

  test(
    'session cache is bounded and retains recently accessed subjects',
    () async {
      var calls = 0;
      final repo = CinemaDoubanReviewsRepository(
        fetch: (uri, _) async {
          calls++;
          return response([review('1', subject: uri.pathSegments[4])]);
        },
      );
      for (var i = 1000; i < 1080; i++) {
        await repo.load('$i');
      }
      await repo.load('1000');
      await repo.load('1080');
      await repo.load('1000');
      expect(calls, 81);
      await repo.load('1001');
      expect(calls, 82);
    },
  );
}
