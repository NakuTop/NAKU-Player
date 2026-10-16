import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'cinema_nas_media.dart';
import 'cinema_nas_sync.dart';
import 'cinema_watch_together.dart';
import 'cinema_models.dart';
import 'cinema_douban_details.dart';
import 'cinema_store.dart';
import 'cinema_player_page.dart';
import 'cinema_download_sheet.dart';

import 'cinema_theme.dart';

export 'cinema_nas_media.dart' show CinemaNASClient, nasInt, nasRows, nasFiles;

/// Classify explicit private/local hosts; an arbitrary UGlink alias is remote.
bool isNASLANAddress(String address) {
  final raw = address.trim();
  final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
  final host = uri?.host.toLowerCase() ?? '';
  if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
    return true;
  }
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length == 4 &&
      parts.every((v) => v != null && v >= 0 && v <= 255)) {
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31) ||
        (parts[0] == 192 && parts[1] == 168) ||
        parts[0] == 127;
  }
  return raw.contains('://') && host.isNotEmpty && !host.contains('.');
}

class CinemaNASPage extends StatefulWidget {
  const CinemaNASPage({
    super.key,
    this.client,
    this.store,
    this.sync,
    this.onRecommendationSelected,
    this.onSyncSettings,
  });
  final ValueChanged<DoubanRecommendation>? onRecommendationSelected;
  final VoidCallback? onSyncSettings;
  final CinemaStore? store;
  final CinemaNASSync? sync;
  final CinemaNASClient? client;
  @override
  State<CinemaNASPage> createState() => _CinemaNASPageState();
}

class _CinemaNASPageState extends State<CinemaNASPage> {
  late final _client = widget.client ?? CinemaNASClient();
  late final _store = widget.store ?? CinemaStore();
  final _address = TextEditingController();
  String _mode = 'remote';
  String _lanAddress = '', _remoteAddress = '';
  List<String> _lanCandidates = [];
  final _username = TextEditingController(),
      _password = TextEditingController();
  final _search = TextEditingController();
  List<Map<String, dynamic>> _libraries = [], _items = [];
  bool _loggedIn = false,
      _busy = false,
      _last = true,
      _remember = true,
      _hasSaved = false;
  String? _error;
  String _name = '我的 NAS';
  final _collectionCache = <String, Map<String, dynamic>>{};
  final _collectionPending = <String>{};
  final _collectionFailed = <String>{};
  int _countWorkers = 0;

  String _collectionKey(Map<String, dynamic> row) =>
      '${_client.namespace}|${nasInt(row['media_lib_set_id'])}|${row['collection_id']}';

  String _collectionLabel(Map<String, dynamic> row) {
    final data = _collectionCache[_collectionKey(row)];
    if (data == null) return '合集';
    final entries = nasRows(data['video_arr']);
    final total = nasInt(data['total_num']);
    if (total > entries.length) return '$total项资源';
    if (entries.isEmpty) return '0项资源';
    if (entries.every((e) => nasInt(e['type']) == 1)) {
      return '${entries.length}部电影';
    }
    if (entries.every((e) => nasInt(e['type']) == 2)) {
      return '${entries.length}季';
    }
    return '${entries.length}项资源';
  }

  // Resolve a few cards at a time without holding up catalog interaction.
  void _resolveCollectionCounts() {
    if (!mounted || !_loggedIn) return;
    while (_countWorkers < 3) {
      final candidates = _items.where((row) {
        final key = _collectionKey(row);
        return nasInt(row['type']) == 3 &&
            '${row['collection_id'] ?? ''}'.isNotEmpty &&
            !_collectionCache.containsKey(key) &&
            !_collectionPending.contains(key) &&
            !_collectionFailed.contains(key);
      });
      if (candidates.isEmpty) return;
      final row = candidates.first;
      final key = _collectionKey(row);
      final generation = _generation;
      _collectionPending.add(key);
      _countWorkers++;
      unawaited(() async {
        try {
          final data = await _client.call('collection', {
            'id': '${row['collection_id']}',
            'library': nasInt(row['media_lib_set_id']),
          });
          if (mounted &&
              _loggedIn &&
              generation == _generation &&
              key == _collectionKey(row)) {
            setState(() => _collectionCache[key] = data);
          }
        } catch (_) {
          if (mounted && generation == _generation) _collectionFailed.add(key);
        } finally {
          _collectionPending.remove(key);
          _countWorkers--;
          _resolveCollectionCounts();
        }
      }());
    }
  }

