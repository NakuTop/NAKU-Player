import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'cinema_media_transport.dart';
import 'cinema_playback_buffer.dart';

class CinemaCachePreferences {
  const CinemaCachePreferences({
    this.enabled = true,
    this.quotaMB = 2048,
    this.forwardSeconds = 300,
    this.nextSeconds = 90,
  });
  final bool enabled;
  final int quotaMB, forwardSeconds, nextSeconds;
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'quotaMB': quotaMB,
    'forwardSeconds': forwardSeconds,
    'nextSeconds': nextSeconds,
  };
  factory CinemaCachePreferences.parse(Map raw) => CinemaCachePreferences(
    enabled: raw['enabled'] != false,
    quotaMB: (raw['quotaMB'] is int ? raw['quotaMB'] as int : 2048).clamp(
      128,
      8192,
    ),
    forwardSeconds:
        (raw['forwardSeconds'] is int ? raw['forwardSeconds'] as int : 300)
            .clamp(30, 900),
    nextSeconds: (raw['nextSeconds'] is int ? raw['nextSeconds'] as int : 90)
        .clamp(0, 300),
  );
}

class _Resource {
  const _Resource(this.uri, this.manifest, this.persist);
  final Uri uri;
  final bool manifest, persist;
}

class _Segment {
  const _Segment(this.uri, this.start, this.duration, this.range);
  final Uri uri;
  final double start, duration;
  final String? range;
}

class CinemaCacheSession {
  CinemaCacheSession._(
    this.cache,
    this.id,
    this.headers, {
    this.manifestPolicy,
    bool backgroundPrefetchAllowed = true,
  }) : _backgroundPrefetchAllowed = backgroundPrefetchAllowed;
  final CinemaMediaCache cache;
  final String id;
  final Map<String, String> headers;
  final Future<String> Function(String manifest, Uri base)? manifestPolicy;
  final Map<String, _Resource> _resources = {};
  final Map<String, String> _ids = {};
  final Map<String, List<_Segment>> _playlists = {};
  bool closed = false, buffering = false, prefetching = false;
  bool _backgroundPrefetchAllowed;
  bool get backgroundPrefetchAllowed => _backgroundPrefetchAllowed;
  set backgroundPrefetchAllowed(bool allowed) {
    if (_backgroundPrefetchAllowed == allowed) return;
    _backgroundPrefetchAllowed = allowed;
    if (!allowed) {
      // A player may already be consuming this exact in-flight segment. Only
      // cancel speculative work, never a promoted foreground response.
      if (!cache._promoted.contains(_fetchKey)) _token?.cancel('当前播放优先，暂停后台预取');
    } else if (!closed && !buffering) {
      unawaited(cache._prefetch(this));
    }
  }

  double position = 0;
  int hits = 0, downloadedBytes = 0;
  String networkRoute = '';
  Uri? networkMediaUri;
  CancelToken? _token;
  String? _fetchKey;
  final Set<CancelToken> _requests = {};
  Timer? _timer;
  DateTime? _lastPrefetchAt;
  Uri register(Uri uri, {bool manifest = false, bool persist = true}) {
    if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
      throw const FormatException('媒体地址无效');
    }
    final key = '${manifest ? 'm' : 's'}:${persist ? 'cache' : 'pass'}:$uri';
    var index = _ids[key];
    if (index == null) {
      if (_resources.length >= 20000) throw const FormatException('媒体清单过大');
      index = '${_resources.length}';
      _ids[key] = index;
      _resources[index] = _Resource(uri, manifest, persist);
    }
    return Uri.parse(
      'http://127.0.0.1:${cache._server!.port}/${cache._secret}/$id/$index${manifest ? '/stream.m3u8' : '/segment'}',
    );
  }

  double playbackRate = 1;
  void update(Duration at, {required bool buffering, double rate = 1}) {
    playbackRate = CinemaPlaybackBufferPolicy(rate).rate;
    if ((position - at.inMilliseconds / 1000).abs() > 30) {
      _lastPrefetchAt = null;
    }
    position = at.inMilliseconds / 1000;
    if (buffering && !this.buffering && networkMediaUri != null) {
      cache.transport.router?.reconsiderAfterStall(networkMediaUri!);
    }
    this.buffering = buffering;
    if (buffering) {
      if (!cache._promoted.contains(_fetchKey)) _token?.cancel('播放优先');
    } else if (backgroundPrefetchAllowed && !prefetching && !closed) {
      unawaited(cache._prefetch(this));
    }
  }

  Future<void> close() async {
    closed = true;
    _timer?.cancel();
    _token?.cancel('播放已结束');
    for (final request in _requests) {
      request.cancel('播放已结束');
    }
    cache._sessions.remove(id);
  }
}

