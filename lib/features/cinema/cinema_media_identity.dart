/// Normalize only technical edition tags. Work names, years and sequel/season
/// numbers keep their identity; source labels and playback addresses stay intact.
const _editionToken =
    r'(?:普通话|普通話|国语|國語|粤语|粵語|英语|英語|原声|原聲|配音|中文配音|国配|國配|台配|港配|中字|中英双字|中英雙字)(?:配音)?(?:版)?|(?:4\s*K|8K|2K|2160P|1080P|720P|4320P|HDR10\+?|HDR|UHD|Dolby[ ._-]*Vision|杜比视界|杜比視界|高清|超清|蓝光|藍光|BluRay|BDRip|WEB[ ._-]*DL|WEBRip|HEVC|H[ ._-]?265|H[ ._-]?264|X265|X264)';
final _editionTail = RegExp(
  r'(?:[\s._·,，-]*)(' + _editionToken + r')\s*$',
  caseSensitive: false,
);
final _editionOnly = RegExp(
  r'^(?:[\s._·,，/-]*(?:' + _editionToken + r'))+[\s._·,，/-]*$',
  caseSensitive: false,
);

String cinemaMediaBaseTitle(String title) {
  var name = title
      .trim()
      .replaceAllMapped(
        RegExp(r'[（(\[【]([^）)\]】]+)[）)\]】]'),
        (m) => _editionOnly.hasMatch(m[1]!) ? '' : m[0]!,
      )
      .trim();
  for (var i = 0; i < 16; i++) {
    final next = name.replaceFirst(_editionTail, '').trim();
    if (next.isEmpty || next == name) break;
    name = next.replaceFirst(RegExp(r'[\s._·,，-]+$'), '');
  }
  return name.isEmpty
      ? title.trim()
      : name.replaceAll(RegExp(r'\s+'), ' ').trim();
}

typedef CinemaSeasonName = ({String work, int number});

const _seasonDigits = '零一二三四五六七八九';
final _seasonAtEnd = RegExp(
  r'(?:第\s*)?([0-9０-９一二两兩三四五六七八九十]+)\s*季$'
  r'|(?:[\s:：_–—-]+|(?<=[\u3400-\u9fff]))(?:season\s*|s)([0-9０-９]+)$',
  caseSensitive: false,
);

int? _seasonNumber(String value) {
  final text = value
      .replaceAll('两', '二')
      .replaceAll('兩', '二')
      .replaceAllMapped(
        RegExp(r'[０-９]'),
        (match) => String.fromCharCode(match[0]!.codeUnitAt(0) - 0xfee0),
      );
  final digits = int.tryParse(text);
  if (digits != null) return digits >= 1 && digits <= 99 ? digits : null;
  if (text.length == 1 && _seasonDigits.contains(text)) {
    return _seasonDigits.indexOf(text);
  }
  final tens = RegExp(r'^([一二三四五六七八九]?)十([一二三四五六七八九]?)$').firstMatch(text);
  if (tens == null) return null;
  final high = tens[1]!.isEmpty ? 1 : _seasonDigits.indexOf(tens[1]!);
  final low = tens[2]!.isEmpty ? 0 : _seasonDigits.indexOf(tens[2]!);
  return high * 10 + low;
}

String cinemaChineseSeasonNumber(int number) {
  if (number < 10) return _seasonDigits[number];
  return '${number < 20 ? '' : _seasonDigits[number ~/ 10]}十'
      '${number % 10 == 0 ? '' : _seasonDigits[number % 10]}';
}

/// Only an explicit season label changes identity. Bare sequel numbers and
/// the name of an unsplit series remain distinct.
CinemaSeasonName? cinemaSeasonName(String value) {
  final name = cinemaMediaBaseTitle(value);
  final match = _seasonAtEnd.firstMatch(name);
  if (match == null) return null;
  final number = _seasonNumber(match[1] ?? match[2]!);
  final work = name
      .substring(0, match.start)
      .replaceFirst(RegExp(r'[\s:：_–—-]+$'), '')
      .trim();
  return number == null || work.isEmpty ? null : (work: work, number: number);
}

String cinemaSeasonTitleKey(String value) {
  final name = cinemaMediaBaseTitle(value);
  final season = cinemaSeasonName(name);
  final canonical = season == null
      ? name.replaceAllMapped(RegExp(r'第\s*([0-9０-９一二两兩三四五六七八九十]+)\s*季'), (
          match,
        ) {
          final number = _seasonNumber(match[1]!);
          return number == null ? match[0]! : '第$number季';
        })
      : '${season.work}第${season.number}季';
  return canonical.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

bool cinemaMatchesSeason(String title, CinemaSeasonName query) {
  final season = cinemaSeasonName(title);
  if (season == null || season.number != query.number) return false;
  String key(String work) => work.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  return key(season.work).contains(key(query.work));
}

/// A source's 4K/2160p/UHD label is a catalogue signal, not a media probe.
bool cinemaIs4KLabel(String value) => RegExp(
  r'(?:^|[^a-z0-9])(?:4\s*k|2160p|uhd)(?=$|[^a-z0-9\u3400-\u9fff]|电影|電影|剧|劇|专区|專區|资源|資源)|超高清',
  caseSensitive: false,
).hasMatch(value);

String cinemaMediaTitleKey(String title) => cinemaMediaBaseTitle(title)
    .replaceAll(RegExp(r'[（(](?:19|20)\d{2}[）)]'), '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

String cinemaMediaDub(String title) {
  if (RegExp(r'普通话|普通話|国语|國語|中文配音|国配|國配|台配').hasMatch(title)) {
    return 'mandarin';
  }
  if (RegExp(r'粤语|粵語|港配').hasMatch(title)) return 'cantonese';
  return '';
}

bool cinemaExplicitSubtitleEpisode(String value) => RegExp(
  r'(?:^|[^a-z0-9])S\d{1,2}[ ._-]*E\d{1,4}(?!\d)|第\s*[零一二两三四五六七八九十百\d]+\s*[集话話]',
  caseSensitive: false,
).hasMatch(value);
