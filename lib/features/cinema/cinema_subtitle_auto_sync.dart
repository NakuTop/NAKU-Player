import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_subtitle_timing.dart';
import 'cinema_subtitle_clip_match.dart';
import 'package:kazumi/services/player/native_playback_setup.dart';

const _tools = MethodChannel('naku/subtitle-tools');

class CinemaVoiceWindow {
  const CinemaVoiceWindow(this.startSeconds, this.speech, {this.pcm});
  final double startSeconds;

  /// 20 ms frames at 16 kHz, 1 = voice, 0 = other audio.
  final Uint8List speech;
  final Uint8List? pcm;
  int get sampleSeconds => (speech.length / 50).round().clamp(5, 20);
}

class CinemaAutoSyncResult {
  const CinemaAutoSyncResult(this.timing, this.confidence, this.message);
  final CinemaSubtitleTiming? timing;
  final double confidence;
  final String message;
}

/// Correlate subtitle intervals with voice activity, without recognizing words.
/// Two distant windows must agree; a single music cue cannot retime a film.
CinemaAutoSyncResult matchCinemaSubtitleVoice(
  List<CinemaSubtitleCue> cues,
  List<CinemaVoiceWindow> windows, {
  CinemaSubtitleTiming current = const CinemaSubtitleTiming(),
}) {
  const rejected = CinemaAutoSyncResult(null, 0, '对白匹配置信度不足，保留原对齐；可换字幕版本或手动校准');
  if (cues.length < 12 || windows.length < 2) return rejected;
  ({double offset, double score, double margin})? peak(
    CinemaVoiceWindow window,
    double scale,
    double center,
    double radius,
  ) {
    // 100 ms bins suppress VAD hangover and keep a bounded CPU budget.
    final n = window.speech.length ~/ 5;
    if (n < 300) return null;
    final voice = List<double>.generate(
      n,
      (i) =>
          window.speech.skip(i * 5).take(5).fold(0, (int a, int b) => a + b) /
          5,
    );
    final sumV = voice.fold(0.0, (a, b) => a + b);
    final variance = voice.fold(0.0, (a, b) => a + b * b) - sumV * sumV / n;
    if (sumV / n < .08 || sumV / n > .92 || variance < 5) return null;
    double score(double offset) {
      final caption = Uint8List(n);
      for (final cue in cues) {
        final a =
            ((cue.start / 1000 * scale + offset - window.startSeconds) * 10)
                .round();
        final b = ((cue.end / 1000 * scale + offset - window.startSeconds) * 10)
            .round();
        if (b <= 0) continue;
        if (a >= n) break;
        caption.fillRange(a.clamp(0, n), b.clamp(0, n), 1);
      }
      var count = 0.0, joint = 0.0;
      for (var i = 0; i < n; i++) {
        count += caption[i];
        joint += voice[i] * caption[i];
      }
      final cv = count - count * count / n;
      if (cv < 5 || count / n > .92 || count / n < .08) return -1;
      return (joint - sumV * count / n) / math.sqrt(variance * cv);
    }

    var best = -1.0, at = center;
    final scores = <(double, double)>[];
    for (var i = -radius * 10; i <= radius * 10; i += 1) {
      final offset = center + i / 10;
      final value = score(offset);
      scores.add((offset, value));
      if (value > best) {
        best = value;
        at = offset;
      }
    }
    var competitor = -1.0;
    for (final candidate in scores) {
      if ((candidate.$1 - at).abs() > 1.5) {
        competitor = math.max(competitor, candidate.$2);
      }
    }
    if ((at - center).abs() > radius - .3) return null;
    return (offset: at, score: best, margin: best - competitor);
  }

  final first = peak(windows.first, current.scale, current.offsetSeconds, 90);
  final last = peak(windows.last, current.scale, current.offsetSeconds, 90);
  if (first == null ||
      last == null ||
      first.score < .22 ||
      last.score < .22 ||
      first.margin < .025 ||
      last.margin < .025) {
    return rejected;
  }
  final span = windows.last.startSeconds - windows.first.startSeconds;
  if (span < 120) return rejected;
  final delta = last.offset - first.offset;
  final scale = current.scale * (1 + delta / span);
  if (scale < .95 || scale > 1.05) return rejected;
  final mid = windows.first.startSeconds + windows.first.speech.length * .01;
  final offset =
      first.offset -
      (scale - current.scale) * ((mid - first.offset) / current.scale);
  final checkA = peak(windows.first, scale, offset, 2);
  final checkB = peak(windows.last, scale, offset, 2);
  if (checkA == null ||
      checkB == null ||
      (checkA.offset - checkB.offset).abs() > .6 ||
      checkA.score < .22 ||
      checkB.score < .22) {
    return rejected;
  }
  final timing = CinemaSubtitleTiming(
    scale: scale,
    offsetSeconds: (checkA.offset + checkB.offset) / 2,
  );
  return CinemaAutoSyncResult(
    timing,
    math.min(checkA.score, checkB.score),
    '本地对白匹配完成：偏移 ${timing.offsetSeconds.toStringAsFixed(2)} 秒，时间轴倍率 ${timing.scale.toStringAsFixed(6)}',
  );
}

