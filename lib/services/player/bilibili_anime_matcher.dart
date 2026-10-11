import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'package:path_provider/path_provider.dart';

class BilibiliAnimeMatches {
  const BilibiliAnimeMatches(
    this.candidates, {
    this.automatic,
    this.offset = 0,
  });
  final List<BilibiliAnimeCandidate> candidates;
  final BilibiliAnimeCandidate? automatic;
  final int offset;
}

/// Bangumi IDs establish season identity; episode numbers establish the CID.
/// Search results require exact names and a compatible year before auto-use.
class BilibiliAnimeMatcher {
  BilibiliAnimeMatcher({
    BilibiliDanmakuClient? client,
    this.directory,
    Future<Map<String, List<String>>> Function()? mappingLoader,
  }) : client = client ?? BilibiliDanmakuClient(),
       _mappingLoader = mappingLoader ?? _bundledMappings;

  static final instance = BilibiliAnimeMatcher();
  final BilibiliDanmakuClient client;
  final Directory? directory;
  final Future<Map<String, List<String>>> Function() _mappingLoader;
  Future<Map<String, List<String>>>? _mappings;
  final _videos = <String, (DateTime, Future<BilibiliDanmakuVideo>)>{};
  final _revisions = <int, int>{};
  final _loads = <String, Future<List<DanmakuEntry>>>{};
  final _bindingWrites = <int, Future<void>>{};

  static Future<Map<String, List<String>>> _bundledMappings() async {
    final data =
        jsonDecode(
              await rootBundle.loadString('assets/data/bangumi_bilibili.json'),
            )
            as Map;
    return (data['subjects'] as Map).map(
      (k, v) => MapEntry('$k', List<String>.from(v as List)),
    );
  }

  Future<Directory> _root() async =>
      directory ??
      Directory(
        '${(await getApplicationSupportDirectory()).path}/bilibili-danmaku',
      );
  Future<File> _bindingFile(int subject) async {
    if (subject <= 0) throw const FormatException('无效的动漫编号');
    return File('${(await _root()).path}/matches/$subject.json');
  }

  static bool _validReference(String ref) =>
      RegExp(r'^(md|ss)[1-9][0-9]{0,17}$').hasMatch(ref);

  Future<BilibiliAnimeMatches?> _saved(int subject) async {
    try {
      final file = await _bindingFile(subject);
      if (!await file.exists() || await file.length() > 8192) return null;
      final value = jsonDecode(await file.readAsString()) as Map;
      final ref = value['reference'], offset = value['offset'];
      if (ref is! String ||
          !_validReference(ref) ||
          offset is! int ||
          offset.abs() > 2000) {
        return null;
      }
      final candidate = BilibiliAnimeCandidate(
        ref,
        '${value['title'] ?? '已匹配番剧'}',
      );
      return BilibiliAnimeMatches(
        [candidate],
        automatic: candidate,
        offset: offset,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(
    int subject,
    BilibiliAnimeCandidate candidate,
    int offset,
  ) async {
    if (!_validReference(candidate.reference) || offset.abs() > 2000) {
      throw const FormatException('无效的番剧匹配');
    }
    _revisions[subject] = (_revisions[subject] ?? 0) + 1;
    await _writeBinding(subject, candidate, offset, _revisions[subject]!);
  }

  Future<void> _writeBinding(
    int subject,
    BilibiliAnimeCandidate candidate,
    int offset,
    int revision,
  ) {
    final previous = _bindingWrites[subject] ?? Future<void>.value();
    final future = previous.catchError((Object _) {}).then((_) async {
      if ((_revisions[subject] ?? 0) != revision) return;
      final file = await _bindingFile(subject);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'reference': candidate.reference,
          'title': candidate.title,
          'offset': offset,
        }),
        flush: true,
      );
      if ((_revisions[subject] ?? 0) == revision) {
        await tmp.rename(file.path);
      } else {
        await tmp.delete();
      }
    });
    _bindingWrites[subject] = future;
    return future.whenComplete(() {
      if (identical(_bindingWrites[subject], future)) {
        _bindingWrites.remove(subject);
      }
    });
  }

