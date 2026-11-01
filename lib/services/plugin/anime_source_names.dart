/// Normalizes typography for deduplication without removing seasons or sequels.
String animeSourceNameKey(String value) {
  final ascii = String.fromCharCodes(
    value.runes.map((c) => c >= 0xff01 && c <= 0xff5e ? c - 0xfee0 : c),
  );
  return ascii.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
}

List<String> uniqueAnimeSourceNames(Iterable<String> values, {int limit = 6}) {
  final seen = <String>{};
  return values
      .map((v) => v.trim().replaceAll(RegExp(r'\s+'), ' '))
      .where(
        (v) =>
            v.length >= 2 &&
            v.length <= 160 &&
            !v.contains('://') &&
            !v.contains('\n') &&
            seen.add(animeSourceNameKey(v)),
      )
      .take(limit)
      .toList();
}

List<String> animeSourceKeywords({
  required String chineseTitle,
  required String originalTitle,
  Iterable<String> aliases = const [],
}) => uniqueAnimeSourceNames([chineseTitle, originalTitle, ...aliases]);

List<String> mergeAnimeSourceAliases(
  Iterable<String> incoming,
  Iterable<String> local,
) => uniqueAnimeSourceNames([...incoming, ...local], limit: 80);
