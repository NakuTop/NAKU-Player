import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_rating_lookup.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';

Map<String, dynamic> _entity({
  String kind = 'Q5398426',
  String name = 'Original Show',
  String date = 'P580',
  String? year = '2026',
  bool douban = true,
}) => {
  'labels': {
    'en': {'value': name},
    'zh-hans': {'value': '原名剧集'},
  },
  'claims': {
    for (final entry in <String, Object>{
      if (douban) 'P4529': '12345',
      'P345': 'tt1234567',
      'P1258': kind == 'Q11424' ? 'm/original_show' : 'tv/original_show',
      'P31': {'id': kind},
      if (year != null) date: {'time': '+$year-01-01T00:00:00Z'},
    }.entries)
      entry.key: [
        {
          'rank': 'normal',
          'mainsnak': {
            'datavalue': {'value': entry.value},
          },
        },
      ],
  },
};
const _title = CinemaTitle(
  id: 'a',
  sourceId: 'fixture',
  title: '原名剧集',
  year: '2026',
  category: '电视剧',
  doubanId: '12345',
);
const _subject = DoubanSubjectDetails(
  doubanId: '12345',
  title: '原名剧集',
  originalTitle: 'Original Show',
  year: '2026',
);
String _rtPage(
  String id, {
  String year = '2026',
  String type = 'TVSeason',
  bool rating = true,
}) =>
    '<script type="application/ld+json">${jsonEncode({
      '@type': type,
      'url': 'https://www.rottentomatoes.com/$id',
      'dateCreated': '$year-01-01',
      if (rating) 'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 91, 'ratingCount': 20},
    })}</script>';