  int _library = 0, _page = 1, _generation = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  void _rememberAddress() {
    if (isNASLANAddress(_address.text.trim())) {
      _lanAddress = _address.text.trim();
    } else {
      _remoteAddress = _address.text.trim();
    }
  }

  Future<void> _saveConnections() async {
    _rememberAddress();
    if (widget.store == null) return;
    try {
      await widget.store!.setExtra('nasConnections', {
        'lanAddress': _lanAddress,
        'remoteAddress': _remoteAddress,
        'mode': _mode,
      });
    } catch (_) {
      /* Address preferences must not fail an authenticated session. */
    }
  }

  Future<void> _readConnectionInfo() async {
    try {
      final info = await _client.call('connectionInfo');
      if (!mounted) return;
      _rememberAddress();
      setState(() {
        _lanCandidates = (info['lanCandidates'] is List
            ? (info['lanCandidates'] as List)
                  .whereType<String>()
                  .where(isNASLANAddress)
                  .toSet()
                  .toList()
            : <String>[]);
        if (_lanAddress.isEmpty && _lanCandidates.isNotEmpty) {
          _lanAddress = _lanCandidates.first;
        }
        final remote = info['remoteAddress'];
        if (remote is String && remote.isNotEmpty && _remoteAddress.isEmpty) {
          _remoteAddress = remote;
        }
        final current = info['currentAddress'];
        if (current is String && current.isNotEmpty) {
          _mode = isNASLANAddress(current) ? 'lan' : 'remote';
          _address.text = current;
        }
      });
      await _saveConnections();
    } catch (_) {
      /* Older native builds may not supply connection discovery. */
    }
  }

