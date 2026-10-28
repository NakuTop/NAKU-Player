import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/naku_device.dart';

/// Draw above poster pixels so the remote focus remains visible on every image.
class CinemaTVFocus extends StatefulWidget {
  const CinemaTVFocus({super.key, required this.child});
  final Widget child;
  @override
  State<CinemaTVFocus> createState() => _CinemaTVFocusState();
}

class _CinemaTVFocusState extends State<CinemaTVFocus> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    if (!NakuDevice.isTV) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (v) {
        setState(() => _focused = v);
        if (v) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _focused) {
              Scrollable.ensureVisible(
                context,
                duration: Duration.zero,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          });
        }
      },
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _focused
                        ? const Color(0xFFFFC36A)
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
