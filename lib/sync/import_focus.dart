// import_focus.dart — ONE owner of "an import has the database to itself".
//
// Focus starts where the import is admitted (ImportJournal.runExclusive, for a
// resume too) and outlives the copy: it ends when the heavy derive pass queued
// for the import completes (DeriveScheduler), or at once when the import fails
// or is abandoned. While it is active the screen-read connection is closed,
// repository reads throw ReadPaused, and only today's and yesterday's read
// models, published by the engine as it derives them, are served.
// See edge.research/perf/import-focus-design.md.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/day_label.dart';
import '../data/db.dart';
import '../data/local_repository_impl.dart';

class ImportFocus {
  ImportFocus._();

  /// Every place that reads the database for a screen or a background feature
  /// and must stand down while focus is active. The source guard in
  /// test/import_focus/read_guard_test.dart keeps this honest.
  static const List<String> readEntryPoints = [
    'repo.read', // LocalRepositoryImpl public reads (_focusCheck)
    'insights.refresh', // ArtifactWarmer._held: the warmed insight artifacts
    'notifications.schedule', // AppState._ensureRemindersScheduled
    'health.export', // HealthExporter.exportAll
    'coach.read', // CoachEngine._runTool
    'widget.snapshot', // WidgetService.refresh
  ];

  /// True from the start of an import until the first post-import derive pass
  /// ends (or the import fails or is abandoned).
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// Today's and yesterday's served read models, by day label, then by the
  /// repository method that serves them (`getToday`, `getDayOverview`),
  /// published by the engine right after it derives each of them while focus
  /// is active.
  static final ValueNotifier<Map<String, Map<String, dynamic>>> days =
      ValueNotifier<Map<String, Map<String, dynamic>>>(
          const <String, Map<String, dynamic>>{});

  /// The repository the app serves reads with, so a published model carries
  /// the profile (step goal…). Unset ⇒ a profile-less one is used.
  static LocalRepositoryImpl? repo;

  static void enter() {
    active.value = true;
    unawaited(LocalDb.holdReader(true));
  }

  static void leave() {
    final was = active.value;
    days.value = const <String, Map<String, dynamic>>{};
    unawaited(LocalDb.holdReader(false));
    if (was) active.value = false;
  }

  static void publishDay(String day, Map<String, dynamic> readModel) {
    days.value = {...days.value, day: readModel};
  }

  /// The engine just committed [day]: while focus is active, publish today's
  /// and yesterday's read models (read once, through the normal read code on
  /// the one connection). Never throws; a failed read is simply not published.
  static Future<void> publishCommitted(String day) async {
    if (!active.value) return;
    final today = todayLabel();
    if (day != today && day != dayLabelBefore(today, 1)) return;
    try {
      final r = repo ?? LocalRepositoryImpl(getProfileMap: () => null);
      final model = await r.focusReadModels(day, isToday: day == today);
      if (active.value) publishDay(day, model);
    } catch (_) {}
  }

  /// The post-import derive pass completed (or was given up): focus ends.
  static void importPassDone() => leave();

  @visibleForTesting
  static void debugReset() {
    repo = null;
    active.value = false;
    days.value = const <String, Map<String, dynamic>>{};
    unawaited(LocalDb.holdReader(false));
  }
}