CinemaAutoSyncResult _matchClip(List<Object?> args) {
  final window = args[1] as CinemaVoiceWindow;
  final result = matchCinemaSubtitleClip(
    args[0] as List<CinemaSubtitleCue>,
    window.speech,
    startSeconds: window.startSeconds,
    positionSeconds: args[3] as double,
    current: args[2] as CinemaSubtitleTiming,
    anchor: args[4] as CinemaSubtitleCue?,
    sampleSeconds: window.sampleSeconds,
  );
  return CinemaAutoSyncResult(result.timing, result.confidence, result.message);
}

CinemaAutoSyncResult _matchWords(List<Object?> args) {
  final result = matchCinemaSubtitleWords(
    args[0] as List<CinemaSubtitleCue>,
    args[1] as List<CinemaSpokenWord>,
    startSeconds: args[2] as double,
    current: args[3] as CinemaSubtitleTiming,
    speech: args[4] as Uint8List,
    sampleSeconds: args[5] as int,
  );
  return CinemaAutoSyncResult(result.timing, result.confidence, result.message);
}

enum CinemaSubtitleSyncOutcome {
  idle,
  working,
  succeeded,
  noMatch,
  failed,
  cancelled,
  timedOut,
  saveFailed,
}

class _CinemaSubtitleSyncRun {
  _CinemaSubtitleSyncRun(this.session, this.sampleSeconds)
    : fingerprint = session.fingerprint,
      expectedTiming = session.timing.value;
  final CinemaExternalSubtitleState session;
  final int sampleSeconds;
  final id = '${DateTime.now().microsecondsSinceEpoch}';
  final String fingerprint;
  CinemaSubtitleTiming expectedTiming;
  final stopped = Completer<void>();
  final watch = Stopwatch()..start();
  Timer? ticker, deadline;
  Player? worker;
  Future<void>? disposal;
  Directory? temporary;
  bool applied = false;
}

class _CinemaSubtitleSyncStopped implements Exception {}

class CinemaSubtitleAutoSync extends ChangeNotifier {
  CinemaSubtitleAutoSync(
    this.player, {
    required this.media,
    this.headers,
    this.onSaved,
    this.timeout = const Duration(seconds: 30),
    this.extractionTimeout = const Duration(seconds: 12),
    this.cleanupTimeout = const Duration(seconds: 3),
    this.extractWindow,
    this.matchVoice,
    this.createWorker,
    this.inspectRecognition,
    int sampleSeconds = 5,
    this.onSampleSecondsChanged,
  }) : _sampleSeconds = sampleSeconds.clamp(5, 20);
  int _sampleSeconds;
  int get sampleSeconds => _sampleSeconds;
  final Future<void> Function(int)? onSampleSecondsChanged;
  void setSampleSeconds(int value) {
    final next = value.clamp(5, 20);
    if (next == _sampleSeconds || _closed) return;
    if (busy) cancel();
    _sampleSeconds = next;
    notifyListeners();
  }

  Future<void> saveSamplingPreference() async {
    try {
      await onSampleSecondsChanged?.call(sampleSeconds);
    } catch (_) {
      if (!_closed) {
        message = '采样时长已调整，但保存失败，请重试';
        notifyListeners();
      }
    }
  }

