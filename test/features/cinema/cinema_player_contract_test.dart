import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';

void main() {
  const title = CinemaTitle(
    id: '42',
    sourceId: 'movies',
    title: 'Fixture',
    routes: [
      CinemaRoute(
        name: '线路 A',
        episodes: [CinemaEpisode(name: '正片', url: 'https://example.org/a.mp4')],
      ),
      CinemaRoute(
        name: '线路 B',
        episodes: [
          CinemaEpisode(name: '第 1 集', url: 'https://example.org/1.m3u8'),
          CinemaEpisode(name: '第 2 集', url: 'https://example.org/2.m3u8'),
          CinemaEpisode(name: '第 3 集', url: 'https://example.org/3.m3u8'),
          CinemaEpisode(name: '第 4 集', url: 'https://example.org/4.m3u8'),
          CinemaEpisode(name: '第 5 集', url: 'https://example.org/5.m3u8'),
        ],
      ),
    ],
  );
  CinemaHistory history({
    CinemaTitle item = title,
    int route = 1,
    int episode = 4,
    int position = 600,
    int duration = 3600,
  }) => CinemaHistory(
    title: item,
    routeIndex: route,
    episodeIndex: episode,
    positionSeconds: position,
    durationSeconds: duration,
    updatedAt: DateTime.utc(2026, 10, 8),
  );

  test('resume preserves the chosen episode and source identity', () {
    expect(cinemaResumePosition(title, history(), 1, 4), 600);
    expect(cinemaResumePosition(title, history(), 1, 3), 0);
    expect(cinemaResumePosition(title, history(), 0, 4), 0);
    expect(
      cinemaResumePosition(
        title,
        history(
          item: const CinemaTitle(
            id: '42',
            sourceId: 'anime',
            title: 'Fixture',
          ),
        ),
        1,
        4,
      ),
      0,
    );
    expect(
      cinemaResumePosition(
        title,
        history(
          item: const CinemaTitle(
            id: '43',
            sourceId: 'movies',
            title: 'Fixture',
          ),
        ),
        1,
        4,
      ),
      0,
    );
  });

  test(
    'finished or corrupt progress starts cleanly; unknown duration resumes',
    () {
      expect(cinemaResumePosition(title, history(position: 3597), 1, 4), 0);
      expect(cinemaResumePosition(title, history(position: 9000), 1, 4), 0);
      expect(cinemaResumePosition(title, history(position: -1), 1, 4), 0);
      expect(cinemaResumePosition(title, history(duration: 0), 1, 4), 600);
      expect(cinemaResumePosition(title, null, 1, 4), 0);
    },
  );

  test('resume follows media when routes and episodes are reordered', () {
    final reordered = title.copyWith(
      routes: [
        CinemaRoute(
          name: '已更名的线路',
          episodes: title.routes[1].episodes.reversed.toList(),
        ),
        title.routes[0],
      ],
    );
    expect(cinemaResumeSelection(reordered, history()), (
      routeIndex: 0,
      episodeIndex: 0,
    ));
    expect(cinemaResumePosition(reordered, history(), 0, 0), 600);
    expect(cinemaResumePosition(reordered, history(), 1, 4), 0);
  });

  test('rotating URLs fall back to an unambiguous route and episode name', () {
    final refreshed = title.copyWith(
      routes: const [
        CinemaRoute(
          name: '线路 B',
          episodes: [
            CinemaEpisode(
              name: '第 5 集',
              url: 'https://example.org/5.m3u8?new-signature=abc',
            ),
          ],
        ),
      ],
    );
    expect(cinemaResumeSelection(refreshed, history()), (
      routeIndex: 0,
      episodeIndex: 0,
    ));
    expect(cinemaResumePosition(refreshed, history(), 0, 0), 600);
    final duplicate = refreshed.copyWith(
      routes: [...refreshed.routes, ...refreshed.routes],
    );
    expect(cinemaResumeSelection(duplicate, history()), isNull);
    expect(cinemaResumePosition(duplicate, history(), 0, 0), 0);
  });

  test(
    'removed or corrupt saved episodes never borrow another episode offset',
    () {
      final removed = title.copyWith(routes: [title.routes[0]]);
      expect(cinemaResumeSelection(removed, history()), isNull);
      expect(cinemaResumePosition(removed, history(), 0, 0), 0);
      expect(cinemaResumeSelection(title, history(route: -1)), isNull);
      expect(cinemaResumeSelection(title, history(episode: 99)), isNull);
      expect(
        cinemaResumeSelection(title, history(item: title.copyWith(routes: []))),
        isNull,
      );
    },
  );

  test(
    'stall watchdog tolerates recovery, seeks, pauses and end of playback',
    () {
      final watchdog = CinemaPlaybackWatchdog();
      final start = DateTime.utc(2026, 10, 8);
      bool sample(
        int seconds,
        int position, {
        bool playing = true,
        bool completed = false,
      }) => watchdog.sample(
        now: start.add(Duration(seconds: seconds)),
        position: Duration(seconds: position),
        playing: playing,
        completed: completed,
      );
      expect(sample(0, 10), isFalse);
      expect(
        sample(25, 10),
        isFalse,
      ); // A transient log has no fail transition.
      expect(sample(27, 12), isFalse); // The connection recovered.
      expect(sample(50, 12), isFalse);
      expect(sample(51, 3), isFalse); // A backward seek is progress too.
      expect(sample(70, 3, playing: false), isFalse);
      expect(sample(200, 3, playing: false), isFalse);
      expect(sample(201, 3), isFalse); // Resume gets a fresh timeout window.
      expect(sample(232, 3), isTrue); // Confirmed sustained lack of progress.
      expect(sample(240, 3, completed: true), isFalse);
      watchdog.reset();
      expect(sample(300, 3), isFalse);
    },
  );

  test('signed HLS URLs stay direct; page URLs use the resolver', () {
    const maccms = CinemaSource(
      id: 'movies',
      name: 'Movies',
      kind: CinemaSourceKind.maccms,
      url: 'https://example.org/api',
    );
    const kazumi = CinemaSource(
      id: 'anime',
      name: 'Anime',
      kind: CinemaSourceKind.kazumi,
      url: 'https://example.org',
    );
    const direct = CinemaEpisode(
      name: '1',
      url: 'https://example.org/video/INDEX.M3U8?expires=123&signature=xyz',
    );
    const page = CinemaEpisode(name: '1', url: 'https://example.org/play/123');
    const route = CinemaRoute(name: '线路 1', episodes: [direct]);
    const hlsRoute = CinemaRoute(name: 'provider-m3u8', episodes: [page]);
    expect(cinemaUsesDirectMedia(maccms, route, direct), isTrue);
    expect(cinemaUsesDirectMedia(kazumi, route, direct), isTrue);
    expect(cinemaUsesDirectMedia(maccms, route, page), isFalse);
    expect(cinemaUsesDirectMedia(kazumi, hlsRoute, page), isFalse);
    expect(cinemaUsesDirectMedia(maccms, hlsRoute, page), isTrue);
  });

  test(
    'switching routes preserves progress in the uniquely matching episode',
    () {
      const current = CinemaEpisode(
        name: '第 5 集',
        url: 'https://example.org/route-a/5.m3u8',
      );
      const target = CinemaRoute(
        name: '线路 B',
        episodes: [
          CinemaEpisode(
            name: '第 6 集',
            url: 'https://example.org/route-b/6.m3u8',
          ),
          CinemaEpisode(
            name: '第 5 集',
            url: 'https://example.org/route-b/5.m3u8',
          ),
        ],
      );
      final switched = cinemaRouteSwitchSelection(
        currentEpisode: current,
        targetRoute: target,
        positionSeconds: 1200,
      );
      expect(switched, (episodeIndex: 1, positionSeconds: 1200));
      // The retained target position can be passed onward if this route fails.
      expect(
        cinemaRouteSwitchSelection(
          currentEpisode: target.episodes[1],
          targetRoute: const CinemaRoute(name: '线路 C', episodes: [current]),
          positionSeconds: switched!.positionSeconds,
        ),
        (episodeIndex: 0, positionSeconds: 1200),
      );
    },
  );

  test('ambiguous or renamed route episodes require manual selection', () {
    const current = CinemaEpisode(name: '第 5 集', url: 'https://example.org/5');
    expect(
      cinemaRouteSwitchSelection(
        currentEpisode: current,
        targetRoute: const CinemaRoute(
          name: '重复',
          episodes: [current, current],
        ),
        positionSeconds: 1200,
      ),
      isNull,
    );
    expect(
      cinemaRouteSwitchSelection(
        currentEpisode: current,
        targetRoute: const CinemaRoute(
          name: '重命名',
          episodes: [CinemaEpisode(name: '05', url: 'https://example.org/b/5')],
        ),
        positionSeconds: 1200,
      ),
      isNull,
    );
    expect(
      cinemaRouteSwitchSelection(
        currentEpisode: current,
        targetRoute: const CinemaRoute(name: '空', episodes: []),
        positionSeconds: 1200,
      ),
      isNull,
    );
  });
}
