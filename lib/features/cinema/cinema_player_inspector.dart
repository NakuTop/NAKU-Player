import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'cinema_optical_glass.dart';

Future<T?> showCinemaPlayerPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required String title,
  bool isScrollControlled = true,
  BoxConstraints? constraints,
  Color? backgroundColor,
}) {
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      constraints: constraints,
      backgroundColor: backgroundColor,
    );
  }
  return showCinemaSettingsDialog<T>(
    context: context,
    builder: (panel) => SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: (MediaQuery.sizeOf(panel).width - 88).clamp(0.0, 400.0),
            child: CinemaOpticalGlass(
              opacity: .94,
              interactive: false,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(panel).textTheme.titleSmall,
                            ),
                          ),
                          CloseButton(onPressed: () => Navigator.pop(panel)),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Flexible(child: ClipRect(child: builder(panel))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<T?> showCinemaSettingsDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  AnimationStyle? animationStyle,
}) {
  if (defaultTargetPlatform != TargetPlatform.macOS) {
    return showDialog<T>(context: context, builder: builder,
        useRootNavigator: useRootNavigator, animationStyle: animationStyle);
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push(_CinemaSettingsRoute<T>(
    context: context, builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  ));
}

class _CinemaSettingsRoute<T> extends DialogRoute<T> {
  _CinemaSettingsRoute({required super.context, required super.builder, required super.themes})
      : super(barrierColor: Colors.black26);

  @override
  Widget buildModalBarrier() => ModalBarrier(
    color: barrierColor, semanticsLabel: barrierLabel, dismissible: true,
    onDismiss: () {
      if (isCurrent) navigator?.popUntil((route) => route is! _CinemaSettingsRoute);
    },
  );
}
