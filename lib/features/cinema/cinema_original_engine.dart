import 'dart:async';
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/services/storage/cinema_disk_cache_files.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart' show CancelToken;
import 'cinema_original_match.dart';
import 'cinema_video_metadata.dart';

/// Once real bytes arrive, give the demuxer and decoder time to produce a frame,
/// even when the peer connected near the end of the discovery window.
Duration originalStartupTimeout(
  Duration remaining,
  Duration limit, {
  bool decoding = false,
}) {
  final available =
      remaining + (decoding ? const Duration(seconds: 10) : Duration.zero);
  if (available <= Duration.zero) return Duration.zero;
  return available < limit ? available : limit;
}

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

class CinemaOriginalEngine {
  CinemaOriginalEngine({String? host}) : _overrideHost = host;
  static final instance = CinemaOriginalEngine();
  final String? _overrideHost;
  String get helper =>
      _overrideHost ??
      (Platform.isAndroid
          ? NakuDevice.originalHost ?? ''
          : File(Platform.resolvedExecutable).parent.parent.uri
                .resolve('Helpers/NakuOriginalHost')
                .toFilePath());
  bool get available =>
      (Platform.isMacOS || Platform.isAndroid) &&
      helper.isNotEmpty &&
      File(helper).existsSync();
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
    int Function(OriginalEdition)? compatibility,
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
      final rank = compatibility?.call(edition) ?? 0;
      if (rank < 0) continue;
      if (best == null) {
        best = edition;
        continue;
      }
      final bestRank = compatibility?.call(best) ?? 0;
      var comparison = rank.compareTo(bestRank);
      if (comparison == 0 && compatibility != null) {
        comparison = (edition.seeds == 0 ? 1 : 0).compareTo(
          best.seeds == 0 ? 1 : 0,
        );
      }
      if (comparison == 0) comparison = edition.compareAvailability(best);
      if (comparison < 0) best = edition;
    }
    return best == null ? null : (matches: matches, edition: best);
  }

  OriginalSelection? alternate(
    OriginalSelection primary, {
    Set<String> excluding = const {},
    int Function(OriginalEdition)? compatibility,
  }) {
    final first = primary.edition;
    final skipped = {...excluding, first.hash};
    // A compact, well-seeded encode can sustain playback when a large remux
    // has delivered its header but stalls. Never compare season-pack sizes.
    if (!first.pack && first.size > 0) {
      final preferredRank = compatibility?.call(first) ?? 0;
      final compact = preferred(
        primary.matches,
        compatibility: compatibility,
        excluding: {
          ...skipped,
          for (final e in primary.matches.editions)
            if (e.pack ||
                e.size <= 0 ||
                e.size * 2 > first.size ||
                e.seeds < max(1, (first.seeds + 1) ~/ 2) ||
                (compatibility?.call(e) ?? 0) > preferredRank)
              e.hash,
        },
      );
      if (compact != null) return compact;
    }
    return preferred(
      primary.matches,
      excluding: skipped,
      compatibility: compatibility,
    );
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
    final root = _dir = await CinemaDiskCacheFiles.instance.openOriginal();
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

  /// Metadata and seed counts cannot establish that a peer has the selected
  /// episode's first piece. Keep its lease alive when handing it to the player.
  Future<({OriginalSelection selection, OriginalStream stream})> openPlayable(
    OriginalSelection first, {
    required CancelToken cancel,
    OriginalSelection? alternate,
    Duration hedge = const Duration(seconds: 2),
    Duration budget = const Duration(seconds: 18),
    bool Function(CinemaVideoMetadata)? acceptsVideo,
    void Function(OriginalSelection)? onFailure,
    void Function()? onFirstBytes,
  }) async {
    final choices = [
      first,
      if (alternate != null && alternate.edition.hash != first.edition.hash)
        alternate,
    ];
    final result =
        Completer<({OriginalSelection selection, OriginalStream stream})>();
    final tokens = <CancelToken>[];
    final clock = Stopwatch()..start();
    var finished = 0;
    void fail(Object error) {
      if (!result.isCompleted) result.completeError(error);
    }

    Future<void> tryNext() async {
      if (result.isCompleted || tokens.length >= choices.length) return;
      final choice = choices[tokens.length];
      final token = CancelToken();
      tokens.add(token);
      OriginalStream? lease;
      var keep = false;
      try {
        lease = await open(
          choice.matches,
          choice.edition,
          cancel: token,
          budget: budget - clock.elapsed,
        );
        if (result.isCompleted || token.isCancelled) return;
        final video = await readOriginalHead(
          lease,
          token,
          budget - clock.elapsed,
          onFirstBytes: onFirstBytes,
        );
        if (result.isCompleted || token.isCancelled) return;
        if (video != null) {
          record(choice.matches, choice.edition, video);
          if (acceptsVideo != null && !acceptsVideo(video)) {
            throw const FormatException('本机无法播放此版本的实测格式');
          }
        }
        keep = true;
        result.complete((selection: choice, stream: lease));
      } catch (error) {
        if (!result.isCompleted && !token.isCancelled) onFailure?.call(choice);
        finished++;
        if (finished == choices.length) {
          fail(error);
        } else if (!result.isCompleted) {
          unawaited(tryNext());
        }
      } finally {
        if (!keep) await lease?.close();
      }
    }

    if (cancel.isCancelled) throw const FormatException('原画准备已取消');
    unawaited(
      cancel.whenCancel.then((_) => fail(const FormatException('原画准备已取消'))),
    );
    final deadline = Timer(budget, () {
      if (!result.isCompleted) {
        for (final choice in choices.take(tokens.length)) {
          onFailure?.call(choice);
        }
        fail(const FormatException('节点尚未送达本集视频'));
      }
    });
    final backup = choices.length > 1 ? Timer(hedge, tryNext) : null;
    unawaited(tryNext());
    try {
      return await result.future;
    } finally {
      deadline.cancel();
      backup?.cancel();
      for (final token in tokens) {
        token.cancel('原画起播选择结束');
      }
    }
  }

  Future<CinemaVideoMetadata?> readOriginalHead(
    OriginalStream stream,
    CancelToken cancel,
    Duration remaining, {
    void Function()? onFirstBytes,
  }) async {
    if (cancel.isCancelled || remaining <= Duration.zero) {
      throw const FormatException('原画首段等待结束');
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    final timer = Timer(remaining, () => client.close(force: true));
    unawaited(cancel.whenCancel.then((_) => client.close(force: true)));
    try {
      // Keep the alternate live while the winner starts delivering consecutive
      // media data. A Matroska tracks header alone does not feed the decoder.
      final n = min(384 * 1024, stream.file.length);
      if (n < 1) throw const FormatException('原画文件为空');
      Future<HttpClientResponse> range(int start, int end) async {
        final request = await client.getUrl(stream.url);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
        final response = await request.close();
        if (response.statusCode != HttpStatus.partialContent ||
            response.headers.value(HttpHeaders.contentRangeHeader) !=
                'bytes $start-${end - 1}/${stream.file.length}') {
          throw const FormatException('原画分段不可读');
        }
        return response;
      }

      Future<void> warm(int start, int end) async {
        final response = await range(start, end);
        int count = 0;
        await for (final bytes in response) {
          count += bytes.length;
          if (count > end - start) throw const FormatException('原画索引范围有误');
        }
        if (count != end - start) throw const FormatException('节点未送达原画索引');
      }

      final head = Uint8List(n);
      int used = 0;
      bool inspected = false;
      Future<Object?>? index;
      void warmIndex() {
        final spans = cinemaMatroskaStartupRanges(
          Uint8List.sublistView(head, 0, used),
          stream.file.length,
          n,
        );
        if (spans.isNotEmpty) {
          index = Future.wait([
            for (final span in spans) warm(span.start, span.end),
          ]).then<Object?>((_) => null, onError: (Object e) => e);
        }
      }

      await for (final bytes in await range(0, n)) {
        if (used + bytes.length > n) throw const FormatException('原画首段范围有误');
        if (used == 0 && bytes.isNotEmpty) onFirstBytes?.call();
        head.setAll(used, bytes);
        used += bytes.length;
        if (!inspected && used >= 16 * 1024) {
          inspected = true;
          warmIndex();
        }
      }
      if (used != n) throw const FormatException('节点未送达完整首段');
      if (index == null) warmIndex();
      final failure = await index;
      if (failure != null) throw failure;
      return cinemaVideoMetadata(head);
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }

  static Future<void> _remove(Directory d) async {
    try {
      await CinemaDiskCacheFiles.instance.closeOriginal(d);
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
