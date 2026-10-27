import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_moyu_exports.dart';

void main() {
  test('export bridge accepts only the fixed HTTPS site', () {
    expect(cinemaIsMoyuUrl('https://1in8b.life/zh-hans/'), true);
    for (final value in [
      'http://1in8b.life/',
      'https://1in8b.life.evil.test/',
      'https://user@1in8b.life/',
      'https://1in8b.life:444/',
      null,
    ]) {
      expect(cinemaIsMoyuUrl(value), false);
    }
  });
  test(
    'record and card exports retain bytes and get safe matching filenames',
    () {
      final card = CinemaMoyuExport.decode([
        '../../人生卡.png',
        'data:image/png;base64,AQID',
      ]);
      expect(card.name, '人生卡.png');
      expect(card.bytes, [1, 2, 3]);
      final video = CinemaMoyuExport.decode([
        'life.exe',
        'data:video/webm;codecs="vp9,opus";base64,AQID',
      ]);
      expect(video.name, 'life.webm');
      final record = CinemaMoyuExport.decode([
        '.json',
        'data:application/json;charset=utf-8;base64,e30=',
      ]);
      expect(record.name, '1in8b.json');
      expect(record.bytes, [123, 125]);
    },
  );
  test('malformed or active content never becomes a saved export', () {
    for (final args in <List<dynamic>>[
      [],
      [1, 'data:image/png;base64,AQID'],
      ['x', 'data:text/html;base64,AQID'],
      ['x', 'data:application/javascript;base64,AQID'],
      ['x', 'data:image/png;base64,'],
      ['x', 'data:image/png;base64,invalid!'],
    ]) {
      expect(() => CinemaMoyuExport.decode(args), throwsFormatException);
    }
  });
}
