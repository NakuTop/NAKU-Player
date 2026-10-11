import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';
import 'cinema_downloads.dart';
import 'cinema_models.dart';

Future<void> showCinemaDownloadSheet(
  BuildContext context, {
  required CinemaTitle title,
  required CinemaSource source,
  int routeIndex = 0,
  int? episodeIndex,
}) async {
  final downloads = inject<DownloadController>();
  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (_) => EpisodeDownloadPicker(
      title: title.title,
      initialGroup: routeIndex,
      initialEpisode: episodeIndex,
      groups: [
        for (var i = 0; i < title.routes.length; i++)
          DownloadEpisodeGroup(
            name: '${source.name} · ${title.routes[i].name}',
            labels: title.routes[i].episodes.map((e) => e.name).toList(),
            urls: title.routes[i].episodes.map((e) => e.url).toList(),
            queuedUrls: queuedDownloadUrls(
              downloads.getRecord(
                0,
                cinemaDownloadRecord(title, source, i).pluginName,
              ),
            ),
          ),
      ],
      onDownload: (road, indexes) => downloads.startEpisodeDownloads(
        media: cinemaDownloadRecord(title, source, road),
        selections: [
          for (final index in indexes)
            DownloadSelection(
              number: index + 1,
              name: title.routes[road].episodes[index].name,
              road: road,
              url: title.routes[road].episodes[index].url,
            ),
        ],
      ),
    ),
  );
}
