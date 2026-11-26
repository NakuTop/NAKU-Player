import 'cinema_models.dart';

bool cinemaVarietyCategory(String name) => RegExp(
  r'综艺|綜藝|真人秀|脱口秀|脫口秀|^variety(?: shows?)?$',
  caseSensitive: false,
).hasMatch(name.trim());

final _shortDrama = RegExp(
  r'(?:微短[剧劇]|短[剧劇]|(?:ai|a\.i\.)\s*(?:动态|動態)?漫[剧劇]|^漫[剧劇]$)',
  caseSensitive: false,
);

// Some feeds omit type_pid on individual items. Only unambiguous short-drama
// labels are used as a fallback; broad genres such as 都市 and 古装 need ancestry.
bool cinemaShortDramaLabel(String value) => value
    .split(RegExp(r'[,，、|/;；]'))
    .map((s) => s.trim())
    .any(
      (s) =>
          _shortDrama.hasMatch(s) ||
          const {
            '闪婚离婚',
            '閃婚離婚',
            '反转爽文',
            '反轉爽文',
            '反转爽剧',
            '反轉爽劇',
            '女恋总裁',
            '女戀總裁',
            '擦边短',
            '擦邊短',
          }.contains(s),
    );

final _aiDrama = RegExp(
  r'(?:人工智[能慧]|a[ ._-]?i(?:gc)?)[ .·_-]*(?:生成|制作|製作|动态|動態|动画|動畫|动画微|動畫微)?[ .·_-]*(?:微?短[剧劇]|漫[剧劇])|(?:微?短[剧劇]|漫[剧劇])\s*[(（\[【·/:_-]?\s*(?:AI(?:GC)?|人工智[能慧])(?:生成|制作|製作)?',
  caseSensitive: false,
);

bool cinemaAiDramaLabel(String value) => _aiDrama.hasMatch(value);

Set<String> cinemaShortDramaIds(
  List<CinemaCategory> categories, {
  bool onlyAi = false,
}) {
  final hidden = <String>{
    for (final c in categories)
      if (onlyAi ? cinemaAiDramaLabel(c.name) : cinemaShortDramaLabel(c.name))
        c.id,
  };
  // Some feeds expose AI制作 as a parent. Hide it only when every child is
  // already classified; a separate full-length AI movie category stays visible.
  final aiShelves = categories.where(
    (c) => const {'AI制作', 'AI製作', 'AI生成'}.contains(c.name.trim().toUpperCase()),
  );
  var size = -1;
  while (size != hidden.length) {
    size = hidden.length;
    for (final c in categories) {
      if (hidden.contains(c.parentId)) hidden.add(c.id);
    }
    for (final shelf in aiShelves) {
      final children = categories.where((c) => c.parentId == shelf.id);
      if (children.isNotEmpty && children.every((c) => hidden.contains(c.id))) {
        hidden.add(shelf.id);
      }
    }
  }
  return hidden;
}

bool cinemaIsAiDrama(CinemaTitle title, Set<String> hidden) =>
    hidden.contains(title.categoryId) ||
    cinemaAiDramaLabel(title.category) ||
    cinemaAiDramaLabel(title.genres);

bool cinemaIsShortDrama(CinemaTitle title, Set<String> hidden) =>
    hidden.contains(title.categoryId) ||
    cinemaShortDramaLabel(title.category) ||
    cinemaShortDramaLabel(title.genres);
