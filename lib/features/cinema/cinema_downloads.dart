import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'cinema_models.dart';

/// Retain the online identity so an offline viewing session shares its history
/// and favorite with the original work. Never use a file URL as its identity.
DownloadRecord cinemaDownloadRecord(
  CinemaTitle title,
  CinemaSource source,
  int routeIndex,
) {
  final route = title.routes[routeIndex];
  final digest = sha256
      .convert(utf8.encode(jsonEncode([title.key, routeIndex, route.name])))
      .toString();
  return DownloadRecord(
    0,
    title.title,
    title.poster,
    'cinema_$digest',
    {},
    DateTime.now(),
    sourceLabel: '${source.name} · ${route.name}',
    mediaMetadata: jsonEncode({
      'title': title.toJson(),
      'source': source.toJson(),
      'routeIndex': routeIndex,
    }),
  );
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
          CinemaRoute(name: original.routes[road].name, episodes: episodes),
        ],
      ),
      source,
      paths,
      selectedIndex,
    );
  }
}
