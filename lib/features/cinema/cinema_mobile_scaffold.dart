import 'package:flutter/material.dart';
import 'cinema_theme.dart';

class CinemaMobileDestination {
  const CinemaMobileDestination(this.id, this.label, this.icon);
  final String id, label;
  final IconData icon;
}

/// Touch-first shell: one scrolling content pane, persistent destinations, and
/// independent entry points for the original native features.
class CinemaMobileScaffold extends StatelessWidget {
  const CinemaMobileScaffold({
    super.key,
    required this.heading,
    required this.selected,
    required this.destinations,
    required this.onSelect,
    required this.drawer,
    required this.body,
    required this.onHomeDisplay,
    required this.onDownloads,
    required this.onUpdates,
    this.search,
    this.onBack,
    this.onDrawerChanged,
  });
  final String heading, selected;
  final List<CinemaMobileDestination> destinations;
  final ValueChanged<String> onSelect;
  final Widget drawer, body;
  final Widget? search;
  final VoidCallback onHomeDisplay, onDownloads, onUpdates;
  final VoidCallback? onBack;
  final ValueChanged<bool>? onDrawerChanged;

  Widget _action(String label, IconData icon, VoidCallback callback) =>
      SizedBox.square(
        dimension: 44,
        child: IconButton(
          tooltip: label,
          onPressed: callback,
          icon: Icon(icon, size: 21),
          color: CinemaTheme.controlTint,
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey('cinema-mobile-shell'),
    backgroundColor: const Color(0xFF09090B),
    onDrawerChanged: onDrawerChanged,
    drawer: Drawer(backgroundColor: const Color(0xFF1B1B1D), child: drawer),
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              children: [
                Builder(
                  builder: (context) => _action(
                    onBack == null ? '更多功能' : '返回',
                    onBack == null
                        ? Icons.menu_rounded
                        : Icons.arrow_back_rounded,
                    onBack ?? () => Scaffold.of(context).openDrawer(),
                  ),
                ),
                const Expanded(
                  child: Text(
                    'NAKU',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                _action('Home Display', Icons.public_rounded, onHomeDisplay),
                _action(
                  '下载内容',
                  Icons.download_for_offline_outlined,
                  onDownloads,
                ),
                _action('检查更新', Icons.system_update_alt_rounded, onUpdates),
              ],
            ),
          ),
          if (search != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: search!,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                heading,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.5,
                ),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    ),
    bottomNavigationBar: DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF171719),
        border: Border(top: BorderSide(color: Color(0x18FFFFFF), width: .5)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            for (final item in destinations)
              Expanded(
                child: Semantics(
                  selected: selected == item.id,
                  button: true,
                  child: InkWell(
                    key: ValueKey('mobile-destination-${item.id}'),
                    onTap: () => onSelect(item.id),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            item.icon,
                            size: 22,
                            color: selected == item.id
                                ? CinemaTheme.text
                                : CinemaTheme.muted,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.label,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: selected == item.id
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected == item.id
                                  ? CinemaTheme.text
                                  : CinemaTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
