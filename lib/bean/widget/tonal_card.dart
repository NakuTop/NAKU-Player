import 'package:flutter/material.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

const double tonalCardRadius = 24;

class TonalCard extends StatelessWidget {
  const TonalCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS
      ? CinemaGlass(
          blur: false,
          interactive: false,
          radius: tonalCardRadius,
          padding: padding,
          child: child,
        )
      : Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(tonalCardRadius),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding, child: child),
        );
}
