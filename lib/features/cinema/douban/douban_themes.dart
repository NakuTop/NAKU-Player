import 'douban_models.dart';

/// Session-wide discoveries. Old responses cannot freeze out newer topics, and
/// reopening the board does not discard topics already returned by Douban.
class DoubanThemeCatalog {
  static final shared = DoubanThemeCatalog();
  static const capacity = 240;
  final _topics = <DoubanKind, List<String>>{};

  List<String> topics(DoubanKind kind) =>
      List.unmodifiable(_topics[kind] ?? const <String>[]);

  List<String> remember(
    DoubanKind kind,
    Iterable<String> incoming, {
    Iterable<String> selected = const [],
  }) {
    final pinned = selected.toSet();
    final values = {...?_topics[kind]};
    for (final value in [...incoming, ...selected]) {
      final topic = value.trim();
      if (topic.isNotEmpty &&
          topic.length <= 120 &&
          !RegExp(r'[,\x00-\x1f\x7f]').hasMatch(topic)) {
        values.add(topic);
      }
    }
    while (values.length > capacity) {
      final removable = values.where((topic) => !pinned.contains(topic));
      if (removable.isEmpty) break;
      values.remove(removable.first);
    }
    return _topics[kind] = values.toList();
  }
}
