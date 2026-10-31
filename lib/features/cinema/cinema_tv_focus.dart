import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_tv_motion.dart';

/// Draw above poster pixels so the remote focus remains visible on every image.
class CinemaTVFocus extends StatefulWidget {
  const CinemaTVFocus({
    super.key,
    required this.child,
    this.radius = 14,
    this.scale = 1.035,
  });
  final Widget child;
  final double radius, scale;
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
                duration: CinemaTVMotion.duration(
                  context,
                  CinemaTVMotion.focus,
                ),
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          });
        }
      },
      child: AnimatedScale(
        scale: _focused ? widget.scale : 1,
        duration: CinemaTVMotion.duration(context, CinemaTVMotion.focus),
        curve: CinemaTVMotion.curve,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: CinemaTVMotion.duration(
                    context,
                    CinemaTVMotion.focus,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    border: Border.all(
                      color: _focused
                          ? const Color(0xFFF5F5F7)
                          : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
