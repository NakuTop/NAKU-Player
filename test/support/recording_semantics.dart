import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';

/// Records the native update stream, including nodes omitted by the final
/// render-tree dump. Desktop AXTree accepts only nodes reachable from root 0.
class RecordingSemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  final nodes = <int, List<int>>{};
  final violations = <String>[];
  final adjustableNodes = <int>{};
  int commits = 0;

  void resetRecording() {
    nodes.clear();
    violations.clear();
    adjustableNodes.clear();
    commits = 0;
  }

  @override
  SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingUpdate(this);
}

class _RecordingUpdate extends Fake implements SemanticsUpdateBuilder {
  _RecordingUpdate(this.binding);
  final RecordingSemanticsBinding binding;
  final _builder = SemanticsUpdateBuilder();
  final updates = <int, List<int>>{};
  final labels = <int, String>{};

  @override
  void updateNode({
    required int id,
    required SemanticsFlags flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required int traversalParent,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required Rect rect,
    required String identifier,
    required String label,
    required List<StringAttribute> labelAttributes,
    required String value,
    required List<StringAttribute> valueAttributes,
    required String increasedValue,
    required List<StringAttribute> increasedValueAttributes,
    required String decreasedValue,
    required List<StringAttribute> decreasedValueAttributes,
    required String hint,
    required List<StringAttribute> hintAttributes,
    required String tooltip,
    required TextDirection? textDirection,
    required Float64List transform,
    required Float64List hitTestTransform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String linkUrl = '',
    SemanticsRole role = SemanticsRole.none,
    required List<String>? controlsNodes,
    SemanticsValidationResult validationResult = SemanticsValidationResult.none,
    SemanticsHitTestBehavior hitTestBehavior = SemanticsHitTestBehavior.defer,
    required SemanticsInputType inputType,
    required Locale? locale,
    required String minValue,
    required String maxValue,
  }) {
    updates[id] = childrenInTraversalOrder.toList();
    labels[id] = label;
    if (flags.isSlider && (actions & SemanticsAction.increase.index) != 0 &&
        (actions & SemanticsAction.decrease.index) != 0) {
      binding.adjustableNodes.add(id);
    } else {
      binding.adjustableNodes.remove(id);
    }
    _builder.updateNode(
      id: id,
      flags: flags,
      actions: actions,
      maxValueLength: maxValueLength,
      currentValueLength: currentValueLength,
      textSelectionBase: textSelectionBase,
      textSelectionExtent: textSelectionExtent,
      platformViewId: platformViewId,
      scrollChildren: scrollChildren,
      scrollIndex: scrollIndex,
      traversalParent: traversalParent,
      scrollPosition: scrollPosition,
      scrollExtentMax: scrollExtentMax,
      scrollExtentMin: scrollExtentMin,
      rect: rect,
      identifier: identifier,
      label: label,
      labelAttributes: labelAttributes,
      value: value,
      valueAttributes: valueAttributes,
      increasedValue: increasedValue,
      increasedValueAttributes: increasedValueAttributes,
      decreasedValue: decreasedValue,
      decreasedValueAttributes: decreasedValueAttributes,
      hint: hint,
      hintAttributes: hintAttributes,
      tooltip: tooltip,
      textDirection: textDirection,
      transform: transform,
      hitTestTransform: hitTestTransform,
      childrenInTraversalOrder: childrenInTraversalOrder,
      childrenInHitTestOrder: childrenInHitTestOrder,
      additionalActions: additionalActions,
      headingLevel: headingLevel,
      linkUrl: linkUrl,
      role: role,
      controlsNodes: controlsNodes,
      validationResult: validationResult,
      hitTestBehavior: hitTestBehavior,
      inputType: inputType,
      locale: locale,
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _builder.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  SemanticsUpdate build() {
    binding.commits++;
    binding.nodes.addAll(updates);
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in binding.nodes[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    for (final id in updates.keys) {
      if (!reachable.contains(id)) {
        binding.violations.add(
          'commit ${binding.commits}: orphan $id label=${labels[id]}',
        );
      }
      if (id != 0 && updates[id]!.contains(0)) {
        binding.violations.add(
          'commit ${binding.commits}: node $id reparents root 0',
        );
      }
    }
    binding.nodes.removeWhere((id, _) => !reachable.contains(id));
    binding.adjustableNodes.removeWhere((id) => !reachable.contains(id));
    return _builder.build();
  }
}
