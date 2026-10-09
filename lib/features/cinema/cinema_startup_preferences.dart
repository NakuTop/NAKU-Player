import 'package:kazumi/services/storage/storage.dart';

enum CinemaStartupSection {
  movies,
  series,
  anime,
  douban,
  favorites,
  history,
  settings,
}

/// Indices match the complete anime host's visible tabs, not legacy route order.
enum CinemaAnimeStartupTab { popular, timeline, search, collect, more }

class CinemaStartupTarget {
  const CinemaStartupTarget({
    this.section = CinemaStartupSection.movies,
    this.animeTab = CinemaAnimeStartupTab.popular,
  });

  final CinemaStartupSection section;
  final CinemaAnimeStartupTab animeTab;

  /// Keep preferences navigable by legacy callers until they reach the NAKU shell.
  String get location => Uri(
    path: '/cinema',
    queryParameters: {
      'section': section.name,
      if (section == CinemaStartupSection.anime &&
          animeTab != CinemaAnimeStartupTab.popular)
        'animeTab': animeTab.name,
    },
  ).toString();

  factory CinemaStartupTarget.fromStored(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null || uri.hasScheme || uri.hasAuthority) {
      return const CinemaStartupTarget();
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final legacyTab = switch (path) {
      '/tab/popular' => CinemaAnimeStartupTab.popular,
      '/tab/timeline' => CinemaAnimeStartupTab.timeline,
      '/tab/collect' => CinemaAnimeStartupTab.collect,
      '/tab/my' => CinemaAnimeStartupTab.more,
      _ => null,
    };
    if (legacyTab != null) {
      return CinemaStartupTarget(
        section: CinemaStartupSection.anime,
        animeTab: legacyTab,
      );
    }
    if (path != '/cinema') return const CinemaStartupTarget();
    final section = CinemaStartupSection.values.firstWhere(
      (candidate) => candidate.name == uri.queryParameters['section'],
      orElse: () => CinemaStartupSection.movies,
    );
    final animeTab = section == CinemaStartupSection.anime
        ? CinemaAnimeStartupTab.values.firstWhere(
            (candidate) => candidate.name == uri.queryParameters['animeTab'],
            orElse: () => CinemaAnimeStartupTab.popular,
          )
        : CinemaAnimeStartupTab.popular;
    return CinemaStartupTarget(section: section, animeTab: animeTab);
  }
}

class CinemaStartupPreferences {
  const CinemaStartupPreferences({this.readValue, this.writeValue});

  final String? Function()? readValue;
  final Future<void> Function(String value)? writeValue;

  // A fresh NAKU install keeps its movie landing page. An explicitly saved old
  // /tab preference is preserved instead of confusing it with Kazumi's default.
  static final _storedKey = SettingKey<String?>(
    SettingsKeys.defaultStartupPage.name,
    null,
    group: SettingGroup.interface,
  );

  static const options = <String, String>{
    '/cinema?section=movies': '电影',
    '/cinema?section=series': '剧集',
    '/cinema?section=anime': '动漫 · 热门',
    '/cinema?section=anime&animeTab=timeline': '动漫 · 时间表',
    '/cinema?section=anime&animeTab=search': '动漫 · 搜索',
    '/cinema?section=anime&animeTab=collect': '动漫 · 追番',
    '/cinema?section=anime&animeTab=more': '动漫 · 更多',
    '/cinema?section=douban': '豆瓣榜单',
    '/cinema?section=favorites': '我的收藏',
    '/cinema?section=history': '继续观看',
    '/cinema?section=settings': '设置',
  };

  CinemaStartupTarget read() => CinemaStartupTarget.fromStored(
    readValue != null ? readValue!() : GStorage.getSetting(_storedKey),
  );

  Future<void> save(CinemaStartupTarget target) => writeValue != null
      ? writeValue!(target.location)
      : GStorage.putSetting(SettingsKeys.defaultStartupPage, target.location);
}
