import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'cinema_models.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_seasons.dart';
import 'cinema_variety_episode.dart';

class CinemaShowChoice {
  CinemaShowChoice(this.candidate)
    : info = CinemaShowEpisode(
        candidate.episode.name,
        bonusCollection: cinemaVarietyEdition.hasMatch(candidate.title.title),
      );
  final CinemaPlaybackCandidate candidate;
  final CinemaShowEpisode info;
  String label = '';
}

class CinemaShowGuide {
  List<CinemaTitle> _titles = [];
  int? _road;
  List<CinemaShowChoice> _rows = [];
  List<CinemaShowChoice> build(
    List<CinemaTitle> titles,
    CinemaSource Function(CinemaTitle) source, {
    int? road,
  }) {
    if (listEquals(_titles, titles) && _road == road) return _rows;
    _titles = List.of(titles);
    _road = road;
    final guides = <List<CinemaShowChoice>>[];
    for (final t in titles) {
      for (final (r, route) in t.routes.indexed) {
        if (road != null && road != r) continue;
        final seen = <String>{};
        guides.add([
          for (final (i, e) in route.episodes.indexed)
            if (e.url.isNotEmpty && seen.add(e.url))
              CinemaShowChoice(
                CinemaPlaybackCandidate(
                  title: t,
                  source: source(t),
                  routeIndex: r,
                  episodeIndex: i,
                ),
              ),
        ]);
      }
    }
    final result = <CinemaShowChoice>[];
    for (final type in CinemaShowSection.values) {
      final lists = guides
          .map((g) => g.where((e) => e.info.section == type).toList())
          .where((g) => g.isNotEmpty)
          .toList();
      if (lists.isEmpty) continue;
      if (type != CinemaShowSection.pure) {
        // Retain one consistent broadcast guide per section. A season projection can
        // also contain anonymous provider indexes that are not broadcast numbers.
        int score(List<CinemaShowChoice> g) =>
            (cinemaIsSeasonProjection(g.first.candidate.title) ? 0 : 100000) +
            g.where((e) => e.info.issue.isNotEmpty).length.clamp(0, 999) * 100 +
            g.length.clamp(0, 99);
        var guide = lists.first;
        for (final g in lists.skip(1)) {
          if (score(g) > score(guide)) guide = g;
        }
        result.addAll(guide);
        continue;
      }
      final named = <String, CinemaShowChoice>{};
      final slots = <String, Set<String>>{};
      final issues = <String, Set<String>>{};
      final parts = <String, Set<String>>{};
      for (final g in lists) {
        for (final e in g.where((e) => e.info.namedPure)) {
          final x = e.info;
          if (x.part.isNotEmpty) (parts[x.pureKey] ??= {}).add(x.part);
        }
      }
      String key(CinemaShowEpisode x) =>
          parts[x.pureKey] != null && parts[x.pureKey]!.length > 1
          ? '${x.pureKey}/${x.part}'
          : x.pureKey;
      for (final g in lists) {
        for (final e in g.where((e) => e.info.namedPure)) {
          final x = e.info, k = key(x);
          for (final slot in [x.slot, x.dateSlot]) {
            if (slot.isNotEmpty) (slots[slot] ??= {}).add(k);
          }
          if (x.issue.isNotEmpty) (issues[k] ??= {}).add(x.issue);
          final old = named[k];
          if (old == null ||
              cinemaIsSeasonProjection(old.candidate.title) &&
                  !cinemaIsSeasonProjection(e.candidate.title))
            named[k] = e;
        }
      }
      final ordered = named.entries.toList()
        ..sort((a, b) => a.value.info.day.compareTo(b.value.info.day));
      for (final entry in ordered) {
        final e = entry.value, x = e.info, ns = issues[entry.key];
        final n = ns?.length == 1 ? ns!.single : x.issue;
        final p = parts[x.pureKey];
        final half = x.part.isNotEmpty
            ? x.part
            : p?.length == 1
            ? p!.single
            : '';
        e.label = [
          if (n.isNotEmpty) '第$n期$half',
          if (x.day.isNotEmpty) n.isEmpty ? '${x.day}$half' : x.day,
          x.clip,
        ].join(' · ');
        result.add(e);
      }
      final anonymous = <String, List<CinemaShowChoice>>{};
      for (final g in lists) {
        final local = <String, List<CinemaShowChoice>>{};
        for (final e in g.where((e) => !e.info.namedPure)) {
          (local[e.info.text] ??= []).add(e);
        }
        for (final entry in local.entries) {
          final x = entry.value.first.info;
          if (x.clip.isEmpty &&
              [x.slot, x.dateSlot].any(
                (slot) =>
                    slot.isNotEmpty &&
                    (slots[slot]?.length ?? 0) >= entry.value.length,
              ))
            continue;
          if (entry.value.length > (anonymous[entry.key]?.length ?? 0))
            anonymous[entry.key] = entry.value;
        }
      }
      for (final options in anonymous.values) {
        result.addAll(options);
      }
    }
    final counts = <String, int>{}, seen = <String, int>{};
    for (final row in result) {
      if (row.label.isEmpty) row.label = row.info.text;
      final key = '${row.info.section}/${row.label}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    for (final row in result) {
      final key = '${row.info.section}/${row.label}';
      if (counts[key]! > 1) {
        final i = (seen[key] ?? 0) + 1;
        seen[key] = i;
        row.label += ' · 片段 $i';
      }
    }
    return _rows = result;
  }
}

