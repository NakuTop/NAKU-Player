import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'cinema_models.dart';

class CinemaHealthRecord {
  const CinemaHealthRecord({
    required this.checkedAt,
    required this.ok,
    this.failures = 0,
    this.latencyMs,
    this.firstFrameMs,
    this.mbps,
    this.reason = '',
    this.retryAt,
  });
  final DateTime checkedAt;
  final bool ok;
  final int failures;
  final int? latencyMs, firstFrameMs;
  final double? mbps;
  final String reason;
  final DateTime? retryAt;
  Map<String, dynamic> toJson() => {
    'at': checkedAt.toIso8601String(),
    'ok': ok,
    'failures': failures,
    'latencyMs': latencyMs,
    'firstFrameMs': firstFrameMs,
    'mbps': mbps,
    'reason': reason,
    'retryAt': retryAt?.toIso8601String(),
  };
  static CinemaHealthRecord? parse(Object? value) {
    if (value is! Map) return null;
    final at = DateTime.tryParse('${value['at']}');
    if (at == null || value['ok'] is! bool) return null;
    int? integer(String key) =>
        value[key] is int && value[key] >= 0 ? value[key] as int : null;
    final speed = value['mbps'];
    return CinemaHealthRecord(
      checkedAt: at,
      ok: value['ok'],
      failures: integer('failures') ?? 0,
      latencyMs: integer('latencyMs'),
      firstFrameMs: integer('firstFrameMs'),
      mbps: speed is num && speed.isFinite && speed >= 0
          ? speed.toDouble()
          : null,
      reason: '${value['reason'] ?? ''}'.substring(
        0,
        '${value['reason'] ?? ''}'.length.clamp(0, 80),
      ),
      retryAt: DateTime.tryParse('${value['retryAt']}'),
    );
  }

  String get label =>
      '${ok
          ? '可用'
          : reason.isEmpty
          ? '连接失败'
          : reason}'
      '${latencyMs == null ? '' : ' · ${latencyMs}ms'}'
      '${mbps == null ? '' : ' · ${mbps!.toStringAsFixed(1)}Mbps'}'
      '${firstFrameMs == null ? '' : ' · 首帧 ${(firstFrameMs! / 1000).toStringAsFixed(1)}s'}';
}

