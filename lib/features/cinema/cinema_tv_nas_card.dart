import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';
import 'package:kazumi/services/network/cinema_poster_file_system.dart';
import 'cinema_models.dart';
import 'cinema_nas_media.dart';

// NAS artwork URLs carry NAS sessions and must never use public-image proxies,
// acceleration hosts or fallback CDNs. Keep the existing persistent directory.
final _nasPosterCache = CacheManager(
  Config(
    'nakuTVNASPosters',
    fileService: HttpFileService(
      httpClient: IOClient(HttpClient()..findProxy = (_) => 'DIRECT'),
    ),
    fileSystem: CinemaPosterFileSystem(),
    stalePeriod: const Duration(days: 90),
    maxNrOfCacheObjects: 600,
  ),
);

Map<String, String>? _reference(CinemaTitle title) {
  if (title.sourceId != cinemaNASSource.id) return null;
  for (final route in title.routes) {
    for (final episode in route.episodes) {
      try {
        final ref = parseNASMediaReference(episode.url);
        if (title.id == '${ref['nas']}:${ref['id']}') return ref;
      } on FormatException {
        // Non-NAS or stale entries never resolve against another NAS item.
      }
    }
  }
  return null;
}

String? cinemaTVNASPosterKey(CinemaTitle title) {
  final ref = _reference(title);
  return ref == null
      ? null
      : 'nas-poster-${sha256.convert(utf8.encode('${ref['nas']}:${ref['library']}:${ref['id']}'))}';
}

class CinemaTVNASMetadata {
  const CinemaTVNASMetadata(this.title, {this.posterPath = '', this.reference});
  final CinemaTitle title;
  final String posterPath;
  final Map<String, String>? reference;
}

/// Restores legacy history cards from the exact NAS item, never from a name.
/// Two metadata workers and a bounded queue; no movie streams or media probes.
class CinemaTVNASMetadataRepository {
  CinemaTVNASMetadataRepository(this.client);
  final CinemaNASClient client;
  final _cache = <String, (DateTime, Future<CinemaTVNASMetadata>)>{};
  final _waiters = <Completer<void>>[];
  int _running = 0;
  bool _disposed = false;

  Future<CinemaTVNASMetadata> resolve(CinemaTitle title) {
    final ref = _reference(title), key = cinemaTVNASPosterKey(title);
    if (_disposed || ref == null || key == null) {
      return Future.value(CinemaTVNASMetadata(title));
    }
    final saved = _cache[key];
    if (saved != null && DateTime.now().isBefore(saved.$1)) {
      return _forTitle(saved.$2, title);
    }
    late final Future<CinemaTVNASMetadata> future;
    future = _load(title, ref).then((result) {
      if (result.reference == null && identical(_cache[key]?.$2, future)) {
        _cache[key] = (DateTime.now().add(const Duration(seconds: 30)), future);
      }
      return result;
    });
    _cache[key] = (DateTime.now().add(const Duration(minutes: 5)), future);
    while (_cache.length > 128) {
      _cache.remove(_cache.keys.first);
    }
    return _forTitle(future, title);
  }

  Future<CinemaTVNASMetadata> _forTitle(
    Future<CinemaTVNASMetadata> future,
    CinemaTitle title,
  ) => future.then(
    (result) => CinemaTVNASMetadata(
      title.copyWith(
        year: title.year.isNotEmpty ? title.year : result.title.year,
        doubanId: title.doubanId.isNotEmpty
            ? title.doubanId
            : result.title.doubanId,
        imdbId: title.imdbId.isNotEmpty ? title.imdbId : result.title.imdbId,
      ),
      posterPath: result.posterPath,
      reference: result.reference,
    ),
  );

