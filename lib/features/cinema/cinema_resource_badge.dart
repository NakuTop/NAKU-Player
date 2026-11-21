import 'dart:async';
import 'package:flutter/material.dart';
import 'cinema_models.dart';
import 'cinema_resource_availability.dart';
import 'cinema_scroll_activity.dart';
import 'cinema_theme.dart';

class CinemaResourceBadge extends StatefulWidget {
  const CinemaResourceBadge({
    super.key,
    required this.title,
    required this.sources,
    required this.service,
    this.compact = false,
  });
  final CinemaTitle title;
  final List<CinemaSource> sources;
  final CinemaResourceAvailabilityService service;
  final bool compact;
  @override
  State<CinemaResourceBadge> createState() => _CinemaResourceBadgeState();
}

class _CinemaResourceBadgeState extends State<CinemaResourceBadge> {
  CinemaScrollActivity? _scroll;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scroll = CinemaScrollActivityScope.maybeOf(context);
    if (!identical(scroll, _scroll)) {
      _scroll?.removeListener(_check);
      _scroll = scroll;
      _scroll?.addListener(_check);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(CinemaResourceBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  void _check() {
    if (!mounted || (_scroll?.value ?? false)) return;
    final entry = widget.service.entry(widget.title, widget.sources);
    unawaited(
      widget.service.check(
        widget.title,
        widget.sources,
        isCurrent: () =>
            mounted &&
            identical(
              entry,
              widget.service.entry(widget.title, widget.sources),
            ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<CinemaResourceAvailability>(
        valueListenable: widget.service.entry(widget.title, widget.sources),
        builder: (_, value, _) {
          final label = widget.compact
              ? switch (value.state) {
                  CinemaResourceState.waiting ||
                  CinemaResourceState.checking => '',
                  CinemaResourceState.found =>
                    value.confirmedQualityTier >= 4320
                        ? '8K'
                        : value.confirmedQualityTier >= 2160
                        ? '4K'
                        : '有片源',
                  CinemaResourceState.missing => '暂无片源',
                  CinemaResourceState.incomplete => '待确认',
                  CinemaResourceState.noSources => '未启用片源',
                }
              : value.label;
          if (label.isEmpty) return const SizedBox.shrink();
          return Tooltip(
            message: value.state == CinemaResourceState.found
                ? '已找到带播放线路的片源；实际画质和播放情况以打开后的检测为准'
                : value.state == CinemaResourceState.incomplete
                ? '部分片源超时或不可用，暂时无法确定是否有资源；点击影片可重试'
                : '检查已启用片源 ${value.checked}/${value.total}；暂未找到不代表影片永远没有资源',
            child: Container(
              key: ValueKey('resource-${value.state.name}'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(
                color: widget.compact
                    ? const Color(0xC3242529)
                    : value.state == CinemaResourceState.found
                    ? const Color(0xF2225445)
                    : Colors.black.withValues(alpha: .85),
                borderRadius: BorderRadius.circular(widget.compact ? 7 : 5),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: CinemaTheme.text),
              ),
            ),
          );
        },
      );
}