  Future<void> _changeConnection() async {
    widget.sync?.pause();
    _generation++;
    setState(() => _busy = true);
    try {
      await _saveConnections();
      await CinemaWatchTogether.instance.pauseNASPairing();
      await _client.logout();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(error);
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _loggedIn = false;
      _password.clear();
      _items = [];
      _libraries = [];
      _collectionCache.clear();
      _collectionFailed.clear();
      _error = null;
    });
  }

  Future<void> _restore() async {
    if (!Platform.isMacOS && widget.client == null) return;
    setState(() => _busy = true);
    try {
      if (widget.store != null) {
        await widget.store!.load();
        final prefs = widget.store!.extras['nasConnections'];
        if (prefs is Map) {
          _lanAddress = prefs['lanAddress'] is String
              ? prefs['lanAddress']
              : '';
          _remoteAddress = prefs['remoteAddress'] is String
              ? prefs['remoteAddress']
              : _remoteAddress;
          _mode = prefs['mode'] == 'lan' ? 'lan' : 'remote';
          _address.text = _mode == 'lan' ? _lanAddress : _remoteAddress;
        }
      }
      final saved = await _client.call('savedLogin');
      if (!mounted) return;
      if (saved.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      _hasSaved = true;
      final savedAddress = saved['address']?.toString() ?? _address.text;
      _mode = isNASLANAddress(savedAddress) ? 'lan' : 'remote';
      _address.text = savedAddress;
      _rememberAddress();
      _username.text = saved['username']?.toString() ?? '';
      setState(() => _busy = false);
      await _login(restoring: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    for (final c in [_address, _username, _password, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? 'NAS 请求失败，请重试。'
      : 'NAS 请求失败，请检查连接后重试。';

  Future<void> _login({bool restoring = false}) async {
    if (_busy) return;
    if (!Platform.isMacOS && widget.client == null) {
      setState(() => _error = 'NAS 影视中心当前支持 macOS 版。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _saveConnections();
      final expected = _client.namespace.isNotEmpty
          ? _client.namespace
          : widget.sync?.account;
      final reuse =
          !restoring &&
          _hasSaved &&
          _password.text.isEmpty &&
          expected != null &&
          expected.isNotEmpty;
      final info = restoring
          ? await _client.call('restore')
          : reuse
          ? await _client.call('restoreAt', {
              'address': _address.text.trim(),
              'namespace': expected,
              'remember': _remember,
            })
          : await _client.call('login', {
              'address': _address.text.trim(),
              'username': _username.text.trim(),
              'password': _password.text,
              'remember': _remember,
            });
      if (!mounted) {
        await CinemaWatchTogether.instance.pauseNASPairing();
        await _client.logout();
        return;
      }
      _password.clear();
      if (info['namespace'] is String) {
        _client.namespace = info['namespace'] as String;
      }
      try {
        await _client.call('autoConnect', {'namespace': _client.namespace});
      } catch (_) {
        // Keep the verified login usable if discovery/probing is unavailable.
      }
      final libraries = await _client.call('libraries');
      if (!mounted) return;
      setState(() {
        _hasSaved = restoring || _remember;
        if (info['namespace'] is String) {
          _client.namespace = info['namespace'] as String;
        }
        _name = info['name']?.toString() ?? '我的 NAS';
        _libraries = nasRows(
          libraries['media_lib_set_arr'],
        ).where((e) => e['can_view'] != false).toList();
        _loggedIn = true;
      });
    } catch (error) {
      if (mounted) _password.clear();
      await CinemaWatchTogether.instance.pauseNASPairing();
      await _client.logout();
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_loggedIn && mounted) {
      await _readConnectionInfo();
      await _saveConnections();
      await widget.sync?.bind(_client.namespace);
      await CinemaWatchTogether.instance.resumeNASPairing(_client.namespace);
      await _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    final generation = ++_generation;
    if (!more) {
      _collectionCache.clear();
      _collectionFailed.clear();
    }
    final page = more ? _page + 1 : 1;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _client.call('catalog', {
        'page': page,
        'library': _library,
        'keyword': _search.text.trim(),
      });
      final rows = nasRows(data['video_arr']);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = more ? [..._items, ...rows] : rows;
        _page = page;
        _total = nasInt(data['total_num']);
        _last = data['is_last_page'] is bool
            ? data['is_last_page'] as bool
            : rows.length < 40;
      });
      _resolveCollectionCounts();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _details(Map<String, dynamic> row) async {
    if (_busy) return;
    if (nasInt(row['type']) == 3) {
      await _collection(row);
      return;
    }
    Map<String, dynamic>? selectedSeason;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await _client.call('details', {
        'id': nasInt(row['ug_video_info_id']),
        'library': nasInt(row['media_lib_set_id']),
        'tv': nasInt(row['type']) == 2,
      });
      if (!mounted) return;
      final files = nasFiles(detail);
      final title = _title(row, files, detail: detail);
      final info = detail['video_info'] is Map
          ? Map<String, dynamic>.from(detail['video_info'])
          : row;
      setState(() => _busy = false);
      selectedSeason = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            info['name']?.toString() ?? row['name']?.toString() ?? '影片详情',
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${info['year'] ?? row['year'] ?? ''}  ·  NAS 影视中心',
                    style: const TextStyle(color: CinemaTheme.copper),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    info['introduction']?.toString() ??
                        row['introduction']?.toString() ??
                        '',
                  ),
                  const SizedBox(height: 24),
                  if (nasRows(detail['season_info']).length > 1)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final season in nasRows(detail['season_info']))
                          OutlinedButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, season),
                            child: Text('第 ${season['season_num']} 季'),
                          ),
                      ],
                    ),
                  if (files.isEmpty) const Text('NAS 尚未返回可播放文件。请在影视中心检查此影片。'),
                  for (final file in files)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.play_circle_outline),
                      title: Text(file.label),
                      trailing: IconButton(
                        tooltip: '下载到 Naku',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          await _download(title, files.indexOf(file));
                        },
                      ),
                      subtitle: Text(
                        file.path.split('/').last,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _play(title, files.indexOf(file));
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && selectedSeason != null) {
      await _details({
        ...row,
        'ug_video_info_id': selectedSeason['ug_video_info_id'],
      });
    }
  }

  Future<void> _collection(Map<String, dynamic> row) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    Map<String, dynamic>? selected;
    try {
      final data =
          _collectionCache[_collectionKey(row)] ??
          await _client.call('collection', {
            'id': '${row['collection_id'] ?? ''}',
            'library': nasInt(row['media_lib_set_id']),
          });
      if (!mounted) return;
      final entries = nasRows(data['video_arr']);
      setState(() => _busy = false);
      selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(row['name']?.toString() ?? '影视合集'),
          content: SizedBox(
            width: 600,
            child: entries.isEmpty
                ? const Text('此合集暂无可播放内容。')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in entries)
                        ListTile(
                          title: Text(item['name']?.toString() ?? '未命名'),
                          subtitle: Text(
                            nasInt(item['type']) == 2 ? '剧集 · 选择分集' : '电影',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.pop(ctx, item),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && selected != null) await _details(selected);
  }

  Future<void> _qrLogin() async {
    if (_busy) return;
    setState(() {
      _busy = false;
      _error = null;
    });
    try {
      final info = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _NASQRDialog(
          client: _client,
          address: _address.text.trim(),
          remember: _remember,
        ),
      );
      if (!mounted || info == null) return;
      final libraries = await _client.call('libraries');
      if (!mounted) return;
      setState(() {
        _client.namespace = info['namespace']?.toString() ?? '';
        _username.text = info['username']?.toString() ?? '';
        _name = info['name']?.toString() ?? '我的 NAS';
        _libraries = nasRows(
          libraries['media_lib_set_arr'],
        ).where((e) => e['can_view'] != false).toList();
        _loggedIn = true;
        _hasSaved = _remember;
        _password.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _loggedIn) {
      await _readConnectionInfo();
      await _saveConnections();
      await widget.sync?.bind(_client.namespace);
      await CinemaWatchTogether.instance.resumeNASPairing(_client.namespace);
      await _load();
    }
  }

  CinemaTitle _title(
    Map<String, dynamic> row,
    List<({String label, String path})> files, {
    Map<String, dynamic>? detail,
  }) => createCinemaNASTitle(
    namespace: _client.namespace,
    row: row,
    files: files,
    detail: detail,
  );

  Future<void> _play(CinemaTitle title, int episode) async {
    try {
      await _store.load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CinemaPlayerPage(
            title: title,
            source: cinemaNASSource,
            store: _store,
            routeIndex: title.category == '电视剧' ? 0 : episode,
            episodeIndex: title.category == '电视剧' ? episode : 0,
            autoSelectBestRoute: false,
            onRecommendationSelected: widget.onRecommendationSelected,
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _download(CinemaTitle title, int episode) async {
    try {
      await showCinemaDownloadSheet(
        context,
        title: title,
        source: cinemaNASSource,
        routeIndex: title.category == '电视剧' ? 0 : episode,
        episodeIndex: title.category == '电视剧' ? episode : 0,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '无法创建下载任务，请检查下载目录与空间。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CinemaTheme.background,
    appBar: AppBar(
      title: Text(_loggedIn ? '$_name · 影视中心' : 'NAS 影视中心'),
      actions: [
        if (_loggedIn)
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        if (_loggedIn)
          TextButton(
            onPressed: _busy ? null : _changeConnection,
            child: const Text('连接设置'),
          ),
        if (_loggedIn || _hasSaved)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    widget.sync?.pause();
                    _generation++;
                    _collectionCache.clear();
                    _collectionFailed.clear();
                    await CinemaWatchTogether.instance.pauseNASPairing();
                    await _client.call('forget');
                    if (mounted) {
                      setState(() {
                        _loggedIn = false;
                        _hasSaved = false;
                        _username.clear();
                        _items = [];
                        _libraries = [];
                        _search.clear();
                        _library = 0;
                        _error = null;
                      });
                    }
                  },
            child: const Text('退出并忘记账号'),
          ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: () => setState(() => _error = null),
                child: const Text('关闭'),
              ),
            ],
          ),
        Expanded(child: _loggedIn ? _catalog() : _loginForm()),
      ],
    ),
  );

  Widget _loginForm() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.dns_outlined,
                size: 42,
                color: CinemaTheme.copper,
              ),
              const SizedBox(height: 24),
              const Text(
                '你的私人影院',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '直接浏览绿联影视中心已有的海报、影片和剧集。无需重新整理或刮削。',
                style: TextStyle(color: CinemaTheme.muted, height: 1.6),
              ),
              const SizedBox(height: 32),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.swap_horiz_rounded),
                title: Text('自动选择连接'),
                subtitle: Text('同一局域网优先直连，在外自动使用 UGlink，无需手动切换。'),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _address,
                enabled: !_busy,
                onChanged: (_) => _rememberAddress(),
                decoration: InputDecoration(
                  labelText: 'NAS 地址或 UGlink 别名',
                  hintText: 'UGlink 别名、远程地址或局域网地址',
                ),
              ),
              if (_mode == 'lan' && _lanCandidates.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final candidate in _lanCandidates)
                      ActionChip(
                        label: Text(candidate),
                        onPressed: _busy
                            ? null
                            : () {
                                setState(() => _address.text = candidate);
                                unawaited(_saveConnections());
                              },
                      ),
                  ],
                ),
              if (_hasSaved)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    '可留空密码，使用本机已保存的登录信息验证同一 NAS 账号。',
                    style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 20),
              TextField(
                controller: _username,
                enabled: !_busy,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'NAS 账号'),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'NAS 密码'),
                onSubmitted: (_) => _login(),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('记住账号并自动登录'),
                value: _remember,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _remember = value ?? false),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : () => _login(),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('连接影视中心'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _qrLogin,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('使用绿联云 App 扫码登录'),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '勾选后，账号密码仅存于本机 macOS 钥匙串，下次打开自动连接。',
                style: TextStyle(fontSize: 12, color: CinemaTheme.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _syncPanel() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: TextButton.icon(
      onPressed: widget.onSyncSettings,
      icon: const Icon(Icons.manage_accounts_outlined, size: 18),
      label: const Text('账号与统一同步设置'),
    ),
  );

  Widget _catalog() => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('家中的收藏', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 8),
              Text(
                '自动连接 · ${_mode == 'lan' ? '局域网直连' : '远程 UGlink'} · ${_address.text}',
                style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                _total > 0 ? '影视中心 · $_total 部资源' : '影视中心已有资源',
                style: const TextStyle(color: CinemaTheme.muted),
              ),
              if (widget.sync != null) _syncPanel(),
              const SizedBox(height: 24),
              TextField(
                controller: _search,
                enabled: !_busy,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  hintText: '搜索全部 NAS 影视资源',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: '搜索',
                    onPressed: _busy ? null : () => _load(),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  for (final library in [
                    {'media_lib_set_id': 0, 'media_name': '全部'},
                    ..._libraries,
                  ])
                    ChoiceChip(
                      label: Text(library['media_name']?.toString() ?? '媒体库'),
                      selected: _library == nasInt(library['media_lib_set_id']),
                      onSelected: _busy
                          ? null
                          : (_) {
                              setState(() {
                                _library = nasInt(library['media_lib_set_id']);
                                _search.clear();
                              });
                              _load();
                            },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      if (_items.isEmpty && !_busy)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: Text('此处暂无影片。可切换媒体库或重新搜索。')),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) => SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: (constraints.crossAxisExtent / 180).floor().clamp(
                2,
                8,
              ),
              mainAxisSpacing: 24,
              crossAxisSpacing: 18,
              childAspectRatio: .57,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final row = _items[index];
              final type = nasInt(row['type']);
              final year = nasInt(row['year']);
              final subtitle = [
                if (type != 3 && year >= 1000 && year <= 9999) '$year',
                switch (type) {
                  2 => '剧集',
                  3 => _collectionLabel(row),
                  _ => '电影',
                },
              ].join(' · ');
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _busy ? null : () => _details(row),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: double.infinity,
                          child: _NASPoster(
                            key: ValueKey(
                              '${row['ug_video_info_id']}-${row['poster_path']}',
                            ),
                            client: _client,
                            row: row,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      row['name']?.toString() ?? '未命名影片',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: CinemaTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }, childCount: _items.length),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: !_last
                ? OutlinedButton(
                    onPressed: _busy ? null : () => _load(more: true),
                    child: const Text('加载更多'),
                  )
                : Text(
                    _items.isEmpty ? '' : '已显示全部',
                    style: const TextStyle(color: CinemaTheme.muted),
                  ),
          ),
        ),
      ),
    ],
  );
}

