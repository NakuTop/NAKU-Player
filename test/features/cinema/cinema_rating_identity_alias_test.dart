import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const _title = CinemaTitle(
  id: 'a',
  sourceId: 'fixture',
  title: '原名影片',
  year: '2026',
  category: '电影',
  doubanId: '12345',
);
const _identity = RatingIdentity(doubanId: '12345');
Map<String, dynamic> _entity({
  String name = 'Original Movie',
  String type = 'Q11424',
}) => {
  'labels': {
    'en': {'value': name},
  },
  'claims': {
    for (final claim in <String, Object>{
      'P4529': '12345',
      'P345': 'tt1234567',
      'P1258': 'm/original_movie',
      'P31': {'id': type},
      'P577': {'time': '+2026-01-01T00:00:00Z'},
    }.entries)
      claim.key: [
        {
          'mainsnak': {
            'datavalue': {'value': claim.value},
          },
        },
      ],
  },
};
DoubanSubjectDetails _subject({
  String id = '12345',
  String year = '2026',
  String title = '原名影片',
  String original = 'Original Movie',
}) => DoubanSubjectDetails(
  doubanId: id,
  title: title,
  year: year,
  originalTitle: original,
  score: 7.5,
  fetchedAt: DateTime.now(),
);
String _mobile() => '''
<link rel="canonical" href="https://m.douban.com/movie/subject/12345/">
<meta property="og:title" content="原名影片 - 电影">
<meta itemprop="ratingValue" content="7.5"><meta itemprop="reviewCount" content="200">
<div class="sub-title">原名影片</div><div class="sub-original-title">Original Movie（2026）</div>
''';
void main() {
  test(
    'same exact official subject original title enables a strict English crosswalk',
    () {
      final result = CinemaRatingsRepository.identityFromEntity(
        _title,
        _identity,
        'Q12345',
        _entity(),
        verifiedSubject: _subject(),
        verifiedSubjectKind: 'movie',
      );
      expect(result.imdbId, 'tt1234567');
      expect(result.rottenTomatoesId, 'm/original_movie');
    },
  );
  for (final (label, subject) in [
    ('another subject ID', _subject(id: '54321')),
    ('another release year', _subject(year: '2025')),
    ('another source title', _subject(title: '其他电影')),
    (
      'a near but nonidentical English name',
      _subject(original: 'Original Movie II'),
    ),
  ]) {
    test('$label cannot supply a crosswalk alias', () {
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          _title,
          _identity,
          'Q12345',
          _entity(),
          verifiedSubject: subject,
          verifiedSubjectKind: 'movie',
        ),
        throwsFormatException,
      );
    });
  }
  test('unverified provider aliases alone cannot relax a name match', () {
    const title = CinemaTitle(
      id: 'a',
      sourceId: 'fixture',
      title: '原名影片',
      year: '2026',
      doubanId: '12345',
      aliases: 'Original Movie',
    );
    expect(
      () => CinemaRatingsRepository.identityFromEntity(
        title,
        _identity,
        'Q12345',
        _entity(),
      ),
      throwsFormatException,
    );
  });
  test(
    'movie and series kinds remain distinct even for verified official aliases',
    () {
      for (final (type, kind) in [
        ('Q5398426', 'movie'),
        ('Q11424', 'tv'),
        ('Q11424', ''),
      ]) {
        expect(
          () => CinemaRatingsRepository.identityFromEntity(
            _title,
            _identity,
            'Q12345',
            _entity(type: type),
            verifiedSubject: _subject(),
            verifiedSubjectKind: kind,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('an official season alias cannot inherit the whole series rating', () {
    const title = CinemaTitle(
      id: 'a',
      sourceId: 'fixture',
      title: '原名影片',
      year: '2026',
      category: '电视剧',
      doubanId: '12345',
    );
    expect(
      () => CinemaRatingsRepository.identityFromEntity(
        title,
        _identity,
        'Q12345',
        _entity(name: 'Original Show Season 2', type: 'Q5398426'),
        verifiedSubject: _subject(original: 'Original Show Season 2'),
        verifiedSubjectKind: 'tv',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('季度条目'),
        ),
      ),
    );
  });
  test(
    'card mobile fallback publishes before crosswalk and reuses verified metadata after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp('rating-alias-');
      try {
        // A name-only failure from an older build must not suppress the new exact
        // official-alias validation for another half-hour.
        await File('${directory.path}/ratings-v1.json').writeAsString(
          jsonEncode({
            'version': 1,
            'bindings': {},
            'cache': {},
            'mappings': {
              '12345': {
                'at': DateTime.now().toIso8601String(),
                'failedAt': DateTime.now().toIso8601String(),
                'failure': 'old name-only mismatch',
                'qid': 'Q12345',
                'entity': _entity(),
              },
            },
          }),
        );
        final calls = <String>[];
        late CinemaRatingsRepository repository;
        Future<List<int>> fetch(Uri uri, int _) async {
          calls.add(uri.toString());
          if (uri.path.startsWith('/rexxar/')) {
            throw const HttpException('HTTP 400');
          }
          if (uri.host == 'm.douban.com') return utf8.encode(_mobile());
          if (uri.host == 'datasets.imdbws.com') {
            return gzip.encode(
              utf8.encode(
                'tconst\taverageRating\tnumVotes\ntt1234567\t7.1\t200\n',
              ),
            );
          }
          if (uri.host == 'www.rottentomatoes.com') {
            return utf8.encode(
              '<script type="application/ld+json">${jsonEncode({
                '@type': 'Movie',
                'url': uri.toString(),
                'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 70},
              })}</script>',
            );
          }
          throw StateError('Unexpected HTTP request $uri');
        }

        repository = CinemaRatingsRepository(
          directory: directory,
          fetch: fetch,
        );
        final seen = <double?>[];
        repository.changes.addListener(
          () => seen.add(repository.scoreFor(_title, '豆瓣')),
        );
        final result = await repository.loadForCard(_title);
        expect(result.ratings.map((r) => r.value), [7.5, 7.1, 70]);
        expect(seen, contains(7.5));
        expect(calls.where((url) => url.contains('/rexxar/')), hasLength(1));
        expect(
          calls.where((url) => url.contains('/movie/subject/12345/')),
          hasLength(1),
        );
        expect(calls.any((url) => url.contains('movie.douban.com')), isFalse);
        final count = calls.length;
        final restored = CinemaRatingsRepository(
          directory: directory,
          fetch: fetch,
        );
        final replay = await restored.loadForCard(_title);
        expect(replay.ratings.map((r) => r.value), [7.5, 7.1, 70]);
        expect(
          calls.length,
          count,
          reason:
              'Persisted verified subject metadata and exact provider IDs need no new requests',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
