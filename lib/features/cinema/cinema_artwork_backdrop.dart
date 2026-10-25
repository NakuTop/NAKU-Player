import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cinema_theme.dart';

/// An intentionally quiet charcoal glass floor. The artwork fades into this
/// material rather than into whatever desktop happens to be behind the window.
class CinemaDetailFrost extends StatelessWidget {
  const CinemaDetailFrost({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CinemaAppearanceScope.of(context),
    builder: (context, _) {
      final reduced = CinemaAppearanceScope.of(context).reduceTransparency;
      final tint = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, .48, 1],
            colors: reduced
                ? const [
                    Color(0xFF202024),
                    Color(0xFF1B1B1F),
                    Color(0xFF19191D),
                  ]
                : const [
                    Color(0xE8202024),
                    Color(0xF21B1B1F),
                    Color(0xF719191D),
                  ],
          ),
        ),
        child: const SizedBox.expand(),
      );
      return IgnorePointer(
        child: ClipRect(
          child: reduced
              ? tint
              : BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: tint,
                ),
        ),
      );
    },
  );
}

/// Sharp artwork and its diffuse dark field have independent feathering. The
/// ambient layer survives beyond the sharp image, then meets the window glass.
class CinemaArtworkBackdrop extends StatelessWidget {
  const CinemaArtworkBackdrop({
    super.key,
    required this.image,
    this.alignment = Alignment.center,
    this.featherSides = false,
    this.shadeLeading = false,
  });

  final ImageProvider image;
  final Alignment alignment;
  final bool featherSides;
  final bool shadeLeading;

  Widget _fade(Widget child, List<double> stops, List<double> strengths) =>
      ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: stops,
          colors: strengths
              .map((alpha) => Colors.white.withValues(alpha: alpha))
              .toList(),
        ).createShader(bounds),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final layers = Stack(
      fit: StackFit.expand,
      children: [
        // A small decode is sufficient for Gaussian ambience. The provider and
        // disk cache are shared with the clear artwork; no extra URL is fetched.
        _fade(
          RepaintBoundary(
            child: Opacity(
              opacity: .66,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 34,
                  sigmaY: 34,
                  tileMode: ui.TileMode.clamp,
                ),
                child: ColorFiltered(
                  colorFilter: const ColorFilter.mode(
                    Color(0xB009090B),
                    BlendMode.srcATop,
                  ),
                  child: Image(
                    image: ResizeImage.resizeIfNeeded(384, null, image),
                    fit: BoxFit.cover,
                    alignment: alignment,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          const [0, .09, .23, .56, .73, .86, .95, 1],
          const [0, .50, 1, 1, .90, .54, .12, 0],
        ),
        _fade(
          Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: image,
                fit: BoxFit.cover,
                alignment: alignment,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              if (shadeLeading)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xA609090B), Color(0x0009090B)],
                    ),
                  ),
                ),
            ],
          ),
          const [0, .08, .20, .47, .60, .72, .83, 1],
          const [0, .32, 1, 1, .85, .40, 0, 0],
        ),
      ],
    );
    return IgnorePointer(
      child: ClipRect(
        child: featherSides
            ? ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  stops: [0, .035, .12, .24, .77, .89, .97, 1],
                  colors: [
                    Colors.transparent,
                    Color(0x30FFFFFF),
                    Color(0xB0FFFFFF),
                    Colors.white,
                    Colors.white,
                    Color(0xB0FFFFFF),
                    Color(0x30FFFFFF),
                    Colors.transparent,
                  ],
                ).createShader(bounds),
                child: layers,
              )
            : layers,
      ),
    );
  }
}
