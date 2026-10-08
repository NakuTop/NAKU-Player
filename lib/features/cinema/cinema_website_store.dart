import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class CinemaWebsite {
  const CinemaWebsite({
    required this.id,
    required this.name,
    required this.url,
    this.category = '影视',
  });

  final String id;
  final String name;
  final String url;
  final String category;

  void validate() {
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw const FormatException('站点 ID 和名称不能为空');
    }
    final uri = Uri.tryParse(url);
    if (url != url.trim() ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('站点地址必须是完整的 HTTP 或 HTTPS URL，且不能包含账号密码');
    }
    if (category.trim().isEmpty) {
      throw const FormatException('站点分类不能为空');
    }
  }

  CinemaWebsite copyWith({
    String? id,
    String? name,
    String? url,
    String? category,
  }) => CinemaWebsite(
    id: id ?? this.id,
    name: name ?? this.name,
    url: url ?? this.url,
    category: category ?? this.category,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'category': category,
  };

  factory CinemaWebsite.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        json['name'] is! String ||
        json['url'] is! String ||
        (json.containsKey('category') && json['category'] is! String) ||
        json.keys.any(
          (key) => !{'id', 'name', 'url', 'category'}.contains(key),
        )) {
      throw const FormatException('站点资料格式无效');
    }
    final website = CinemaWebsite(
      id: json['id'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      category: json['category'] as String? ?? '影视',
    );
    website.validate();
    return website;
  }
}

/// The nine original URLs from Joyflix/Home/HLHomeViewController.m's
/// getBuiltInSitesInfo, followed by the user's website. This list is a set of
/// bookmarks, not an assertion that the websites are reachable or playable.
const List<CinemaWebsite> bundledCinemaWebsites = [
  CinemaWebsite(
    id: 'joyflix-kkys',
    name: '可可影视',
    url: 'https://www.kkys20.com/',
  ),
  CinemaWebsite(id: 'joyflix-beimi', name: '北觅影视', url: 'https://v.luttt.com/'),
  CinemaWebsite(
    id: 'joyflix-skura',
    name: 'skura动漫',
    url: 'https://skr.skr2.cc:666/',
    category: '动漫',
  ),
  CinemaWebsite(
    id: 'joyflix-omofun',
    name: 'omofun动漫',
    url: 'https://omofun.in/',
    category: '动漫',
  ),
  CinemaWebsite(id: 'joyflix-gaze', name: 'GAZE', url: 'https://gaze.red/'),
  CinemaWebsite(id: 'joyflix-adys', name: '爱迪影视', url: 'https://adys.tv/'),
  CinemaWebsite(
    id: 'joyflix-gying',
    name: 'GYING',
    url: 'https://www.gying.si',
  ),
  CinemaWebsite(
    id: 'joyflix-cctv',
    name: 'CCTV',
    url: 'https://tv.cctv.com/live/',
    category: '直播',
  ),
  CinemaWebsite(
    id: 'joyflix-live',
    name: '直播',
    url: 'https://live.wxhbts.com/',
    category: '直播',
  ),
  CinemaWebsite(
    id: 'user-interstellar',
    name: '星际穿越',
    url: 'https://www.xn--kivn76b41nnhi.com/',
  ),
];

/// Owns only website bookmarks and launch preferences. Movie sources,
/// favourites and playback history remain in their separate existing store.
class CinemaWebsiteStore extends ChangeNotifier {
  CinemaWebsiteStore({File? file, List<CinemaWebsite>? defaults})
    : _file = file,
      _defaults = List.unmodifiable(defaults ?? bundledCinemaWebsites);

  File? _file;
  final List<CinemaWebsite> _defaults;
  List<CinemaWebsite> _sites = [];
  String? _lastSiteId;
  bool _restoreLastSite = false;
  bool _loaded = false;
  bool _disposed = false;
  String? _lastError;
  Future<void>? _loading;
  Future<void> _mutations = Future.value();

  bool get loaded => _loaded;
  String? get lastError => _lastError;
  List<CinemaWebsite> get sites => List.unmodifiable(_sites);
  String? get lastSiteId => _lastSiteId;
  bool get restoreLastSite => _restoreLastSite;

