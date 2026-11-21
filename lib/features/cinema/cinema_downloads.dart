import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' show CancelToken;
import 'cinema_original_engine.dart';
import 'cinema_original_search.dart';
import 'cinema_original_match.dart';
import 'package:crypto/crypto.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'cinema_models.dart';

/// Retain the online identity so an offline viewing session shares its history
/// and favorite with the original work. Never use a file URL as its identity.
DownloadRecord cinemaDownloadRecord(
  CinemaTitle title,
  CinemaSource source,
  int routeIndex, {
  bool original = false,
}) {
  final route = title.routes[routeIndex];
  final digest = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            title.key,
            routeIndex,
            route.name,
            if (original) 'original',
          ]),
        ),
      )
      .toString();
  return DownloadRecord(
    0,
    title.title,
    title.poster,
    'cinema_$digest',
    {},
    DateTime.now(),
    sourceLabel: original ? '原画' : '${source.name} · ${route.name}',
    mediaMetadata: jsonEncode({
      'title': title.toJson(),
      'source': source.toJson(),
      'routeIndex': routeIndex,
      if (original) 'original': true,
    }),
  );
}

// The local transport could not supply the first bytes. A partial transfer
// already belonging to one file is resumed with its own identity.
class OriginalDownloadStartupFailure implements Exception {
  const OriginalDownloadStartupFailure();
}

class CinemaOriginalDownload {
  const CinemaOriginalDownload(this.title, this.episode);
  final CinemaTitle title;
  final String episode;

  static CinemaOriginalDownload? fromRecord(
    DownloadRecord record,
    DownloadEpisode episode,
  ) {
    if (!record.isCinema) return null;
    final metadata = jsonDecode(record.mediaMetadata) as Map;
    if (metadata['original'] != true) return null;
    final title = CinemaTitle.fromJson(
      Map<String, dynamic>.from(metadata['title']),
    );
    final preferences = metadata['originalEpisodes'];
    final ref = preferences is Map
        ? CinemaOriginalReference.fromJson(
            preferences[episode.episodeNumber.toString()],
          )
        : null;
    return CinemaOriginalDownload(
      title.copyWith(originalReference: ref),
      episode.episodeName,
    );
  }

  static void rememberSelections(
    DownloadRecord record,
    DownloadRecord media,
    Iterable<DownloadEpisode> added,
  ) {
    if (!media.isCinema) return;
    final fresh = jsonDecode(media.mediaMetadata) as Map;
    if (fresh['original'] != true) return;
    final metadata = jsonDecode(record.mediaMetadata) as Map;
    final title = CinemaTitle.fromJson(
      Map<String, dynamic>.from(fresh['title']),
    );
    final reference = title.originalReference;
    final preferences = Map<String, dynamic>.from(
      metadata['originalEpisodes'] ?? {},
    );
    for (final episode in added) {
      final coord = originalEpisode(episode.episodeName);
      if (reference == null ||
          reference.hash.isEmpty ||
          reference.season != null &&
              (coord.episode != reference.episode ||
                  coord.season != null && coord.season != reference.season)) {
        continue;
      }
      preferences[episode.episodeNumber.toString()] = reference.toJson();
    }
    if (preferences.isNotEmpty) metadata['originalEpisodes'] = preferences;
    record.mediaMetadata = jsonEncode(metadata);
  }

