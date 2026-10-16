import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// Public catalogs receive only the query / IMDb ID, never NAS credentials.
class CinemaOnlineSubtitles {
  CinemaOnlineSubtitles({Dio? dio}) : _dio = dio ?? _createDio();
  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'User-Agent': 'NAKUPlayer/2.8.0',
          'Accept': 'application/json',
        },
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = Platform.isMacOS
            ? MacOSSystemProxy.findProxy
            : HttpClient.findProxyFromEnvironment;
        return client;
      },
    );
    return dio;
  }

  final Dio _dio;
  Future<List<Map<String, dynamic>>> _rows(Uri uri, String key) async {
    final data = (await _dio.getUri<dynamic>(uri)).data;
    if (data is! Map || data[key] is! List) {
      throw const FormatException('字幕服务返回无效数据');
    }
    return (data[key] as List)
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  Future<List<Map<String, dynamic>>> search(String query, String type) {
    if (!['movie', 'series'].contains(type)) {
      throw const FormatException('作品类型无效');
    }
    return _rows(
      Uri.parse(
        'https://v3-cinemeta.strem.io/catalog/$type/top/search=${Uri.encodeComponent(query.trim())}.json',
      ),
      'metas',
    );
  }

  Future<List<Map<String, dynamic>>> subtitles(
    String id,
    String type, {
    int season = 1,
    int episode = 1,
  }) async {
    if (!RegExp(r'^tt\d+$').hasMatch(id) ||
        !['movie', 'series'].contains(type) ||
        season < 0 ||
        episode < 1) {
      throw const FormatException('请选择作品及正确的季、集');
    }
    final video = type == 'series' ? '$id:$season:$episode' : id;
    final rows = await _rows(
      Uri.https('opensubtitles-v3.strem.io', '/subtitles/$type/$video.json'),
      'subtitles',
    );
    final seen = <String>{};
    return rows.where((v) {
      final url = Uri.tryParse('${v['url']}');
      return url != null &&
          url.scheme == 'https' &&
          url.host.isNotEmpty &&
          url.userInfo.isEmpty &&
          seen.add(url.toString());
    }).toList();
  }

  Future<String> download(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('字幕链接无效');
    }
    const limit = 8 * 1024 * 1024;
    final cancel = CancelToken();
    final response = await _dio.getUri<List<int>>(
      uri,
      options: Options(responseType: ResponseType.bytes),
      cancelToken: cancel,
      onReceiveProgress: (count, total) {
        if (count > limit || total > limit) cancel.cancel('字幕文件过大');
      },
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty || bytes.length > limit) {
      throw const FormatException('字幕文件无效');
    }
    final text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
    if (!text.contains('-->') && !text.contains('[Events]')) {
      throw const FormatException('未返回可用字幕');
    }
    return text;
  }

  void close() => _dio.close();
}

Future<void> showCinemaOnlineSubtitles(
  BuildContext context,
  Player player, {
  String title = '',
  String imdbId = '',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (ctx) {
    final media = MediaQuery.of(ctx);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: (media.size.height - media.viewInsets.bottom) * .85,
        child: SafeArea(
          child: CinemaOnlineSubtitlesPanel(
            player: player,
            title: title,
            imdbId: imdbId,
          ),
        ),
      ),
    );
  },
);

class CinemaOnlineSubtitlesPanel extends StatefulWidget {
  const CinemaOnlineSubtitlesPanel({
    super.key,
    required this.player,
    this.title = '',
    this.imdbId = '',
    this.client,
  });
  final Player player;
  final String title, imdbId;
  final CinemaOnlineSubtitles? client;
  @override
  State<CinemaOnlineSubtitlesPanel> createState() =>
      _CinemaOnlineSubtitlesPanelState();
}

