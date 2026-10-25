import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;

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

/// The full composition sits inside an edge-colour extension. Only that
/// extension is blurred/feathered; the picture itself is never cropped or faded.
class CinemaArtworkBackdrop extends StatefulWidget {
  const CinemaArtworkBackdrop({
    super.key,
    required this.image,
    this.alignment = Alignment.center,
    this.featherSides = false,
    this.shadeLeading = false,
    this.contentInsets = const EdgeInsets.fromLTRB(24, 24, 24, 56),
  });

  final ImageProvider image;
  final Alignment alignment;
  final bool featherSides;
  final bool shadeLeading;
  final EdgeInsets contentInsets;

  @override
  State<CinemaArtworkBackdrop> createState() => _CinemaArtworkBackdropState();
}

class _CinemaArtworkBackdropState extends State<CinemaArtworkBackdrop> {
  ImageStream? _sharpStream, _ambientStream;
  ImageStreamListener? _sharpListener, _ambientListener;
  ImageInfo? _sharp, _ambient;
  ImageConfiguration? _configuration;
  bool _attaching = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final configuration = createLocalImageConfiguration(context);
    if (_configuration != configuration) {
      _configuration = configuration;
      _resolve();
    }
  }

  @override
  void didUpdateWidget(CinemaArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    _detach();
    _sharp?.dispose();
    _ambient?.dispose();
    _sharp = _ambient = null;
    void frame(ImageInfo info, {required bool ambient}) {
      void replace() {
        if (ambient) {
          _ambient?.dispose();
          _ambient = info;
        } else {
          _sharp?.dispose();
          _sharp = info;
        }
      }

      if (!mounted) {
        info.dispose();
      } else if (_attaching) {
        replace();
      } else {
        setState(replace);
      }
    }

    final configuration = _configuration ?? ImageConfiguration.empty;
    _sharpStream = widget.image.resolve(configuration);
    _ambientStream = ResizeImage.resizeIfNeeded(
      384,
      null,
      widget.image,
    ).resolve(configuration);
    _sharpListener = ImageStreamListener(
      (info, _) => frame(info, ambient: false),
      onError: (Object error, StackTrace? trace) {},
    );
    _ambientListener = ImageStreamListener(
      (info, _) => frame(info, ambient: true),
      onError: (Object error, StackTrace? trace) {},
    );
    _attaching = true;
    _sharpStream!.addListener(_sharpListener!);
    _ambientStream!.addListener(_ambientListener!);
    _attaching = false;
  }

  void _detach() {
    if (_sharpListener != null) _sharpStream?.removeListener(_sharpListener!);
    if (_ambientListener != null) {
      _ambientStream?.removeListener(_ambientListener!);
    }
    _sharpStream = _ambientStream = null;
    _sharpListener = _ambientListener = null;
  }

  @override
  void dispose() {
    _detach();
    _sharp?.dispose();
    _ambient?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: ClipRect(
        child: CustomPaint(
          painter: _ExtendedArtworkPainter(
            sharp: _sharp?.image,
            ambient: _ambient?.image,
            alignment: widget.alignment,
            insets: widget.contentInsets,
            featherSides: widget.featherSides,
            shadeLeading: widget.shadeLeading,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

/// A uniform contain transform. Its whole source rectangle remains visible,
/// independent of poster orientation and the window's aspect ratio.
Rect cinemaArtworkCompositionRect({
  required Size source,
  required Size viewport,
  EdgeInsets insets = const EdgeInsets.fromLTRB(24, 24, 24, 56),
  Alignment alignment = Alignment.center,
}) {
  if (source.isEmpty || viewport.isEmpty) return Rect.zero;
  // Short windows keep an actual picture area instead of consuming it with
  // fixed margins. These are extension banks, not a crop into the source.
  final horizontal = insets.horizontal > viewport.width * .22
      ? viewport.width * .22 / insets.horizontal
      : 1.0;
  final vertical = insets.vertical > viewport.height * .40
      ? viewport.height * .40 / insets.vertical
      : 1.0;
  final available = Rect.fromLTRB(
    insets.left * horizontal,
    insets.top * vertical,
    viewport.width - insets.right * horizontal,
    viewport.height - insets.bottom * vertical,
  );
  final fitted = applyBoxFit(BoxFit.contain, source, available.size);
  return alignment.inscribe(fitted.destination, available);
}

class _ExtendedArtworkPainter extends CustomPainter {
  const _ExtendedArtworkPainter({
    required this.sharp,
    required this.ambient,
    required this.alignment,
    required this.insets,
    required this.featherSides,
    required this.shadeLeading,
  });

  final ui.Image? sharp, ambient;
  final Alignment alignment;
  final EdgeInsets insets;
  final bool featherSides, shadeLeading;

  void _mask(Canvas canvas, Rect bounds, Rect picture) {
    final vertical = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: [
        0,
        picture.top / bounds.height,
        picture.bottom / bounds.height,
        1,
      ],
      colors: const [
        Colors.transparent,
        Colors.white,
        Colors.white,
        Colors.transparent,
      ],
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = vertical.createShader(bounds)
        ..blendMode = BlendMode.dstIn,
    );
    if (featherSides) {
      final horizontal = LinearGradient(
        stops: [
          0,
          picture.left / bounds.width,
          picture.right / bounds.width,
          1,
        ],
        colors: const [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = horizontal.createShader(bounds)
          ..blendMode = BlendMode.dstIn,
      );
    }
  }

  void _seamMask(Canvas canvas, Rect bounds, Rect picture) {
    void axis(bool vertical) {
      final length = vertical ? bounds.height : bounds.width;
      final start = vertical ? picture.top : picture.left;
      final end = vertical ? picture.bottom : picture.right;
      final gradient = LinearGradient(
        begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
        end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
        stops: [
          0,
          math.max(0, start - 32) / length,
          start / length,
          end / length,
          math.min(length, end + 32) / length,
          1,
        ],
        colors: const [
          Colors.transparent,
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
          Colors.transparent,
        ],
      );
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = gradient.createShader(bounds)
          ..blendMode = BlendMode.dstIn,
      );
    }

    axis(true);
    axis(false);
  }

  ui.ImageShader _extendedShader(ui.Image image, Rect picture) =>
      ui.ImageShader(
        image,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Float64List.fromList([
          picture.width / image.width,
          0,
          0,
          0,
          0,
          picture.height / image.height,
          0,
          0,
          0,
          0,
          1,
          0,
          picture.left,
          picture.top,
          0,
          1,
        ]),
        filterQuality: FilterQuality.medium,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final image = sharp;
    if (image == null || size.isEmpty) return;
    final bounds = Offset.zero & size;
    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final picture = cinemaArtworkCompositionRect(
      source: source.size,
      viewport: size,
      insets: insets,
      alignment: alignment,
    );
    // Clamp samples beyond the source edges before Gaussian diffusion. The
    // original picture is painted separately, so only the added field can blur.
    final field = ambient;
    if (field != null) {
      final shader = _extendedShader(field, picture);
      canvas.saveLayer(bounds, Paint());
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = shader
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: 28,
            sigmaY: 28,
            tileMode: ui.TileMode.clamp,
          ),
      );
      _mask(canvas, bounds, picture);
      canvas.restore();
      shader.dispose();
    }
    // Start the extension at the exact border colour and blend to the diffuse
    // field over 32px. This prevents a sharp brightness seam around the picture.
    final seam = _extendedShader(image, picture);
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..shader = seam);
    _seamMask(canvas, bounds, picture);
    _mask(canvas, bounds, picture);
    canvas.restore();
    seam.dispose();
    canvas.drawImageRect(
      image,
      source,
      picture,
      Paint()..filterQuality = FilterQuality.high,
    );
    if (shadeLeading) {
      // A light text-side scrim changes luminance, never composition or alpha.
      canvas.drawRect(
        picture,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0x4009090B), Color(0x0009090B)],
            stops: [0, .65],
          ).createShader(picture),
      );
    }
  }

  @override
  bool shouldRepaint(_ExtendedArtworkPainter oldDelegate) =>
      oldDelegate.sharp != sharp ||
      oldDelegate.ambient != ambient ||
      oldDelegate.alignment != alignment ||
      oldDelegate.insets != insets ||
      oldDelegate.featherSides != featherSides ||
      oldDelegate.shadeLeading != shadeLeading;
}
