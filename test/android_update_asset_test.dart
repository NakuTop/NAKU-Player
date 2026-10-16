import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/auto_updater.dart';

void main() {
  final assets = [
    {'name': 'NAKUPlayer-3.1.0-Android-TV.apk'},
    {'name': 'NAKUPlayer-3.1.0-Android-Mobile-Personal.apk'},
    {'name': 'NAKUPlayer-3.1.0-Android-Mobile.apk'},
    {'name': 'NAKUPlayer-2.8.0-macOS-universal.zip'},
  ];
  test(
    'phone update selects public mobile package even when TV asset is first',
    () {
      expect(
        getUpdateAssetForType(
          assets,
          InstallationType.androidApk,
          television: false,
        )?['name'],
        'NAKUPlayer-3.1.0-Android-Mobile.apk',
      );
    },
  );
  test('TV updates cannot fall through to a mobile package', () {
    expect(
      getUpdateAssetForType(
        assets,
        InstallationType.androidApk,
        television: true,
      )?['name'],
      'NAKUPlayer-3.1.0-Android-TV.apk',
    );
    expect(
      getUpdateAssetForType(
        assets.skip(1).toList(),
        InstallationType.androidApk,
        television: true,
      ),
      isNull,
    );
  });
}
