import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart' show CancelToken;
import 'cinema_original_match.dart';
import 'cinema_original_search.dart' show OriginalLookup;
import 'cinema_video_metadata.dart';

class OriginalStream {
  OriginalStream(this.url, this.headers, this.file, this._release);
  final Uri url;
  final Map<String, String> headers;
  final OriginalFile file;
  final Future<void> Function() _release;
  bool _closed = false;
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _release();
    }
  }
}

class OriginalStartupSample {
  const OriginalStartupSample(
    this.firstByteMs,
    this.elapsedMs,
    this.bytes,
    this.swarmBytesPerSecond,
  );
  final int firstByteMs, elapsedMs, bytes;
  final double swarmBytesPerSecond;

  // Include the cost of finding peers. A cache-to-loopback burst alone does
  // not measure the swarm. Prefer the engine's useful download rate if known.
  double get startupEstimate {
    final rate = swarmBytesPerSecond > 0
        ? swarmBytesPerSecond
        : bytes * 1000 / max(1, elapsedMs);
    return elapsedMs + (512 * 1024 * 1000 / max(1, rate));
  }
}

class CinemaOriginalEngine {
  CinemaOriginalEngine({String? host})
    : helper =
          host ??
          File(
            Platform.resolvedExecutable,
          ).parent.parent.uri.resolve('Helpers/NakuOriginalHost').toFilePath();
  static final instance = CinemaOriginalEngine();
  final String helper;
  late final available = Platform.isMacOS && File(helper).existsSync();
  final _refs = <String, int>{};
  final _changes = <String, Future<void>>{};
  final _tracks = <String, CinemaVideoMetadata>{};
  Process? _process;
  Directory? _dir;
  HttpClient? _client;
  Uri? _base;
  final _random = Random.secure();
  String _auth = '';
  Future<void>? _boot;
  Future<void>? _stopping;
  Timer? _idle;
  int _users = 0;
  String _key(OriginalMatches m, OriginalEdition e) =>
      '${m.work.key}/${e.hash}';
  CinemaVideoMetadata? measured(OriginalMatches m, OriginalEdition e) =>
      _tracks[_key(m, e)];
  OriginalSelection? preferred(
    OriginalMatches? matches, {
    Set<String> excluding = const {},
    String preferredHash = '',
  }) {
    if (matches == null) return null;
    OriginalEdition? best;
    for (final edition in matches.editions) {
      if (excluding.contains(edition.hash)) continue;
      final video = measured(matches, edition);
      if (video != null && video.width < 3840 && video.height < 2160) continue;
      if (preferredHash.isNotEmpty && edition.hash == preferredHash) {
        return (matches: matches, edition: edition);
      }
      if (best == null) {
        best = edition;
        continue;
      }
      final order = edition.compareAvailability(best);
      if (order < 0) best = edition;
    }
    return best == null ? null : (matches: matches, edition: best);
  }

  void record(OriginalMatches m, OriginalEdition e, CinemaVideoMetadata v) {
    if (v.width <= 0 || v.height <= 0) return;
    if (_tracks.length >= 160) _tracks.remove(_tracks.keys.first);
    _tracks[_key(m, e)] = v;
  }

  Future<void> _start() async {
    await _stopping;
    if (_process != null && _base != null && _boot == null) return;
    await (_boot ??= _launch().whenComplete(() => _boot = null));
  }