  final Player player;
  final String Function() media;
  final Map<String, String> Function()? headers;
  final Future<void> Function()? onSaved;
  final Duration timeout, extractionTimeout, cleanupTimeout;
  @visibleForTesting
  final Future<CinemaVoiceWindow> Function(double start)? extractWindow;
  @visibleForTesting
  final Future<CinemaAutoSyncResult> Function(
    List<CinemaSubtitleCue> cues,
    List<CinemaVoiceWindow> windows,
    CinemaSubtitleTiming timing,
  )?
  matchVoice;
  @visibleForTesting
  final Player Function()? createWorker;
  @visibleForTesting
  final void Function(CinemaVoiceWindow window, List<CinemaSpokenWord> words)?
  inspectRecognition;
  bool busy = false, _closed = false;
  CinemaSubtitleSyncOutcome outcome = CinemaSubtitleSyncOutcome.idle;
  String message = '', phase = '';
  double progress = 0;
  Duration elapsed = Duration.zero;
  _CinemaSubtitleSyncRun? _active;
  final _voiceCache = <String, CinemaVoiceWindow>{};
  final _wordCache = <String, List<CinemaSpokenWord>>{};

  bool _current(_CinemaSubtitleSyncRun run) =>
      !_closed &&
      identical(_active, run) &&
      !run.stopped.isCompleted &&
      run.session.fingerprint == run.fingerprint &&
      identical(run.session.timing.value, run.expectedTiming);

  void _stage(_CinemaSubtitleSyncRun run, String label, double value) {
    if (!_current(run)) throw _CinemaSubtitleSyncStopped();
    phase = label;
    message = label;
    progress = value;
    elapsed = run.watch.elapsed;
    notifyListeners();
  }

  Future<T> _guard<T>(
    Future<T> future,
    _CinemaSubtitleSyncRun run, {
    Duration? limit,
  }) async {
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    if (!_current(run)) throw _CinemaSubtitleSyncStopped();
    final value = await Future.any<T>([
      future.timeout(
        limit ?? extractionTimeout + Duration(seconds: run.sampleSeconds - 5),
      ),
      run.stopped.future.then<T>((_) => throw _CinemaSubtitleSyncStopped()),
    ]);
    if (!_current(run)) throw _CinemaSubtitleSyncStopped();
    return value;
  }

  void _finish(
    _CinemaSubtitleSyncRun run,
    CinemaSubtitleSyncOutcome result,
    String notice,
  ) {
    if (!identical(_active, run)) return;
    elapsed = run.watch.elapsed;
    run.watch.stop();
    run.ticker?.cancel();
    run.deadline?.cancel();
    _active = null;
    busy = false;
    outcome = result;
    message = notice;
    if (!run.stopped.isCompleted) run.stopped.complete();
    unawaited(
      _tools
          .invokeMethod<void>('cancelRecognition', run.id)
          .catchError((Object _) {}),
    );
    if (!_closed) notifyListeners();
    // UI completion must never wait for a stuck native decoder to release.
    unawaited(_cleanup(run));
  }

  void cancel() {
    final run = _active;
    if (run != null) {
      _finish(run, CinemaSubtitleSyncOutcome.cancelled, '已停止自动对齐');
    } else if (!_closed && message.isNotEmpty) {
      message = '';
      outcome = CinemaSubtitleSyncOutcome.idle;
      notifyListeners();
    }
  }

  Future<void> _releaseWorker(_CinemaSubtitleSyncRun run) async {
    final worker = run.worker;
    if (worker != null) {
      run.worker = null;
      run.disposal = Future<void>.sync(worker.dispose);
      unawaited(run.disposal!.catchError((Object _) {}));
    }
    await (run.disposal ?? Future<void>.value()).timeout(cleanupTimeout);
  }

  Future<void> _cleanup(_CinemaSubtitleSyncRun run) async {
    try {
      await _releaseWorker(run);
    } catch (_) {}
    try {
      await run.temporary?.delete(recursive: true).timeout(cleanupTimeout);
    } catch (_) {}
  }

