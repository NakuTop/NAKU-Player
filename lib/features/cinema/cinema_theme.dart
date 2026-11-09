import 'package:kazumi/services/platform/naku_device.dart';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'cinema_appearance.dart';
import 'cinema_tv_motion.dart';
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
        alpha:
            NakuDevice.isTV ||
                defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.android
            ? 1
            : appearance.effectiveBackgroundOpacity,
      );
  static Color surfaceFor(CinemaAppearance appearance) =>
      const Color(0xFF1B1B1D).withValues(
        alpha:
            NakuDevice.isTV || defaultTargetPlatform == TargetPlatform.android
            ? 1
            : _panelAlpha(appearance.effectiveBackgroundOpacity, .38, .56),
      );
  static Color raisedFor(CinemaAppearance appearance) =>
      const Color(0xFF242426).withValues(
        alpha:
            NakuDevice.isTV || defaultTargetPlatform == TargetPlatform.android
            ? 1
            : _panelAlpha(appearance.effectiveBackgroundOpacity, .30, .68),
      );
  static double _panelAlpha(double opacity, double base, double scale) =>
      opacity >= .999 ? 1 : base + opacity * scale;
  // Warm light remains a cinematic effect; macOS controls use the same silver
  // contrast as the navigation and native frost instead of the legacy orange.
  static const copper = Color(0xFFFF9F0A);
  static const controlTint = Color(0xFFE3E7ED);
  static const selectionFill = Color(0x1FFFFFFF);
  static const controlInk = Color(0xFF17191E);
  static bool usesRefinedControls(TargetPlatform platform) =>
      !NakuDevice.isTV &&
      (platform == TargetPlatform.macOS || platform == TargetPlatform.android);
  static bool get refinedControls => usesRefinedControls(defaultTargetPlatform);
  static Color get accent => refinedControls ? controlTint : copper;
  static const text = Color(0xFFF5F5F7);
  static const muted = Color(0xFFB3B0B5);
  static const border = Color(0x18FFFFFF);
  static ThemeData? _cached;
  static double? _cachedOpacity;
  static String? _cachedFont;
  static TargetPlatform? _cachedPlatform;
  static bool? _cachedTV;
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
  static ThemeData of(BuildContext context) => dataFor(
    CinemaAppearanceScope.of(context),
    platform: Theme.of(context).platform,
  );

  /// Bottom sheets can be launched from the State context above a player's
  /// local Theme. Capture a complete cinema theme before pushing that route.
  static ThemeData panelDataFor(BuildContext context) {
    final inherited = Theme.of(context);
    return usesRefinedControls(inherited.platform) ? of(context) : inherited;
  }

  static ThemeData dataFor(
    CinemaAppearance appearance, {
    TargetPlatform? platform,
  }) {
    final opacity = appearance.effectiveBackgroundOpacity;
    final fontFamily = _fontFamily;
    platform ??= defaultTargetPlatform;
    final refined = usesRefinedControls(platform);
    final accent = refined ? controlTint : copper;
    if (_cached != null &&
        _cachedOpacity == opacity &&
        _cachedFont == fontFamily &&
        _cachedTV == NakuDevice.isTV &&
        _cachedPlatform == platform) {
      return _cached!;
    }
    final background = backgroundFor(appearance),
        surface = surfaceFor(appearance);
    _cachedOpacity = opacity;
    _cachedFont = fontFamily;
    _cachedPlatform = platform;
    _cachedTV = NakuDevice.isTV;
    return _cached = ThemeData(
      platform: platform,
      useMaterial3: true,
      splashFactory: NakuDevice.isTV
          ? NoSplash.splashFactory
          : InkRipple.splashFactory,
      focusColor: NakuDevice.isTV
          ? Colors.white.withValues(alpha: .14)
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
      pageTransitionsTheme: NakuDevice.isTV
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: CinemaTVPageTransitions(),
                TargetPlatform.macOS: CinemaTVPageTransitions(),
                TargetPlatform.linux: CinemaTVPageTransitions(),
                TargetPlatform.windows: CinemaTVPageTransitions(),
                TargetPlatform.iOS: CinemaTVPageTransitions(),
                TargetPlatform.fuchsia: CinemaTVPageTransitions(),
              },
            )
          : pageTransitionsTheme2024,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.dark(
        primary: accent,
        onPrimary: Colors.black,
        surface: surface,
        onSurface: text,
        secondary: accent,
        onSecondary: Colors.black,
        tertiary: accent,
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
        surfaceTintColor: refined ? Colors.transparent : null,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: refined
              ? const BorderSide(color: border, width: .5)
              : BorderSide.none,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: NakuDevice.isTV || (refined && opacity >= .999)
            ? const Color(0xFF1B1B1D)
            : const Color(0xF01B1B1D),
        surfaceTintColor: Colors.transparent,
        elevation: NakuDevice.isTV ? 0 : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: refined && opacity >= .999
            ? const Color(0xFF202126)
            : const Color(0xEA18181A),
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: NakuDevice.isTV || (refined && opacity >= .999)
            ? const Color(0xFF1B1B1D)
            : const Color(0xF01B1B1D),
        surfaceTintColor: Colors.transparent,
        elevation: NakuDevice.isTV ? 0 : 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tabBarTheme: refined
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
      segmentedButtonTheme: refined
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
          backgroundColor: accent,
          foregroundColor: refined ? controlInk : Colors.black,
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
      // Explicit roles prevent Material controls deriving tinted orange
      // containers from an older route's ColorScheme seed.
      textButtonTheme: refined
          ? TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: controlTint),
            )
          : null,
      switchTheme: refined
          ? SwitchThemeData(
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? const Color(0x668E939D)
                    : states.contains(WidgetState.selected)
                    ? controlTint
                    : muted,
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? const Color(0xFF505660)
                    : const Color(0xFF2B2E34),
              ),
              trackOutlineColor: const WidgetStatePropertyAll(
                Color(0x30FFFFFF),
              ),
            )
          : null,
      checkboxTheme: refined
          ? CheckboxThemeData(
              fillColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? (states.contains(WidgetState.disabled)
                          ? const Color(0x668E939D)
                          : controlTint)
                    : Colors.transparent,
              ),
              checkColor: const WidgetStatePropertyAll(controlInk),
              side: const BorderSide(color: Color(0x60FFFFFF), width: 1.3),
            )
          : null,
      radioTheme: refined
          ? RadioThemeData(
              fillColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? const Color(0x668E939D)
                    : controlTint,
              ),
            )
          : null,
      sliderTheme: refined
          ? const SliderThemeData(
              activeTrackColor: controlTint,
              thumbColor: controlTint,
              inactiveTrackColor: Color(0x30FFFFFF),
              overlayColor: Color(0x18FFFFFF),
              valueIndicatorColor: Color(0xFF454A53),
              valueIndicatorTextStyle: TextStyle(color: text),
            )
          : null,
      progressIndicatorTheme: refined
          ? const ProgressIndicatorThemeData(
              color: controlTint,
              linearTrackColor: Color(0x20FFFFFF),
            )
          : null,
      listTileTheme: refined
          ? const ListTileThemeData(
              selectedColor: text,
              selectedTileColor: selectionFill,
              iconColor: muted,
            )
          : null,
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

/// A complete theme boundary for sheets and legacy settings destinations.
/// It changes inherited color roles without adding another blur or material.
class CinemaPanelTheme extends StatelessWidget {
  const CinemaPanelTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Theme(data: CinemaTheme.panelDataFor(context), child: child);
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
