import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/platform/dandan_credential_store.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:url_launcher/url_launcher.dart';

class DirectDanmakuServiceStatusTile extends StatelessWidget {
  const DirectDanmakuServiceStatusTile({super.key});
  @override
  Widget build(BuildContext context) => SettingsTile(
    leading: Icons.cloud_done_outlined,
    title: const Text('电影与剧集弹幕：播放器直连'),
    description: const Text(
      '自动核对片名、年份、季和集数，直接获取腾讯、优酷、爱奇艺、芒果和 Bilibili 弹幕，无需 NAS 或令牌。播放页可调整开关和样式。',
    ),
  );
}

class DanmakuServiceStatusTile extends StatefulWidget {
  const DanmakuServiceStatusTile({super.key});
  static final guideUri = Uri.parse('https://doc.dandanplay.com/open/');
  @override
  State<DanmakuServiceStatusTile> createState() =>
      _DanmakuServiceStatusTileState();
}

class _DanmakuServiceStatusTileState extends State<DanmakuServiceStatusTile> {
  bool _configured = dandanCredentials.isConfigured;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final value = await DandanCredentialStore.instance.read();
      if (mounted) setState(() => _configured = value.isConfigured);
    } catch (_) {
      /* An inaccessible Keychain is explained when opening. */
    }
  }

  @override
  Widget build(BuildContext context) => SettingsTile(
    leading: _configured ? Icons.check_circle_outline : Icons.settings_outlined,
    title: Text(_configured ? '弹弹play已配置' : '弹弹play（可选）'),
    description: const Text('播放器直连平台弹幕无需此项配置。填写自有凭据后可增加弹弹play聚合弹幕。'),
    trailing: const Icon(Icons.chevron_right_rounded),
    onPressed: (context) async {
      await showDialog<void>(
        context: context,
        builder: (_) => const DanmakuServiceDialog(),
      );
      await _refresh();
    },
  );
}

class DanmakuServiceDialog extends StatefulWidget {
  const DanmakuServiceDialog({super.key});
  @override
  State<DanmakuServiceDialog> createState() => _DanmakuServiceDialogState();
}

class _DanmakuServiceDialogState extends State<DanmakuServiceDialog> {
  final _id = TextEditingController(), _secret = TextEditingController();
  bool _busy = true;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await DandanCredentialStore.instance.read();
      if (!mounted) return;
      _id.text = value.id;
      _secret.text = value.secret;
    } catch (_) {
      _message = '无法读取本机钥匙串，请检查系统授权';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  DandanCredentials get _value =>
      DandanCredentials(id: _id.text.trim(), secret: _secret.text.trim());
  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = success);
    } catch (error) {
      if (mounted) {
        setState(
          () => _message =
              error is DanmakuServiceException ||
                  error is DanmakuNotConfiguredException
              ? error.toString()
              : '操作失败，请检查凭据、网络或钥匙串授权',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('弹幕服务配置'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '使用开发者中心审核通过的 AppId 与任一 AppSecret。凭据只保存在本机钥匙串。无需弹弹play用户账号；应用配额按官方分层管理。没有凭据时仍可用 B 站或本地弹幕。',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _id,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'AppId'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _secret,
              enabled: !_busy,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'AppSecret'),
            ),
            const SizedBox(height: 12),
            if (_message != null) Text(_message!),
            if (_busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            if (!await launchUrl(
                                  DanmakuServiceStatusTile.guideUri,
                                  mode: LaunchMode.externalApplication,
                                ) &&
                                context.mounted) {
                              KazumiDialog.showToast(
                                context: context,
                                message: '请访问 doc.dandanplay.com/open/',
                              );
                            }
                          } catch (_) {
                            if (mounted) {
                              setState(
                                () => _message = '请访问 doc.dandanplay.com/open/',
                              );
                            }
                          }
                        },
                  child: const Text('官方接入说明'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => launchUrl(
                          Uri.parse('https://dev.dandanplay.com/Center'),
                          mode: LaunchMode.externalApplication,
                        ),
                  child: const Text('开发者中心'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final result =
                              await DanmakuClient(credentials: _value).get(
                                '${ApiEndpoints.dandanAPIDomain}${ApiEndpoints.dandanAPISearchEpisodes}',
                                queryParameters: {
                                  'anime': '赛博朋克',
                                  'v2': 'true',
                                },
                              );
                          if (result is! Map || result['animes'] is! List) {
                            throw const DanmakuServiceException();
                          }
                        }, '连接测试通过，可保存并返回播放器重新加载弹幕'),
                  child: const Text('测试连接'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await DandanCredentialStore.instance.clear();
                          _id.clear();
                          _secret.clear();
                        }, '已移除本机凭据'),
                  child: const Text('移除本机配置'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(
                () => DandanCredentialStore.instance.save(_value),
                '已安全保存，下次弹幕请求立即使用此配置',
              ),
        child: const Text('保存'),
      ),
    ],
  );
}
