import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/homepod_audio_diagnostics.dart';

void main() {
  HomePodAudioDiagnostics snapshot(
    int frames,
    int packets, {
    int underruns = 0,
  }) => HomePodAudioDiagnostics.decode({
    'capturedFrames': frames,
    'packetsSent': packets,
    'senderUnderruns': underruns,
    'nonzeroSamples': 0,
  });
  final start = DateTime.utc(2026);

  test('diagnostics copy only known states and finite numeric counters', () {
    final diagnostics = HomePodAudioDiagnostics.decode({
      'packetsSent': 17,
      'senderDriftPPM': -203.5,
      'senderUnderruns': -1,
      'senderLateSends': double.nan,
      'deviceName': 'Private bedroom',
      'address': '192.168.1.2',
      'error': 'request https://secret.invalid/?token=secret',
      'peakSample': 'secret',
    });
    final report = diagnostics.report(
      status: 'secret',
      interruptionReason: '192.168.1.2',
    );
    expect(jsonDecode(report), {
      'format': 'NAKU HomePod diagnostics 1',
      'status': 'unknown',
      'counters': {
        'packetsSent': 17,
        'senderDriftPPM': -203.5,
        'senderUnderruns': 0,
      },
    });
    expect(report, isNot(contains('secret')));
    expect(report, isNot(contains('192.168')));
  });

  test('silence and old underruns are healthy when counters advance', () {
    final sampler = HomePodHealthSampler();
    sampler.sample(snapshot(1000, 10, underruns: 7), start);
    expect(sampler.health, HomePodConnectionHealth.observing);
    sampler.sample(
      snapshot(2000, 20, underruns: 7),
      start.add(const Duration(seconds: 2)),
    );
    expect(sampler.health, HomePodConnectionHealth.stable);
    sampler.sample(
      snapshot(3000, 30, underruns: 8),
      start.add(const Duration(seconds: 4)),
    );
    expect(sampler.health, HomePodConnectionHealth.unstable);
    sampler.sample(
      snapshot(4000, 40, underruns: 8),
      start.add(const Duration(seconds: 6)),
    );
    expect(sampler.health, HomePodConnectionHealth.stable);
  });

  test(
    'detects stopped capture and sender without treating immediate polls as stalls',
    () {
      final sampler = HomePodHealthSampler();
      sampler.sample(snapshot(1000, 10), start);
      sampler.sample(
        snapshot(1000, 10),
        start.add(const Duration(milliseconds: 30)),
      );
      expect(sampler.health, HomePodConnectionHealth.observing);
      sampler.sample(snapshot(1000, 20), start.add(const Duration(seconds: 2)));
      expect(sampler.health, HomePodConnectionHealth.captureStalled);
      sampler.sample(snapshot(2000, 20), start.add(const Duration(seconds: 4)));
      expect(sampler.health, HomePodConnectionHealth.senderStalled);
      sampler.sample(snapshot(0, 0), start.add(const Duration(seconds: 6)));
      expect(sampler.health, HomePodConnectionHealth.observing);
      sampler.reset();
      expect(sampler.health, HomePodConnectionHealth.observing);
    },
  );
}
