import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/update/auto_updater.dart';

void main() {
  test('Windows uses its own NAKU feed and selects exact package types', () {
    expect(
      Uri.parse(ApiEndpoints.windowsApp).host,
      'raw.githubusercontent.com',
    );
    expect(
      Uri.parse(ApiEndpoints.windowsApp).path,
      '/NakuTop/NAKU-Player/main/windows-update.json',
    );
    final assets = <Map<String, dynamic>>[
      {'name': 'NAKUPlayer-3.2.0-macOS-universal.zip'},
      {'name': 'NAKUPlayer-3.2.0-Android-Mobile.apk'},
      {'name': 'NAKUPlayer-3.2.0-Windows-x64-portable.zip'},
      {'name': 'NAKUPlayer-3.2.0-Windows-x64-Setup.exe'},
    ];
    expect(
      getUpdateAssetForType(assets, InstallationType.windowsInstaller)?['name'],
      'NAKUPlayer-3.2.0-Windows-x64-Setup.exe',
    );
    expect(
      getUpdateAssetForType(assets, InstallationType.windowsPortable)?['name'],
      'NAKUPlayer-3.2.0-Windows-x64-portable.zip',
    );
    expect(
      getUpdateAssetForType(
        assets.take(2).toList(),
        InstallationType.windowsInstaller,
      ),
      isNull,
    );
    expect(getUpdateAssetForType(assets, InstallationType.windowsMsix), isNull);
  });
}
