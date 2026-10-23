import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/services/player/windows_playback_policy.dart';

void main() {
  test(
    'Mac normalizes imported Windows defaults to VideoToolbox and preserves software override',
    () {
      for (final saved in [
        '',
        'auto-safe',
        'd3d11va',
        'd3d11va,auto',
        'dxva2',
        'mediacodec',
      ]) {
        expect(
          cinemaHardwareDecoder(saved, platform: TargetPlatform.macOS),
          'videotoolbox,auto',
        );
      }
      for (final saved in ['no', 'videotoolbox', 'videotoolbox-copy']) {
        expect(
          cinemaHardwareDecoder(saved, platform: TargetPlatform.macOS),
          saved,
        );
      }
    },
  );
  test('Mac decodes GB18030 Chinese dialogue strictly', () {
    final text = CinemaOnlineSubtitles.decodeSubtitle([
      ...ascii.encode('1\n00:00:00,000 --> 00:00:02,000\n'),
      0xd6,
      0xd0,
      0xce,
      0xc4,
      10,
    ]);
    expect(text, contains('中文'));
    expect(
      () => CinemaOnlineSubtitles.decodeSubtitle([0x81]),
      throwsFormatException,
    );
  }, skip: !Platform.isMacOS);
  test(
    'Mac extracts only selected subtitle from ZIP and rejects unsafe entries',
    () async {
      final directory = await Directory.systemTemp.createTemp('naku-zip-test-');
      addTearDown(() => directory.delete(recursive: true));
      final season = await Directory('${directory.path}/Season 1').create();
      await File(
        '${season.path}/01.srt',
      ).writeAsString('1\n00:00:00,000 --> 00:00:02,000\n中文\n');
      await File('${season.path}/02.srt').writeAsString('Other episode');
      final packed = await Process.run('/usr/bin/zip', [
        '-qr',
        'fixture.zip',
        'Season 1',
      ], workingDirectory: directory.path);
      expect(packed.exitCode, 0);
      final bytes = await File('${directory.path}/fixture.zip').readAsBytes();
      final selected = await CinemaOnlineSubtitles.extractSubtitle(
        bytes,
        'Season 1/01.srt',
      );
      expect(utf8.decode(selected), contains('中文'));
      expect(utf8.decode(selected), isNot(contains('Other episode')));
      for (final entry in ['../01.srt', '/01.srt', 'C:/01.srt', 'file.exe']) {
        await expectLater(
          CinemaOnlineSubtitles.extractSubtitle(bytes, entry),
          throwsFormatException,
        );
      }
    },
    skip: !Platform.isMacOS,
  );
}
