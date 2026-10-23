import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';
import 'cinema_logvar_client.dart';

Future<bool?> showCinemaLogvarSettings(BuildContext context) =>
    showCupertinoDialog<bool>(
      context: context,
      builder: (_) => const _Settings(),
    );

class _Settings extends StatefulWidget {
  const _Settings();
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  final address = TextEditingController();
  final token = TextEditingController();
  final cancel = CancelToken();
  CinemaLogvarClient? client;
  bool busy = false;
  String message = '填写自己的 LogVar / danmu_api 地址。访问令牌保存在本机钥匙串中。';

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final config = await LogvarCredentialStore.instance.read();
      if (!mounted || config == null) return;
      setState(() {
        address.text = config.baseUrl.toString();
        token.text = config.token;
      });
    } catch (_) {
      if (mounted) setState(() => message = '无法读取钥匙串，请重新填写服务配置');
    }
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      message = '正在测试搜索接口…';
    });
    try {
      final config = LogvarConfiguration(
        baseUrl: address.text,
        token: token.text.trim(),
      );
      client = CinemaLogvarClient(config);
      await client!
          .search('甄嬛传', cancelToken: cancel)
          .timeout(const Duration(seconds: 50));
      if (!mounted) return;
      await LogvarCredentialStore.instance.save(config);
      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) setState(() => message = '连接未通过，请检查 NAS 地址、访问令牌及网络');
    } finally {
      client?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    cancel.cancel();
    client?.close();
    address.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: const Text('NAS 弹幕服务'),
    content: Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          CupertinoTextField(
            controller: address,
            placeholder: '服务地址，如 http://192.168.1.10:9321',
            autocorrect: false,
            enabled: !busy,
          ),
          const SizedBox(height: 10),
          CupertinoTextField(
            controller: token,
            placeholder: '访问令牌',
            obscureText: true,
            autocorrect: false,
            enabled: !busy,
          ),
          const SizedBox(height: 12),
          if (busy) const CupertinoActivityIndicator(),
          Text(message),
          const SizedBox(height: 8),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: busy
                ? null
                : () async {
                    await LogvarCredentialStore.instance.clear();
                    if (context.mounted) Navigator.pop(context, true);
                  },
            child: const Text('移除本机配置'),
          ),
        ],
      ),
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      CupertinoDialogAction(
        isDefaultAction: true,
        onPressed: busy ? null : _save,
        child: const Text('测试并保存'),
      ),
    ],
  );
}