  Future<CinemaTVNASMetadata> _load(
    CinemaTitle title,
    Map<String, String> ref,
  ) async {
    if (_running >= 2) {
      if (_waiters.length >= 16) return CinemaTVNASMetadata(title);
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _running++;
    }
    try {
      if (_disposed) return CinemaTVNASMetadata(title);
      await client
          .call('ensure', {'namespace': ref['nas']})
          .timeout(const Duration(seconds: 8));
      final detail = await client
          .call('details', {
            'id': int.parse(ref['id']!),
            'library': int.parse(ref['library']!),
            'tv': title.category.contains('剧') || title.category.contains('劇'),
          })
          .timeout(const Duration(seconds: 8));
      var info = detail['video_info'];
      if (info is! Map) return CinemaTVNASMetadata(title);
      final returnedId = nasInt(info['ug_video_info_id']);
      if (returnedId > 0 && returnedId != int.parse(ref['id']!)) {
        final season = nasRows(detail['season_info'])
            .where(
              (row) => nasInt(row['ug_video_info_id']) == int.parse(ref['id']!),
            )
            .firstOrNull;
        if (season == null) return CinemaTVNASMetadata(title);
        info = season; // A parent-series ID never replaces a season identity.
      }
      final row = <String, dynamic>{
        ...Map<String, dynamic>.from(info),
        'ug_video_info_id': int.parse(ref['id']!),
        'media_lib_set_id': int.parse(ref['library']!),
        'type': title.category.contains('剧') || title.category.contains('劇')
            ? 2
            : 1,
      };
      final resolved = createCinemaNASTitle(
        namespace: ref['nas']!,
        row: row,
        files: const [],
      );
      // Playback routes, selected season and history identity stay with the
      // saved item. Fresh exact IDs/year allow all three rating providers.
      return CinemaTVNASMetadata(
        title.copyWith(
          year: title.year.isNotEmpty ? title.year : resolved.year,
          doubanId: title.doubanId.isNotEmpty
              ? title.doubanId
              : resolved.doubanId,
          imdbId: title.imdbId.isNotEmpty ? title.imdbId : resolved.imdbId,
        ),
        posterPath: info['poster_path'] is String
            ? (info['poster_path'] as String).trim()
            : '',
        reference: ref,
      );
    } catch (_) {
      return CinemaTVNASMetadata(title);
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
  }
}

/// Uses NAKU's persistent poster directory and a direct NAS image transport,
/// with an account-scoped key independent of the expiring session token.
class CinemaTVNASCard extends StatefulWidget {
  const CinemaTVNASCard({
    super.key,
    required this.title,
    required this.repository,
    required this.builder,
  });
  final CinemaTitle title;
  final CinemaTVNASMetadataRepository repository;
  final Widget Function(CinemaTitle title, Widget? poster) builder;
  @override
  State<CinemaTVNASCard> createState() => _CinemaTVNASCardState();
}

class _CinemaTVNASCardState extends State<CinemaTVNASCard> {
  CinemaTitle? _title;
  File? _file;
  String? _url;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CinemaTVNASCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.repository != widget.repository) {
      _title = null;
      _file = null;
      _url = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation, key = cinemaTVNASPosterKey(widget.title);
    bool current() => mounted && generation == _generation;
    if (key == null) return;
    var freshPoster = false;
    try {
      final cached = await _nasPosterCache.getFileFromCache(key);
      if (!current()) return;
      if (cached != null && await cached.file.exists() && current()) {
        freshPoster = cached.validTill.isAfter(DateTime.now());
        setState(() => _file = cached.file);
      }
    } catch (_) {
      /* Missing/evicted cache can resolve from NAS below. */
    }
    if (!current()) return;
    final metadata = await widget.repository.resolve(widget.title);
    if (!current()) return;
    setState(() => _title = metadata.title);
    if (freshPoster ||
        metadata.posterPath.isEmpty ||
        metadata.reference == null) {
      return;
    }
    try {
      final ref = metadata.reference!;
      await widget.repository.client.call('ensure', {'namespace': ref['nas']});
      final url = await widget.repository.client.asset(
        {
          'ug_video_info_id': int.parse(ref['id']!),
          'media_lib_set_id': int.parse(ref['library']!),
        },
        metadata.posterPath,
        poster: true,
      );
      final uri = Uri.tryParse(url);
      if (current() &&
          uri != null &&
          {'https', 'http'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        setState(() => _url = url);
      }
    } catch (_) {
      /* Existing public artwork and the normal placeholder remain. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _title ?? widget.title;
    final layers = <Widget>[
      if (_file != null)
        Image.file(
          _file!,
          fit: BoxFit.cover,
          cacheWidth: 640,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      if (_url != null)
        CachedNetworkImage(
          imageUrl: _url!,
          cacheKey: cinemaTVNASPosterKey(widget.title),
          cacheManager: _nasPosterCache,
          memCacheWidth: 640,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        ),
    ];
    final Widget? poster = layers.isEmpty
        ? null
        : Stack(fit: StackFit.expand, children: layers);
    return widget.builder(title, poster);
  }
}
