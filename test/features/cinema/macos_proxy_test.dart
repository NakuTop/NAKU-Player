import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  tearDown(() => MacOSSystemProxy.setConfiguration({}));
  test('respects per-scheme system proxies, loopback and CIDR exclusions', () {
    MacOSSystemProxy.setConfiguration({
      'HTTPEnable': 1,
      'HTTPProxy': 'proxy.example',
      'HTTPPort': 8080,
      'HTTPSEnable': 1,
      'HTTPSProxy': 'secure.example',
      'HTTPSPort': 8888,
      'ExceptionsList': ['192.168.0.0/16', '*.local', '10.0.0.0/8'],
    });
    expect(
      MacOSSystemProxy.findProxy(Uri.parse('https://example.com')),
      'PROXY secure.example:8888',
    );
    expect(
      MacOSSystemProxy.findProxy(Uri.parse('http://example.com')),
      'PROXY proxy.example:8080',
    );
    for (final host in [
      '127.0.0.1',
      'localhost',
      '192.168.1.10',
      '10.2.3.4',
      'nas.local',
    ]) {
      expect(MacOSSystemProxy.findProxy(Uri.parse('https://$host')), 'DIRECT');
    }
    expect(
      MacOSSystemProxy.findProxy(Uri.parse('https://192.169.1.1')),
      'PROXY secure.example:8888',
    );
  });
  test('does not apply disabled or malformed system proxy settings', () {
    MacOSSystemProxy.setConfiguration({
      'HTTPSEnable': 0,
      'HTTPSProxy': 'localhost',
      'HTTPSPort': 7897,
    });
    expect(MacOSSystemProxy.proxyFor(Uri.parse('https://example.com')), isNull);
    MacOSSystemProxy.setConfiguration({
      'HTTPSEnable': 1,
      'HTTPSProxy': 'bad/host',
      'HTTPSPort': 7897,
    });
    expect(MacOSSystemProxy.proxyFor(Uri.parse('https://example.com')), isNull);
  });
}
