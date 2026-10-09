import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_rating_title_resolver.dart';

const source = CinemaSource(
  id: 'source',
  name: 'Fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.test/api',
);
CinemaTitle title(String id) => CinemaTitle(
  id: id,
  sourceId: source.id,
  title: '作品$id',
  year: '2020',
  category: '剧情片',
);
CinemaTitle change(CinemaTitle value, Map<String, dynamic> fields) =>
    CinemaTitle.fromJson({...value.toJson(), ...fields});
CinemaTitle enriched(CinemaTitle value) => change(value, {
  'doubanId': '1292052',
  'imdbId': 'tt0111161',
  'sourceDoubanScore': 7.4,
});

class Repository extends CinemaRepository {
  final calls = <String>[];
  final pending = <({CinemaTitle title, Completer<CinemaTitle> result})>[];
  bool delayed = false, fail = false;
  CinemaTitle Function(CinemaTitle)? response;
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    calls.add(title.id);
    if (fail) throw const CinemaSourceException('offline');
    if (delayed) {
      final result = Completer<CinemaTitle>();
      pending.add((title: title, result: result));
      return result.future;
    }
    return (response ?? enriched)(title);
  }
}

void main() {
  test('hydrates without changing card fields, coalesces and caches', () async {
    final repo = Repository();
    final resolver = CinemaRatingTitleResolver(
      repository: repo,
      sourceFor: (_) => source,
    );
    final original = change(title('1'), {
      'imdbId': 'tt0111161',
      'poster': 'https://poster.test/1.jpg',
      'remarks': '高清',
    });
    final results = await Future.wait([
      resolver.resolve(original),
      resolver.resolve(original),
    ]);
    expect(repo.calls, ['1']);
    expect(results.first.doubanId, '1292052');
    expect(results.first.imdbId, original.imdbId);
    expect(results.first.title, original.title);
    expect(results.first.poster, original.poster);
    expect(results.first.remarks, original.remarks);
    await resolver.resolve(original);
    expect(repo.calls, ['1']);
    resolver.dispose();
  });

  test(
    'cache stores source metadata rather than the previous caller score',
    () async {
      final repo = Repository();
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => source,
      );
      final original = change(title('1'), {'sourceDoubanScore': 8.8});
      expect((await resolver.resolve(original)).sourceDoubanScore, 8.8);
      expect((await resolver.resolve(title('1'))).sourceDoubanScore, 7.4);
      expect(repo.calls, ['1']);
      resolver.dispose();
    },
  );

  test(
    'limits concurrency and rejects removed sources before draining queue',
    () async {
      final repo = Repository()..delayed = true;
      CinemaSource? enabled = source;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => enabled,
      );
      final futures = [
        for (var i = 1; i <= 3; i++) resolver.resolve(title('$i')),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(repo.calls, ['1', '2']);
      enabled = null;
      for (final entry in repo.pending) {
        entry.result.complete(enriched(entry.title));
      }
      final results = await Future.wait(futures);
      expect(results.every((r) => r.doubanId.isEmpty), isTrue);
      expect(repo.calls, ['1', '2']);
      resolver.dispose();
    },
  );

  test(
    'failed lookup cools down, cache expires, known ID skips source request',
    () async {
      var now = DateTime.utc(2026);
      final repo = Repository()..fail = true;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => source,
        now: () => now,
      );
      await resolver.resolve(title('1'));
      await resolver.resolve(title('1'));
      await resolver.resolve(change(title('2'), {'doubanId': '1292052'}));
      expect(repo.calls, ['1']);
      now = now.add(const Duration(minutes: 31));
      repo.fail = false;
      expect((await resolver.resolve(title('1'))).doubanId, '1292052');
      expect(repo.calls, ['1', '1']);
      now = now.add(const Duration(minutes: 31));
      await resolver.resolve(title('1'));
      expect(repo.calls, ['1', '1', '1']);
      resolver.dispose();
    },
  );

  test(
    'source URL and headers invalidate cache; header order alone does not',
    () async {
      final repo = Repository();
      var current = source.copyWith(
        requestHeaders: {
          'Accept': 'application/json',
          'Referer': 'https://a.test/',
        },
      );
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => current,
      );
      await resolver.resolve(title('1'));
      current = current.copyWith(
        requestHeaders: {
          'Referer': 'https://a.test/',
          'Accept': 'application/json',
        },
      );
      await resolver.resolve(title('1'));
      expect(repo.calls, ['1']);
      current = current.copyWith(url: 'https://changed.test/api');
      await resolver.resolve(title('1'));
      current = current.copyWith(
        requestHeaders: {'Referer': 'https://b.test/'},
      );
      await resolver.resolve(title('1'));
      expect(repo.calls, ['1', '1', '1']);
      current = current.copyWith(enabled: false);
      expect((await resolver.resolve(title('1'))).doubanId, isEmpty);
      expect(repo.calls, ['1', '1', '1']);
      resolver.dispose();
    },
  );

  test(
    'source change during response prevents publishing or caching old IDs',
    () async {
      final repo = Repository()..delayed = true;
      var current = source;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => current,
      );
      final old = resolver.resolve(title('1'));
      await Future<void>.delayed(Duration.zero);
      current = current.copyWith(url: 'https://new.test/api');
      repo.pending.single.result.complete(enriched(title('1')));
      expect((await old).doubanId, isEmpty);
      repo.delayed = false;
      expect((await resolver.resolve(title('1'))).doubanId, '1292052');
      expect(repo.calls, ['1', '1']);
      resolver.dispose();
    },
  );

  test(
    'rejects wrong work, year, kind, season, source key and conflicting ID',
    () async {
      for (final overrides in <Map<String, dynamic>>[
        {'title': '另一部作品'},
        {'year': '2021'},
        {'category': '欧美剧'},
        {'title': '作品1第二季'},
        {'id': 'different'},
        {'sourceId': 'different'},
        {'imdbId': 'tt0999999'},
      ]) {
        final repo = Repository()
          ..response = (t) => change(enriched(t), overrides);
        final resolver = CinemaRatingTitleResolver(
          repository: repo,
          sourceFor: (_) => source,
        );
        // Only the ID conflict fixture starts with an existing IMDb identity;
        // otherwise a strong matching external ID would intentionally allow aliases.
        final input = overrides.containsKey('imdbId')
            ? change(title('1'), {'imdbId': 'tt0111161'})
            : title('1');
        expect(
          (await resolver.resolve(input)).doubanId,
          isEmpty,
          reason: '$overrides',
        );
        resolver.dispose();
      }
    },
  );

  test(
    'accepts explicit translated aliases and language/format variants',
    () async {
      for (final pair in <(Map<String, dynamic>, Map<String, dynamic>)>[
        ({'title': '怒之杀', 'aliases': 'Mutiny / 反叛'}, {'title': 'MUTINY'}),
        ({'title': '怒之杀', 'aliases': '怒之殺'}, {'title': '怒之殺（國語版）'}),
        ({'title': '作品 1（英语版）'}, {'title': '作品1'}),
        ({'title': 'Interstellar', 'imdbId': 'tt0111161'}, {'title': '星际穿越'}),
      ]) {
        final repo = Repository()
          ..response = (t) => change(enriched(t), pair.$2);
        final resolver = CinemaRatingTitleResolver(
          repository: repo,
          sourceFor: (_) => source,
        );
        final input = change(title('1'), pair.$1);
        expect(
          (await resolver.resolve(input)).doubanId,
          '1292052',
          reason: '$pair',
        );
        resolver.dispose();
      }
    },
  );

  test(
    'queue is bounded and disposal releases stale card waiters immediately',
    () async {
      final repo = Repository()..delayed = true;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => source,
      );
      final futures = [
        for (var i = 0; i < 50; i++) resolver.resolve(title('$i')),
      ];
      final rejected = await Future.wait(futures.skip(34));
      expect(rejected.every((t) => t.doubanId.isEmpty), isTrue);
      expect(repo.calls, ['0', '1']);
      resolver.dispose();
      final queued = await Future.wait(futures.skip(2).take(32));
      expect(queued.every((t) => t.doubanId.isEmpty), isTrue);
      expect(repo.calls, ['0', '1']);
      for (final request in repo.pending) {
        request.result.complete(enriched(request.title));
      }
      expect(
        (await Future.wait(futures.take(2))).every((t) => t.doubanId.isEmpty),
        isTrue,
      );
    },
  );

  test(
    'expired queue wait does not block a fresh retry or consume another slot',
    () async {
      final repo = Repository()..delayed = true;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => source,
        maxQueueWait: Duration.zero,
      );
      final first = resolver.resolve(title('1'));
      final second = resolver.resolve(title('2'));
      expect((await resolver.resolve(title('3'))).doubanId, isEmpty);
      expect(repo.calls, ['1', '2']);
      for (final request in repo.pending) {
        request.result.complete(enriched(request.title));
      }
      await Future.wait([first, second]);
      repo.delayed = false;
      expect((await resolver.resolve(title('3'))).doubanId, '1292052');
      expect(repo.calls, ['1', '2', '3']);
      resolver.dispose();
    },
  );

  test(
    'queue overflow remains retryable without a failed-lookup cooldown',
    () async {
      final repo = Repository()..delayed = true;
      final resolver = CinemaRatingTitleResolver(
        repository: repo,
        sourceFor: (_) => source,
      );
      final accepted = [
        for (var i = 0; i < 34; i++) resolver.resolve(title('$i')),
      ];
      expect((await resolver.resolve(title('34'))).doubanId, isEmpty);
      repo.delayed = false;
      for (final request in repo.pending) {
        request.result.complete(enriched(request.title));
      }
      await Future.wait(accepted);
      expect((await resolver.resolve(title('34'))).doubanId, '1292052');
      expect(repo.calls, hasLength(35));
      resolver.dispose();
    },
  );
}
