import 'cinema_media_identity.dart';

/// A provider's edition label describes a collection. The individual item
/// is more specific: a bonus collection can contain pure cuts and previews.
enum CinemaShowSection {
  main('正片'),
  pure('纯享'),
  extra('加更'),
  special('特辑');

  const CinemaShowSection(this.label);
  final String label;
}

class CinemaShowEpisode {
  CinemaShowEpisode(String raw, {bool bonusCollection = false})
    : text = cinemaIdentityTypography(raw).trim(),
      _bonus = bonusCollection;

  final String text;
  final bool _bonus;
  static final _date = RegExp(
    r'(?<!\d)(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])(?!\d)',
  );
  static final _issue = RegExp(r'第\s*(\d{1,3})\s*期');
  static final _pure = RegExp('纯享版?|純享版?');
  static final _extra = RegExp('加更|加长版|加長版|会员版|會員版');
  static final _special = RegExp(
    '先导|先導|花絮|特辑|特輯|幕后|幕後|回顾|回顧|预告|預告|彩蛋|番外|尝鲜|体验篇',
  );
  static String searchText(String raw) => cinemaIdentityTypography(raw)
      .replaceAllMapped(RegExp(r'第\s*([零〇一二两兩三四五六七八九十\d]+)\s*期'), (m) {
        final n = int.tryParse(m[1]!) ?? cinemaSeasonNumber(m[1]!);
        return n == null ? m[0]! : '第${n}期';
      })
      .replaceAllMapped(
        RegExp(r'((?:19|20)\d{2})[-./年](\d{1,2})[-./月](\d{1,2})日?'),
        (m) => '${m[1]}${m[2]!.padLeft(2, '0')}${m[3]!.padLeft(2, '0')}',
      );
  late final _normalized = searchText(text);
  late final day = _date.stringMatch(_normalized) ?? '';
  late final issue = _issue.firstMatch(_normalized)?[1] ?? '';
  late final section = _pure.hasMatch(text)
      ? CinemaShowSection.pure
      : _extra.hasMatch(text)
      ? CinemaShowSection.extra
      : _special.hasMatch(text)
      ? CinemaShowSection.special
      : _bonus
      ? CinemaShowSection.extra
      : CinemaShowSection.main;

  late final _rest = _normalized
      .replaceFirst(RegExp(r'^第\d+集(?=(?:19|20)\d{6})'), '')
      .replaceFirst(_date, '')
      .replaceFirst(_issue, '')
      .replaceAll(_pure, '')
      .trim();
  late final part =
      RegExp(r'^[第期\s:：·（）()]*([上中下])(?=$|[\s:：·.（）()])')
          .firstMatch(_rest)?[1] ??
      '';
  late final clip = _rest
      .replaceFirst(RegExp(r'^(?:第期|期)'), '')
      .replaceFirst(
        part.isEmpty ? RegExp(r'(?!)') : RegExp('^[\\s:：·（）()]*$part'),
        '',
      )
      .replaceAll(RegExp(r'^[\s:：·.（）()_-]+|[\s:：·.（）()_-]+$'), '')
      .trim();
  String get dateSlot => day.isEmpty ? '' : 'day:$day/$part';
  String get slot => issue.isEmpty ? '' : '$issue/$part';
  bool get namedPure =>
      section == CinemaShowSection.pure &&
      clip.isNotEmpty &&
      (day.isNotEmpty || issue.isNotEmpty);
  bool get plainBroadcast =>
      section == CinemaShowSection.main &&
      clip.isEmpty &&
      (day.isNotEmpty || issue.isNotEmpty);
  String get pureKey => '${day.isEmpty ? '期$issue' : day}/$clip';
  bool sameClip(CinemaShowEpisode other) {
    if (!namedPure || !other.namedPure || clip != other.clip) return false;
    if (part.isNotEmpty && other.part.isNotEmpty && part != other.part)
      return false;
    if (issue.isNotEmpty && other.issue.isNotEmpty && issue != other.issue)
      return false;
    if (day.isNotEmpty && other.day.isNotEmpty) return day == other.day;
    return slot.isNotEmpty && slot == other.slot;
  }
}