void main() {
  setUp(CinemaDoubanAccess.resetForTesting);
  tearDown(CinemaDoubanAccess.resetForTesting);
  for (final failure in <Object>[
    TimeoutException('temporary timeout'),
    const SocketException('temporary connection reset'),
    const HandshakeException('temporary TLS connection reset'),
    const HttpException('服务暂不可用 (HTTP 503)'),
    const HttpException('服务限流，请稍后刷新'),
    const HttpException('豆瓣暂时限制访问或要求验证，请在官网查看'),
    const FormatException('官网未返回影评人评分'),
  ]) {
    test(
      'provider failures retry only a transient connection: $failure',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'rating-retry-',
        );
        addTearDown(() => directory.delete(recursive: true));
        var calls = 0;
        final transient =
            failure is TimeoutException ||
            failure is SocketException ||
            failure is HandshakeException ||
            failure is HttpException && failure.message.contains('503');
        final repository = CinemaRatingsRepository(
          directory: directory,
          fetch: (uri, _) async {
            calls++;
            if (calls == 1) throw failure;
            return utf8.encode(_rtPage('tv/original_show/s01'));
          },
        );
        final result = await repository.load(
          const CinemaTitle(
            id: 'retry',
            sourceId: 'fixture',
            title: 'Original Show Season 1',
            category: '电视剧',
            rottenTomatoesId: 'tv/original_show/s01',
          ),
        );
        expect(calls, transient ? 2 : 1);
        expect(result.ratings[2].value, transient ? 91 : isNull);
      },
    );
  }
  test('a repeated provider timeout stops after one retry', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rating-retry-limit-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var calls = 0;
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (uri, _) async {
        calls++;
        throw TimeoutException('offline');
      },
    );
    final result = await repository.load(
      const CinemaTitle(
        id: 'offline',
        sourceId: 'fixture',
        title: 'Original Show',
        rottenTomatoesId: 'tv/original_show',
      ),
    );
    expect(calls, 2);
    expect(result.ratings[2].value, isNull);
    expect(result.ratings[2].note, contains('超时'));
  });
  for (final correctYear in [true, false]) {
    test(
      'later season joins its verified RT season to the parent IMDb: year match $correctYear',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'rating-season-parent-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final repo = CinemaRatingsRepository(
          directory: directory,
          fetch: (uri, limit) async {
            if (uri.host == 'm.douban.com') {
              return utf8.encode(
                jsonEncode({
                  'id': '12345',
                  'type': 'tv',
                  'title': '原名剧集 第三季',
                  'original_title': 'Original Show Season 3',
                  'year': '2026',
                  'rating': {'max': 10, 'value': 8.3},
                }),
              );
            }
            if (uri.host == 'datasets.imdbws.com') {
              return gzip.encode(
                utf8.encode(
                  'tconst\taverageRating\tnumVotes\ntt1234567\t8.6\t200\n',
                ),
              );
            }
            if (uri.host == 'www.rottentomatoes.com' && uri.path == '/search') {
              return utf8.encode(
                '<search-page-media-row startyear="2020"><a slot="title" href="https://www.rottentomatoes.com/tv/original_show">Original Show</a></search-page-media-row>',
              );
            }
            if (uri.host == 'www.rottentomatoes.com') {
              return utf8.encode(
                _rtPage(
                  'tv/original_show/s03',
                  year: correctYear ? '2026' : '2020',
                ),
              );
            }
            if (uri.host == 'query.wikidata.org' &&
                (uri.queryParameters['query'] ?? '').contains('P1258')) {
              return utf8.encode(
                jsonEncode({
                  'results': {
                    'bindings': [
                      {
                        'item': {
                          'value': 'https://www.wikidata.org/entity/Q777',
                        },
                      },
                    ],
                  },
                }),
              );
            }
            if (uri.queryParameters['action'] == 'wbgetentities') {
              return utf8.encode(
                jsonEncode({
                  'entities': {'Q777': _entity(year: '2020')},
                }),
              );
            }
            return utf8.encode('{}');
          },
        );
        final result = await repo.load(
          const CinemaTitle(
            id: 'season',
            sourceId: 'fixture',
            title: '原名剧集 第三季',
            year: '2026',
            category: '电视剧',
            doubanId: '12345',
          ),
        );
        expect(
          result.ratings.map((r) => r.value),
          correctYear ? [8.3, 8.6, 91] : [8.3, null, null],
        );
        if (correctYear) {
          expect(result.ratings[1].scope, '整剧');
          expect(result.ratings[2].scope, '第3季');
          expect(
            repo.scoreFor(_title, '烂番茄'),
            isNull,
            reason: 'A different season profile never receives these scores',
          );
        }
      },
    );
  }
  test('Douban follows only the exact same-ID movie to TV API route', () {
    final from = Uri.parse('https://m.douban.com/rexxar/api/v2/movie/12345');
    expect(
      CinemaDoubanAccess.subjectRedirect(
        from,
        '/rexxar/api/v2/tv/12345',
      )?.toString(),
      'https://m.douban.com/rexxar/api/v2/tv/12345',
    );
    for (final location in [
      'https://accounts.douban.com/passport/login',
      'https://other.test/rexxar/api/v2/tv/12345',
      '/rexxar/api/v2/tv/54321',
      '/rexxar/api/v2/tv/12345?apikey=guess',
      '/rexxar/api/v2/tv/12345#other',
      'http://m.douban.com/rexxar/api/v2/tv/12345',
      'https://m.douban.com:8443/rexxar/api/v2/tv/12345',
      'https://user@m.douban.com/rexxar/api/v2/tv/12345',
    ]) {
      expect(CinemaDoubanAccess.subjectRedirect(from, location), isNull);
    }
    expect(
      CinemaDoubanAccess.subjectRedirect(
        Uri.parse('https://m.douban.com/rexxar/api/v2/tv/12345'),
        '/rexxar/api/v2/tv/12345',
      ),
      isNull,
    );
  });
  test(
    'an unavailable detail API preserves the exact official feed score and timestamp',
    () async {
      final stamp = DateTime.now().subtract(const Duration(minutes: 1));
      CinemaDoubanAccess.rememberFeedSubject({
        'id': '12345',
        'title': '原名剧集',
        'type': 'tv',
        'year': '2026',
        'rating': {'max': 10, 'value': 8.3, 'count': 100},
      }, now: stamp);
      final directory = await Directory.systemTemp.createTemp('rating-feed-');
      addTearDown(() => directory.delete(recursive: true));
      final repo = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          throw const HttpException('Public detail API temporarily restricted');
        },
      );
      final result = await repo.load(_title);
      expect(result.ratings.first.value, 8.3);
      expect(result.ratings.first.verified, isTrue);
      expect(result.ratings.first.note, contains('榜单'));
      expect(result.ratings.first.fetchedAt, stamp);
      expect(CinemaDoubanAccess.feedSubject('99999'), isNull);
      expect(
        CinemaDoubanAccess.feedSubject(
          '12345',
          now: stamp.add(const Duration(minutes: 16)),
        ),
        isNull,
      );
    },
  );
  test('series and miniseries use their official start date', () {
    for (final type in ['Q5398426', 'Q1259759', 'Q581714']) {
      final identity = CinemaRatingsRepository.identityFromEntity(
        _title,
        const RatingIdentity(doubanId: '12345'),
        'Q12345',
        _entity(kind: type),
      );
      expect(identity.imdbId, 'tt1234567');
      expect(identity.imdbIsSeries, isTrue);
    }
  });
  test(
    'an exact official subject can supply a missing Wikidata date, never override a conflicting date',
    () {
      expect(
        CinemaRatingsRepository.identityFromEntity(
          _title,
          const RatingIdentity(doubanId: '12345'),
          'Q12345',
          _entity(year: null),
          verifiedSubject: _subject,
          verifiedSubjectKind: 'tv',
        ).imdbId,
        'tt1234567',
      );
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          _title,
          const RatingIdentity(doubanId: '12345'),
          'Q12345',
          _entity(year: '1999'),
          verifiedSubject: _subject,
          verifiedSubjectKind: 'tv',
        ),
        throwsFormatException,
      );
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          _title,
          const RatingIdentity(doubanId: '12345'),
          'Q12345',
          _entity(year: null),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'exact official season maps a series IMDb with scope and its own RT season',
    () {
      const title = CinemaTitle(
        id: 'season',
        sourceId: 'fixture',
        title: '原名剧集 第三季',
        year: '2026',
        category: '电视剧',
        doubanId: '12345',
      );
      const official = DoubanSubjectDetails(
        doubanId: '12345',
        title: '原名剧集 第三季',
        originalTitle: 'Original Show Season 3',
        year: '2026',
      );
      final identity = CinemaRatingsRepository.identityFromEntity(
        title,
        const RatingIdentity(doubanId: '12345'),
        'Q12345',
        _entity(year: '2020'),
        verifiedSubject: official,
        verifiedSubjectKind: 'tv',
      );
      expect(identity.imdbId, 'tt1234567');
      expect(identity.imdbIsSeries, isTrue);
      expect(identity.rottenTomatoesId, 'tv/original_show/s03');
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          title,
          const RatingIdentity(doubanId: '12345'),
          'Q12345',
          _entity(year: '2020'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'reverse IMDb mapping verifies its exact claim before adding another platform',
    () {
      final result = CinemaRatingsRepository.identityFromEntity(
        _title.copyWith(doubanId: ''),
        const RatingIdentity(imdbId: 'tt1234567'),
        'Q12345',
        _entity(),
      );
      expect(result.doubanId, '12345');
      expect(result.rottenTomatoesId, 'tv/original_show');
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          _title,
          const RatingIdentity(imdbId: 'tt7654321'),
          'Q12345',
          _entity(),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'IMDb anchor can bridge a missing Douban property but cannot contradict it',
    () {
      final result = CinemaRatingsRepository.identityFromEntity(
        _title,
        const RatingIdentity(doubanId: '12345', imdbId: 'tt1234567'),
        'Q12345',
        _entity(douban: false),
        anchorImdb: true,
      );
      expect(result.doubanId, '12345');
      expect(result.rottenTomatoesId, 'tv/original_show');
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          _title,
          const RatingIdentity(doubanId: '77777', imdbId: 'tt1234567'),
          'Q12345',
          _entity(),
          anchorImdb: true,
        ),
        throwsFormatException,
      );
    },
  );
  test('IMDb suggestions reject wrong year, person, episode and ambiguity', () {
    Map<String, dynamic> row(
      String id, {
      int year = 2026,
      String kind = 'tvSeries',
    }) => {'id': id, 'l': 'Original Show', 'y': year, 'qid': kind};
    String find(List<Map<String, dynamic>> rows) => cinemaImdbSuggestionId(
      {'d': rows},
      names: {'Original Show'},
      year: '2026',
      kind: 'tv',
    );
    expect(
      find([row('tt1234567'), row('tt7654321', year: 2000), row('nm1234567')]),
      'tt1234567',
    );
    expect(find([row('tt1234567', kind: 'tvEpisode')]), '');
    expect(find([row('tt1234567'), row('tt7654321')]), '');
  });
  test(
    'RT search reads both official year attribute styles and ignores search scores',
    () {
      String row(String id, String attr, int year) =>
          '<search-page-media-row $attr="$year" tomatometer-score="99"><a slot="title" href="https://www.rottentomatoes.com/$id">Original Show</a></search-page-media-row>';
      expect(
        cinemaRtSearchId(
          row('m/original_show', 'release-year', 2026),
          names: {'Original Show'},
          year: '2026',
          kind: 'movie',
        ),
        'm/original_show',
      );
      expect(
        cinemaRtSearchId(
          row('tv/original_show', 'startyear', 2020),
          names: {'Original Show'},
          year: '2026',
          kind: 'tv',
          season: '3',
        ),
        'tv/original_show',
      );
      expect(
        cinemaRtSearchId(
          row('m/remake', 'release-year', 2000),
          names: {'Original Show'},
          year: '2026',
          kind: 'movie',
        ),
        '',
      );
      expect(
        cinemaRtSearchId(
          row('tv/old', 'startyear', 2000) + row('tv/new', 'startyear', 2020),
          names: {'Original Show'},
          year: '2026',
          kind: 'tv',
          season: '3',
        ),
        '',
      );
    },
  );
  test(
    'derived RT season needs its canonical season path and release year',
    () {
      expect(
        cinemaRtPageMatches(
          'tv/original_show/s03',
          _rtPage('tv/original_show/s03'),
          year: '2026',
          kind: 'tv',
        ),
        isTrue,
      );
      expect(
        cinemaRtPageMatches(
          'tv/original_show/s03',
          _rtPage('tv/original_show/s02'),
          year: '2026',
          kind: 'tv',
        ),
        isFalse,
      );
      expect(
        cinemaRtPageMatches(
          'tv/original_show/s03',
          _rtPage('tv/original_show/s03', year: '2020'),
          year: '2026',
          kind: 'tv',
        ),
        isFalse,
      );
      expect(
        cinemaRtPageMatches(
          'tv/stranger_things',
          _rtPage('tv/stranger_things', type: 'TVSeries'),
          year: '2026',
          kind: 'tv',
        ),
        isTrue,
      );
    },
  );
  test('current RT scorecard reads only exact canonical critic scores', () {
    String page({
      String canonical = 'm/original_show',
      String title = 'Tomatometer',
      String vanity = 'm/original_show',
    }) =>
        '''
<link rel="canonical" href="https://www.rottentomatoes.com/$canonical">
<script data-json="vanity">${jsonEncode({'href': '/$vanity', 'type': 'movie'})}</script>
<script data-json="mediaScorecard">${jsonEncode({
          'criticsScore': {'title': title, 'score': '87', 'ratingCount': 12},
          'audienceScore': {'score': '99'},
        })}</script>''';
    const url = 'https://www.rottentomatoes.com/m/original_show';
    expect(
      CinemaRatingsRepository.parseRatingPage('烂番茄', url, page()).value,
      87,
    );
    for (final body in [
      page(canonical: 'm/wrong'),
      page(vanity: 'm/wrong'),
      page(title: 'Popcornmeter'),
    ]) {
      expect(
        () => CinemaRatingsRepository.parseRatingPage('烂番茄', url, body),
        throwsFormatException,
      );
    }
  });
  test(
    'missing crosswalk falls through official IMDb suggestions and RT search',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rating-completion-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final requests = <Uri>[];
      final interrupted = <String>{};
      final repo = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          requests.add(uri);
          if (const {
                'www.wikidata.org',
                'v3.sg.media-imdb.com',
              }.contains(uri.host) &&
              interrupted.add(uri.host)) {
            throw const HandshakeException('temporary lookup interruption');
          }
          if (uri.host == 'm.douban.com') {
            return utf8.encode(
              jsonEncode({
                'id': '12345',
                'type': 'tv',
                'title': '原名剧集',
                'original_title': 'Original Show',
                'year': '2026',
                'rating': {'max': 10, 'value': 8.3},
              }),
            );
          }
          if (uri.host == 'datasets.imdbws.com') {
            return gzip.encode(
              utf8.encode(
                'tconst\taverageRating\tnumVotes\ntt1234567\t8.6\t200\n',
              ),
            );
          }
          if (uri.host == 'v3.sg.media-imdb.com') {
            return utf8.encode(
              jsonEncode({
                'd': [
                  {
                    'id': 'tt1234567',
                    'l': 'Original Show',
                    'y': 2026,
                    'qid': 'tvSeries',
                  },
                ],
              }),
            );
          }
          if (uri.host == 'www.rottentomatoes.com' && uri.path == '/search') {
            return utf8.encode(
              '<search-page-media-row startyear="2026"><a slot="title" href="https://www.rottentomatoes.com/tv/original_show">Original Show</a></search-page-media-row>',
            );
          }
          if (uri.host == 'www.rottentomatoes.com') {
            return utf8.encode(_rtPage('tv/original_show', type: 'TVSeries'));
          }
          return utf8.encode('{}');
        },
      );
      final result = await repo.load(_title);
      expect(result.ratings.map((r) => r.value), [8.3, 8.6, 91]);
      expect(result.ratings[1].scope, '整剧');
      expect(result.ratings.every((r) => r.verified), isTrue);
      expect(interrupted, {'www.wikidata.org', 'v3.sg.media-imdb.com'});
      expect(
        requests.where((uri) => uri.host == 'v3.sg.media-imdb.com'),
        hasLength(2),
      );
      final before = requests.length;
      final again = await repo.load(_title);
      expect(again.ratings.map((r) => r.value), [8.3, 8.6, 91]);
      expect(
        requests.length,
        before,
        reason: 'A complete verified identity and provider values are cached',
      );
      expect(repo.peek(_title)!.ratings[1].scope, '整剧');
    },
  );
  test(
    'IMDb page fills a real score before the daily dataset contains it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rating-imdb-page-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final repo = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          if (uri.host == 'datasets.imdbws.com') {
            return gzip.encode(
              utf8.encode('tconst\taverageRating\tnumVotes\n'),
            );
          }
          if (uri.host == 'www.imdb.com') {
            return utf8.encode(
              '<script type="application/ld+json">${jsonEncode({
                '@type': 'Movie',
                'url': 'https://www.imdb.com/title/tt1234567/',
                'aggregateRating': {'bestRating': 10, 'ratingValue': 8.1, 'ratingCount': 250},
              })}</script>',
            );
          }
          throw const HttpException('No fixture for unrelated provider');
        },
      );
      final result = await repo.load(
        const CinemaTitle(
          id: 'imdb',
          sourceId: 'fixture',
          title: 'New Film',
          imdbId: 'tt1234567',
        ),
      );
      expect(result.ratings[1].value, 8.1);
      expect(result.ratings[1].note, contains('IMDb 官网'));
    },
  );
}
