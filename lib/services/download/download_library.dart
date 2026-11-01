import 'dart:convert';

import 'package:kazumi/features/cinema/cinema_library_identity.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/modules/download/download_module.dart';

/// Presentation groups never replace the durable source/episode identity.
/// This lets a batch span sources without moving files or overwriting versions.
class DownloadEntry {
  const DownloadEntry(this.record, this.episode);
  final DownloadRecord record;
  final DownloadEpisode episode;
  (String, int) get key => (record.key, episode.episodeNumber);
}

class DownloadWork {
  DownloadWork(this.key, Iterable<DownloadRecord> records)
    : records = List.unmodifiable(records);
  final String key;
  final List<DownloadRecord> records;
  String get name => records.first.bangumiName;
  String get cover => records
      .map((r) => r.bangumiCover)
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  bool get isAnime => !records.first.isCinema;
  List<String> get sources =>
      records.map((r) => r.displaySource).toSet().toList();
  late final List<DownloadEntry> entries = [
    for (final r in records)
      for (final e in r.episodes.values) DownloadEntry(r, e),
  ]..sort(compareDownloadEntries);
}

bool downloadIsActive(int status) => {
  DownloadStatus.pending,
  DownloadStatus.resolving,
  DownloadStatus.downloading,
}.contains(status);

bool downloadCanResume(int status) =>
    status == DownloadStatus.paused || status == DownloadStatus.failed;

/// Keep specials apart from numbered episodes, including decimal episode labels.
String downloadEpisodeIdentity(DownloadEpisode episode) {
  final name = episode.episodeName.trim().toLowerCase();
  final numbered = RegExp(
    r'^(?:第\s*)?(\d+(?:\.\d+)?)\s*(?:集|话|話|期)?$',
  ).firstMatch(name);
  return numbered == null
      ? 'label:${name.isEmpty ? episode.episodeNumber : name}'
      : 'number:${num.parse(numbered[1]!)}';
}

int compareDownloadEntries(DownloadEntry a, DownloadEntry b) {
  double? number(DownloadEpisode e) {
    final key = downloadEpisodeIdentity(e);
    return key.startsWith('number:') ? double.tryParse(key.substring(7)) : null;
  }

  final left = number(a.episode), right = number(b.episode);
  final order = left != null && right != null
      ? left.compareTo(right)
      : a.episode.episodeNumber.compareTo(b.episode.episodeNumber);
  if (order != 0) return order;
  return a.record.key.compareTo(b.record.key);
}

List<DownloadWork> groupDownloadWorks(Iterable<DownloadRecord> values) {
  final records = values.where((r) => r.episodes.isNotEmpty).toList();
  final groups = <String, List<DownloadRecord>>{};
  final cinema = <String, DownloadRecord>{};
  final titles = <CinemaTitle>[];
  for (final record in records) {
    if (!record.isCinema) {
      final key = record.bangumiId > 0
          ? 'anime:${record.bangumiId}'
          : record.key;
      groups.putIfAbsent(key, () => []).add(record);
      continue;
    }
    try {
      final metadata = jsonDecode(record.mediaMetadata) as Map;
      final title = CinemaTitle.fromJson(
        Map<String, dynamic>.from(metadata['title']),
      );
      // One source title can have multiple downloaded routes.
      final identity = '${title.key}\u0000${record.key}';
      cinema[identity] = record;
      titles.add(CinemaTitle.fromJson({...title.toJson(), 'id': identity}));
    } catch (_) {
      groups.putIfAbsent(record.key, () => []).add(record);
    }
  }
  for (final group in groupCinemaLibraryTitles(titles)) {
    groups['cinema:${group.key}'] = [
      for (final t in group.variants) cinema[t.id]!,
    ];
  }
  final order = {for (var i = 0; i < records.length; i++) records[i].key: i};
  final works = [for (final g in groups.entries) DownloadWork(g.key, g.value)];
  works.sort((a, b) {
    int first(DownloadWork work) =>
        work.records.map((r) => order[r.key]!).reduce((a, b) => a < b ? a : b);
    return first(a).compareTo(first(b));
  });
  return works;
}

/// One usable version per episode for continuous offline playback. A selected
/// version wins; other episodes prefer its source, then another available source.
List<DownloadEntry> downloadOfflinePlaylist(
  DownloadWork work,
  DownloadEntry selected,
  bool Function(DownloadEntry) playable,
) {
  final entries =
      work.entries
          .where(
            (e) => e.episode.status == DownloadStatus.completed && playable(e),
          )
          .toList()
        ..sort((a, b) {
          int priority(DownloadEntry e) => e.key == selected.key
              ? 0
              : e.record.key == selected.record.key
              ? 1
              : 2;
          return priority(a).compareTo(priority(b));
        });
  final chosen = <String, DownloadEntry>{};
  for (final entry in entries) {
    chosen.putIfAbsent(downloadEpisodeIdentity(entry.episode), () => entry);
  }
  return chosen.values.toList()..sort(compareDownloadEntries);
}
