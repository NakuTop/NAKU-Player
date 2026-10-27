import 'package:flutter/material.dart';

import 'cinema_webview_page.dart';
import 'cinema_swipe_navigation.dart';

class CinemaMoyuSession extends ChangeNotifier {
  bool opened = false;
  bool visible = false;
  void show() {
    if (visible) return;
    FocusManager.instance.primaryFocus?.unfocus();
    opened = visible = true;
    notifyListeners();
  }

  void hide() {
    if (!visible) return;
    FocusManager.instance.primaryFocus?.unfocus();
    visible = false;
    notifyListeners();
  }
}

/// Root-owned platform view: hiding never removes the document from the tree.
class CinemaMoyuHost extends StatelessWidget {
  const CinemaMoyuHost({super.key, required this.session, required this.child});
  final CinemaMoyuSession session;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    child: child,
    builder: (context, home) {
      final active =
          session.visible && (ModalRoute.of(context)?.isCurrent ?? true);
      return Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: session.visible,
            child: TickerMode(enabled: !session.visible, child: home!),
          ),
          if (session.opened)
            Offstage(
              offstage: !active,
              child: TickerMode(
                enabled: active,
                child: CinemaSwipeNavigation(
                  edgeOnly: true,
                  enabled: active,
                  onBack: session.hide,
                  child: CinemaWebviewPage(
                    key: const ValueKey('cinema-retained-moyu'),
                    title: '摸鱼',
                    url: 'https://1in8b.life/zh-hans/',
                    mediaToolsEnabled: false,
                    visible: active,
                    onClose: session.hide,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
