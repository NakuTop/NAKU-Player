import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_catalogs.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';

void main() {
  test('public catalog parses bilingual metadata and ignores unsafe entries', () {
    final rows = CinemaSubtitleCatalogs.parseAssrt(
      '<input id="key" name="searchword">'
      '<div class="subitem"><a class="introtitle" href="/xml/sub/675/675334.xml" title="AHS S10E02"></a>'
      '<span id="sublangchs"></span><span id="sublangdou"></span></div>'
      '<div class="subitem"><a class="introtitle" href="javascript:bad">bad</a></div>',
    );
    expect(rows, hasLength(1));
    expect(rows.single['bilingual'], true);
    final subhd = CinemaSubtitleCatalogs.parseSubHD(
      '<input name="subhd_search">'
      '<div><div class="view-text"><a href="/a/QR1lpA">AHS S10E02</a></div>简体 双语</div>',
    );
    expect(subhd.single['lang'], 'zh');
    expect(
      () => CinemaSubtitleCatalogs.parseAssrt('<html>captcha</html>'),
      throwsFormatException,
    );
    expect(
      () => CinemaSubtitleCatalogs.parseSubHD('<html>captcha</html>'),
      throwsFormatException,
    );
  });
  test(
    'archive reads the selected Unicode subtitle without extracting other files',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'naku-subtitle-test-',
      );
      try {
        const name = '[简体]Test.S10E02.ass';
        const text = '[Script Info]\n[Events]\n测试';
        await File('${folder.path}/$name').writeAsString(text);
        await File(
          '${folder.path}/ignored.url',
        ).writeAsString('not a subtitle');
        final zip = File('${folder.path}/fixture.zip');
        final result = await Process.run('tar.exe', [
          '-a',
          '-cf',
          zip.path,
          '-C',
          folder.path,
          name,
          'ignored.url',
        ]);
        expect(result.exitCode, 0);
        final bytes = await zip.readAsBytes();
        expect(
          utf8.decode(await CinemaOnlineSubtitles.extractSubtitle(bytes, name)),
          text,
        );
        await expectLater(
          CinemaOnlineSubtitles.extractSubtitle(bytes, '../private.ass'),
          throwsFormatException,
        );
        await expectLater(
          CinemaOnlineSubtitles.extractSubtitle(bytes, 'ignored.url'),
          throwsFormatException,
        );
        expect(await File('${folder.path}/private.ass').exists(), false);
      } finally {
        if (folder.parent.absolute.path == Directory.systemTemp.absolute.path) {
          await folder.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows,
  );
}