class CinemaShowPicker extends StatefulWidget {
  const CinemaShowPicker({
    super.key,
    required this.choices,
    required this.select,
    this.reverse = false,
    this.current,
  });
  final List<CinemaShowChoice> choices;
  final ValueChanged<CinemaPlaybackCandidate> select;
  final bool reverse;
  final CinemaPlaybackCandidate? current;
  @override
  State<CinemaShowPicker> createState() => _CinemaShowPickerState();
}

class _CinemaShowPickerState extends State<CinemaShowPicker> {
  CinemaShowSection? _section = CinemaShowSection.main;
  String _query = '';
  final _input = TextEditingController();
  final _scroll = ScrollController();
  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _isCurrent(CinemaShowChoice row) {
    final c = widget.current;
    return c != null &&
        (row.candidate.key == c.key ||
            row.candidate.episode.url == c.episode.url ||
            row.info.sameClip(CinemaShowEpisode(c.episode.name)));
  }

  void _locate(CinemaShowChoice row) {
    _input.clear();
    setState(() {
      _query = '';
      _section = row.info.section;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final group = widget.choices
          .where((c) => c.info.section == row.info.section)
          .toList();
      final i = group.indexOf(row);
      if (i < 0) return;
      _scroll.jumpTo(
        ((widget.reverse ? group.length - 1 - i : i) * 48.0).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
      Scrollable.ensureVisible(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.choices.map((c) => c.info.section).toSet();
    if (available.isEmpty) return const SizedBox.shrink();
    final type = _section == null || available.contains(_section)
        ? _section
        : available.first;
    final q = CinemaShowEpisode.searchText(_query).trim().toLowerCase();
    final terms = q.split(RegExp(r"\s+"));
    // Typing searches every section, including clips outside the current tab.
    final matches = widget.choices.where((c) {
      if (type != null && c.info.section != type) return false;
      if (q.isEmpty) return true;
      final haystack = CinemaShowEpisode.searchText(
        '${c.label} ${c.info.text} ${c.info.section.label}',
      ).toLowerCase();
      return terms.every(haystack.contains);
    });
    final rows = (widget.reverse ? matches.toList().reversed : matches)
        .toList();
    final current = widget.current == null
        ? null
        : widget.choices.where(_isCurrent).firstOrNull;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _input,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索期数、日期或片段名',
              suffixIcon: current == null
                  ? null
                  : IconButton(
                      tooltip: '定位当前集',
                      icon: const Icon(Icons.my_location),
                      onPressed: () => _locate(current),
                    ),
            ),
            onChanged: (v) => setState(() {
              if (_query.isEmpty && v.isNotEmpty) _section = null;
              _query = v;
            }),
          ),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: type == null,
                onSelected: (_) => setState(() => _section = null),
              ),
              for (final s in CinemaShowSection.values)
                if (available.contains(s))
                  ChoiceChip(
                    label: Text(s.label),
                    selected: type == s,
                    onSelected: (_) => setState(() => _section = s),
                  ),
            ],
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('没有匹配的期数或片段'),
            )
          else
            SizedBox(
              height: (rows.length * 48.0).clamp(48.0, 288.0),
              child: Material(
                type: MaterialType.transparency,
                child: ListView.builder(
                  key: ValueKey((type, q)),
                  controller: _scroll,
                  primary: false,
                  itemExtent: 48,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => ListTile(
                    selected: identical(rows[i], current),
                    title: Text(
                      rows[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => widget.select(rows[i].candidate),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