  Future<void> run({CinemaSubtitleCue? anchorCue}) async {
    if (busy || _closed) return;
    if (!Platform.isMacOS) {
      outcome = CinemaSubtitleSyncOutcome.failed;
      message = '本地自动校准目前适用于 Mac';
      notifyListeners();
      return;
    }
    final session = cinemaExternalSubtitleState(player);
    if (!session.active.value || session.cues.isEmpty) {
      outcome = CinemaSubtitleSyncOutcome.failed;
      message = '请先加载带时间轴的外挂字幕';
      notifyListeners();
      return;
    }
    if (media().isEmpty) {
      outcome = CinemaSubtitleSyncOutcome.failed;
      message = '当前视频尚未就绪，请开始播放后重试';
      notifyListeners();
      return;
    }
    final run = _active = _CinemaSubtitleSyncRun(session, sampleSeconds);
    busy = true;
    outcome = CinemaSubtitleSyncOutcome.working;
    elapsed = Duration.zero;
    _stage(run, '准备当前对白附近的 ${run.sampleSeconds} 秒音频', .03);
    run.deadline = Timer(
      timeout + Duration(seconds: run.sampleSeconds - 5),
      () {
        _finish(
          run,
          run.applied
              ? CinemaSubtitleSyncOutcome.saveFailed
              : CinemaSubtitleSyncOutcome.timedOut,
          run.applied
              ? '对齐已应用，但保存超时；请检查本集设置'
              : '自动对齐已超时（$phase），本次未应用新对齐，可重试或手动校准',
        );
      },
    );
    run.ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_current(run)) {
        _finish(run, CinemaSubtitleSyncOutcome.cancelled, '字幕已更换或手动调整，自动对齐已停止');
      } else {
        elapsed = run.watch.elapsed;
        notifyListeners();
      }
    });
    try {
      await _perform(run, anchorCue: anchorCue);
    } on _CinemaSubtitleSyncStopped {
      if (identical(_active, run)) {
        _finish(run, CinemaSubtitleSyncOutcome.cancelled, '自动对齐已停止');
      }
    } on TimeoutException {
      _finish(
        run,
        run.applied
            ? CinemaSubtitleSyncOutcome.saveFailed
            : CinemaSubtitleSyncOutcome.timedOut,
        run.applied
            ? '对齐已应用，但保存未完成；请检查本集设置'
            : '自动对齐已超时（$phase），本次未应用新对齐，可重试或手动校准',
      );
    } on FormatException catch (error) {
      _finish(
        run,
        run.applied
            ? CinemaSubtitleSyncOutcome.saveFailed
            : CinemaSubtitleSyncOutcome.failed,
        run.applied ? '对齐已应用，但保存失败；请检查本集设置' : error.message,
      );
    } catch (_) {
      _finish(
        run,
        run.applied
            ? CinemaSubtitleSyncOutcome.saveFailed
            : CinemaSubtitleSyncOutcome.failed,
        run.applied ? '对齐已应用，但保存失败；请检查本集设置' : '自动对齐未完成（$phase），保留原对齐；可重试或手动校准',
      );
    } finally {
      if (identical(_active, run)) {
        _finish(run, CinemaSubtitleSyncOutcome.failed, '自动对齐未完成，可重试或手动校准');
      }
    }
  }

  Future<void> _perform(
    _CinemaSubtitleSyncRun run, {
    CinemaSubtitleCue? anchorCue,
  }) async {
    final session = run.session,
        cues = session.cues,
        timing = run.expectedTiming;
    final position = player.state.position.inMicroseconds / 1000000;
    final duration = player.state.duration.inMicroseconds / 1000000;
    final currentStart = (position - 2)
        .floorToDouble()
        .clamp(
          0.0,
          duration > run.sampleSeconds
              ? duration - run.sampleSeconds
              : math.max(0.0, position),
        )
        .toDouble();
    var start = anchorCue != null || matchVoice != null
        ? currentStart
        : cinemaSubtitleDialogueStart(
            cues,
            position: position,
            duration: duration,
            timing: timing,
            sampleSeconds: run.sampleSeconds,
          );
    if (anchorCue == null && matchVoice == null) {
      final prefix = '${media()}|${player.state.track.audio.id}|';
      for (final entry in _voiceCache.entries) {
        if (entry.key.startsWith(prefix) &&
            entry.key.endsWith('|${run.sampleSeconds}') &&
            (entry.value.startSeconds + run.sampleSeconds / 2 - position)
                    .abs() <=
                30 &&
            _wordCache.entries.any(
              (w) => w.key.startsWith('${entry.key}|') && w.value.length >= 4,
            )) {
          start = entry.value.startSeconds;
          break;
        }
      }
    }
    final key =
        '${media()}|${player.state.track.audio.id}|$start|${run.sampleSeconds}';
    final cached = _voiceCache[key];
    final CinemaVoiceWindow window;
    if (cached == null) {
      _stage(run, '读取当前对白附近的 ${run.sampleSeconds} 秒音频', .12);
      window = await _guard(
        extractWindow?.call(start) ?? _extract(run, start),
        run,
      );
      if (_voiceCache.length >= 4) _voiceCache.remove(_voiceCache.keys.first);
      _voiceCache[key] = window;
    } else {
      window = cached;
    }
    CinemaAutoSyncResult? recognized;
    if (anchorCue == null && matchVoice == null && window.pcm != null) {
      _stage(run, 'Mac 本地识别 ${run.sampleSeconds} 秒对白文字（首次可能准备语音模型）', .74);
      final selectedAudio = player.state.track.audio;
      final audioLanguage =
          (selectedAudio.language ??
                  player.state.tracks.audio
                      .where(
                        (a) =>
                            a.id == selectedAudio.id ||
                            (selectedAudio.id == 'auto' &&
                                RegExp(r'^\d+$').hasMatch(a.id)),
                      )
                      .map((a) => a.language)
                      .whereType<String>()
                      .firstOrNull ??
                  '')
              .toLowerCase();
      final latinCount = cues.fold(
        0,
        (int n, c) => n + RegExp(r'[a-zA-Z]{2,}').allMatches(c.text).length,
      );
      final locale =
          audioLanguage.startsWith('zh') ||
              audioLanguage == 'chi' ||
              audioLanguage == 'zho'
          ? 'zh-CN'
          : audioLanguage.startsWith('en') ||
                audioLanguage == 'eng' ||
                latinCount > 30
          ? 'en-US'
          : 'zh-CN';
      final wordsKey = '$key|$locale';
      var words = _wordCache[wordsKey];
      try {
        if (words == null) {
          final raw = await _guard(
            _tools.invokeListMethod<dynamic>('transcribeClip', {
              'id': run.id,
              'pcm': window.pcm!,
              'locale': locale,
            }),
            run,
            limit: const Duration(seconds: 10),
          );
          words = [
            for (final row in raw ?? const [])
              if (row is Map &&
                  row['text'] is String &&
                  row['start'] is num &&
                  row['end'] is num)
                CinemaSpokenWord(
                  row['text'],
                  (row['start'] as num).toDouble(),
                  (row['end'] as num).toDouble(),
                  row['confidence'] is num
                      ? (row['confidence'] as num).toDouble()
                      : 0,
                ),
          ];
          if (_wordCache.length >= 4) _wordCache.remove(_wordCache.keys.first);
          _wordCache[wordsKey] = words;
        }
        _stage(run, '在字幕文件中定位已识别的对白', .86);
        inspectRecognition?.call(window, words);
        final matched = await _guard<CinemaAutoSyncResult>(
          compute(_matchWords, <Object?>[
            cues,
            words,
            window.startSeconds,
            timing,
            window.speech,
            run.sampleSeconds,
          ]),
          run,
          limit: const Duration(seconds: 3),
        );
        recognized = matched;
        if (matched.timing == null) {
          _finish(
            run,
            CinemaSubtitleSyncOutcome.noMatch,
            words.isEmpty
                ? '这 ${run.sampleSeconds} 秒未识别到清晰对白，保留原对齐；请在有人说话时重试或选中听到的一句'
                : matched.message,
          );
          return;
        }
      } on PlatformException {
        // Older macOS versions retain the short voice/onset matcher.
      } on MissingPluginException {
        // Native host is unavailable in headless tests.
      }
    }
    _stage(
      run,
      anchorCue == null ? '匹配 ${run.sampleSeconds} 秒对白' : '定位选中对白的语音起点',
      .9,
    );
    final result =
        recognized ??
        await _guard<CinemaAutoSyncResult>(
          matchVoice?.call(cues, [window], timing) ??
              compute(_matchClip, <Object?>[
                cues,
                window,
                timing,
                position,
                anchorCue,
              ]),
          run,
          limit: const Duration(seconds: 2),
        );
    if (result.timing == null) {
      _finish(run, CinemaSubtitleSyncOutcome.noMatch, result.message);
      return;
    }
    _stage(run, '保存本视频对齐设置', .96);
    run.expectedTiming = result.timing!;
    run.applied = true;
    session.setTiming(result.timing!);
    await _guard(session.flush(), run, limit: const Duration(seconds: 10));
    if (session.saveError.value != null) {
      throw const FormatException('字幕对齐保存失败');
    }
    await _guard(
      onSaved?.call() ?? Future<void>.value(),
      run,
      limit: const Duration(seconds: 10),
    );
    progress = 1;
    _finish(
      run,
      CinemaSubtitleSyncOutcome.succeeded,
      '${result.message} · ${session.saveTiming == null ? '已应用当前视频' : '已保存'}',
    );
  }

  Future<CinemaVoiceWindow> _extract(
    _CinemaSubtitleSyncRun run,
    double start,
  ) async {
    run.temporary ??= await Directory.systemTemp.createTemp(
      'naku-subtitle-sync-',
    );
    if (!_current(run)) {
      unawaited(_cleanup(run));
      throw _CinemaSubtitleSyncStopped();
    }
    final worker = run.worker =
        createWorker?.call() ??
        Player(
          configuration: const PlayerConfiguration(vo: 'null', pitch: false),
        );
    final file = File('${run.temporary!.path}/${start.toStringAsFixed(3)}.pcm');
    try {
      final native = worker.platform;
      if (native is! NativePlayer) throw const FormatException('当前后端不支持本地音频分析');
      final uri = Uri.tryParse(media());
      if (uri != null && ['http', 'https'].contains(uri.scheme)) {
        await configureNativePlayback(
          native,
          uri,
          isCurrent: () => _current(run),
          diskCache: false,
        );
      }
      final aid = player.state.track.audio.id;
      if (RegExp(r'^\d+$').hasMatch(aid)) await native.setProperty('aid', aid);
      for (final option in <String, String>{
        'ao': 'pcm',
        'vid': 'no',
        'sid': 'no',
        'audio-samplerate': '16000',
        'audio-channels': 'mono',
        'audio-format': 's16',
        'ao-pcm-waveheader': 'no',
        'ao-pcm-file': file.path,
        'untimed': 'yes',
        'start': '$start',
        'length': '${run.sampleSeconds}',
        'cache': 'no',
        'demuxer-readahead-secs': '0',
        'demuxer-max-bytes': '1048576',
      }.entries) {
        if (!_current(run)) throw _CinemaSubtitleSyncStopped();
        await native.setProperty(option.key, option.value);
      }
      final completion = worker.stream.completed
          .firstWhere((done) => done)
          .then<void>((_) {});
      unawaited(completion.catchError((Object _) {}));
      await worker.open(
        Media(
          media(),
          httpHeaders: headers?.call() ?? const {},
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(
            milliseconds: ((start + run.sampleSeconds) * 1000).round(),
          ),
        ),
      );
      await Future.any<void>([completion, run.stopped.future]);
    } finally {
      await _releaseWorker(run);
    }
    if (!_current(run)) throw _CinemaSubtitleSyncStopped();
    if (!await file.exists() ||
        await file.length() > run.sampleSeconds * 32000 + 16384) {
      throw const FormatException('音频分析片段无效或过大');
    }
    _stage(run, '分析 ${run.sampleSeconds} 秒语音活动', .68);
    final pcm = Uint8List.fromList(
      (await file.readAsBytes()).take(run.sampleSeconds * 32000).toList(),
    );
    final voice = await _guard(
      _tools.invokeMethod<Uint8List>('voiceActivity', pcm),
      run,
      limit: const Duration(seconds: 2),
    );
    if (voice == null) throw const FormatException('本地语音活动分析不可用');
    return CinemaVoiceWindow(
      start,
      Uint8List.fromList(voice.take(run.sampleSeconds * 50).toList()),
      pcm: pcm,
    );
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _voiceCache.clear();
    _wordCache.clear();
    final run = _active;
    if (run != null) {
      _finish(run, CinemaSubtitleSyncOutcome.cancelled, '自动对齐已停止');
    }
    super.dispose();
  }
}

Future<bool> cinemaHasBurnedChinese(
  Player player, {
  bool Function()? isCurrent,
}) async {
  if (!Platform.isMacOS || player.platform is! NativePlayer) return false;
  var found = 0;
  for (var i = 0; i < 3; i++) {
    if (isCurrent?.call() == false) return false;
    try {
      final bytes = await player.screenshot(format: 'image/png');
      if (bytes != null &&
          await _tools.invokeMethod<bool>('hasChineseCaption', bytes) == true) {
        found++;
      }
    } catch (_) {
      return false;
    }
    if (found >= 2) return true;
    if (i < 2) await Future<void>.delayed(const Duration(seconds: 2));
  }
  return false;
}
