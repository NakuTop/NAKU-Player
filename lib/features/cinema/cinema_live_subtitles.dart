import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/request/core/network_config.dart';

Uint8List cinemaPcmWave(Uint8List pcm) {
  final bytes = Uint8List(44 + pcm.length);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

bool cinemaPcmHasSpeech(Uint8List pcm) {
  if (pcm.length < 2) return false;
  final data = ByteData.sublistView(pcm);
  var energy = 0.0;
  for (var i = 0; i + 1 < pcm.length; i += 2) {
    final sample = data.getInt16(i, Endian.little) / 32768;
    energy += sample * sample;
  }
  return sqrt(energy / (pcm.length ~/ 2)) > .002;
}

class CinemaLiveAudioWindow {
  Uint8List _pcm = Uint8List(0);
  void clear() => _pcm = Uint8List(0);
  Uint8List push(Uint8List next) {
    const maximum = 16000 * 2 * 4;
    final combined = Uint8List(_pcm.length + next.length)
      ..setAll(0, _pcm)
      ..setAll(_pcm.length, next);
    _pcm = combined.length > maximum
        ? Uint8List.sublistView(combined, combined.length - maximum)
        : combined;
    return _pcm;
  }
}

/// Owned by one playback selection. No microphone, public ASR service or translation.
class CinemaLiveSubtitles extends ChangeNotifier {
  CinemaLiveSubtitles(this.player, {this.enginePath, this.modelDirectory});
  final Player player;
  final String? enginePath, modelDirectory;
  static const modelHash =
      '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe';
  static const _channel = MethodChannel('naku/live_audio');
  bool enabled = false, busy = false;
  String text = '', status = '本地识别播放器音频，生成原文字幕；不翻译、不上传音频。';
  double? progress;
  String language = 'en';
  Process? _server;
  Dio? _local;
  Timer? _timer, _clearTimer;
  CancelToken? _download;
  int _generation = 0;
  int _audioRevision = 0;
  Future<void>? _stopping;
  bool _disposed = false, _inferenceBusy = false;
  Duration _lastPosition = Duration.zero;
  final _audioWindow = CinemaLiveAudioWindow();
  int lastRecognitionMilliseconds = 0;
  final _subscriptions = <StreamSubscription<dynamic>>[];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<File> modelFile() async {
    if (modelDirectory == null) {
      final bundled = File(
        '${File(Platform.resolvedExecutable).parent.path}/ai-runtime/ggml-base.bin',
      );
      if (await bundled.exists()) return bundled;
    }
    return File(
      '${modelDirectory ?? '${(await getApplicationSupportDirectory()).path}/ai'}/ggml-base.bin',
    );
  }

  Future<void> prepare() async {
    if (busy) return;
    busy = true;
    status = '准备本地语音模型（约 148 MB）';
    _notify();
    final file = await modelFile();
    final temporary = File('${file.path}.download');
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    try {
      try {
        dio.httpClientAdapter = NetworkConfig.fromSettings()
            .copyWith(allowBadCertificates: false)
            .createAdapter();
      } catch (_) {
        dio.httpClientAdapter = const NetworkConfig().createAdapter();
      }
      await file.parent.create(recursive: true);
      if (!await file.exists()) {
        _download = CancelToken();
        Object? failure;
        for (final host in ['huggingface.co', 'hf-mirror.com']) {
          try {
            await dio.download(
              'https://$host/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
              temporary.path,
              cancelToken: _download,
              onReceiveProgress: (count, total) {
                progress = count / 147951465;
                status =
                    '正在下载本地语音模型 ${(progress! * 100).clamp(0, 100).round()}%';
                _notify();
              },
            );
            failure = null;
            break;
          } catch (error) {
            failure = error;
            if (_disposed || _download!.isCancelled) rethrow;
          }
        }
        if (failure != null) throw failure;
        final hash = (await sha256.bind(temporary.openRead()).first).toString();
        if (hash != modelHash) throw const FormatException('模型校验失败，请重新下载');
        await temporary.rename(file.path);
      }
      status = '语音模型已就绪，可开启实时原文字幕';
    } catch (_) {
      status = '模型准备失败，请检查网络后重试';
    } finally {
      dio.close(force: true);
      if (await temporary.exists()) await temporary.delete();
      busy = false;
      progress = null;
      _notify();
    }
  }

  Future<void> start() async {
    if (enabled || busy || _disposed) return;
    if (!Platform.isWindows) {
      status = '实时语音字幕目前支持 Windows';
      _notify();
      return;
    }
    busy = true;
    _notify();
    await _stopping;
    final model = await modelFile();
    final executable = File(
      enginePath ??
          '${File(Platform.resolvedExecutable).parent.path}/ai-runtime/whisper-server.exe',
    );
    if (!await executable.exists() || !await model.exists()) {
      busy = false;
      status = '请先准备语音模型，并使用包含本地识别引擎的 Windows 安装包';
      _notify();
      return;
    }
    if (_disposed) return;
    busy = true;
    enabled = true;
    text = '';
    status = '正在启动本地语音识别';
    final generation = ++_generation;
    _notify();
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final nonce = List.generate(
        20,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _local =
          Dio(
              BaseOptions(
                baseUrl: 'http://127.0.0.1:$port',
                connectTimeout: const Duration(milliseconds: 500),
                receiveTimeout: const Duration(seconds: 25),
              ),
            )
            ..httpClientAdapter = IOHttpClientAdapter(
              createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
            );
      final server = await Process.start(executable.path, [
        '-m',
        model.path,
        '-t',
        '6',
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--inference-path',
        '/recognize',
        '--request-path',
        '/$nonce',
        '-sns',
        '-ng',
      ], workingDirectory: executable.parent.path);
      if (generation != _generation || _disposed) {
        server.kill();
        return;
      }
      _server = server;
      unawaited(_server!.stdout.drain<void>());
      unawaited(_server!.stderr.drain<void>());
      var ready = false;
      for (var i = 0; i < 80 && generation == _generation; i++) {
        try {
          await _local!.get<dynamic>('/$nonce/');
          ready = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (generation != _generation) return;
      if (!ready) throw StateError('ASR startup failed');
      await _channel.invokeMethod<void>('start');
      _lastPosition = player.state.position;
      _subscriptions.add(
        player.stream.position.listen((position) {
          if ((position - _lastPosition).inMilliseconds.abs() > 1800) {
            ++_audioRevision;
            _audioWindow.clear();
            text = '';
            _clearTimer?.cancel();
            unawaited(_channel.invokeMethod<void>('clear'));
            _notify();
          }
          _lastPosition = position;
        }),
      );
      _subscriptions.add(
        player.stream.playing.listen((playing) {
          if (!playing) {
            ++_audioRevision;
            _audioWindow.clear();
            unawaited(_channel.invokeMethod<void>('clear'));
          }
        }),
      );
      _timer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_tick(generation, '/$nonce/recognize')),
      );
      busy = false;
      status = '正在实时识别原文';
      _notify();
    } catch (_) {
      await stop();
      status = '实时字幕启动失败，请检查 Windows 版本或重新准备引擎';
      _notify();
    }
  }

  Future<void> _tick(int generation, String path) async {
    if (_inferenceBusy || generation != _generation || !enabled) return;
    _inferenceBusy = true;
    try {
      if (!player.state.playing || player.state.buffering) {
        _audioWindow.clear();
        await _channel.invokeMethod<void>('clear');
        return;
      }
      final result = await _channel.invokeMapMethod<String, dynamic>('pull');
      if ((result?['error'] as int? ?? 0) < 0) {
        await stop();
        status = '播放器音频采集失败；该功能需要 Windows 11 或支持进程音频捕获的系统';
        _notify();
        return;
      }
      final pcm = result?['pcm'];
      if (pcm is! Uint8List || pcm.isEmpty) return;
      final window = _audioWindow.push(pcm);
      if (!cinemaPcmHasSpeech(pcm)) return;
      final position = player.state.position;
      final revision = _audioRevision;
      final watch = Stopwatch()..start();
      final response = await _local!.post<dynamic>(
        path,
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(
            cinemaPcmWave(window),
            filename: 'speech.wav',
          ),
          'response_format': 'json',
          'language': language,
          'translate': 'false',
          'temperature': '0',
          'no_context': 'true',
        }),
      );
      lastRecognitionMilliseconds = watch.elapsedMilliseconds;
      if (generation != _generation ||
          revision != _audioRevision ||
          !enabled ||
          (player.state.position - position).inSeconds.abs() > 12 ||
          !player.state.playing) {
        return;
      }
      final data = response.data;
      final sentence = data is Map ? '${data['text'] ?? ''}'.trim() : '';
      if (sentence.isEmpty || RegExp(r'^\[.*\]$').hasMatch(sentence)) return;
      text = sentence;
      status = '实时原文字幕已生成';
      _clearTimer?.cancel();
      _clearTimer = Timer(const Duration(seconds: 3), () {
        text = '';
        _notify();
      });
      _notify();
    } catch (_) {
      if (generation == _generation && enabled) {
        status = '当前音频段识别失败，将继续下一段';
        _notify();
      }
    } finally {
      _inferenceBusy = false;
    }
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);
  Future<void> _stop() async {
    ++_generation;
    _audioWindow.clear();
    enabled = false;
    busy = false;
    text = '';
    _timer?.cancel();
    _clearTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _local?.close(force: true);
    _local = null;
    final process = _server;
    _server = null;
    process?.kill();
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
    status = '实时字幕已关闭';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _download?.cancel();
    unawaited(stop());
    super.dispose();
  }
}