  Future<void> _launch() async {
    if (!available) throw const FormatException('本机原画引擎不可用');
    final root = _dir = await Directory.systemTemp.createTemp('naku-original-');
    try {
      final secret = base64Url.encode(
        List.generate(32, (_) => _random.nextInt(256)),
      );
      _auth = 'Basic ${base64.encode(utf8.encode('naku:$secret'))}';
      await File(
        '${root.path}/accs.db',
      ).writeAsString(jsonEncode({'naku': secret}), flush: true);
      final disk = await Directory('${root.path}/cache').create();
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          port = socket.port;
      await socket.close();
      _base = Uri.parse('http://127.0.0.1:$port');
      _client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 2)
        ..findProxy = (_) => 'DIRECT';
      final proc = _process = await Process.start(helper, [
        '--ip',
        '127.0.0.1',
        '--port',
        '$port',
        '--httpauth',
        '--torrentaddr',
        '0.0.0.0:0',
        '--path',
        root.path,
      ]);
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.drain<void>());
      var exited = false;
      unawaited(
        proc.exitCode.then((_) {
          exited = true;
          if (identical(_process, proc)) {
            _process = null;
            _client?.close(force: true);
            _client = null;
            _base = null;
            unawaited(_remove(root));
          }
        }),
      );
      Map? settings;
      final end = DateTime.now().add(const Duration(seconds: 8));
      while (!exited && DateTime.now().isBefore(end)) {
        try {
          settings = await _post('/settings', {'action': 'get'}) as Map;
          break;
        } on SocketException {
          await Future<void>.delayed(const Duration(milliseconds: 90));
        }
      }
      if (settings == null) throw const FormatException('本机原画引擎启动超时');
      await _post('/settings', {
        'action': 'set',
        'sets': {
          ...settings,
          'UseDisk': true,
          'CacheSize': 128 << 20,
          'PreloadCache': 4,
          'ReaderReadAHead': 85,
          'TorrentsSavePath': disk.path,
          'RemoveCacheOnDrop': true,
          'DisableUpload': true,
          'DisableUPNP': true,
          'EnableDLNA': false,
          'EnableLPD': false,
          'EnableBonjour': false,
          'TrackTimecode': false,
          'ConnectionsLimit': 45,
          'RetrackersMode': 0,
          'DefaultTrackers': '',
          'TrackersListURL': '',
          'ResponsiveMode': true,
        },
      });
      final checked = await _post('/settings', {'action': 'get'});
      if (checked is! Map ||
          checked['UseDisk'] != true ||
          checked['DisableUpload'] != true ||
          checked['TorrentsSavePath'] != disk.path) {
        throw const FormatException('本机缓存未就绪');
      }
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> data) async {
    final client = _client, base = _base;
    if (client == null || base == null) throw const FormatException('原画引擎已关闭');
    final req = await client
        .postUrl(base.resolve(path))
        .timeout(const Duration(seconds: 3));
    req.followRedirects = false;
    req.headers.set('Authorization', _auth);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(data)));
    final deadline = Timer(
      const Duration(seconds: 5),
      () => req.abort(TimeoutException('原画引擎响应超时')),
    );
    try {
      final rsp = await req.close();
      if (rsp.statusCode != 200) {
        await rsp.drain<void>();
        throw const FormatException('原画引擎未能读取资源');
      }
      final b = BytesBuilder(copy: false);
      await for (final c in rsp) {
        if (b.length + c.length > 4 << 20) {
          throw const FormatException('种子清单过大');
        }
        b.add(c);
      }
      return b.isEmpty ? null : jsonDecode(utf8.decode(b.takeBytes()));
    } finally {
      deadline.cancel();
    }
  }

  Future<void> _serial(String hash, Future<void> Function() action) {
    final prior = _changes[hash] ?? Future<void>.value();
    final f = prior.then((_) => action(), onError: (_) => action());
    _changes[hash] = f;
    f.then<void>(
      (_) {
        if (identical(_changes[hash], f)) _changes.remove(hash);
      },
      onError: (_) {
        if (identical(_changes[hash], f)) _changes.remove(hash);
      },
    );
    return f;
  }

  Future<OriginalStream> open(
    OriginalMatches matches,
    OriginalEdition edition, {
    required CancelToken cancel,
    Duration budget = const Duration(seconds: 15),
  }) async {
    _idle?.cancel();
    _users++;
    final hash = edition.hash;
    var held = false;
    Future<void> release() async {
      if (held) {
        held = false;
        await _serial(hash, () async {
          final n = (_refs[hash] ?? 1) - 1;
          if (n > 0) {
            _refs[hash] = n;
            return;
          }
          _refs.remove(hash);
          try {
            await _post('/torrents', {'action': 'drop', 'hash': hash});
          } catch (_) {}
        });
      }
      if (--_users == 0) {
        _idle = Timer(const Duration(seconds: 3), () {
          if (_users == 0) {
            _stopping = _stop().whenComplete(() => _stopping = null);
          }
        });
      }
    }

    void check() {
      if (cancel.isCancelled) throw const FormatException('原画准备已取消');
    }

    try {
      await _start();
      check();
      await _serial(hash, () async {
        check();
        final prior = _refs[hash] ?? 0;
        _refs[hash] = prior + 1;
        held = true;
        if (prior == 0) {
          await _post('/torrents', {
            'action': 'add',
            'link': edition.magnet,
            'save_to_db': false,
          });
        }
      });
      final watch = Stopwatch()..start();
      while (watch.elapsed < budget) {
        check();
        final info = await _post('/torrents', {'action': 'get', 'hash': hash});
        check();
        if (info is Map &&
            info['hash']?.toString().toLowerCase() == hash &&
            info['file_stats'] is List) {
          final rows = (info['file_stats'] as List).whereType<Map>();
          if (rows.isNotEmpty) {
            final files = [
              for (final r in rows)
                if (r['id'] is int && r['path'] is String && r['length'] is int)
                  OriginalFile(r['id'], r['path'], r['length']),
            ];
            final file = originalMainFile(matches.work, edition, files);
            if (file == null) throw const FormatException('此版本没有能确认的正片或集数');
            // The engine's playback-only endpoint serves active local torrents.
            // MPV owns its Range connections and never receives the control password.
            final uri = _base!.resolve('/play/$hash/${file.id}');
            return OriginalStream(uri, const {}, file, release);
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 240));
      }
      throw const FormatException('该版本暂时没有可用节点');
    } catch (_) {
      await release();
      rethrow;
    }
  }

  /// Compare a bounded group. Hand the winning open cache lease to the player.
  Future<({OriginalEdition edition, OriginalStream stream})> openFastest(
    OriginalMatches matches,
    OriginalEdition first, {
    required Set<String> excluding,
    required CancelToken cancel,
    required void Function(String hash) onFailure,
    OriginalLookup? lookup,
  }) async {
    final options = [first];
    final considered = {...excluding, first.hash};
    var lanes = 3;
    const batchLimit = 6;
    void collect(OriginalMatches latest, int limit) {
      final expected = matches.work, other = latest.work;
      if (expected.season != other.season ||
          expected.episode != other.episode ||
          expected.imdbId.isNotEmpty &&
              other.imdbId.isNotEmpty &&
              expected.imdbId != other.imdbId ||
          expected.doubanId.isNotEmpty &&
              other.doubanId.isNotEmpty &&
              expected.doubanId != other.doubanId) {
        return;
      }
      while (options.length < limit) {
        final next = preferred(latest, excluding: considered)?.edition;
        if (next == null) break;
        options.add(next);
        considered.add(next.hash);
      }
    }

    collect(lookup?.matches ?? matches, lanes);
    if (options.length == 1 && lookup?.done != false) {
      try {
        return (
          edition: first,
          stream: await open(matches, first, cancel: cancel),
        );
      } catch (_) {
        if (!cancel.isCancelled) onFailure(first.hash);
        rethrow;
      }
    }

    final tokens = <CancelToken>[];
    final firstReady = Completer<void>(), allDone = Completer<void>();
    final ready =
        <
          ({
            OriginalEdition edition,
            OriginalStream stream,
            OriginalStartupSample sample,
          })
        >[];
    var finished = 0, accepting = true;
    late final void Function() launchAvailable;
    void wake() {
      if (!firstReady.isCompleted) firstReady.complete();
    }

    void abort() {
      for (final token in tokens) {
        if (!token.isCancelled) token.cancel('原画比较结束');
      }
      wake();
    }

    unawaited(
      cancel.whenCancel.then((_) {
        if (accepting) abort();
      }),
    );
    void checkDone() {
      if (finished != options.length) return;
      if (ready.isEmpty || lookup?.done != false || options.length >= lanes) {
        if (!allDone.isCompleted) allDone.complete();
        wake();
      }
    }

    Future<void> probe(OriginalEdition edition, CancelToken token) async {
      OriginalStream? lease;
      final clock = Stopwatch()..start();
      final deadline = Timer(
        const Duration(seconds: 13),
        () => token.cancel('原画采样超时'),
      );
      try {
        lease = await open(
          matches,
          edition,
          cancel: token,
          budget: const Duration(seconds: 9),
        );
        if (!accepting) return;
        if (token.isCancelled) throw const FormatException('原画采样已取消');
        final sample = await sampleStartup(
          matches,
          edition,
          lease,
          clock,
          token,
        );
        if (!accepting) return;
        if (token.isCancelled) throw const FormatException('原画采样已取消');
        ready.add((edition: edition, stream: lease, sample: sample));
        lease = null;
        wake();
      } catch (_) {
        if (accepting && !cancel.isCancelled) onFailure(edition.hash);
      } finally {
        deadline.cancel();
        finished++;
        launchAvailable();
        await lease?.close();
      }
    }

    launchAvailable = () {
      if (!accepting || allDone.isCompleted || cancel.isCancelled) return;
      // Refill failed slots promptly. Once playable data arrives, compare
      // the in-flight reads within the short settling window.
      final limit = ready.isEmpty
          ? min(batchLimit, lanes + finished)
          : max(options.length, lanes);
      collect(lookup?.matches ?? matches, limit);
      while (tokens.length < options.length) {
        final edition = options[tokens.length];
        final token = CancelToken();
        tokens.add(token);
        unawaited(probe(edition, token));
      }
      checkDone();
    };
    final hedge = Timer(const Duration(milliseconds: 1200), () {
      if (ready.isEmpty && accepting) {
        lanes = 4;
        launchAvailable();
      }
    });
    lookup?.addListener(launchAvailable);
    launchAvailable();
    OriginalStream? kept;
    Timer? window;
    try {
      await firstReady.future;
      if (ready.isNotEmpty && !allDone.isCompleted && !cancel.isCancelled) {
        final settle = Completer<void>();
        window = Timer(const Duration(milliseconds: 300), settle.complete);
        await Future.any([settle.future, allDone.future, cancel.whenCancel]);
      }
      if (cancel.isCancelled) throw const FormatException('原画准备已取消');
      if (ready.isEmpty) throw const FormatException('这些原画版本暂未读到视频');
      ready.sort((a, b) {
        final speed = a.sample.startupEstimate.compareTo(
          b.sample.startupEstimate,
        );
        if (speed != 0) return speed;
        final firstByte = a.sample.firstByteMs.compareTo(b.sample.firstByteMs);
        if (firstByte != 0) return firstByte;
        if (a.edition.chineseSubtitles != b.edition.chineseSubtitles) {
          return a.edition.chineseSubtitles ? -1 : 1;
        }
        return a.edition.compareAvailability(b.edition);
      });
      final best = ready.first;
      kept = best.stream;
      return (edition: best.edition, stream: best.stream);
    } finally {
      accepting = false;
      hedge.cancel();
      lookup?.removeListener(launchAvailable);
      window?.cancel();
      abort();
      for (final row in ready) {
        if (!identical(row.stream, kept)) unawaited(row.stream.close());
      }
    }
  }

  Future<OriginalStartupSample> sampleStartup(
    OriginalMatches matches,
    OriginalEdition edition,
    OriginalStream stream,
    Stopwatch clock,
    CancelToken cancel,
  ) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    unawaited(cancel.whenCancel.then((_) => client.close(force: true)));
    try {
      if (cancel.isCancelled) throw const FormatException('原画采样已取消');
      final limit = min(512 * 1024, stream.file.length);
      if (limit <= 0) throw const FormatException('原画文件为空');
      final req = await client.getUrl(stream.url);
      req.followRedirects = false;
      stream.headers.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${limit - 1}');
      final response = await req.close();
      if (response.statusCode != 206 && response.statusCode != 200) {
        throw const FormatException('原画未返回视频数据');
      }
      final data = BytesBuilder(copy: false);
      int? firstByte;
      await for (final chunk in response) {
        if (chunk.isEmpty) continue;
        firstByte ??= clock.elapsedMilliseconds;
        final needed = limit - data.length;
        data.add(chunk.length > needed ? chunk.sublist(0, needed) : chunk);
        if (data.length == limit) break;
      }
      final elapsed = clock.elapsedMilliseconds;
      if (data.length != limit || firstByte == null) {
        throw const FormatException('原画视频数据不完整');
      }
      final metadata = cinemaVideoMetadata(data.takeBytes());
      if (metadata != null) {
        record(matches, edition, metadata);
        if (metadata.width < 3840 && metadata.height < 2160) {
          throw const FormatException('此版本实测低于 4K');
        }
      }
      var swarm = 0.0;
      if (_client != null) {
        try {
          final status = await _post('/torrents', {
            'action': 'get',
            'hash': edition.hash,
          }).timeout(const Duration(milliseconds: 150));
          final speed = status is Map ? status['download_speed'] : null;
          if (speed is num && speed.isFinite && speed > 0) {
            swarm = speed.toDouble();
          }
        } catch (_) {
          /* The sampled prefix is still usable. */
        }
      }
      return OriginalStartupSample(firstByte, elapsed, limit, swarm);
    } finally {
      client.close(force: true);
    }
  }

  Future<CinemaVideoMetadata?> inspect(
    OriginalMatches matches,
    OriginalEdition edition,
    CancelToken cancel,
  ) async {
    final known = measured(matches, edition);
    if (known != null) return known;
    OriginalStream? stream;
    HttpClient? client;
    final timeout = Timer(
      const Duration(seconds: 15),
      () => cancel.cancel('原画检测结束'),
    );
    try {
      stream = await open(
        matches,
        edition,
        cancel: cancel,
        budget: const Duration(seconds: 7),
      );
      client = HttpClient()..findProxy = (_) => 'DIRECT';
      final c = client;
      unawaited(
        cancel.whenCancel.then((_) {
          c.close(force: true);
        }),
      );
      final req = await c.getUrl(stream.url);
      req.followRedirects = false;
      stream.headers.forEach(req.headers.set);
      req.headers.set('Range', 'bytes=0-393215');
      final resp = await req.close();
      if (resp.statusCode != 206 && resp.statusCode != 200) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        final left = 393216 - bytes.length;
        bytes.add(chunk.length > left ? chunk.sublist(0, left) : chunk);
        if (bytes.length >= 393216) break;
      }
      final v = cinemaVideoMetadata(bytes.takeBytes());
      if (v != null && !cancel.isCancelled) record(matches, edition, v);
      return v;
    } catch (_) {
      return null;
    } finally {
      timeout.cancel();
      client?.close(force: true);
      await stream?.close();
    }
  }

  static Future<void> _remove(Directory d) async {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _stop() async {
    _idle?.cancel();
    final p = _process, d = _dir;
    _process = null;
    _base = null;
    _dir = null;
    _client?.close(force: true);
    _client = null;
    _refs.clear();
    if (p != null) {
      try {
        await p.stdin.close();
        await p.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        p.kill();
      }
    }
    if (d != null) await _remove(d);
  }
}