  Future<void> load() {
    _ensureActive();
    if (_loaded) return Future.value();
    return _loading ??= _read().whenComplete(() => _loading = null);
  }

  Future<void> _read() async {
    try {
      _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/websites-v1.json',
      );
      final file = _file!;
      final _WebsiteState state;
      if (await file.exists()) {
        state = _WebsiteState.fromJson(jsonDecode(await file.readAsString()));
      } else {
        state = _WebsiteState(sites: List.of(_defaults));
        state.validate();
      }
      _apply(state);
      _loaded = true;
      _lastError = null;
      _notify();
    } catch (error) {
      _lastError = '网页影院资料读取失败，原文件已保留：$error';
      _notify();
      rethrow;
    }
  }

  Future<void> saveSite(CinemaWebsite website) async {
    website.validate();
    await _mutate((state) {
      final index = state.sites.indexWhere((site) => site.id == website.id);
      if (index < 0) {
        state.sites.add(website);
      } else {
        state.sites[index] = website;
      }
    });
  }

  Future<void> removeSite(String id) => _mutate((state) {
    state.sites.removeWhere((site) => site.id == id);
    if (state.lastSiteId == id) state.lastSiteId = null;
  });

  Future<void> recordLastSite(String id) => _mutate((state) {
    if (!state.sites.any((site) => site.id == id)) {
      throw ArgumentError.value(id, 'id', '站点不存在');
    }
    state.lastSiteId = id;
  });

  Future<void> setRestoreLastSite(bool value) => _mutate((state) {
    state.restoreLastSite = value;
  });

  Future<void> _mutate(void Function(_WebsiteState) mutation) async {
    _ensureActive();
    await load();
    // Serialize the mutation as well as the write. State becomes visible only
    // after its complete snapshot has replaced the old file successfully.
    final next = _mutations.catchError((Object _) {}).then((_) async {
      final state = _WebsiteState(
        sites: List.of(_sites),
        lastSiteId: _lastSiteId,
        restoreLastSite: _restoreLastSite,
      );
      mutation(state);
      state.validate();
      try {
        final file = _file!;
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          const JsonEncoder.withIndent('  ').convert(state.toJson()),
          flush: true,
        );
        await temporary.rename(file.path);
        _apply(state);
        _lastError = null;
        _notify();
      } catch (error) {
        _lastError = '网页影院资料保存失败：$error';
        _notify();
        rethrow;
      }
    });
    _mutations = next;
    await next;
  }

  Future<void> flush() => _mutations;

  void _apply(_WebsiteState state) {
    _sites = List.of(state.sites);
    _lastSiteId = state.lastSiteId;
    _restoreLastSite = state.restoreLastSite;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('CinemaWebsiteStore 已关闭');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

class _WebsiteState {
  _WebsiteState({
    required this.sites,
    this.lastSiteId,
    this.restoreLastSite = false,
  });

  final List<CinemaWebsite> sites;
  String? lastSiteId;
  bool restoreLastSite;

  void validate() {
    final seen = <String>{};
    for (final site in sites) {
      site.validate();
      if (!seen.add(site.id)) throw const FormatException('网页影院资料含有重复站点 ID');
    }
    if (lastSiteId != null && !seen.contains(lastSiteId)) {
      throw const FormatException('上次访问的站点不在站点库中');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'sites': sites.map((site) => site.toJson()).toList(),
    'lastSiteId': lastSiteId,
    'restoreLastSite': restoreLastSite,
  };

  factory _WebsiteState.fromJson(Object? json) {
    const keys = {'version', 'sites', 'lastSiteId', 'restoreLastSite'};
    if (json is! Map ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['sites'] is! List ||
        !json.containsKey('lastSiteId') ||
        (json['lastSiteId'] != null && json['lastSiteId'] is! String) ||
        json['restoreLastSite'] is! bool ||
        json.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('网页影院资料格式或版本无法识别');
    }
    final sites = <CinemaWebsite>[];
    for (final item in json['sites'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('网页影院站点条目不是 JSON 对象');
      }
      sites.add(CinemaWebsite.fromJson(item));
    }
    final state = _WebsiteState(
      sites: sites,
      lastSiteId: json['lastSiteId'] as String?,
      restoreLastSite: json['restoreLastSite'] as bool,
    );
    state.validate();
    return state;
  }
}