class CinemaLiveSubtitleControls extends StatelessWidget {
  const CinemaLiveSubtitleControls({super.key, required this.controller});
  final CinemaLiveSubtitles controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('实时生成原文字幕'),
        Text(controller.status),
        if (controller.progress != null)
          LinearProgressIndicator(value: controller.progress!.clamp(0, 1)),
        DropdownButtonFormField<String>(
          initialValue: controller.language,
          decoration: const InputDecoration(labelText: '音频语言'),
          items: const [
            DropdownMenuItem(value: 'en', child: Text('英语')),
            DropdownMenuItem(value: 'zh', child: Text('中文')),
            DropdownMenuItem(value: 'ja', child: Text('日语')),
            DropdownMenuItem(value: 'auto', child: Text('自动识别')),
          ],
          onChanged: controller.enabled || controller.busy
              ? null
              : (value) {
                  controller.language = value!;
                },
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: controller.busy || controller.enabled
                  ? null
                  : controller.prepare,
              child: const Text('准备本地语音模型'),
            ),
            FilledButton.icon(
              onPressed: controller.enabled
                  ? controller.stop
                  : controller.busy
                  ? null
                  : controller.start,
              icon: Icon(
                controller.enabled ? Icons.stop : Icons.closed_caption,
              ),
              label: Text(controller.enabled ? '停止生成' : '开启实时原文字幕'),
            ),
          ],
        ),
      ],
    ),
  );
}