/// Catalogue health and actual media health are independent. A broken video
/// never disables an otherwise useful catalogue. No signed URL is persisted.
class CinemaSourceHealth extends ChangeNotifier {
  CinemaSourceHealth({File? file, DateTime Function()? now})
    : _file = file,
      _now = now ?? DateTime.now;
  static final instance = CinemaSourceHealth();
  File? _file;
  final DateTime Function() _now;
  final Map<String, CinemaHealthRecord> _records = {};
  final Map<String, List<CinemaHealthRecord>> _events = {};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  Timer? _saveTimer;
  bool _loaded = false, _disposed = false;
  String? saveError;
  bool probing = false;
  int completed = 0, total = 0, _probeGeneration = 0;
  String _key(CinemaSource source, bool media) =>
      '${media ? 'media' : 'api'}:${sha256.convert(utf8.encode(jsonEncode({'id': source.id, 'kind': source.kind.name, 'url': source.url, 'headers': source.headers, 'rule': source.rule})))}';
  CinemaHealthRecord? record(CinemaSource source, {bool media = false}) =>
      _records[_key(source, media)];
  List<CinemaHealthRecord> history(CinemaSource source, {bool media = false}) =>
      List.unmodifiable(_events[_key(source, media)] ?? []);
  bool cooling(CinemaSource source) =>
      record(source)?.retryAt?.isAfter(_now()) == true;
  List<CinemaSource> available(Iterable<CinemaSource> sources) =>
      sources.where((source) => source.enabled && !cooling(source)).toList();
  Future<void> load() => _loaded ? Future.value() : _loading ??= _load();
  Future<void> _load() async {
    try {
      _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/source-health-v2.json',
      );
      if (await _file!.exists()) {
        if (await _file!.length() > 8 * 1024 * 1024) {
          throw const FormatException('健康记录过大');
        }
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map && raw['records'] is Map) {
          for (final entry in (raw['records'] as Map).entries.take(1000)) {
            final record = CinemaHealthRecord.parse(entry.value);
            if (record != null &&
                _now().difference(record.checkedAt).inDays < 7) {
              final key = entry.key.toString();
              _records[key] = record;
              final events = raw['events'];
              final saved = events is Map ? events[key] : null;
              _events[key] = saved is List
                  ? saved
                        .take(12)
                        .map(CinemaHealthRecord.parse)
                        .whereType<CinemaHealthRecord>()
                        .toList()
                  : [record];
            }
          }
        }
      }
    } catch (_) {
      saveError = '健康记录暂时无法读取';
    }
    _loaded = true;
    _notify();
  }

  void observe(
    CinemaSource source, {
    required bool ok,
    bool media = false,
    int? latencyMs,
    int? firstFrameMs,
    double? mbps,
    String reason = '连接失败',
  }) {
    if (_disposed) return;
    final key = _key(source, media), old = _records[_key(source, media)];
    final failures = ok ? 0 : (old?.failures ?? 0) + 1;
    final delay = failures < 2
        ? 0
        : failures < 4
        ? 2
        : failures < 6
        ? 10
        : 60;
    _records[key] = CinemaHealthRecord(
      checkedAt: _now(),
      ok: ok,
      failures: failures,
      latencyMs: latencyMs ?? old?.latencyMs,
      firstFrameMs: firstFrameMs ?? old?.firstFrameMs,
      mbps: mbps ?? old?.mbps,
      reason: ok ? '' : reason,
      retryAt: !media && delay > 0
          ? _now().add(Duration(minutes: delay))
          : null,
    );
    final event = CinemaHealthRecord(
      checkedAt: _now(),
      ok: ok,
      failures: failures,
      latencyMs: latencyMs,
      firstFrameMs: firstFrameMs,
      mbps: mbps,
      reason: ok ? '' : reason,
    );
    _events[key] = [event, ...?_events[key]].take(12).toList();
    if (_records.length > 1000) {
      final oldest = _records.keys.first;
      _records.remove(oldest);
      _events.remove(oldest);
    }
    _notify();
    _saveTimer?.cancel();
    if (_loaded && _file != null) {
      _saveTimer = Timer(const Duration(milliseconds: 600), () {
        unawaited(flush());
      });
    }
  }

  void restore(CinemaSource source) {
    _records.remove(_key(source, false));
    _notify();
    unawaited(flush());
  }

  void cancelProbes() {
    ++_probeGeneration;
    probing = false;
    _notify();
  }

  Future<void> probeAll(
    List<CinemaSource> sources,
    Future<void> Function(CinemaSource) probe,
  ) async {
    if (probing) return;
    final gen = ++_probeGeneration;
    probing = true;
    completed = 0;
    total = sources.length;
    _notify();
    var index = 0;
    Future<void> worker() async {
      while (!_disposed && gen == _probeGeneration && index < sources.length) {
        final source = sources[index++], watch = Stopwatch()..start();
        try {
          await probe(source).timeout(const Duration(seconds: 16));
          if (gen == _probeGeneration) {
            observe(source, ok: true, latencyMs: watch.elapsedMilliseconds);
          }
        } catch (_) {
          if (gen == _probeGeneration) {
            observe(source, ok: false, reason: '探活失败');
          }
        }
        if (gen == _probeGeneration) {
          completed++;
          _notify();
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    if (gen == _probeGeneration) {
      probing = false;
      _notify();
      await flush();
    }
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    final bytes = jsonEncode({
      'version': 2,
      'records': _records.map((key, value) => MapEntry(key, value.toJson())),
      'events': _events.map(
        (key, value) => MapEntry(key, value.map((v) => v.toJson()).toList()),
      ),
    });
    final task = _writes.catchError((Object _) {}).then((_) async {
      if (_file == null) return;
      try {
        await _file!.parent.create(recursive: true);
        final temp = File('${_file!.path}.tmp');
        await temp.writeAsString(bytes, flush: true);
        await temp.rename(_file!.path);
        saveError = null;
      } catch (_) {
        saveError = '健康记录未能保存';
      }
    });
    return _writes = task;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    ++_probeGeneration;
    super.dispose();
  }
}
