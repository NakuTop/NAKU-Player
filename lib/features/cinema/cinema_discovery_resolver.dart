import 'package:flutter/material.dart';

import 'cinema_models.dart';
import 'cinema_repository.dart';
import 'cinema_theme.dart';
import 'cinema_work_sources.dart';

/// Resolve a catalogue-only work into real source identities before opening
/// details. Finding a source entry does not claim that its stream is playable.
Future<List<CinemaTitle>?> resolveCinemaDiscoverySources(
  BuildContext context, {
  required CinemaTitle anchor,
  required List<CinemaSource> sources,
  required CinemaRepository repository,
}) async {
  if (!context.mounted) return null;
  final available = List<CinemaSource>.unmodifiable(
    sources.where(
      (source) =>
          source.enabled &&
          source.kind == CinemaSourceKind.maccms &&
          source.id != 'douban-discovery',
    ),
  );
  return showDialog<List<CinemaTitle>>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) => Theme(
      data: CinemaTheme.of(dialogContext),
      child: _DiscoveryDialog(
        anchor: anchor,
        sources: available,
        repository: repository,
        callerMounted: () => context.mounted,
      ),
    ),
  );
}

class _DiscoveryDialog extends StatefulWidget {
  const _DiscoveryDialog({
    required this.anchor,
    required this.sources,
    required this.repository,
    required this.callerMounted,
  });

  final CinemaTitle anchor;
  final List<CinemaSource> sources;
  final CinemaRepository repository;
  final bool Function() callerMounted;

  @override
  State<_DiscoveryDialog> createState() => _DiscoveryDialogState();
}

class _DiscoveryDialogState extends State<_DiscoveryDialog> {
  ModalRoute<dynamic>? _route;
  bool _started = false, _closed = false, _complete = false, _failed = false;
  List<CinemaTitle> _variants = const [];

  bool get _current =>
      mounted &&
      !_closed &&
      widget.callerMounted() &&
      _route?.isCurrent == true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _route = ModalRoute.of(context);
    _resolve();
  }

  Future<void> _resolve() async {
    final sourceIds = widget.sources.map((source) => source.id).toSet();
    try {
      await for (final found in discoverCinemaWorkSources(
        anchor: widget.anchor,
        known: const [],
        sources: widget.sources,
        repository: widget.repository,
        isCurrent: () => _current,
      )) {
        if (!_current) return;
        setState(() {
          _variants = List.unmodifiable(
            found.where(
              (title) =>
                  title.sourceId != 'douban-discovery' &&
                  sourceIds.contains(title.sourceId),
            ),
          );
        });
      }
      if (!_current) return;
      if (_variants.isNotEmpty) {
        _finish(_variants);
      } else {
        setState(() => _complete = true);
      }
    } catch (_) {
      if (!_current) return;
      if (_variants.isNotEmpty) {
        _finish(_variants);
      } else {
        setState(() {
          _complete = true;
          _failed = true;
        });
      }
    }
  }

  void _finish(List<CinemaTitle>? result) {
    if (!_current) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  @override
  void dispose() {
    // In-flight requests can finish, but cannot start another batch or pop the
    // caller's next page after this dialog has been dismissed.
    _closed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final source in widget.sources) source.id: source.name};
    final foundSources = _variants.map((title) => title.sourceId).toSet();
    return PopScope<List<CinemaTitle>>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _closed = true;
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 440,
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: CinemaGlass(
            radius: 24,
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _complete
                            ? Icons.search_off_rounded
                            : Icons.hub_outlined,
                        color: CinemaTheme.copper,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _complete ? '暂未找到匹配的片源' : '正在查找播放线路',
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.anchor.title,
                    style: const TextStyle(fontSize: 16),
                  ),
                  if (widget.anchor.year.isNotEmpty ||
                      widget.anchor.category.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      [
                        widget.anchor.year,
                        widget.anchor.category,
                      ].where((text) => text.isNotEmpty).join(' · '),
                      style: const TextStyle(color: CinemaTheme.muted),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (!_complete) ...[
                    const LinearProgressIndicator(minHeight: 3),
                    const SizedBox(height: 12),
                    Text(
                      foundSources.isEmpty
                          ? '正在查询 ${widget.sources.length} 个已启用片源…'
                          : '已找到 ${foundSources.length} 个片源，继续查找其他线路…',
                      style: const TextStyle(color: CinemaTheme.muted),
                    ),
                  ] else
                    Text(
                      widget.sources.isEmpty
                          ? '当前没有启用的电影与剧集片源。'
                          : _failed
                          ? '暂时无法查询片源，请稍后重试。'
                          : '已查询当前启用的片源，未找到同年份、同类型的作品。请调整片源或稍后重试。',
                      style: const TextStyle(color: CinemaTheme.muted),
                    ),
                  if (foundSources.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final id in foundSources)
                          Chip(
                            avatar: const Icon(
                              Icons.check_rounded,
                              color: CinemaTheme.copper,
                              size: 16,
                            ),
                            label: Text(names[id] ?? id),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 22),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => _finish(null),
                          child: Text(_complete ? '关闭' : '取消'),
                        ),
                        if (_variants.isNotEmpty)
                          FilledButton(
                            onPressed: () => _finish(_variants),
                            child: const Text('打开已找到的线路'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
