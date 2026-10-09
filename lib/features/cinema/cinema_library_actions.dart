import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';

import 'cinema_models.dart';
import 'cinema_store.dart';
import 'cinema_theme.dart';

/// Desktop context menus and touch actions share the same reversible operation.
class CinemaLibraryActions extends StatefulWidget {
  const CinemaLibraryActions({
    super.key,
    required this.store,
    required this.title,
    required this.child,
    this.history = false,
  });

  final CinemaStore store;
  final CinemaTitle title;
  final Widget child;
  final bool history;

  @override
  State<CinemaLibraryActions> createState() => _CinemaLibraryActionsState();
}

class _CinemaLibraryActionsState extends State<CinemaLibraryActions> {
  bool _menuOpen = false;
  bool _removing = false;

  String get _label => widget.history ? '删除记录' : '取消收藏';

  Future<void> _showMenu(Offset globalPosition) async {
    if (_menuOpen || _removing) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    _menuOpen = true;
    final remove = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<bool>(
          value: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.history
                    ? Icons.delete_outline_rounded
                    : Icons.favorite_border_rounded,
                size: 18,
                color: CinemaTheme.copper,
              ),
              const SizedBox(width: 10),
              Text(_label),
            ],
          ),
        ),
      ],
    );
    _menuOpen = false;
    if (remove == true && mounted) await _remove();
  }

  Future<bool> _remove() async {
    if (_removing) return false;
    _removing = true;
    final messenger = ScaffoldMessenger.of(context);
    final message = widget.history ? '已删除观看记录' : '已取消收藏';
    try {
      final undo = widget.history
          ? await widget.store.removeHistory(widget.title)
          : await widget.store.removeFavorite(widget.title);
      if (undo == null) return false;
      if (!messenger.mounted) return true;
      KazumiDialog.showToast(
        messenger: messenger,
        message: message,
        showActionButton: true,
        actionLabel: '撤销',
        onActionPressed: () async {
          try {
            final restored = await undo.restore();
            if (!restored && messenger.mounted) {
              KazumiDialog.showToast(
                messenger: messenger,
                message: '已保留这部作品的新记录',
              );
            }
          } catch (_) {
            if (messenger.mounted) {
              KazumiDialog.showToast(
                messenger: messenger,
                message: '恢复记录保存失败，请稍后重试',
              );
            }
          }
        },
      );
      return true;
    } catch (_) {
      if (messenger.mounted) {
        KazumiDialog.showToast(
          messenger: messenger,
          message: '未能保存删除操作，记录已保留',
        );
      }
      return false;
    } finally {
      _removing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: _label): () => unawaited(_remove()),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            unawaited(_showMenu(details.globalPosition)),
        onLongPressStart: (details) =>
            unawaited(_showMenu(details.globalPosition)),
        child: widget.child,
      ),
    );
    if (!widget.history) return child;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Dismissible(
      key: ValueKey('dismiss-history:${widget.title.key}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: .35},
      movementDuration: Duration(milliseconds: reduceMotion ? 0 : 180),
      resizeDuration: Duration(milliseconds: reduceMotion ? 0 : 140),
      // Keep the row reversible until its atomic storage write succeeds. A
      // failure may restore the same key before the next frame.
      confirmDismiss: (_) => _remove(),
      background: Container(
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsetsDirectional.only(end: 20),
        decoration: BoxDecoration(
          color: CinemaTheme.copper.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline_rounded, color: CinemaTheme.copper),
            SizedBox(width: 8),
            Text('删除记录', style: TextStyle(color: CinemaTheme.copper)),
          ],
        ),
      ),
      child: child,
    );
  }
}