/// Loopback-only, unguessable-session HLS proxy. The disk cache is keyed by URL,
/// request headers and byte range; AES keys are forwarded but never persisted.
/// Master playlists retain alternate audio/subtitles. Live playlists are never
/// stored or prefetched, and unsupported/oversized segments remain playable.
class CinemaMediaCache extends ChangeNotifier {
  CinemaMediaCache({
    Directory? directory,
    CinemaMediaTransport? transport,
    this.preferences = const CinemaCachePreferences(),
  }) : _directory = directory,
       transport = transport ?? CinemaMediaTransport();
  static final instance = CinemaMediaCache();
  Directory? _directory;
  final CinemaMediaTransport transport;
  CinemaCachePreferences preferences;
  HttpServer? _server;
  Future<void>? _starting;
  final _secret = List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final Map<String, CinemaCacheSession> _sessions = {};
  final Map<String, Future<File?>> _pending = {};
  final Set<String> _promoted = {};
  final Set<String> _pinned = {};
  int _serial = 0, _foreground = 0, _background = 0;
  int bytesUsed = 0, hits = 0;
  String? error;
  bool _disposed = false;
  Future<void> initialize() => _starting ??= _start();
  Future<void> _start() async {
    _directory ??= Directory(
      '${(await getApplicationCacheDirectory()).path}/naku-video-v2',
    );
    await _directory!.create(recursive: true);
    await _prune();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      unawaited(_serve(request));
    });
  }

  Future<({String url, CinemaCacheSession session})?> open(
    String url,
    Map<String, String> headers, {
    bool hls = false,
    Future<String> Function(String manifest, Uri base)? manifestPolicy,
    bool backgroundPrefetchAllowed = true,
  }) async {
    final uri = Uri.tryParse(url);
    if ((!preferences.enabled && transport.router?.active != true) ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        !(hls || uri.path.toLowerCase().endsWith('.m3u8'))) {
      return null;
    }
    await initialize();
    final session = CinemaCacheSession._(
      this,
      '${++_serial}',
      Map.unmodifiable(headers),
      manifestPolicy: manifestPolicy,
      backgroundPrefetchAllowed: backgroundPrefetchAllowed,
    );
    _sessions[session.id] = session;
    session._timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!session.closed &&
          !session.buffering &&
          session.backgroundPrefetchAllowed) {
        unawaited(_prefetch(session));
      }
    });
    return (
      url: session.register(uri, manifest: true).toString(),
      session: session,
    );
  }

  String _key(Uri uri, Map<String, String> headers, String? range) {
    final keys = headers.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              uri.toString(),
              {for (final k in keys) k: headers[k]},
              range,
            ]),
          ),
        )
        .toString();
  }

  Future<File?> _cached(String key) async {
    final file = File('${_directory!.path}/$key.bin');
    try {
      if (!await file.exists()) return null;
      // Touch implements LRU without repeatedly serializing a global index.
      await file.setLastModified(DateTime.now());
      return file;
    } on FileSystemException {
      return null;
    }
  }

  bool _cacheable(Uri uri) => !RegExp(
    r'\.(?:key|m3u8|vtt|srt|ass)$',
    caseSensitive: false,
  ).hasMatch(uri.path);
  Future<File?> _fetch(CinemaCacheSession session, _Segment segment) async {
    final key = _key(segment.uri, session.headers, segment.range);
    final cached = await _cached(key);
    if (cached != null) return cached;
    if (_background > 0 ||
        _foreground > 0 ||
        session.closed ||
        !session.backgroundPrefetchAllowed) {
      return null;
    }
    return _pending.putIfAbsent(key, () async {
      _background++;
      final token = session._token = CancelToken();
      session._fetchKey = key;
      try {
        final data = await transport.bytes(
          segment.uri,
          session.headers,
          cancel: token,
          range: segment.range,
          limit: 32 * 1024 * 1024,
        );
        final bounds = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(segment.range ?? '');
        if (session.closed ||
            token.isCancelled ||
            data.isEmpty ||
            (segment.range != null &&
                (bounds == null ||
                    data.length !=
                        int.parse(bounds[2]!) - int.parse(bounds[1]!) + 1))) {
          return null;
        }
        session.networkRoute = transport.router?.labelFor(segment.uri) ?? '';
        return await _store(key, data);
      } catch (_) {
        return null;
      } finally {
        _background--;
        _pending.remove(key);
        if (identical(session._token, token)) session._token = null;
        if (session._fetchKey == key) session._fetchKey = null;
      }
    });
  }

  Future<File?> _store(String key, Uint8List data) async {
    if (data.length > preferences.quotaMB * 1024 * 1024 || _disposed) {
      return null;
    }
    final temp = File('${_directory!.path}/$key.${++_serial}.part');
    try {
      await temp.writeAsBytes(data, flush: true);
      final previous = File('${_directory!.path}/$key.bin');
      final oldBytes = await previous.exists() ? await previous.length() : 0;
      final file = await temp.rename('${_directory!.path}/$key.bin');
      bytesUsed += data.length - oldBytes;
      if (bytesUsed > preferences.quotaMB * 1024 * 1024) {
        await _prune();
      } else {
        _notify();
      }
      return file;
    } on FileSystemException {
      error = '视频缓存写入失败，播放仍可继续';
      return null;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    var counted = false;
    try {
      final parts = request.uri.pathSegments;
      if (!['GET', 'HEAD'].contains(request.method) ||
          parts.length != 4 ||
          parts[0] != _secret) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final session = _sessions[parts[1]],
          resource = _sessions[parts[1]]?._resources[parts[2]];
      if (session == null || session.closed || resource == null) {
        response.statusCode = 410;
        return;
      }
      _foreground++;
      counted = true;
      if (resource.manifest) {
        _yieldBackground();
        final cancel = CancelToken();
        session._requests.add(cancel);
        late final ({String text, Uri uri}) document;
        try {
          document = await transport.document(
            resource.uri,
            session.headers,
            cancel: cancel,
          );
        } finally {
          session._requests.remove(cancel);
        }
        final text = document.text;
        if (!text.trimLeft().startsWith('#EXTM3U')) {
          throw const FormatException('媒体清单无效');
        }
        final selected =
            await session.manifestPolicy?.call(text, document.uri) ?? text;
        if (session.closed) {
          response.statusCode = 410;
          return;
        }
        final rewritten = _rewrite(session, document.uri, selected);
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        response.headers.set('Cache-Control', 'no-store');
        if (request.method != 'HEAD') response.write(rewritten);
        if (!session.buffering) unawaited(_prefetch(session));
        return;
      }
      final range = request.headers.value('range');
      final key = _key(resource.uri, session.headers, range);
      _pinned.add(key);
      try {
        var cached =
            preferences.enabled && resource.persist && _cacheable(resource.uri)
            ? await _cached(key)
            : null;
        var completeFile = range == null;
        final wholeKey = _key(resource.uri, session.headers, null);
        final canUseWhole =
            range == null || RegExp(r'^bytes=(\d*)-(\d*)$').hasMatch(range);
        final pendingKey = _pending.containsKey(key)
            ? key
            : canUseWhole
            ? wholeKey
            : key;
        final pending = preferences.enabled && resource.persist
            ? _pending[pendingKey]
            : null;
        if (cached == null && pending != null) {
          // Adopt an in-flight warmup for this exact segment instead of
          // cancelling it and downloading the same bytes a second time.
          _promoted.add(pendingKey);
          _yieldBackground();
          try {
            cached = await pending.timeout(
              const Duration(seconds: 20),
              onTimeout: () => null,
            );
            completeFile = pendingKey == wholeKey;
          } finally {
            _promoted.remove(pendingKey);
          }
        }
        // FFmpeg commonly sends bytes=0- even for whole HLS segments. A warmed
        // complete segment can answer open, suffix and explicit byte ranges.
        if (cached == null &&
            range != null &&
            preferences.enabled &&
            resource.persist &&
            _cacheable(resource.uri) &&
            RegExp(r'^bytes=(\d*)-(\d*)$').hasMatch(range)) {
          cached = await _cached(_key(resource.uri, session.headers, null));
          completeFile = cached != null;
        }
        if (cached != null) {
          session.hits++;
          hits++;
          _notify();
          final length = await cached.length();
          var start = 0, end = length - 1;
          final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
          if (range != null && completeFile) {
            final bounds = _rangeBounds(range, length);
            if (bounds == null) {
              response.statusCode = 416;
              response.headers.set('Content-Range', 'bytes */$length');
              return;
            }
            (start, end) = bounds;
            response.statusCode = 206;
            response.headers.set('Content-Range', 'bytes $start-$end/$length');
          } else if (match != null) {
            response.statusCode = 206;
            response.headers.set(
              'Content-Range',
              'bytes ${match[1]}-${match[2]}/*',
            );
          } else if (range != null) {
            // Open/suffix ranges need upstream size semantics; don't reuse.
            await _relay(request, session, resource, key, cache: false);
            return;
          }
          response.headers.set('Accept-Ranges', 'bytes');
          response.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            await response.addStream(cached.openRead(start, end + 1));
          }
        } else {
          _yieldBackground();
          await _relay(
            request,
            session,
            resource,
            key,
            cache:
                preferences.enabled &&
                resource.persist &&
                _cacheable(resource.uri),
          );
        }
      } finally {
        _pinned.remove(key);
      }
    } catch (_) {
      try {
        response.statusCode = 502;
      } catch (_) {}
    } finally {
      if (counted) _foreground = (_foreground - 1).clamp(0, 1000);
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _yieldBackground() {
    for (final session in _sessions.values) {
      if (!_promoted.contains(session._fetchKey)) {
        session._token?.cancel('播放优先');
      }
    }
  }

  (int, int)? _rangeBounds(String range, int length) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
    if (match == null || length <= 0 || range.length > 200) return null;
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      return suffix == null || suffix <= 0
          ? null
          : ((length - suffix).clamp(0, length - 1), length - 1);
    }
    final start = int.tryParse(match[1]!);
    final end = match[2]!.isEmpty ? length - 1 : int.tryParse(match[2]!);
    if (start == null || end == null || start >= length || end < start) {
      return null;
    }
    return (start, end.clamp(0, length - 1));
  }

  Future<void> _relay(
    HttpRequest request,
    CinemaCacheSession session,
    _Resource resource,
    String key, {
    required bool cache,
  }) async {
    final token = CancelToken();
    session._requests.add(token);
    final deadline = Timer(
      const Duration(seconds: 60),
      () => token.cancel('片段超时'),
    );
    try {
      if (resource.persist) session.networkMediaUri = resource.uri;
      final upstream = await transport.stream(
        resource.uri,
        session.headers,
        cancel: token,
        range: request.headers.value('range'),
        metadata: !resource.persist,
      );
      if (resource.persist) {
        session.networkRoute = upstream.extra['cinemaRoute'] as String? ?? '';
      }
      final response = request.response;
      response.statusCode = upstream.statusCode ?? 200;
      for (final name in ['content-type', 'content-range', 'accept-ranges']) {
        final value = upstream.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      final range = request.headers.value('range');
      var storeKey = key;
      if (range == null && upstream.statusCode != 200) cache = false;
      if (range != null) {
        final bounds = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
        final returned = RegExp(
          r'^bytes (\d+)-(\d+)/',
        ).firstMatch(upstream.headers.value('content-range') ?? '');
        final fullRange = RegExp(
          r'^bytes 0-(\d+)/(\d+)$',
        ).firstMatch(upstream.headers.value('content-range') ?? '');
        final wholeResponse =
            range == 'bytes=0-' &&
            (upstream.statusCode == 200 ||
                upstream.statusCode == 206 &&
                    fullRange != null &&
                    int.parse(fullRange[1]!) + 1 == int.parse(fullRange[2]!));
        if (wholeResponse) {
          storeKey = _key(resource.uri, session.headers, null);
        } else if (upstream.statusCode != 206 ||
            bounds == null ||
            returned == null ||
            bounds[1] != returned[1] ||
            bounds[2] != returned[2]) {
          cache = false;
        }
      }
      final length = int.tryParse(
        upstream.headers.value('content-length') ?? '',
      );
      if (length != null) response.contentLength = length;
      var builder = cache ? BytesBuilder(copy: false) : null;
      final saved = cache && !_pending.containsKey(storeKey)
          ? Completer<File?>()
          : null;
      if (saved != null) _pending[storeKey] = saved.future;
      try {
        await for (final chunk in upstream.data!.stream) {
          if (session.closed) {
            token.cancel();
            break;
          }
          session.downloadedBytes += chunk.length;
          if (builder != null) {
            if (builder.length + chunk.length > 32 * 1024 * 1024) {
              builder = null;
            } else {
              builder.add(chunk);
            }
          }
          if (request.method != 'HEAD') {
            response.add(chunk);
            await response.flush();
          } else {
            token.cancel();
            break;
          }
        }
        if (builder != null && builder.length > 0 && !token.isCancelled) {
          final file = await _store(storeKey, builder.takeBytes());
          saved?.complete(file);
        }
      } finally {
        if (saved != null) {
          if (!saved.isCompleted) saved.complete(null);
          if (identical(_pending[storeKey], saved.future)) {
            _pending.remove(storeKey);
          }
        }
        token.cancel();
      }
    } finally {
      deadline.cancel();
      token.cancel();
      session._requests.remove(token);
    }
  }

  String _rewrite(CinemaCacheSession session, Uri base, String text) {
    final lines = text.split('\n'), out = <String>[], segments = <_Segment>[];
    double time = 0, duration = 0;
    String? range;
    int lastRangeEnd = 0;
    final master = text.contains('#EXT-X-STREAM-INF:');
    final live = !master && !text.contains('#EXT-X-ENDLIST');
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        duration = double.tryParse(line.substring(8).split(',').first) ?? 0;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final values = line.substring(17).split('@');
        final length = int.tryParse(values.first) ?? 0;
        final start = values.length == 2
            ? int.tryParse(values[1]) ?? 0
            : lastRangeEnd;
        range = 'bytes=$start-${start + length - 1}';
        lastRangeEnd = start + length;
      }
      if (line.isNotEmpty && !line.startsWith('#')) {
        final uri = base.resolve(line);
        out.add(session.register(uri, manifest: master).toString());
        if (!master && !live && duration > 0) {
          segments.add(_Segment(uri, time, duration, range));
        }
        time += duration;
        duration = 0;
        range = null;
      } else {
        out.add(
          raw.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (match) {
            final uri = base.resolve(match[1]!);
            final manifest =
                line.startsWith('#EXT-X-MEDIA:') ||
                line.startsWith('#EXT-X-I-FRAME-STREAM-INF:');
            final key =
                line.startsWith('#EXT-X-KEY:') ||
                line.startsWith('#EXT-X-SESSION-KEY:');
            return 'URI="${session.register(uri, manifest: manifest, persist: !key)}"';
          }),
        );
      }
    }
    if (!master && !live) session._playlists[base.toString()] = segments;
    return out.join('\n');
  }

  Future<void> _prefetch(CinemaCacheSession session, {int? seconds}) async {
    if (session.prefetching ||
        _background > 0 ||
        session.closed ||
        session.buffering ||
        !session.backgroundPrefetchAllowed ||
        !preferences.enabled) {
      return;
    }
    if (session._lastPrefetchAt != null &&
        DateTime.now().difference(session._lastPrefetchAt!).inSeconds < 4) {
      return;
    }
    session._lastPrefetchAt = DateTime.now();
    session.prefetching = true;
    try {
      final startPosition = session.position;
      for (final playlist in session._playlists.values.toList()) {
        for (final segment in playlist) {
          if (session.closed ||
              session.buffering ||
              !session.backgroundPrefetchAllowed ||
              !preferences.enabled) {
            return;
          }
          if (segment.start + segment.duration < session.position ||
              segment.start >
                  session.position +
                      (seconds ??
                          CinemaPlaybackBufferPolicy(
                            session.playbackRate,
                          ).prefetchSeconds(preferences.forwardSeconds))) {
            continue;
          }
          // One background request at a time; no new traffic while playback
          // has a pending request. Pausing remains eligible for prefetch.
          if (_foreground > 0) return;
          if ((session.position - startPosition).abs() > 30) return;
          await _fetch(session, segment);
        }
      }
    } finally {
      session.prefetching = false;
      _notify();
    }
  }

  Future<void> warmNext(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) async {
    if (!preferences.enabled || preferences.nextSeconds == 0) return;
    final opened = await open(url, headers);
    if (opened == null) return;
    final session = opened.session;
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => session.close()));
    }
    try {
      var uri = Uri.parse(url);
      for (var i = 0; i < 4; i++) {
        if (cancel?.isCancelled == true || _foreground > 0) return;
        final document = await transport.document(uri, headers, cancel: cancel);
        uri = document.uri;
        final text = document.text;
        if (!text.trimLeft().startsWith('#EXTM3U')) return;
        final variants = cinemaHlsVariants(text, uri);
        if (variants.isNotEmpty) {
          uri = variants.reduce((a, b) => a.bitrate > b.bitrate ? a : b).uri;
          continue;
        }
        _rewrite(session, uri, text);
        await _prefetch(session, seconds: preferences.nextSeconds);
        return;
      }
    } catch (_) {
      /* Warmup failure cannot interrupt current playback. */
    } finally {
      await session.close();
    }
  }

  Future<void> _prune() async {
    if (_directory == null || !await _directory!.exists()) return;
    final files = <({File file, FileStat stat})>[];
    await for (final entity in _directory!.list(followLinks: false)) {
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (entity.path.endsWith('.bin')) {
        files.add((file: entity, stat: stat));
      } else if (entity.path.endsWith('.part') &&
          DateTime.now().difference(stat.modified).inHours > 1) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    bytesUsed = files.fold(0, (sum, f) => sum + f.stat.size);
    final quota = preferences.quotaMB * 1024 * 1024;
    for (final item in files) {
      if (bytesUsed <= quota) break;
      final name = item.file.uri.pathSegments.last.replaceFirst('.bin', '');
      if (_pinned.contains(name)) continue;
      try {
        await item.file.delete();
        bytesUsed -= item.stat.size;
      } catch (_) {}
    }
    _notify();
  }

  Future<void> clear() async {
    await initialize();
    for (final session in _sessions.values) {
      session._token?.cancel('清理缓存');
    }
    await for (final entity in _directory!.list(followLinks: false)) {
      if (entity is File &&
          !_pinned.contains(
            entity.uri.pathSegments.last.replaceFirst('.bin', ''),
          )) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    await _prune();
  }

  Future<void> configure(CinemaCachePreferences value) async {
    preferences = value;
    if (!value.enabled) {
      for (final session in _sessions.values) {
        session._token?.cancel('缓存已关闭');
      }
    }
    if (_directory != null) await _prune();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> shutdown() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}
