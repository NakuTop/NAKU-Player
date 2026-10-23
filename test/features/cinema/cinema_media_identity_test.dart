import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_identity.dart';

void main() {
  test('quality and dub suffixes identify the same film across sources', () {
    for (final name in [
      '泰坦尼克号国语4K', '泰坦尼克号4K', '泰坦尼克号 4K',
      '泰坦尼克号（国语4K）', '泰坦尼克号【4K HDR】',
      '泰坦尼克号.2160p.UHD.BluRay', '泰坦尼克号（普通话版）4K',
      '泰坦尼克号 1080P', '泰坦尼克号 4K国语',
    ]) {
      expect(cinemaMediaBaseTitle(name), '泰坦尼克号', reason:name);
      expect(cinemaMediaBaseTitle(cinemaMediaBaseTitle(name)), '泰坦尼克号');
    }
    for (final name in ['1917', '1984', '2046', '4K杀手', '泰坦尼克号2']) {
      expect(cinemaMediaBaseTitle(name), name);
    }
    expect(cinemaMediaBaseTitle('泰坦尼克号2 4K'), '泰坦尼克号2');
  });
}