class _NASPoster extends StatefulWidget {
  const _NASPoster({super.key, required this.client, required this.row});
  final CinemaNASClient client;
  final Map<String, dynamic> row;
  @override
  State<_NASPoster> createState() => _NASPosterState();
}

class _NASPosterState extends State<_NASPoster> {
  late final Future<String> _url = widget.client.asset(
    widget.row,
    widget.row['poster_path']?.toString() ?? '',
    poster: true,
  );
  Widget _placeholder() => const ColoredBox(
    color: Color(0xff202126),
    child: Center(
      child: Icon(Icons.movie_outlined, color: CinemaTheme.muted, size: 40),
    ),
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _url,
    builder: (context, snapshot) {
      if (!snapshot.hasData || snapshot.data!.isEmpty) return _placeholder();
      return Image.network(
        snapshot.data!,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    },
  );
}

class _NASQRDialog extends StatefulWidget {
  const _NASQRDialog({
    required this.client,
    required this.address,
    required this.remember,
  });
  final CinemaNASClient client;
  final String address;
  final bool remember;
  @override
  State<_NASQRDialog> createState() => _NASQRDialogState();
}

class _NASQRDialogState extends State<_NASQRDialog> {
  Timer? _timer;
  String? _url, _error;
  String _status = '正在创建二维码';
  bool _creating = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    unawaited(widget.client.call('qrCancel').then((_) {}, onError: (_) {}));
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) return;
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _creating = true;
      _url = null;
      _error = null;
      _status = '正在创建二维码';
    });
    try {
      final qr = await widget.client.call('qrCreate', {
        'address': widget.address,
      });
      if (!mounted || generation != _generation) return;
      final url = qr['url']?.toString();
      if (url == null || !url.startsWith('https://')) {
        throw const FormatException();
      }
      setState(() {
        _url = url;
        _status = '请用绿联云 App 扫码，并在手机上确认登录';
      });
      _timer = Timer(const Duration(seconds: 3), () => _poll(generation));
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is PlatformException
              ? error.message
              : '无法创建二维码，请刷新重试。',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _creating = false);
      }
    }
  }

  Future<void> _poll(int generation) async {
    try {
      final result = await widget.client.call('qrPoll', {
        'remember': widget.remember,
      });
      if (!mounted || generation != _generation) return;
      switch (result['state']) {
        case 'authorized':
          Navigator.pop(context, result);
          return;
        case 'expired':
          setState(() {
            _url = null;
            _status = '二维码已过期，请刷新';
          });
          return;
        case 'scanned':
          setState(() => _status = '已扫码，请在手机上确认');
      }
      _timer = Timer(const Duration(seconds: 3), () => _poll(generation));
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _url = null;
          _error = error is PlatformException ? error.message : '扫码连接中断，请刷新重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('扫码登录 NAS'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_url != null)
            ColoredBox(
              color: Colors.white,
              child: QrImageView(
                data: _url!,
                size: 240,
                padding: const EdgeInsets.all(16),
              ),
            ),
          if (_creating)
            const Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            ),
          const SizedBox(height: 20),
          Text(_error ?? _status, textAlign: TextAlign.center),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: _creating ? null : _create,
        child: const Text('刷新二维码'),
      ),
    ],
  );
}
