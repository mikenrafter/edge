// import_focus.dart — ONE owner of "an import has the database to itself".
//
// STUB (red phase): nothing here does anything yet. See
// edge.research/perf/import-focus-design.md.
library;

import 'package:flutter/foundation.dart';

class ImportFocus {
  ImportFocus._();

  /// Every place that reads the database for a screen or a background feature
  /// and must stand down while focus is active. The source guard in
  /// test/import_focus/read_guard_test.dart keeps this honest.
  static const List<String> readEntryPoints = [];

  /// True from the start of an import until the first post-import derive pass
  /// ends (or the import fails or is abandoned).
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Today's and yesterday's read models, by day label, published by the
  /// engine right after it derives each of them while focus is active.
  static final ValueNotifier<Map<String, Map<String, dynamic>>> days =
      ValueNotifier<Map<String, Map<String, dynamic>>>(
          const <String, Map<String, dynamic>>{});

  static void enter() {}

  static void leave() {}

  static void publishDay(String day, Map<String, dynamic> readModel) {}

  @visibleForTesting
  static void debugReset() {}
}
