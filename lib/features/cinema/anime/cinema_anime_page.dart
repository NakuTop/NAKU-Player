import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_page.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/my/my_page.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/pages/search/search_page.dart';
import 'package:kazumi/pages/timeline/timeline_controller.dart';
import 'package:kazumi/pages/timeline/timeline_page.dart';

import '../cinema_theme.dart';

/// These are local to the NAKU route, independently of the legacy /tab scope.
/// Repositories and library/account coordinators remain application-owned.
void provideCinemaAnimeControllers(Scoped scoped) {
  scoped
    ..add<PopularController>(PopularController.new)
    ..add<TimelineController>(TimelineController.new)
    ..add<SearchPageController>(SearchPageController.new);
}

/// NAKU navigation around the complete original anime pages. Keeping this host
/// mounted preserves each page's filters, requests, input and scroll position.
class CinemaAnimePage extends StatefulWidget {
  const CinemaAnimePage({super.key, this.active = true, this.initialTab = 0});

  final bool active;
  final int initialTab;

  @override
  State<CinemaAnimePage> createState() => _CinemaAnimePageState();
}

class _CinemaAnimePageState extends State<CinemaAnimePage> with RouteAware {
  static const _destinations = <(String, IconData)>[
    ('热门', Icons.local_fire_department_outlined),
    ('时间表', Icons.calendar_month_outlined),
    ('搜索', Icons.search_rounded),
    ('追番', Icons.favorite_border_rounded),
    ('更多', Icons.tune_rounded),
  ];
  final _pages = <int, Widget>{};
  final _focusScope = FocusScopeNode(debugLabel: 'NAKU anime');
  late int _selected = widget.initialTab.clamp(0, _destinations.length - 1);
  bool _covered = false;
  PageRoute<void>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void> && route != _route) {
      rootRouteObserver.unsubscribe(this);
      _route = route;
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(covariant CinemaAnimePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) _focusScope.unfocus();
  }

  @override
  void didPushNext() => _setCovered(true);

  @override
  void didPopNext() => _setCovered(false);

  void _setCovered(bool value) {
    if (mounted && _covered != value) setState(() => _covered = value);
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    _focusScope.dispose();
    super.dispose();
  }

  Widget _page(int index) => _pages.putIfAbsent(
    index,
    () => switch (index) {
      0 => PopularPage(
        controller: context.read<PopularController>(),
        embedded: true,
      ),
      1 => TimelinePage(
        controller: context.read<TimelineController>(),
        embedded: true,
      ),
      2 => SearchPage(
        controller: context.read<SearchPageController>(),
        embedded: true,
      ),
      3 => CollectPage(controller: inject<CollectController>(), embedded: true),
      _ => MyPage(controller: inject<MyController>(), embedded: true),
    },
  );

  void _select(int index) {
    if (index == _selected) return;
    _focusScope.unfocus();
    setState(() => _selected = index);
  }

  @override
  Widget build(BuildContext context) {
    final covered =
        !widget.active || _covered || RouteVisibility.isCoveredOf(context);
    _page(_selected);
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: Colors.transparent,
        ),
      ),
      child: ExcludeFocus(
        excluding: covered,
        child: FocusScope(
          node: _focusScope,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: CinemaGlass(
                  blur: false,
                  radius: 16,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (
                          var index = 0;
                          index < _destinations.length;
                          index++
                        )
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              key: ValueKey('anime-tab-$index'),
                              avatar: Icon(_destinations[index].$2, size: 18),
                              label: Text(_destinations[index].$1),
                              selected: index == _selected,
                              showCheckmark: false,
                              onSelected: (_) => _select(index),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Original pages size their lazy grids using MediaQuery. This
                    // viewport excludes NAKU's sidebar and the anime navigation.
                    final media = MediaQuery.of(context);
                    return MediaQuery(
                      data: media.copyWith(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                        padding: media.padding.copyWith(
                          top: 0,
                          left: 0,
                          right: 0,
                        ),
                      ),
                      child: IndexedStack(
                        index: _selected,
                        sizing: StackFit.expand,
                        children: [
                          for (
                            var index = 0;
                            index < _destinations.length;
                            index++
                          )
                            RouteVisibility(
                              isCovered: covered || index != _selected,
                              child: TickerMode(
                                enabled: !covered && index == _selected,
                                child: ExcludeFocus(
                                  excluding: covered || index != _selected,
                                  child: HeroMode(
                                    enabled:
                                        widget.active && index == _selected,
                                    child:
                                        _pages[index] ??
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