  Future<void> transfer(
    CancelToken cancel,
    Future<void> Function(OriginalStream, CinemaOriginalReference) save, {
    String previousHash = '',
    CinemaOriginalSearch? search,
    CinemaOriginalEngine? engine,
  }) async {
    final lookup = (search ?? CinemaOriginalSearch.instance).find(
      title,
      episode,
    );
    final local = engine ?? CinemaOriginalEngine.instance;
    if (!local.available) throw const FormatException('本机原画引擎不可用');
    if (previousHash.isNotEmpty ||
        title.originalReference?.hash.isNotEmpty != true) {
      final ready = previousHash.isNotEmpty
          ? lookup.waitForEdition(previousHash)
          : lookup.ready.then((_) => lookup.waitForChinese());
      await Future.any([ready, cancel.whenCancel.then((_) {})]);
    }
    final attempted = <String>{};
    final ref = title.originalReference;
    OriginalSelection? choose(OriginalMatches? matches) => local.preferred(
      matches,
      excluding: attempted,
      preferredHash: previousHash.isNotEmpty
          ? previousHash
          : matches?.work.season == ref?.season &&
                matches?.work.episode == ref?.episode
          ? ref?.hash ?? ''
          : '',
    );
    while (!cancel.isCancelled) {
      final selection = await Future.any<OriginalSelection?>([
        lookup.nextAvailable(choose),
        cancel.whenCancel.then((_) => null),
      ]);
      if (cancel.isCancelled) return;
      if (selection == null) break;
      attempted.add(selection.edition.hash);
      OriginalStream stream;
      try {
        stream = await local.open(
          selection.matches,
          selection.edition,
          cancel: cancel,
        );
      } on Exception {
        continue;
      }
      try {
        if (!cancel.isCancelled) {
          final reference = originalLibraryTitle(
            title,
            selection.matches,
            edition: selection.edition,
          ).originalReference!;
          await save(stream, reference);
        }
        return;
      } on OriginalDownloadStartupFailure {
        continue;
      } finally {
        await stream.close();
      }
    }
    if (!cancel.isCancelled) {
      throw FormatException(attempted.isEmpty ? '这一集暂无匹配的原画' : '这一集的原画暂时无法连接');
    }
  }
}

Future<CinemaTitle> cinemaSavedOriginalTitle(
  CinemaTitle title,
  String videoPath,
) async {
  try {
    final directory = File(videoPath).parent;
    final file = File.fromUri(directory.uri.resolve('.naku-transfer.json'));
    final data = jsonDecode(await file.readAsString());
    final reference = CinemaOriginalReference.fromJson(
      data is Map ? data['originalReference'] : null,
    );
    if (reference != null && reference.hash.isNotEmpty) {
      return title.copyWith(originalReference: reference);
    }
  } on FileSystemException {
    // Downloads from older versions still play directly from disk.
  } on FormatException {
    // The video is independent of its optional library metadata.
  }
  return title;
}

class CinemaOfflinePlayback {
  const CinemaOfflinePlayback(
    this.title,
    this.source,
    this.paths,
    this.episodeIndex,
  );
  final CinemaTitle title;
  final CinemaSource source;
  final Map<String, String> paths;
  final int episodeIndex;

  static CinemaOfflinePlayback? fromRecord(
    DownloadRecord record,
    DownloadEpisode selected,
    String? Function(DownloadEpisode) localPath,
  ) {
    if (!record.isCinema) return null;
    final metadata = jsonDecode(record.mediaMetadata) as Map<String, dynamic>;
    final original = CinemaTitle.fromJson(
      Map<String, dynamic>.from(metadata['title'] as Map),
    );
    final source = CinemaSource.fromJson(
      Map<String, dynamic>.from(metadata['source'] as Map),
    );
    final road = metadata['routeIndex'] as int;
    final entries =
        record.episodes.values
            .where((e) => e.status == DownloadStatus.completed)
            .toList()
          ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    final episodes = <CinemaEpisode>[];
    final paths = <String, String>{};
    var selectedIndex = -1;
    for (final entry in entries) {
      final file = localPath(entry);
      if (file == null) continue;
      if (entry.episodeNumber == selected.episodeNumber) {
        selectedIndex = episodes.length;
      }
      episodes.add(
        CinemaEpisode(name: entry.episodeName, url: entry.episodePageUrl),
      );
      paths[entry.episodePageUrl] = file;
    }
    if (selectedIndex < 0) return null;
    return CinemaOfflinePlayback(
      original.copyWith(
        routes: [
          CinemaRoute(
            name: metadata['original'] == true
                ? '原画'
                : original.routes[road].name,
            episodes: episodes,
          ),
        ],
      ),
      source,
      paths,
      selectedIndex,
    );
  }
}
