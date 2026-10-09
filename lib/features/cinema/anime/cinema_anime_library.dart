import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/storage/history_storage_coordinator.dart';
import 'package:kazumi/services/sync/history_sync_service.dart';
import '../cinema_models.dart';
import '../cinema_store.dart';

/// A live view of the original anime library. No migration, copies or lost
/// statuses: all existing collections appear as favorites, grouped by subject.
class CinemaAnimeLibrary extends ChangeNotifier {
  CinemaAnimeLibrary() {
    _subscriptions.add(
      GStorage.collectibles.watch().listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      GStorage.histories.watch().listen((_) => notifyListeners()),
    );
  }
  final _subscriptions = <StreamSubscription<dynamic>>[];
  List<CollectedBangumi> get favorites =>
      GStorage.collectibles.values.where((entry) => entry.type != 0).toList()
        ..sort((a, b) => b.time.compareTo(a.time));
  List<History> get history => groupAnimeHistory(GStorage.histories.values);

  Future<CinemaLibraryUndo?> removeFavorite(BangumiItem item) async {
    final old = GStorage.collectibles.get(item.id);
    if (old == null) return null;
    await GStorage.deleteCollectible(item.id);
    try {
      await GStorage.appendCollectChange(
        bangumiId: item.id,
        action: 3,
        type: old.type,
      );
    } catch (_) {
      await GStorage.restoreCollectibleIfAbsent(old);
      rethrow;
    }
    return CinemaLibraryUndo.action(() async {
      if (!await GStorage.restoreCollectibleIfAbsent(old)) return false;
      await GStorage.appendCollectChange(
        bangumiId: item.id,
        action: 1,
        type: old.type,
      );
      return true;
    });
  }

  Future<CinemaLibraryUndo?> removeHistory(
    BangumiItem item,
  ) => HistoryStorageCoordinator().run(() async {
    final box = GStorage.histories;
    final saved = <dynamic, History>{
      for (final key in box.keys)
        if (box.get(key)?.bangumiItem.id == item.id) key: box.get(key)!,
    };
    if (saved.isEmpty) return null;
    await box.deleteAll(saved.keys);
    final sync = HistorySyncService();
    for (final entry in saved.values) {
      await sync.appendSafely(() => sync.appendDeleteHistory(entry));
    }
    return CinemaLibraryUndo.action(
      () => HistoryStorageCoordinator().run(() async {
        // New progress wins over an old undo, across every source for this subject.
        if (box.values.any((entry) => entry.bangumiItem.id == item.id)) {
          return false;
        }
        await box.putAll(saved);
        for (final entry in saved.values) {
          for (final progress in entry.progresses.entries) {
            await sync.appendSafely(
              () => sync.appendUpsertProgress(
                history: entry,
                episode: progress.key,
                road: progress.value.road,
                progressMs: progress.value.progress.inMilliseconds,
                updatedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          }
        }
        return true;
      }),
    );
  });
  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}

List<History> groupAnimeHistory(Iterable<History> records) {
  final latest = <int, History>{};
  for (final entry in records) {
    final previous = latest[entry.bangumiItem.id];
    if (previous == null ||
        entry.lastWatchTime.isAfter(previous.lastWatchTime)) {
      latest[entry.bangumiItem.id] = entry;
    }
  }
  return latest.values.toList()
    ..sort((a, b) => b.lastWatchTime.compareTo(a.lastWatchTime));
}

CinemaTitle animeLibraryTitle(BangumiItem item) => CinemaTitle(
  id: '${item.id}',
  sourceId: 'bangumi-library',
  title: item.nameCn.isEmpty ? item.name : item.nameCn,
  poster: item.images['large'] ?? item.images['common'] ?? '',
  category: '动漫',
  genres: '动画',
  year: item.airDate.length >= 4 ? item.airDate.substring(0, 4) : '',
);
