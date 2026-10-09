import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/features/cinema/cinema_appearance_settings.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'package:kazumi/features/cinema/cinema_settings_page.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/naku_update_page.dart';
import 'package:kazumi/utils/constants.dart';

/// All legacy setting routes remain nested here, but their root menu is the
/// same NAKU settings page used by the main sidebar at every window width.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.location});

  final String location;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _outletKey = GlobalKey<RouterOutletState>();

  void _goBack() {
    if (_outletKey.currentState?.maybePop() ?? false) return;
    if (!context.maybePop()) context.navigate('/cinema');
  }

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    onPopWithResult: (_) => _goBack(),
    child: SettingsPaneScope(
      embedded: false,
      showBackButton: true,
      onBack: _goBack,
      child: Theme(
        data: CinemaTheme.of(
          context,
        ).copyWith(pageTransitionsTheme: settingsPageTransitionsTheme),
        child: RouterOutlet(key: _outletKey),
      ),
    ),
  );
}

class SettingsIndexPage extends StatelessWidget {
  const SettingsIndexPage({super.key});

  void _openSources(BuildContext context) {
    if (CinemaSettingsHostBinding.instance.openSources()) return;
    KazumiDialog.showToast(context: context, message: '请返回主界面后打开片源管理。');
  }

  @override
  Widget build(BuildContext context) {
    final host = CinemaSettingsHostBinding.instance;
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('设置'),
        leading: BackButton(
          onPressed:
              SettingsPaneScope.of(context)?.onBack ??
              () {
                if (!context.maybePop()) context.navigate('/cinema');
              },
        ),
      ),
      body: CinemaSettingsPage(
        enabledSourceCount: host.enabledSourceCount,
        sourceCount: host.sourceCount,
        onSources: () => _openSources(context),
        onAppearance: () => showCinemaAppearanceSheet(context),
        onUpdates: () => Navigator.of(
          context,
          rootNavigator: true,
        ).push(MaterialPageRoute<void>(builder: (_) => const NakuUpdatePage())),
      ),
    );
  }
}
