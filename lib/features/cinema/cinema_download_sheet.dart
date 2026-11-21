import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';
import 'cinema_downloads.dart';
import 'cinema_models.dart';
import 'cinema_original_engine.dart';
import 'cinema_original_search.dart';
import 'cinema_nas_media.dart';

Future<void> showCinemaDownloadSheet(
  BuildContext context, {
  required CinemaTitle title,
  required CinemaSource source,
  int routeIndex = 0,
  int? episodeIndex,
  bool preferOriginal = false,
  CinemaOriginalEngine? originalEngine,
}) async {
  if (!NakuDevice.canDownload) return;
  if (title.routes.isEmpty ||
      routeIndex < 0 ||
      routeIndex >= title.routes.length) {
    return;
  }
  final downloads = inject<DownloadController>();
  final groups = [
    if ((originalEngine ?? CinemaOriginalEngine.instance).available &&
        source.id != cinemaNASSource.id &&
        !title.isDirectMedia)
      (road: routeIndex, original: true),
    if (title.sourceId != originalCatalogSource.id)
      for (var i = 0; i < title.routes.length; i++) (road: i, original: false),
  ];
  if (groups.isEmpty) return;
  final records = [
    for (final group in groups)
      cinemaDownloadRecord(title, source, group.road, original: group.original),
  ];
  final initial = groups.indexWhere(
    (g) => g.road == routeIndex && g.original == preferOriginal,
  );
  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (_) => EpisodeDownloadPicker(
      title: title.title,
      initialGroup: initial < 0 ? 0 : initial,
      initialEpisode: episodeIndex,
      groups: [
        for (var i = 0; i < groups.length; i++)
          DownloadEpisodeGroup(
            name: records[i].sourceLabel,
            labels: title.routes[groups[i].road].episodes
                .map((e) => e.name)
                .toList(),
            urls: title.routes[groups[i].road].episodes
                .map((e) => e.url)
                .toList(),
            queuedUrls: queuedDownloadUrls(
              downloads.getRecord(0, records[i].pluginName),
            ),
          ),
      ],
      onDownload: (i, indexes) {
        final road = groups[i].road;
        return downloads.startEpisodeDownloads(
          media: records[i],
          selections: [
            for (final index in indexes)
              DownloadSelection(
                number: index + 1,
                name: title.routes[road].episodes[index].name,
                road: road,
                url: title.routes[road].episodes[index].url,
              ),
          ],
        );
      },
    ),
  );
}