class _CinemaOnlineSubtitlesPanelState
    extends State<CinemaOnlineSubtitlesPanel> {
  late final _client = widget.client ?? CinemaOnlineSubtitles();
  late final _query = TextEditingController(text: widget.title);
  final _season = TextEditingController(text: '1'),
      _episode = TextEditingController(text: '1');
  String _type = 'movie', _language = 'zh';
  bool _busy = false;
  String? _error, _selected;
  List<Map<String, dynamic>> _works = [], _subtitles = [];
  @override
  void dispose() {
    if (widget.client == null) _client.close();
    _query.dispose();
    _season.dispose();
    _episode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '搜索或加载失败，请重试；也可使用本地字幕或字幕链接。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _search() => _run(() async {
    final query = _query.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入片名或 IMDb ID');
      return;
    }
    final works = RegExp(r'^tt\d+$').hasMatch(query)
        ? <Map<String, dynamic>>[
            {'id': query, 'name': query},
          ]
        : await _client.search(query, _type);
    if (mounted) {
      setState(() {
        _works = works;
        _selected = null;
        _subtitles = [];
        if (works.isEmpty) _error = '未找到作品，可改用英文片名或 IMDb ID。';
      });
    }
  });
  Future<void> _load(String id) => _run(() async {
    final season = int.tryParse(_season.text),
        episode = int.tryParse(_episode.text);
    if (_type == 'series' &&
        (season == null || season < 0 || episode == null || episode < 1)) {
      setState(() => _error = '请输入正确的季、集数');
      return;
    }
    final rows = await _client.subtitles(
      id,
      _type,
      season: season ?? 1,
      episode: episode ?? 1,
    );
    if (mounted) {
      setState(() {
        _selected = id;
        _subtitles = rows;
        if (rows.isEmpty) _error = '该作品暂无在线字幕。';
      });
    }
  });
  bool _matches(Map<String, dynamic> row) {
    final lang = row['lang']?.toString() ?? '';
    return _language == 'all' ||
        (_language == 'zh'
            ? ['chi', 'zho', 'zht', 'zhe', 'zhs', 'zh'].contains(lang)
            : lang == _language);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _subtitles.where(_matches).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('在线搜索字幕', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          '来源：OpenSubtitles / Stremio。搜索片名或 IMDb ID，确认作品后选择字幕。仅发送搜索词和作品编号。',
        ),
        TextField(
          controller: _query,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '片名或 IMDb ID',
            hintText: '可尝试英文片名',
          ),
          onSubmitted: (_) => _search(),
        ),
        if (widget.imdbId.isNotEmpty)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _query.text = widget.imdbId;
                    _search();
                  },
            child: Text('使用本片编号 ${widget.imdbId}'),
          ),
        DropdownButtonFormField<String>(
          initialValue: _type,
          decoration: const InputDecoration(labelText: '作品类型'),
          items: const [
            DropdownMenuItem(value: 'movie', child: Text('电影')),
            DropdownMenuItem(value: 'series', child: Text('剧集 / 动漫')),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  _type = v!;
                  _works = [];
                  _subtitles = [];
                  _selected = null;
                }),
        ),
        if (_type == 'series')
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _season,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '季（特别篇为 0）'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _episode,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '集'),
                ),
              ),
            ],
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _search,
          icon: const Icon(Icons.search),
          label: const Text('搜索作品'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        for (final work in _works.take(20))
          ListTile(
            title: Text('${work['name']}'),
            subtitle: Text('${work['releaseInfo'] ?? ''} · ${work['id']}'),
            selected: work['id'] == _selected,
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () => _load('${work['id']}'),
          ),
        const Divider(),
        DropdownButtonFormField<String>(
          initialValue: _language,
          decoration: const InputDecoration(labelText: '字幕语言'),
          items: const [
            DropdownMenuItem(value: 'zh', child: Text('中文（简体 / 繁体）')),
            DropdownMenuItem(value: 'eng', child: Text('English')),
            DropdownMenuItem(value: 'jpn', child: Text('日语')),
            DropdownMenuItem(value: 'all', child: Text('全部语言')),
          ],
          onChanged: (v) => setState(() => _language = v!),
        ),
        if (_selected != null && rows.isEmpty && !_busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('当前语言没有结果，可切换全部语言。'),
          ),
        for (final row in rows)
          ListTile(
            leading: const Icon(Icons.subtitles_outlined),
            title: Text(
              '${row['subtitleFileName'] ?? row['movieReleaseName'] ?? '字幕 ${row['id']}'}',
            ),
            subtitle: Text('${row['lang']} · ${row['releaseFormat'] ?? ''}'),
            trailing: const Icon(Icons.download_done),
            onTap: _busy
                ? null
                : () => _run(() async {
                    final text = await _client.download('${row['url']}');
                    if (!mounted) return;
                    await widget.player.setSubtitleTrack(
                      SubtitleTrack.data(
                        text,
                        title: '${row['subtitleFileName'] ?? '在线字幕'}',
                        language: '${row['lang']}',
                      ),
                    );
                    if (context.mounted) Navigator.pop(context);
                  }),
          ),
      ],
    );
  }
}
