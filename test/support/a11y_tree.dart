// Reading the semantics tree the way TalkBack walks it, for the a11y tests.
// Not a test file (no _test suffix).
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

SemanticsNode _root(WidgetTester t) =>
    t.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;

/// Every node, depth first, children in TalkBack's traversal order.
List<SemanticsNode> semanticsNodes(WidgetTester t) {
  final out = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    out.add(n);
    n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(visit);
  }
  visit(_root(t));
  return out;
}

/// Each non-empty node label, in reading order.
List<String> spokenLabels(WidgetTester t) => [
      for (final n in semanticsNodes(t))
        if (n.label.trim().isNotEmpty) n.label,
    ];

/// Labels in which one line appears twice ("Save\nSave"): a node read twice.
List<String> repeatedLines(WidgetTester t) => [
      for (final l in spokenLabels(t))
        if (_hasRepeat(l)) l.replaceAll('\n', ' | '),
    ];

/// Only lines of three letters or more count: weekday initials ("T", "S")
/// and dashes repeat legitimately and are no doubled label.
bool _hasRepeat(String label) {
  final seen = <String>{};
  for (final line in label.split('\n')) {
    final x = line.trim();
    if (!RegExp(r'\p{L}.*\p{L}.*\p{L}', unicode: true).hasMatch(x)) continue;
    if (!seen.add(x)) return true;
  }
  return false;
}

/// Nodes with a heading flag.
List<String> headings(WidgetTester t) => [
      for (final n in semanticsNodes(t))
        if (n.getSemanticsData().hasFlag(SemanticsFlag.isHeader)) n.label,
    ];
