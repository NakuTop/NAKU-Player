import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';

const movie = CinemaTitle(
  id: '1',
  sourceId: 'source',
  title: '星际穿越',
  year: '2014',
  category: '科幻片',
);
CinemaDiscoveryTitle candidate({
  String id = '1889243',
  String title = '星际穿越',
  String year = '2014',
  String kind = 'movie',
  bool verified = true,
  String aliases = 'Interstellar',
}) => CinemaDiscoveryTitle(
  id: id,
  title: title,
  year: year,
  kind: kind,
  aliases: aliases,
  identityVerified: verified,
);

void main() {
  test(
    'unique verified exact title, year and kind enriches source metadata only',
    () {
      final result = CinemaRatingIdentitySearch.match(movie, [candidate()]);
      expect(result?.doubanId, '1889243');
      expect(result?.sourceId, movie.sourceId);
      expect(result?.title, movie.title);
      expect(result?.sourceDoubanScore, isNull);
      expect(
        CinemaRatingIdentitySearch.match(
          CinemaTitle.fromJson({...movie.toJson(), 'title': 'Interstellar'}),
          [candidate()],
        )?.doubanId,
        '1889243',
      );
    },
  );

  test(
    'ambiguous remakes, kind/year mismatch and unverified candidates remain unbound',
    () {
      for (final candidates in [
        [candidate(), candidate(id: '99999')],
        [candidate(year: '2015')],
        [candidate(kind: 'tv')],
        [candidate(kind: '')],
        [candidate(verified: false)],
        [candidate(title: '星际穿越2', aliases: '')],
      ]) {
        expect(CinemaRatingIdentitySearch.match(movie, candidates), isNull);
      }
      expect(
        CinemaRatingIdentitySearch.match(
          CinemaTitle.fromJson({...movie.toJson(), 'year': ''}),
          [candidate()],
        ),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(movie.copyWith(doubanId: '99999'), [
          candidate(),
        ]),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(movie.copyWith(imdbId: 'tt9999999'), [
          candidate(),
        ]),
        isNull,
      );
    },
  );

  test('season cannot inherit series or another season through aliases', () {
    final season = CinemaTitle.fromJson({
      ...movie.toJson(),
      'title': '喜鹊谋杀案第三季',
      'year': '2026',
      'category': '欧美剧',
    });
    expect(
      CinemaRatingIdentitySearch.match(season, [
        candidate(
          title: '喜鹊谋杀案',
          aliases: season.title,
          year: '2026',
          kind: 'tv',
        ),
      ]),
      isNull,
    );
    expect(
      CinemaRatingIdentitySearch.match(season, [
        candidate(
          title: '喜鹊谋杀案第二季',
          aliases: season.title,
          year: '2026',
          kind: 'tv',
        ),
      ]),
      isNull,
    );
    expect(
      CinemaRatingIdentitySearch.match(season, [
        candidate(title: season.title, year: '2026', kind: 'tv'),
      ])?.doubanId,
      '1889243',
    );
  });

  test(
    'discovery has two active requests while distinct queued titles remain available',
    () async {
      final gates = <Completer<CinemaSearchDiscovery>>[];
      final resolver = CinemaRatingIdentitySearch(
        search: (_) {
          final gate = Completer<CinemaSearchDiscovery>();
          gates.add(gate);
          return gate.future;
        },
      );
      final pending = [
        for (var i = 0; i < 4; i++)
          resolver.resolve(
            CinemaTitle.fromJson({...movie.toJson(), 'title': 'Movie$i'}),
          ),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2);
      gates.first.complete(const CinemaSearchDiscovery());
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 3);
      gates[1].complete(const CinemaSearchDiscovery());
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 4);
      for (final gate in gates.skip(2)) {
        gate.complete(const CinemaSearchDiscovery());
      }
      await Future.wait(pending);
    },
  );

  test(
    'coalesces and caches missing or restricted searches without repeated traffic',
    () async {
      final gate = Completer<CinemaSearchDiscovery>();
      var calls = 0;
      final resolver = CinemaRatingIdentitySearch(
        search: (_) {
          calls++;
          return gate.future;
        },
      );
      final first = resolver.resolve(movie), second = resolver.resolve(movie);
      gate.complete(const CinemaSearchDiscovery());
      expect((await first).doubanId, isEmpty);
      expect((await second).doubanId, isEmpty);
      await resolver.resolve(movie);
      expect(calls, 1);
    },
  );
}
