import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

import 'cinema_poster_palette.dart';
import 'douban/douban_image_headers.dart';

/// Poster sampling is decorative: it never holds the playback/first-frame gate.
/// Encoded images share the existing proxy-aware cache; decoding stays small.
class CinemaPlayerPosterLight extends StatefulWidget {
  const CinemaPlayerPosterLight({
    super.key,
    required this.posterUrl,
    this.image,
    required this.builder,
  });

  final String posterUrl;
  final ImageProvider? image;
  final Widget Function(BuildContext context, Color color, bool resolved)
  builder;

  @override
  State<CinemaPlayerPosterLight> createState() =>
      _CinemaPlayerPosterLightState();
}

class _CinemaPlayerPosterLightState extends State<CinemaPlayerPosterLight> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  var _ticket = 0;
  bool _initialized = false;
  bool _resolved = false;
  Timer? _deadline;
  Color _color = cinemaNeutralLampColor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _attach();
    }
  }

  @override
  void didUpdateWidget(CinemaPlayerPosterLight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.posterUrl != oldWidget.posterUrl ||
        widget.image != oldWidget.image) {
      _attach();
    }
  }

  void _detach() {
    final stream = _stream, listener = _listener;
    _stream = null;
    _listener = null;
    if (stream != null && listener != null) stream.removeListener(listener);
  }

  void _attach() {
    _deadline?.cancel();
    _deadline = null;
    _detach();
    final ticket = ++_ticket;
    _color = cinemaNeutralLampColor;
    _resolved = false;
    final url = widget.posterUrl.trim();
    final image =
        widget.image ??
        (url.isEmpty
            ? null
            : ResizeImage(
                CachedNetworkImageProvider(
                  url,
                  cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
                  headers:
                      Uri.tryParse(url)?.host.endsWith('.doubanio.com') == true
                      ? doubanImageHeaders
                      : null,
                ),
                width: 160,
                height: 240,
                policy: ResizeImagePolicy.fit,
              ));
    if (image == null) {
      _resolved = true;
      return;
    }
    // Resolve a final color before exposing the lamp. A timeout locks neutral
    // for this poster; a later image must not recolor an already visible lamp.
    _deadline = Timer(const Duration(seconds: 2), () {
      _finish(cinemaNeutralLampColor, ticket);
    });
    final stream = _stream = image.resolve(
      createLocalImageConfiguration(context),
    );
    final listener = _listener = ImageStreamListener(
      (frame, synchronous) {
        if (!mounted || ticket != _ticket || _resolved) {
          frame.dispose();
          return;
        }
        // The sampler clones before awaiting readback, so frame ownership ends here.
        final palette = cinemaPosterPalette(frame.image);
        frame.dispose();
        _detach();
        unawaited(
          palette.then(
            (colors) {
              _finish(cinemaPosterLampColor(colors), ticket);
            },
            onError: (Object error, StackTrace stack) {
              _finish(cinemaNeutralLampColor, ticket);
            },
          ),
        );
      },
      onError: (Object error, StackTrace? stack) {
        _finish(cinemaNeutralLampColor, ticket);
      },
    );
    stream.addListener(listener);
  }

  void _finish(Color color, int ticket) {
    if (!mounted || ticket != _ticket || _resolved) return;
    _deadline?.cancel();
    _deadline = null;
    _detach();
    setState(() {
      _color = color;
      _resolved = true;
    });
  }

  @override
  void dispose() {
    _ticket++;
    _deadline?.cancel();
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _color, _resolved);
}
