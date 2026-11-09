import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_update_service.dart';
import 'package:kazumi/services/update/auto_updater.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  test(
    'published phone feed upgrades the prior phone release with a public APK',
    () {
      final feed =
          jsonDecode(File('android-update.json').readAsStringSync()) as Map;
      expect(needUpdate('3.1.2', feed['tag_name'] as String), isTrue);
      final asset = getUpdateAssetForType(
        feed['assets'] as List,
        InstallationType.androidApk,
        television: false,
      )!;
      expect(
        asset['name'],
        'NAKUPlayer-${feed['tag_name']}-Android-Mobile.apk',
      );
      expect(getUpdateFileHashFromAsset(asset), matches(r'^[a-f0-9]{64}$'));
      expect(asset['size'], greaterThan(0));
    },
  );
  test('published TV feed upgrades 1.1.6 and rejects mobile assets', () {
    final feed =
        jsonDecode(File('android-tv-update.json').readAsStringSync()) as List;
    const installed = CinemaTVInstalledVersion(
      version: '1.1.6',
      build: 8,
      directory: '/unused',
      canInstall: true,
    );
    final release = cinemaTVSelectUpdate(feed, installed)!;
    expect(release.build, greaterThan(installed.build));
    expect(release.sha256, matches(r'^[a-f0-9]{64}$'));
    final phone = jsonDecode(File('android-update.json').readAsStringSync());
    expect(cinemaTVSelectUpdate([phone], installed), isNull);
    expect(
      getUpdateAssetForType(
        feed.first['assets'] as List,
        InstallationType.androidApk,
        television: false,
      ),
      isNull,
    );
  });
}
