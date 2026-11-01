import 'dart:convert';

/// Only protocol counters and known states leave the app through Copy. Device
/// names, IP addresses, service IDs and arbitrary native error text are excluded.
class HomePodAudioDiagnostics {
  HomePodAudioDiagnostics.decode(Map value)
    : values = Map.unmodifiable({
        for (final key in metricKeys)
          if (value[key] is num && (value[key] as num).isFinite)
            key: (value[key] as num).clamp(
              key == 'senderDriftPPM' ? -1000000 : 0,
              9007199254740991,
            ),
      });

  static const metricKeys = [
    'capturedFrames',
    'nonzeroSamples',
    'peakSample',
    'packetsSent',
    'senderBufferedFrames',
    'senderUnderruns',
    'senderDroppedFrames',
    'senderDriftPPM',
    'senderLateSends',
    'senderClockResets',
    'senderRetransmitRequests',
  ];
  final Map<String, num> values;
  bool get available => values.containsKey('packetsSent');

  String report({required String status, String? interruptionReason}) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': 'NAKU HomePod diagnostics 1',
        'status':
            const {
              'off',
              'streaming',
              'connecting',
              'error',
              'interrupted',
              'installing',
            }.contains(status)
            ? status
            : 'unknown',
        if (const {'sleep', 'network'}.contains(interruptionReason))
          'interruptionReason': interruptionReason,
        'counters': values,
      });
}

enum HomePodConnectionHealth {
  observing('正在观察连接状态'),
  stable('音频采集与发送正常'),
  unstable('检测到传输波动'),
  captureStalled('音频采集暂未推进'),
  senderStalled('音频发送暂未推进');

  const HomePodConnectionHealth(this.label);
  final String label;
}

/// Uses differences between sufficiently separated samples. Silence is valid
/// audio; neither peak level nor a historical underrun means a current fault.
class HomePodHealthSampler {
  HomePodAudioDiagnostics? _previous;
  DateTime? _sampledAt;
  HomePodConnectionHealth health = HomePodConnectionHealth.observing;

  void reset() {
    _previous = null;
    _sampledAt = null;
    health = HomePodConnectionHealth.observing;
  }

  void sample(HomePodAudioDiagnostics current, DateTime now) {
    final previous = _previous;
    final elapsed = _sampledAt == null ? null : now.difference(_sampledAt!);
    if (previous == null || elapsed!.isNegative) {
      _previous = current;
      _sampledAt = now;
      health = HomePodConnectionHealth.observing;
      return;
    }
    if (elapsed < const Duration(seconds: 1)) return;
    _previous = current;
    _sampledAt = now;
    final before = previous.values, after = current.values;
    if (!before.containsKey('capturedFrames') ||
        !before.containsKey('packetsSent') ||
        !after.containsKey('capturedFrames') ||
        !after.containsKey('packetsSent') ||
        after['capturedFrames']! < before['capturedFrames']! ||
        after['packetsSent']! < before['packetsSent']!) {
      health = HomePodConnectionHealth.observing;
    } else if (after['capturedFrames'] == before['capturedFrames']) {
      health = HomePodConnectionHealth.captureStalled;
    } else if (after['packetsSent'] == before['packetsSent']) {
      health = HomePodConnectionHealth.senderStalled;
    } else if (const [
      'senderUnderruns',
      'senderDroppedFrames',
      'senderLateSends',
      'senderClockResets',
      'senderRetransmitRequests',
    ].any((key) => (after[key] ?? 0) > (before[key] ?? 0))) {
      health = HomePodConnectionHealth.unstable;
    } else {
      health = HomePodConnectionHealth.stable;
    }
  }
}
