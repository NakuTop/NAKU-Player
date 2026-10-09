import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:url_launcher/url_launcher.dart';

/// A configuration status, not a claim that a remote request has succeeded.
class DanmakuServiceStatusTile extends StatelessWidget {
  const DanmakuServiceStatusTile({super.key});

  static final guideUri = Uri.parse('https://doc.dandanplay.com/open/');

  Future<void> _openGuide(BuildContext context) async {
    try {
      if (await launchUrl(guideUri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // Keep a failed external link from interrupting the settings page.
    }
    if (!context.mounted) return;
    KazumiDialog.showToast(
      context: context,
      message: '无法打开说明，请访问 doc.dandanplay.com/open/',
    );
  }

  @override
  Widget build(BuildContext context) {
    final configured = dandanCredentials.isConfigured;
    return SettingsTile(
      leading: configured ? Icons.check_circle_outline : Icons.info_outline,
      title: Text(configured ? '弹幕服务已配置' : '弹幕服务尚未配置'),
      description: Text(
        configured
            ? '使用弹弹play加载弹幕。查看官方接入说明。'
            : '当前版本无法在线加载弹幕，需由发布者完成服务配置。已有离线弹幕仍可使用。查看官方接入说明。',
      ),
      trailing: const Icon(Icons.open_in_new_rounded),
      onPressed: _openGuide,
    );
  }
}
