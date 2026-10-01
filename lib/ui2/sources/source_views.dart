// The factory the Sources screens and tests build the pure views through, so
// the views stay free of AppState and a test can reach the real widgets from
// one place (`AppState.debugSourceViews()`).

import 'package:flutter/material.dart';

import 'resolved_data_view.dart';
import 'source_catalog_view.dart';
import 'source_priority_view.dart';

class SourceViews {
  const SourceViews();

  Widget catalog({required List<Map<String, Object?>> cards}) =>
      SourceCatalogView(cards: cards);

  Widget resolvedData({
    required List<Map<String, Object?>> rows,
    required Map<String, String> names,
  }) =>
      ResolvedDataView(rows: rows, names: names);

  Widget priorityEditor({
    required List<Map<String, Object?>> signals,
    required void Function(String signal, List<String> order) onSave,
    required VoidCallback onRebuild,
    void Function(String signal)? onReset,
  }) =>
      SourcePriorityEditor(
        signals: signals,
        onSave: onSave,
        onRebuild: onRebuild,
        onReset: onReset,
      );
}
