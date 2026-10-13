import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/anime/cinema_anime_invitation.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

BangumiItem _subject({String nameCn = '测试动漫'}) => BangumiItem(
  id: 123,
  type: 2,
  name: 'Anime',
  nameCn: nameCn,
  summary: '',
  airDate: '2020-01-01',
  airWeekday: 1,
  rank: 0,
  images: {},
  tags: [],
  alias: ['English alias'],
  ratingScore: 0,
  votes: 0,
  votesCount: [],
  info: '',
);

class _Rule extends Plugin {
  _Rule({this.matchName = '测试动漫', this.labels = const ['第1集', '第2集']})
    : super(
        api: '1',
        type: 'anime',
        name: 'Rule',
        version: '1',
        muliSources: true,
        useWebview: true,
        useNativePlayer: true,
        usePost: false,
        useLegacyParser: false,
        adBlocker: false,
        userAgent: '',
        baseUrl: 'https://anime.example',
        searchURL: '',
        searchList: '',
        searchName: '',
        searchResult: '',
        chapterRoads: '',
        chapterResult: '',
        referer: '',
      );
  final String matchName;
  final List<String> labels;
  int chapterQueries = 0;
  @override
  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async => PluginSearchResponse(
    pluginName: name,
    data: [SearchItem(name: matchName, src: '/show')],
  );
  @override
  Future<List<Road>> queryChapterRoads(
    String source, {
    RuleCancelToken? cancelToken,
  }) async {
    chapterQueries++;
    return [
      Road(
        name: 'road',
        data: [for (var i = 0; i < labels.length; i++) '/$i'],
        identifier: labels,
      ),
    ];
  }
}

void main() {
  test(
    'anime room identity uses Bangumi id and episode across translated titles',
    () {
      final first = cinemaAnimeSyncTitle(_subject(), '第02集');
      final translated = cinemaAnimeSyncTitle(
        _subject(nameCn: 'English anime'),
        'EP2',
      );
      final media = CinemaSyncMedia.fromSelection(
        first,
        first.routes.first.episodes.first,
      );
      expect(media.animeId, 123);
      expect(
        media.matches(translated, translated.routes.first.episodes.first),
        true,
      );
      expect(CinemaSyncMedia.fromJson(media.toJson())!.animeId, 123);
      expect(
        media.matches(
          CinemaTitle(
            id: '124',
            sourceId: 'bangumi',
            title: translated.title,
            category: '动漫',
            routes: translated.routes,
          ),
          translated.routes.first.episodes.first,
        ),
        false,
      );
      expect(
        media.matches(translated, const CinemaEpisode(name: '第3集', url: '')),
        false,
      );
    },
  );
  test(
    'anime invite resolves recipient rules by labels and overrides resume selection',
    () async {
      final subject = _subject();
      final anchor = cinemaAnimeSyncTitle(subject, '第2集');
      final rule = _Rule(labels: ['第2集', '第1集']);
      final args = await resolveCinemaAnimeInvitation(
        media: CinemaSyncMedia.fromSelection(
          anchor,
          anchor.routes.first.episodes.first,
        ),
        plugins: [rule],
        isCurrent: () => true,
        positionSeconds: 80,
        loadSubject: (_) async => subject,
      );
      expect(args, isNotNull);
      expect(args!.initialEpisode, 1);
      expect(args.initialRoad, 0);
      expect(args.initialOffset, 80);
      expect(args.hasInitialSelection, true);
    },
  );
  test(
    'anime invite cannot resolve a different season or a missing episode',
    () async {
      final subject = _subject();
      final anchor = cinemaAnimeSyncTitle(subject, '第5集');
      final other = _Rule(matchName: '测试动漫 第二季');
      final media = CinemaSyncMedia.fromSelection(
        anchor,
        anchor.routes.first.episodes.first,
      );
      expect(
        await resolveCinemaAnimeInvitation(
          media: media,
          plugins: [other],
          isCurrent: () => true,
          loadSubject: (_) async => subject,
        ),
        isNull,
      );
      expect(other.chapterQueries, 0);
      expect(
        await resolveCinemaAnimeInvitation(
          media: media,
          plugins: [_Rule()],
          isCurrent: () => true,
          loadSubject: (_) async => subject,
        ),
        isNull,
      );
      expect(
        await resolveCinemaAnimeInvitation(
          media: media,
          plugins: [_Rule()],
          isCurrent: () => false,
          loadSubject: (_) async => subject,
        ),
        isNull,
      );
    },
  );
}
