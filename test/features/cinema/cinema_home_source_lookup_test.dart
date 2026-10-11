import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_seasons.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_work_sources.dart';
import 'cinema_data_test.dart' show FixtureAdapter, jsonResponse;

const _source = CinemaSource(
  id: 'juliang',
  name: '巨量',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.invalid/api/provide/vod/?ac=detail',
);
const _anchor = CinemaTitle(
  id: 'third',
  sourceId: 'douban-discovery',
  title: '绝望写手 第三季',
  category: '电视剧',
  year: '2024',
);

Map<String, Object?> _bundle() => {
  'vod_id': 629306141028909058,
  'vod_name': '绝望写手',
  'type_name': '欧美剧',
  'vod_year': '2021',
  'vod_douban_id': '123456',
  'vod_douban_score': '9.2',
  'vod_play_from': 'jlm3u8',
  'vod_play_url': [
    for (var s = 1; s <= 3; s++)
      for (var e = 1; e <= 2; e++)
        '第 $s 季 第 $e 集\$https://fixture.invalid/$s/$e.m3u8',
  ].join('#'),
};

void main() {
  test(
    'homepage season lookup uses compact title and series fallback, details retain season',
    () async {
      final adapter = FixtureAdapter((request) {
        final q = request.uri.queryParameters;
        return jsonResponse({
          'code': 1,
          'page': 1,
          'pagecount': 1,
          'list': q['wd'] == '绝望写手' || q['ids'] == '629306141028909058'
              ? [_bundle()]
              : [],
        });
      });
      final repository = CinemaRepository(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final results = await discoverCinemaWorkSources(
        anchor: _anchor,
        known: [],
        sources: [_source],
        repository: repository,
        isCurrent: () => true,
      ).last;
      final selected = results.singleWhere((r) => r.sourceId == _source.id);
      expect(adapter.requests.map((r) => r.uri.queryParameters['wd']), [
        '绝望写手第三季',
        '绝望写手',
      ]);
      expect(selected.id, '629306141028909058~s3');
      expect(
        selected.year,
        isEmpty,
      ); // Never borrow the premiere year for season 3.
      expect(selected.doubanId, isEmpty);
      expect(selected.sourceDoubanScore, isNull);
      final detail = await repository.detail(_source, selected);
      expect(detail.id, selected.id);
      expect(
        detail.routes.single.episodes.map((e) => e.url),
        everyElement(contains('/3/')),
      );
      expect(detail.routes.single.episodes.map((e) => e.name), [
        '第01集',
        '第02集',
      ]);
      expect(
        adapter.requests.last.uri.queryParameters['ids'],
        '629306141028909058',
      );
      // Search and homepage share the same normalized request cache.
      await repository.search(_source, '绝望写手 第三季');
      expect(adapter.requests.length, 3);
    },
  );

  test(
    'projection keeps special episodes intact and never merges different seasons or years',
    () {
      final seasons = CinemaRepository.parseMacCmsPage(_source, {
        'list': [_bundle()],
      }).items;
      expect(seasons, hasLength(3));
      expect(groupCinemaTitles(seasons), hasLength(3));
      final all = groupCinemaTitles([_anchor, ...seasons]);
      expect(all.first.variants.map((t) => t.id), [
        'third',
        '629306141028909058~s3',
      ]);
      final different = CinemaTitle.fromJson({
        ..._anchor.toJson(),
        'year': '1999',
      });
      expect(groupCinemaTitles([different, seasons.first]), hasLength(2));
      final special = {
        ..._bundle(),
        'vod_play_url':
            '${_bundle()['vod_play_url']}#花絮\$https://fixture.invalid/special.mp4',
      };
      expect(
        CinemaRepository.parseMacCmsPage(_source, {
          'list': [special],
        }).items.single.id,
        '629306141028909058',
      );
      expect(cinemaSourceQuery('The White Lotus'), 'The White Lotus');
      expect(cinemaSourceQuery('老友记 第一季'), '老友记第一季');
      expect(cinemaSourceQuery('老友记 第 1 季'), '老友记第1季');
      expect(cinemaSourceQuery('电影 & test'), '电影 & test');
      expect(cinemaSourceQuery('Hacks 第三季'), 'Hacks 第三季');
    },
  );

  test(
    'saved priority chooses the representative and orders failover sources stably',
    () {
      final a = CinemaTitle.fromJson({..._anchor.toJson(), 'sourceId': 'a'});
      final b = CinemaTitle.fromJson({..._anchor.toJson(), 'sourceId': 'b'});
      final c = CinemaTitle.fromJson({..._anchor.toJson(), 'sourceId': 'c'});
      expect(
        groupCinemaTitles(
          [a, b, c],
          sourcePriority: ['c', 'b', 'a'],
        ).single.representative,
        c,
      );
      expect(orderCinemaVariants([a, b, c], ['c', 'b', 'a']), [c, b, a]);
    },
  );

  test(
    'live default sources resolve homepage Friends and Hacks season cards',
    () async {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
      );
      final repository = CinemaRepository(dio: dio);
      final evidence = <Object>[];
      for (final source in cinema110SourcePack.sources) {
        final categories = await repository.categories(source);
        expect(categories, isNotEmpty);
        for (final entry in [('老友记 第一季', '1994'), ('绝望写手 第三季', '2024')]) {
          final anchor = CinemaTitle(
            id: entry.$1,
            sourceId: 'douban-discovery',
            title: entry.$1,
            year: entry.$2,
            category: '电视剧',
          );
          final matches = await discoverCinemaWorkSources(
            anchor: anchor,
            known: [],
            sources: [source],
            repository: repository,
            isCurrent: () => true,
          ).last;
          final match = matches.singleWhere((r) => r.sourceId == source.id);
          final detail = await repository.detail(source, match);
          expect(detail.routes.first.episodes, isNotEmpty);
          evidence.add({
            'source': source.name,
            'query': entry.$1,
            'matched': detail.title,
            'id': detail.id,
            'routes': detail.routes.length,
            'episodes': detail.routes.first.episodes.length,
          });
        }
      }
      await File(
        '../home-source-lookup-1.10.json',
      ).writeAsString(jsonEncode(evidence));
      dio.close(force: true);
    },
    skip: !const bool.fromEnvironment('CINEMA_NEW_SOURCES_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
