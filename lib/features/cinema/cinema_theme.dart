import 'package:kazumi/services/platform/naku_device.dart';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'cinema_appearance.dart';
import 'cinema_optical_glass.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';

abstract final class CinemaTheme {
  // The native macOS material supplies the blur; keep this scrim translucent.
  static Color get background => backgroundFor(CinemaAppearance.instance);
  static Color get surface => surfaceFor(CinemaAppearance.instance);
  static Color get raised => raisedFor(CinemaAppearance.instance);
  static Color backgroundFor(CinemaAppearance appearance) =>
      const Color(0xFF09090B).withValues(
        alpha: defaultTargetPlatform == TargetPlatform.windows
            ? 1
            : appearance.effectiveBackgroundOpacity,
      );
  static Color surfaceFor(CinemaAppearance appearance) =>
      const Color(0xFF1B1B1D).withValues(
        alpha: _panelAlpha(appearance.effectiveBackgroundOpacity, .38, .56),
      );
  static Color raisedFor(CinemaAppearance appearance) =>
      const Color(0xFF242426).withValues(
        alpha: _panelAlpha(appearance.effectiveBackgroundOpacity, .30, .68),
      );
  static double _panelAlpha(double opacity, double base, double scale) =>
      opacity >= .999 ? 1 : base + opacity * scale;
  static const copper = Color(0xFFFF9F0A);
  static const text = Color(0xFFF5F5F7);
  static const muted = Color(0xFFB3B0B5);
  static const border = Color(0x18FFFFFF);
  static ThemeData? _cached;
  static double? _cachedOpacity;
  static String? _cachedFont;
  static TargetPlatform? _cachedPlatform;
  static String get _fontFamily {
    try {
      return GStorage.getSetting(SettingsKeys.useSystemFont)
          ? '.AppleSystemUIFont'
          : customAppFontFamily;
    } catch (_) {
      return '.AppleSystemUIFont';
    }
  }

  static ThemeData get data => dataFor(CinemaAppearance.instance);
  static ThemeData of(BuildContext context) =>
      dataFor(CinemaAppearanceScope.of(context));
  static ThemeData dataFor(CinemaAppearance appearance) {
    final opacity = appearance.effectiveBackgroundOpacity;
    final fontFamily = _fontFamily;
    final platform = defaultTargetPlatform;
    if (_cached != null &&
        _cachedOpacity == opacity &&
        _cachedFont == fontFamily &&
        _cachedPlatform == platform) {
      return _cached!;
    }
    final background = backgroundFor(appearance),
        surface = surfaceFor(appearance);
    _cachedOpacity = opacity;
    _cachedFont = fontFamily;
    _cachedPlatform = platform;
    return _cached = ThemeData(
      useMaterial3: true,
      focusColor: NakuDevice.isTV
          ? copper.withValues(alpha: .45)
          : const Color(0x24FFFFFF),
      hoverColor: const Color(0x0CFFFFFF),
      highlightColor: const Color(0x10FFFFFF),
      splashColor: const Color(0x10FFFFFF),
      visualDensity: NakuDevice.isTV
          ? VisualDensity.comfortable
          : VisualDensity.standard,
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      fontFamilyFallback: const ['MI_Sans_Regular'],
      pageTransitionsTheme: pageTransitionsTheme2024,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.dark(
        primary: copper,
        onPrimary: Colors.black,
        surface: surface,
        onSurface: text,
        secondary: copper,
        onSecondary: Colors.black,
        tertiary: copper,
        onTertiary: Colors.black,
        primaryContainer: const Color(0xFF323234),
        onPrimaryContainer: text,
        secondaryContainer: const Color(0xFF29292B),
        onSecondaryContainer: text,
        tertiaryContainer: const Color(0xFF29292B),
        onTertiaryContainer: text,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: raisedFor(appearance),
        surfaceContainerHighest: const Color(0xFF303032),
        onSurfaceVariant: muted,
        outline: border,
        outlineVariant: const Color(0x10FFFFFF),
        error: Color(0xFFFF9D92),
      ),
      appBarTheme: AppBarTheme(
        toolbarHeight: platform == TargetPlatform.macOS ? 78 : null,
        titleTextStyle: platform == TargetPlatform.macOS
            ? TextStyle(
                fontFamily: fontFamily,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: text,
              )
            : null,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xF01B1B1D),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xEA18181A),
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xF01B1B1D),
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tabBarTheme: platform == TargetPlatform.macOS
          ? TabBarThemeData(
              labelColor: text,
              unselectedLabelColor: muted,
              dividerColor: Colors.transparent,
              indicatorSize: TabBarIndicatorSize.label,
              indicator: BoxDecoration(
                color: const Color(0x16FFFFFF),
                borderRadius: BorderRadius.circular(10),
              ),
              indicatorAnimation: TabIndicatorAnimation.elastic,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
            )
          : null,
      segmentedButtonTheme: platform == TargetPlatform.macOS
          ? SegmentedButtonThemeData(
              style: ButtonStyle(
                side: const WidgetStatePropertyAll(BorderSide.none),
                foregroundColor: const WidgetStatePropertyAll(text),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? const Color(0x20FFFFFF)
                      : Colors.transparent,
                ),
              ),
            )
          : null,
      chipTheme: ChipThemeData(
        labelStyle: const TextStyle(color: muted, fontWeight: FontWeight.w400),
        secondaryLabelStyle: const TextStyle(
          color: text,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: text,
        showCheckmark: false,
        backgroundColor: const Color(0x08FFFFFF),
        selectedColor: const Color(0x1FFFFFFF),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: copper,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style:
            OutlinedButton.styleFrom(
              foregroundColor: text,
              backgroundColor: const Color(0x0AFFFFFF),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ).copyWith(
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(color: Color(0x80FFFFFF))
                    : BorderSide.none,
              ),
            ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x10FFFFFF),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Color(0x80FFFFFF)),
        ),
      ),
      dividerColor: const Color(0x10FFFFFF),
      dividerTheme: const DividerThemeData(
        color: Color(0x10FFFFFF),
        thickness: .5,
      ),
    );
  }
}

