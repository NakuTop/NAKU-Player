import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_address.dart';

void main() {
  test('UGlink shares, aliases and bare origins normalize consistently', () {
    for (final value in [
      'example',
      'https://ug.link/example',
      'ug.link/example/',
      'http://ug.link/example',
    ]) {
      expect(normalizeNASConnectionInput(value), 'example');
    }
    expect(
      normalizeNASConnectionInput('example.cn21.ug.link'),
      'https://example.cn21.ug.link',
    );
    expect(
      normalizeNASConnectionInput(' 192.168.1.10:9999 '),
      'http://192.168.1.10:9999',
    );
  });
  test('credentials, ambiguous paths and incomplete shares are rejected', () {
    for (final value in [
      '',
      'https://ug.link/',
      'https://ug.link/a/b',
      'https://user@ug.link/example',
      'https://ug.link/example?token=secret',
      '8.8.8.8:80',
    ]) {
      expect(() => normalizeNASConnectionInput(value), throwsFormatException);
    }
  });
}
