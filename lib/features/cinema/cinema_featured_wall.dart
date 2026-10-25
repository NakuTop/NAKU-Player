import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

import 'cinema_media_identity.dart';
import 'cinema_models.dart';
import 'cinema_theme.dart';
import 'cinema_artwork_backdrop.dart';
import 'douban/douban_image_headers.dart';

/// A real catalogue selection; these titles are excluded from the wall below.
class CinemaFeaturedWall extends StatefulWidget {
  const CinemaFeaturedWall({
    super.key,
    required this.titles,
    required this.onOpen,
    this.statusBuilder,
    this.topInset = 0,
  });

  final List<CinemaTitle> titles;
  final ValueChanged<CinemaTitle> onOpen;
  final Widget Function(CinemaTitle)? statusBuilder;
  final double topInset;

  @override
  State<CinemaFeaturedWall> createState() => _CinemaFeaturedWallState();
}

class _CinemaFeaturedWallState extends State<CinemaFeaturedWall>
    with WidgetsBindingObserver {
  final PageController _pages = PageController(keepPage: false);
  int _index = 0;
  int _dataGeneration = 0;
  Timer? _timer;
  Timer? _wheelEnd;
  bool _hovered = false;
  bool _focused = false;
  bool _active = true;
  bool _tickerMode = true;
  bool _reduced = false;
  bool _scrolling = false;
  bool _wheelActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.valuesOf(context).enabled;
    _reduced =
        MediaQuery.disableAnimationsOf(context) ||
        CinemaAppearanceScope.of(context).reduceMotion;
    if (!_tickerMode || _reduced) _cancelWheelAndSnap();
    _schedule();
  }

  @override
  void didUpdateWidget(CinemaFeaturedWall oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKeys = oldWidget.titles.map((title) => title.key).toList();
    final newKeys = widget.titles.map((title) => title.key).toList();
    if (!listEquals(oldKeys, newKeys)) {
      final selectedKey = oldKeys.isEmpty
          ? null
          : oldKeys[_index.clamp(0, oldKeys.length - 1)];
      final retained = selectedKey == null ? -1 : newKeys.indexOf(selectedKey);
      _index = retained < 0 ? 0 : retained;
      _wheelEnd?.cancel();
      _wheelActive = false;
      _scrolling = false;
      final generation = ++_dataGeneration;
      final retainedIndex = _index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _dataGeneration && _pages.hasClients) {
          _pages.jumpToPage(retainedIndex);
        }
      });
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) _cancelWheelAndSnap();
    _schedule();
  }

  bool get _canRotate =>
      mounted &&
      _active &&
      _tickerMode &&
      !_reduced &&
      !_hovered &&
      !_focused &&
      !_scrolling &&
      widget.titles.length > 1;

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!_canRotate) return;
    _timer = Timer(const Duration(seconds: 9), () {
      if (!_canRotate) return;
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final top = box.localToGlobal(Offset.zero).dy;
        if (top < MediaQuery.sizeOf(context).height &&
            top + box.size.height > 0) {
          _select((_index + 1) % widget.titles.length);
        }
      }
      _schedule();
    });
  }

  void _select(int index) {
    if (widget.titles.isEmpty || !_pages.hasClients) return;
    final target = index.clamp(0, widget.titles.length - 1);
    _wheelEnd?.cancel();
    _wheelActive = false;
    if (_reduced) {
      _pages.jumpToPage(target);
    } else {
      _pages.animateToPage(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
    _schedule();
  }

  // On macOS, smooth horizontal trackpad scrolling may arrive as wheel signals
  // rather than pan/zoom gestures. Keep those deltas under the finger, then snap
  // once the stream stops. A vertical wheel remains available to the film wall.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_pages.hasClients) return;
    final shifted =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.isShiftPressed;
    final delta = shifted ? event.scrollDelta.dy : event.scrollDelta.dx;
    final crossDelta = shifted ? event.scrollDelta.dx : event.scrollDelta.dy;
    if (delta == 0 || delta.abs() < crossDelta.abs()) return;
    final position = _pages.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _wheelActive = true;
      _pages.position.pointerScroll(delta);
      event.respond(allowPlatformDefault: false);
      _wheelEnd?.cancel();
      _wheelEnd = Timer(const Duration(milliseconds: 120), () {
        if (!mounted || !_active || !_tickerMode || !_pages.hasClients) return;
        _wheelActive = false;
        final page = _pages.page;
        if (page != null) _select(page.round());
      });
    });
  }

  void _cancelWheelAndSnap() {
    if (!_wheelActive) return;
    _wheelEnd?.cancel();
    _wheelActive = false;
    final generation = _dataGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _dataGeneration || !_pages.hasClients) {
        return;
      }
      final page = _pages.page;
      if (page != null) _pages.jumpToPage(page.round());
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _scrolling = true;
      if (notification.dragDetails != null) {
        _wheelEnd?.cancel();
        _wheelActive = false;
      }
      _schedule();
    } else if (notification is ScrollEndNotification) {
      _scrolling = false;
      _schedule();
    }
    return false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _wheelEnd?.cancel();
    _pages.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.titles.isEmpty) return const SizedBox.shrink();
    final wide = MediaQuery.sizeOf(context).width > 1200;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) {
        _hovered = true;
        _schedule();
      },
      onExit: (_) {
        _hovered = false;
        _schedule();
      },
      child: Focus(
        key: const ValueKey('cinema-featured-focus'),
        onFocusChange: (value) {
          _focused = value;
          _schedule();
        },
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _select(_index - 1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _select(_index + 1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SizedBox(
          height: (wide ? 410 : 350) + widget.topInset,
          child: Stack(
            fit: StackFit.expand,
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: PageView.builder(
                  key: const ValueKey('cinema-featured-pages'),
                  controller: _pages,
                  pageSnapping: false,
                  scrollBehavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                    dragDevices: {
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.touch,
                      PointerDeviceKind.trackpad,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                    },
                  ),
                  physics: _FeaturedPagePhysics(
                    wheelActive: () => _wheelActive,
                    parent: const BouncingScrollPhysics(),
                  ),
                  itemCount: widget.titles.length,
                  onPageChanged: (index) {
                    setState(() => _index = index);
                    _schedule();
                  },
                  itemBuilder: (context, index) => Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerSignal: _onPointerSignal,
                    child: _artwork(widget.titles[index], wide: wide),
                  ),
                ),
              ),
              Positioned(
                right: 26,
                bottom: 31,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < widget.titles.length; index++)
                      Semantics(
                        selected: _index == index,
                        child: IconButton(
                          tooltip: '查看${widget.titles[index].title}',
                          onPressed: () => _select(index),
                          constraints: const BoxConstraints(
                            minWidth: 29,
                            minHeight: 36,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          icon: AnimatedContainer(
                            duration: _reduced
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            width: _index == index ? 18 : 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: _index == index
                                  ? Colors.white
                                  : Colors.white38,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artwork(CinemaTitle title, {required bool wide}) {
    return Stack(
      key: ValueKey('cinema-featured-${title.key}'),
      fit: StackFit.expand,
      children: [
        if (title.poster.isNotEmpty)
          CachedNetworkImage(
            imageUrl: title.poster,
            cacheManager: ProxyAwareImageCacheManager.cinemaInstance,
            httpHeaders: title.sourceId == 'douban-discovery'
                ? doubanImageHeaders
                : null,
            memCacheWidth: 1600,
            fadeInDuration: Duration.zero,
            fit: BoxFit.cover,
            alignment: const Alignment(.4, -.65),
            imageBuilder: (_, provider) => CinemaArtworkBackdrop(
              image: provider,
              alignment: const Alignment(.4, -.65),
              featherSides: true,
            ),
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        IgnorePointer(
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: [0, .18, .72, 1],
            ).createShader(bounds),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xA609090B),
                    Color(0x2009090B),
                    Color(0x0009090B),
                  ],
                  stops: [0, .5, 1],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            wide ? 38 : 26,
            30 + widget.topInset,
            26,
            31,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.statusBuilder != null) widget.statusBuilder!(title),
              const Spacer(),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: wide ? 570 : 460),
                child: Text(
                  cinemaMediaBaseTitle(title.title),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: wide ? 46 : 38,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.8,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 13),
              Text(
                [
                  title.year,
                  title.category,
                  title.durationText,
                ].where((text) => text.isNotEmpty).join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xBFFFFFFF)),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: () => widget.onOpen(title),
                icon: const Icon(Icons.play_arrow_rounded, size: 21),
                label: const Text('查看影片'),
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFF151515),
                  backgroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 23,
                    vertical: 17,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Delay snapping until a horizontal wheel stream ends. Pointer pan/zoom and
/// mouse drags retain Flutter's normal distance/velocity page physics.
class _FeaturedPagePhysics extends PageScrollPhysics {
  const _FeaturedPagePhysics({required this.wheelActive, super.parent});

  final bool Function() wheelActive;

  @override
  _FeaturedPagePhysics applyTo(ScrollPhysics? ancestor) => _FeaturedPagePhysics(
    wheelActive: wheelActive,
    parent: buildParent(ancestor),
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (wheelActive()) return null;
    return super.createBallisticSimulation(position, velocity);
  }
}
