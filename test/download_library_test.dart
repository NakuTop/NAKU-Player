import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_downloads.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/download/download_library.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';

DownloadEpisode episode(int number, {String? name}) => DownloadEpisode(
  number,
  name ?? '第$number集',
  0,
  DownloadStatus.completed,
  1,
  1,
  1,
  '/$number.mp4',
  '/$number',
  '',
  DateTime(2026),
  '',
  10,
  '/episode/$number',
);
DownloadRecord anime(int id, String source, List<int> episodes) =>
    DownloadRecord(id, '死神 千年血战篇', '', source, {
      for (final number in episodes) number: episode(number),
    }, DateTime(2026));
const source = CinemaSource(
  id: 'one',
  name: '来源一',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.invalid',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'anime groups by subject across sources without overwriting equal episode numbers',
    () {
      final a = anime(412916, 'one', [1, 3]);
      final b = anime(412916, 'two', [1, 2]);
      final sequel = anime(484322, 'one', [1]);
      final works = groupDownloadWorks([a, b, sequel]);
      expect(works.length, 2);
      expect(works.first.entries.length, 4);
      expect(works.first.entries.map((e) => e.key).toSet().length, 4);
      expect(works.first.sources, ['one', 'two']);
      expect(a.episodes.keys, [1, 3]);
      expect(b.episodes.keys, [1, 2]);
    },
  );
  test('cinema groups routes and sources but preserves season and kind', () {
    DownloadRecord record(
      String provider,
      String title,
      String category,
      String year,
    ) {
      final r = cinemaDownloadRecord(
        CinemaTitle(
          id: '$title-$category',
          sourceId: provider,
          title: title,
          category: category,
          year: year,
          routes: const [
            CinemaRoute(
              name: 'HD',
              episodes: [
                CinemaEpisode(name: '第1集', url: 'https://fixture.invalid/1'),
              ],
            ),
          ],
        ),
        source,
        0,
      );
      r.episodes[1] = episode(1);
      return r;
    }

    final works = groupDownloadWorks([
      record('one', '同名作品 第一季', '电视剧', '2026'),
      record('two', '同名作品 第一季', '电视剧', '2026'),
      record('two', '同名作品 第二季', '电视剧', '2026'),
      record('film', '同名作品 第一季', '电影', '2026'),
    ]);
    expect(works.length, 3);
    expect(works.first.entries.length, 2);
  });
  test(
    'offline playlist spans sources and selected version wins without conflating specials',
    () {
      final a = anime(412916, 'one', [1, 3]);
      final b = anime(412916, 'two', [1, 2]);
      b.episodes[4] = episode(4, name: 'SP1');
      final work = groupDownloadWorks([a, b]).single;
      final chosen = DownloadEntry(b, b.episodes[1]!);
      final playlist = downloadOfflinePlaylist(work, chosen, (_) => true);
      expect(playlist.length, 4);
      expect(playlist.first.record.key, b.key);
      expect(playlist[1].record.key, b.key);
      expect(playlist[2].record.key, a.key);
      expect(
        downloadEpisodeIdentity(b.episodes[4]!),
        isNot(downloadEpisodeIdentity(b.episodes[1]!)),
      );
      expect(
        downloadOfflinePlaylist(
          work,
          chosen,
          (e) => e.episode.episodeNumber != 2,
        ).length,
        3,
      );
    },
  );
  test(
    'merged offline playback reads each original source and preserves its episode identity',
    () async {
      final a = anime(412916, 'one', [1]);
      final b = anime(412916, 'two', [4]);
      b.episodes[4]!.episodeName = '第2集';
      final entries = [
        DownloadEntry(a, a.episodes[1]!),
        DownloadEntry(b, b.episodes[4]!),
      ];
      final repository = _Repository(entries);
      final controller = VideoPageController(
        _History(),
        repository,
        _Manager(),
      );
      final item = BangumiItem(
        id: 412916,
        type: 2,
        name: '死神',
        nameCn: '死神',
        summary: '',
        airDate: '',
        airWeekday: 0,
        rank: 0,
        images: {},
        tags: [],
        alias: [],
        ratingScore: 0,
        votes: 0,
        votesCount: [],
        info: '',
      );
      controller.applyPlaybackArgs(
        OfflineVideoPlaybackArgs(
          bangumiItem: item,
          pluginName: b.pluginName,
          episodeNumber: 4,
          road: 0,
          downloadedEpisodes: b.episodes.values.toList(),
          downloadEntries: entries,
        ),
      );
      expect(controller.selectedEpisode.episode, 2);
      expect(controller.currentHistoryIdentity!.pluginName, b.pluginName);
      expect(controller.currentHistoryIdentity!.episodeNumber, 4);
      final player = _Player();
      await controller.changeEpisode(1, offset: 1, playerController: player);
      expect(repository.requested.last, (a.pluginName, 1));
      expect(player.params!.videoUrl, '/1.mp4');
      expect(player.params!.pluginName, a.pluginName);
      await controller.changeEpisode(2, offset: 1, playerController: player);
      expect(repository.requested.last, (b.pluginName, 4));
      expect(player.params!.videoUrl, '/4.mp4');
      expect(player.params!.danmakuEpisodeNumber, 4);
      expect(controller.currentHistoryIdentity!.pluginName, b.pluginName);
      controller.dispose();
    },
  );
}

class _Repository extends Fake implements IDownloadRepository {
  _Repository(this.entries);
  final List<DownloadEntry> entries;
  final requested = <(String, int)>[];
  @override
  DownloadEpisode? getEpisode(int id, String plugin, int number) {
    requested.add((plugin, number));
    return entries
        .where(
          (e) =>
              e.record.pluginName == plugin &&
              e.episode.episodeNumber == number,
        )
        .firstOrNull
        ?.episode;
  }
}

class _Manager extends Fake implements IDownloadManager {
  @override
  String? getLocalVideoPath(DownloadEpisode? e) => e?.localM3u8Path;
}

class _History extends Fake implements HistoryController {}

class _Danmaku extends Fake implements PlayerDanmakuController {
  @override
  void finishDanmakuLoad({bool disableDanmaku = false}) {}
}

class _Player extends Fake implements PlayerController {
  PlaybackInitParams? params;
  @override
  final danmaku = _Danmaku();
  @override
  Future<void> stop() async {}
  @override
  Future<bool> init(PlaybackInitParams p) async {
    params = p;
    return false;
  }
}
