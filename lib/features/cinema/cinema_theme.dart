import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

abstract final class CinemaTheme {
  // The native macOS material supplies the blur; keep this scrim translucent.
  static const background = Color(0x7809090B);
  static const surface = Color(0xA41B1B1F);
  static const raised = Color(0x9E2A292B);
  static const copper = Color(0xFFFF9F0A);
  static const text = Color(0xFFF5F5F7);
  static const muted = Color(0xFFB3B0B5);
  static const border = Color(0x30FFFFFF);
  static final ThemeData data = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: const ['MI_Sans_Regular'],
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: copper,
      onPrimary: Colors.black,
      surface: surface,
      onSurface: text,
      secondary: copper,
      outline: border,
      error: Color(0xFFFF9D92),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0x7809090B),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xF0202024),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: border),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Color(0xEA17171B),
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    chipTheme: ChipThemeData(
      labelStyle: const TextStyle(color: text),
      secondaryLabelStyle: const TextStyle(color: text),
      checkmarkColor: copper,
      backgroundColor: const Color(0x901C1C20),
      selectedColor: copper.withValues(alpha: .22),
      side: const BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: copper,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xA02A292D),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: copper),
      ),
    ),
    dividerColor: border,
  );
}

/// Restrict each blur to its panel, keeping large poster grids inexpensive.
class CinemaGlass extends StatelessWidget {
  const CinemaGlass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
    this.blur = true,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool blur;
  @override
  Widget build(BuildContext context) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x662D2B30), Color(0x47111014)],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: CinemaTheme.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(padding: padding, child: child),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: blur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: content,
            )
          : content,
    );
  }
}

class CinemaCanvas extends StatelessWidget {
  const CinemaCanvas({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment.topLeft,
        radius: 1.5,
        colors: [Color(0x303D2515), Color(0x1209090B)],
        stops: [0, 1],
      ),
    ),
    child: child,
  );
}

class CinemaCoverBackdrop extends StatelessWidget {
  const CinemaCoverBackdrop({
    super.key,
    required this.poster,
    required this.child,
  });
  final String poster;
  final Widget child;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: const Color(0xFF101014),
            child: poster.isEmpty
                ? const SizedBox()
                : ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Opacity(
                      opacity: .5,
                      child: CachedNetworkImage(
                        memCacheWidth: 640,
                        imageUrl: poster,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const SizedBox(),
                      ),
                    ),
                  ),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x70202024), Color(0xE60A0A0D)],
                stops: [0, .8],
              ),
            ),
          ),
        ),
        child,
      ],
    ),
  );
}
