import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_follow_resolver.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';

CinemaSource source(String id, {bool enabled = true}) => CinemaSource(
  id: id,
  name: id,
  kind: CinemaSourceKind.maccms,
  url: 'https://$id.invalid/api.php/provide/vod',
  enabled: enabled,
);
CinemaTitle title(
  String source, {
  String year = '2022',
  String name = '边缘行者',
  String id = 'one',
  String doubanId = '',
  List<String> episodes = const ['第01集', '第02集'],
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: '欧美剧',
  doubanId: doubanId,
  routes: [
    CinemaRoute(
      name: 'HLS',
      episodes: [
        for (var i = 0; i < episodes.length; i++)
          CinemaEpisode(
            name: episodes[i],
            url: 'https://media.invalid/$source/$i.m3u8',
          ),
      ],
    ),
  ],
);

class Repository extends CinemaRepository {
  final replies = <String, Future<CinemaPage>>{};
  final queried = <String>[];
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) {
    queried.add(source.id);
    return replies[source.id] ?? Future.value(const CinemaPage(items: []));
  }
}

void main() {
  final peerTitle = title('peer', doubanId: '123456');
  final media = CinemaSyncMedia.fromSelection(
    peerTitle,
    peerTitle.routes.first.episodes[1],
  );

  test(
    'follows the same episode from a local source with missing external ID',
    () async {
      final repository = Repository()
        ..replies['local'] = Future.value(
          CinemaPage(
            items: [
              title('local', episodes: ['EP02', 'EP01']),
            ],
          ),
        );
      final found = await resolveCinemaPeerPlayback(
        media: media,
        sources: [source('local')],
        repository: repository,
        isCurrent: () => true,
      );
      expect(found, isNotNull);
      expect(found!.source.id, 'local');
      expect(found.episodeIndex, 0);
      expect(found.episode.name, 'EP02');
      expect(found.episode.url, startsWith('https://media.invalid/local/'));
    },
  );

  test(
    'a fast matching source wins without waiting for an unavailable source',
    () async {
      final delayed = Completer<CinemaPage>();
      final repository = Repository()
        ..replies['slow'] = delayed.future
        ..replies['fast'] = Future.value(CinemaPage(items: [title('fast')]));
      final found = await resolveCinemaPeerPlayback(
        media: media,
        sources: [source('slow'), source('fast')],
        repository: repository,
        isCurrent: () => true,
      ).timeout(const Duration(seconds: 1));
      expect(found!.source.id, 'fast');
      delayed.complete(const CinemaPage(items: []));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'disabled sources, another year and another season never become a match',
    () async {
      final repository = Repository()
        ..replies['disabled'] = Future.value(
          CinemaPage(items: [title('disabled')]),
        )
        ..replies['wrong'] = Future.value(
          CinemaPage(
            items: [
              title('wrong', year: '2021'),
              title('wrong', id: 'two', name: '边缘行者第二季'),
            ],
          ),
        );
      final found = await resolveCinemaPeerPlayback(
        media: media,
        sources: [source('disabled', enabled: false), source('wrong')],
        repository: repository,
        isCurrent: () => true,
      );
      expect(found, isNull);
      expect(repository.queried, ['wrong']);
    },
  );

  test('ambiguous duplicate episode labels are not selected', () async {
    final repository = Repository()
      ..replies['local'] = Future.value(
        CinemaPage(
          items: [
            title('local', episodes: ['第02集', '第02集']),
          ],
        ),
      );
    final found = await resolveCinemaPeerPlayback(
      media: media,
      sources: [source('local')],
      repository: repository,
      isCurrent: () => true,
    );
    expect(found, isNull);
  });

  test(
    'unpairing while lookup is in flight cannot open a late result',
    () async {
      var current = true;
      final delayed = Completer<CinemaPage>();
      final repository = Repository()..replies['local'] = delayed.future;
      final lookup = resolveCinemaPeerPlayback(
        media: media,
        sources: [source('local')],
        repository: repository,
        isCurrent: () => current,
      );
      current = false;
      delayed.complete(CinemaPage(items: [title('local')]));
      expect(await lookup, isNull);
    },
  );
}
