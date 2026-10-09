import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';

class CollectButton extends StatefulWidget {
  const CollectButton({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) : _isExtended = false;

  const CollectButton.extend({
    super.key,
    required this.bangumiItem,
    this.color = Colors.white,
    this.onOpen,
    this.onClose,
  }) : _isExtended = true;

  final BangumiItem bangumiItem;
  final Color color;
  final bool _isExtended;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  @override
  State<CollectButton> createState() => _CollectButtonState();
}

class _CollectButtonState extends State<CollectButton> {
  final _collectController = inject<CollectController>();

  late final _changes = inject<ICollectCrudRepository>().changes;
  bool _busy = false;
  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    widget.onOpen?.call();
    try {
      await _collectController.toggleFavorite(widget.bangumiItem);
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '收藏未能保存，请重试');
      }
    } finally {
      widget.onClose?.call();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: _changes,
    builder: (context, _) {
      final saved = _collectController.getCollectType(widget.bangumiItem) != 0;
      final label = saved ? '已收藏' : '收藏';
      final icon = saved ? Icons.favorite : Icons.favorite_border;
      return widget._isExtended
          ? FilledButton.icon(
              onPressed: _busy ? null : _toggle,
              icon: Icon(icon),
              label: Text(label),
            )
          : IconButton(
              onPressed: _busy ? null : _toggle,
              tooltip: label,
              icon: Icon(icon, color: widget.color),
            );
    },
  );
}