/// Restrict each blur to its panel, keeping large poster grids inexpensive.
class CinemaGlass extends StatelessWidget {
  const CinemaGlass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
    this.blur = true,
    this.fluted = false,
    this.interactive = true,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool blur;
  final bool fluted;
  final bool interactive;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CinemaAppearanceScope.of(context),
    builder: (context, _) {
      final appearance = CinemaAppearanceScope.of(context);
      return CinemaOpticalGlass(
        radius: radius,
        padding: padding,
        blur: blur,
        interactive: interactive,
        opacity: appearance.effectiveBackgroundOpacity,
        reduceTransparency: appearance.reduceTransparency,
        reduceMotion: appearance.reduceMotion,
        child: child,
      );
    },
  );
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
        colors: [Color(0x0AFFFFFF), Color(0x0009090B)],
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
          child: RepaintBoundary(
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

/// Install above the app Navigator using MaterialApp.builder. Route-local
/// themes subscribe with CinemaTheme.of(context), so open pages and dialogs
/// react without recreating their player/controllers or navigation state.
class CinemaAppearanceScope extends StatefulWidget {
  const CinemaAppearanceScope({
    super.key,
    required this.child,
    this.appearance,
  });
  final Widget child;
  final CinemaAppearance? appearance;
  static CinemaAppearance of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_CinemaAppearanceInherited>()
          ?.notifier ??
      CinemaAppearance.instance;
  @override
  State<CinemaAppearanceScope> createState() => _CinemaAppearanceScopeState();
}

class _CinemaAppearanceScopeState extends State<CinemaAppearanceScope>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _fontChanges;
  CinemaAppearance get _appearance =>
      widget.appearance ?? CinemaAppearance.instance;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _fontChanges = GStorage.watchSettings([SettingsKeys.useSystemFont])
          .listen((_) {
            if (mounted) setState(() {});
          });
    } catch (_) {
      // A standalone preview may not have initialized application storage.
    }
    unawaited(_appearance.initialize());
  }

  @override
  void didUpdateWidget(CinemaAppearanceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.appearance, widget.appearance)) {
      unawaited(_appearance.initialize());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_appearance.flush());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_fontChanges?.cancel());
    unawaited(_appearance.flush());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CinemaAppearanceInherited(
    notifier: _appearance,
    child: ListenableBuilder(
      listenable: _appearance,
      child: widget.child,
      builder: (context, child) {
        final media = MediaQuery.maybeOf(context);
        final themed = Theme(
          data: CinemaTheme.dataFor(_appearance),
          child: child!,
        );
        return media == null
            ? themed
            : MediaQuery(
                data: media.copyWith(
                  disableAnimations:
                      media.disableAnimations || _appearance.reduceMotion,
                ),
                child: themed,
              );
      },
    ),
  );
}

class _CinemaAppearanceInherited extends InheritedNotifier<CinemaAppearance> {
  const _CinemaAppearanceInherited({
    required super.notifier,
    required super.child,
  });
}