  Future<BilibiliAnimeMatches> discover(
    BangumiItem subject, {
    String? keyword,
  }) async {
    if (keyword == null) {
      final saved = await _saved(subject.id);
      if (saved != null) return saved;
      final refs =
          (await (_mappings ??= _mappingLoader()))['${subject.id}'] ??
          const <String>[];
      final candidates = [
        for (final ref in refs.where(_validReference))
          BilibiliAnimeCandidate(
            ref,
            subject.nameCn.isEmpty ? subject.name : subject.nameCn,
          ),
      ];
      if (candidates.isNotEmpty) {
        return BilibiliAnimeMatches(
          candidates,
          automatic: candidates.length == 1 ? candidates.single : null,
        );
      }
    }
    final queries = keyword == null
        ? [
            subject.nameCn,
            subject.name,
            ...subject.alias,
          ].where((n) => n.trim().isNotEmpty).toSet().take(2)
        : [keyword];
    final found = <String, BilibiliAnimeCandidate>{};
    Object? failure;
    var successes = 0;
    for (final query in queries) {
      try {
        for (final candidate in await client.searchAnime(query)) {
          found[candidate.reference] = candidate;
        }
        successes++;
      } catch (e) {
        failure = e;
      }
    }
    if (successes == 0 && failure != null) throw failure;
    final names = [
      subject.name,
      subject.nameCn,
      ...subject.alias,
    ].where((n) => n.isNotEmpty).map(_name).toSet();
    final year = int.tryParse(subject.airDate.split('-').first);
    final exact = found.values
        .where(
          (c) =>
              (names.contains(_name(c.title)) ||
                  (c.originalTitle.isNotEmpty &&
                      names.contains(_name(c.originalTitle)))) &&
              (year == null || c.year == null || year == c.year),
        )
        .toList();
    return BilibiliAnimeMatches(
      found.values.toList(),
      automatic: exact.length == 1 ? exact.single : null,
    );
  }

  static String _name(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );

  Future<BilibiliDanmakuVideo> video(String reference) {
    final cached = _videos[reference];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      return cached.$2;
    }
    if (_videos.length >= 24) _videos.remove(_videos.keys.first);
    final future = client.video(reference);
    _videos[reference] = (DateTime.now(), future);
    return future.catchError((Object error) {
      if (identical(_videos[reference]?.$2, future)) _videos.remove(reference);
      throw error;
    });
  }

  static BilibiliDanmakuPage? episode(BilibiliDanmakuVideo video, int number) {
    final matches = video.pages
        .where((p) => p.episodeNumber == number)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  Future<List<DanmakuEntry>> load(
    BangumiItem subject,
    int number, {
    bool persist = true,
  }) {
    final revision = _revisions[subject.id] ?? 0;
    final key = '${subject.id}:$number:$revision:$persist';
    final existing = _loads[key];
    if (existing != null) return existing;
    final future = _load(subject, number, persist, revision);
    _loads[key] = future;
    return future.whenComplete(() => _loads.remove(key));
  }

  Future<List<DanmakuEntry>> _load(
    BangumiItem subject,
    int number,
    bool persist,
    int revision,
  ) async {
    final matches = await discover(subject);
    final candidate = matches.automatic;
    if (candidate == null) {
      throw FormatException(
        matches.candidates.isEmpty
            ? 'B 站没有找到对应番剧，可在弹幕切换中搜索其他名称'
            : '找到多个番剧版本，请在弹幕切换中选择一次，后续自动沿用',
      );
    }
    final cache = LocalDanmakuStore(
      directory: Directory(
        '${(await _root()).path}/comments/${candidate.reference}_${matches.offset}',
      ),
    );
    final cached = await cache.read(subject.id, number);
    if (cached != null) return cached;
    final details = await video(candidate.reference);
    final page = episode(details, number + matches.offset);
    if (page == null) throw const FormatException('B 站没有找到对应集号，请在弹幕切换中确认分集');
    final entries = await client.comments(page.cid);
    if (persist && (_revisions[subject.id] ?? 0) == revision) {
      try {
        await cache.save(subject.id, number, entries);
        // Exact search results become stable IDs for subsequent episodes and
        // offline reuse. A later explicit choice always wins over this request.
        if ((_revisions[subject.id] ?? 0) == revision) {
          await _writeBinding(subject.id, candidate, matches.offset, revision);
        }
      } catch (_) {
        /* Cache failure must not hide successfully fetched text. */
      }
    }
    return entries;
  }
}
