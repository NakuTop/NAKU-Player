import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'cinema_theme.dart';
import 'cinema_tv_motion.dart';

/// A remote-first modal: no drag handle, no hidden hover actions, and focus
/// remains visible when a result list scrolls.
Future<T?> showCinemaTVPanel<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  double width = 620,
}) => showDialog<T>(
  context: context,
  useRootNavigator: false,
  requestFocus: true,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: CinemaTVMotion.panel,
          reverseDuration: CinemaTVMotion.focus,
          curve: CinemaTVMotion.curve,
        ),
  builder: (dialogContext) {
    final media = MediaQuery.of(dialogContext);
    return Dialog(
      backgroundColor: Colors.transparent,
      alignment: Alignment.centerRight,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: math.min(
          width,
          math.min(
            500,
            math.min(
              math.max(360, media.size.width * .42),
              math.max(280, media.size.width - 48),
            ),
          ),
        ),
        height: math.max(180, media.size.height - media.viewInsets.bottom - 48),
        child: CinemaGlass(
          child: FocusTraversalGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('返回'),
                      ),
                    ],
                  ),
                ),
                Expanded(child: Builder(builder: builder)),
              ],
            ),
          ),
        ),
      ),
    );
  },
);

class CinemaTVAuxiliaryAction extends StatelessWidget {
  const CinemaTVAuxiliaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.subtitle,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
  });
  final String label;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool autofocus, selected;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              Scrollable.ensureVisible(
                context,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                duration: CinemaTVMotion.duration(
                  context,
                  CinemaTVMotion.focus,
                ),
              );
            }
          });
        }
      },
      child: TextButton(
        focusNode: focusNode,
        autofocus: autofocus,
        onPressed: onPressed,
        style: ButtonStyle(
          alignment: Alignment.centerLeft,
          minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? CinemaTheme.raised
                : CinemaTheme.surface,
          ),
          foregroundColor: WidgetStatePropertyAll(
            selected ? CinemaTheme.copper : CinemaTheme.text,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.focused)
                  ? const Color(0xFFF5F5F7)
                  : Colors.transparent,
              width: 2,
            ),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 20)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFFB3B0B5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Icon(Icons.check, size: 22),
              ),
          ],
        ),
      ),
    ),
  );
}
