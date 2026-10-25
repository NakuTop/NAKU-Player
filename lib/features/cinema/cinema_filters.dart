import 'package:flutter/material.dart';
import 'cinema_models.dart';
import 'cinema_theme.dart';

String cinemaSearchKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s·・,，、/：:;；\-_.()（）]'), '');

bool cinemaMatchesKeyword(CinemaTitle title, String keyword) {
  final key = cinemaSearchKey(keyword);
  return key.isEmpty ||
      [
        title.title,
        title.aliases,
        title.actors,
      ].any((v) => cinemaSearchKey(v).contains(key));
}

class CinemaFilters {
  const CinemaFilters({this.year = '', this.region = '', this.genre = ''});
  final String year, region, genre;
  bool get isEmpty => year.isEmpty && region.isEmpty && genre.isEmpty;
  CinemaFilters copyWith({String? year, String? region, String? genre}) =>
      CinemaFilters(
        year: year ?? this.year,
        region: region ?? this.region,
        genre: genre ?? this.genre,
      );
  bool matches(CinemaTitle title) {
    final itemYear = RegExp(r'\d{4}').firstMatch(title.year)?.group(0) ?? '';
    final regionText = title.area
        .replaceAll('中国大陆', '大陆')
        .replaceAll('内地', '大陆')
        .replaceAll('中国香港', '香港')
        .replaceAll('中国台湾', '台湾');
    final genreText = '${title.genres} ${title.category}';
    return (year.isEmpty ||
            (year == '更早'
                ? (int.tryParse(itemYear) ?? 9999) < 2000
                : year == itemYear)) &&
        (region.isEmpty || regionText.contains(region)) &&
        (genre.isEmpty || genreText.contains(genre));
  }
}

/// Local source APIs do not consistently support region/year predicates.
/// Always filter actual metadata and explicitly state the loaded-data scope.
class CinemaFilterBar extends StatelessWidget {
  const CinemaFilterBar({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.scope = '已加载内容',
    this.compact = false,
  });
  final CinemaFilters value;
  final List<CinemaTitle> items;
  final ValueChanged<CinemaFilters> onChanged;
  final String scope;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().year;
    final years = <String>{
      for (int y = now + 1; y >= 2000; y--) '$y',
      ...items.map((t) => t.year).where((s) => RegExp(r'^\d{4}$').hasMatch(s)),
    }.toList()..sort((a, b) => b.compareTo(a));
    final genres = <String>{
      '剧情',
      '喜剧',
      '动作',
      '爱情',
      '科幻',
      '动画',
      '悬疑',
      '惊悚',
      '恐怖',
      '犯罪',
      '冒险',
      '奇幻',
      '战争',
      '纪录',
      '家庭',
      '历史',
      '音乐',
      '运动',
      ...items
          .expand((t) => t.genres.split(RegExp(r'[,，/、\s]+')))
          .where((s) => s.isNotEmpty && s.length <= 6 && !s.contains('擦边')),
    }.toList();
    Widget menu(
      String label,
      String current,
      List<String> choices,
      void Function(String) select,
    ) => Semantics(
      label: '按$label筛选',
      child: SizedBox(
        width: compact ? 112 : 138,
        child: DropdownButtonFormField<String>(
          key: ValueKey('cinema-filter-$label-$current'),
          initialValue: current,
          isExpanded: true,
          icon: Icon(
            Icons.expand_more_rounded,
            size: compact ? 16 : 20,
            color: CinemaTheme.muted,
          ),
          style: compact
              ? Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: CinemaTheme.text,
                  fontSize: 12,
                )
              : null,
          decoration: InputDecoration(
            isDense: true,
            filled: compact ? false : null,
            border: compact ? InputBorder.none : null,
            enabledBorder: compact ? InputBorder.none : null,
            focusedBorder: compact
                ? const UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0x80FFFFFF)),
                  )
                : null,
            contentPadding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 12,
              vertical: compact ? 8 : 10,
            ),
          ),
          items: [
            DropdownMenuItem(value: '', child: Text('全部$label')),
            for (final item in {...choices, if (current.isNotEmpty) current})
              DropdownMenuItem(value: item, child: Text(item)),
          ],
          onChanged: (v) {
            if (v != null) select(v);
          },
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: compact ? 4 : 16, bottom: 6),
      child: Wrap(
        spacing: compact ? 8 : 10,
        runSpacing: compact ? 4 : 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          menu('年份', value.year, [
            ...years,
            '更早',
          ], (v) => onChanged(value.copyWith(year: v))),
          menu('地区', value.region, [
            '大陆',
            '香港',
            '台湾',
            '美国',
            '英国',
            '日本',
            '韩国',
            '法国',
            '德国',
            '意大利',
            '西班牙',
            '印度',
            '泰国',
            '加拿大',
            '澳大利亚',
          ], (v) => onChanged(value.copyWith(region: v))),
          menu(
            '类型',
            value.genre,
            genres,
            (v) => onChanged(value.copyWith(genre: v)),
          ),
          if (!value.isEmpty)
            TextButton(
              onPressed: () => onChanged(const CinemaFilters()),
              child: const Text('重置'),
            ),
          if (!compact)
            Text(
              '$scope · ${items.where(value.matches).length}/${items.length} 部',
              style: const TextStyle(fontSize: 11, color: CinemaTheme.muted),
            ),
        ],
      ),
    );
  }
}
