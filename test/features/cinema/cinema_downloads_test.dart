import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_downloads.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/modules/download/download_module.dart';

const source = CinemaSource(
  id: 'film',
  name: 'Film source',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.invalid/api',
);
const title = CinemaTitle(
  id: '1',
  sourceId: 'film',
  title: 'Fixture',
  routes: [
    CinemaRoute(
      name: 'HD',
      episodes: [
        CinemaEpisode(name: '1', url: 'https://fixture.invalid/1'),
        CinemaEpisode(name: '2', url: 'https://fixture.invalid/2'),
      ],
    ),
  ],
);
DownloadEpisode episode(int n) => DownloadEpisode(
  n,
  '$n',
  0,
  DownloadStatus.completed,
  1,
  1,
  1,
  '/fixture/$n.mp4',
  '/fixture',
  'https://fixture.invalid/$n.mp4',
  DateTime(2026),
  '',
  100,
  'https://fixture.invalid/$n',
);
void main() {
  test(
    'offline selection retains original identity and URL while excluding missing downloads',
    () {
      final record = cinemaDownloadRecord(title, source, 0);
      record.episodes.addAll({1: episode(1), 2: episode(2)});
      final offline = CinemaOfflinePlayback.fromRecord(
        record,
        record.episodes[2]!,
        (e) => e.episodeNumber == 2 ? '/saved/2.mp4' : null,
      )!;
      expect(offline.title.key, title.key);
      expect(offline.paths, {'https://fixture.invalid/2': '/saved/2.mp4'});
      expect(
        offline.title.routes.single.episodes.single.url,
        'https://fixture.invalid/2',
      );
      expect(offline.episodeIndex, 0);
      final history = CinemaHistory(
        title: title,
        routeIndex: 0,
        episodeIndex: 1,
        positionSeconds: 90,
        durationSeconds: 1200,
        updatedAt: DateTime(2026),
      );
      expect(cinemaResumePosition(offline.title, history, 0, 0), 90);
      expect(record.bangumiId, 0);
      expect(record.key, isNot('Film source_1'));
      expect(
        CinemaOfflinePlayback.fromRecord(
          record,
          record.episodes[1]!,
          (_) => null,
        ),
        isNull,
      );
    },
  );
  test(
    'legacy anime records survive new Hive fields and cinema metadata survives reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'naku-download-migration-',
      );
      Hive.init(dir.path);
      Hive.registerAdapter(_LegacyRecord());
      Hive.registerAdapter(_LegacyEpisode());
      var box = await Hive.openBox<DownloadRecord>('fixture');
      await box.put(
        'anime',
        DownloadRecord(309311, 'Anime', '', 'rule', {
          1: episode(1),
        }, DateTime(2026)),
      );
      await box.close();
      Hive.registerAdapter(DownloadRecordAdapter(), override: true);
      Hive.registerAdapter(DownloadEpisodeAdapter(), override: true);
      box = await Hive.openBox<DownloadRecord>('fixture');
      final anime = box.get('anime')!;
      expect(anime.isCinema, isFalse);
      expect(anime.displaySource, 'rule');
      expect(anime.episodes[1]!.requestHeadersJson, isEmpty);
      final cinema = cinemaDownloadRecord(title, source, 0);
      cinema.episodes[1] = episode(1)
        ..requestHeadersJson = '{"Referer":"https://fixture.invalid/"}';
      await box.put('cinema', cinema);
      await box.close();
      box = await Hive.openBox<DownloadRecord>('fixture');
      expect(box.get('cinema')!.isCinema, isTrue);
      expect(box.get('cinema')!.mediaMetadata, cinema.mediaMetadata);
      expect(
        box.get('cinema')!.episodes[1]!.requestHeadersJson,
        contains('Referer'),
      );
      await Hive.close();
      await dir.delete(recursive: true);
    },
  );
}

class _LegacyRecord extends TypeAdapter<DownloadRecord> {
  @override
  int get typeId => 7;
  @override
  DownloadRecord read(BinaryReader r) => throw UnimplementedError();
  @override
  void write(BinaryWriter w, DownloadRecord r) {
    w.writeByte(6);
    final values = [
      r.bangumiId,
      r.bangumiName,
      r.bangumiCover,
      r.pluginName,
      r.episodes,
      r.createdAt,
    ];
    for (var i = 0; i < values.length; i++) {
      w.writeByte(i);
      w.write(values[i]);
    }
  }
}

class _LegacyEpisode extends TypeAdapter<DownloadEpisode> {
  @override
  int get typeId => 8;
  @override
  DownloadEpisode read(BinaryReader r) => throw UnimplementedError();
  @override
  void write(BinaryWriter w, DownloadEpisode e) {
    final values = [
      e.episodeNumber,
      e.episodeName,
      e.road,
      e.status,
      e.progressPercent,
      e.totalSegments,
      e.downloadedSegments,
      e.localM3u8Path,
      e.downloadDirectory,
      e.networkM3u8Url,
      e.completedAt,
      e.errorMessage,
      e.totalBytes,
      e.episodePageUrl,
      e.danmakuData,
      e.danDanBangumiID,
    ];
    w.writeByte(values.length);
    for (var i = 0; i < values.length; i++) {
      w.writeByte(i);
      w.write(values[i]);
    }
  }
}
