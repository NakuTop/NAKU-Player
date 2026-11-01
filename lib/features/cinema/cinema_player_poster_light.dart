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
  final Widget Function(BuildContext context, Color color) builder;

  @override
  State<CinemaPlayerPosterLight> createState() =>
      _CinemaPlayerPosterLightState();
}

class _CinemaPlayerPosterLightState extends State<CinemaPlayerPosterLight> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  var _ticket = 0;
  bool _initialized = false;
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
    _detach();
    final ticket = ++_ticket;
    _color = cinemaNeutralLampColor;
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
    if (image == null) return;
    final stream = _stream = image.resolve(
      createLocalImageConfiguration(context),
    );
    final listener = _listener = ImageStreamListener(
      (frame, synchronous) {
        if (!mounted || ticket != _ticket) {
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
              if (mounted && ticket == _ticket) {
                setState(() => _color = cinemaPosterLampColor(colors));
              }
            },
            onError: (Object error, StackTrace stack) {
              // Missing/failed artwork keeps neutral light and never affects playback.
            },
          ),
        );
      },
      onError: (Object error, StackTrace? stack) {
        if (ticket == _ticket) _detach();
      },
    );
    stream.addListener(listener);
  }

  @override
  void dispose() {
    _ticket++;
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _color);
}
