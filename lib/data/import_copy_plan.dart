// Turns "table T is at rowid N" into the ImportCopying a backup restore
// reports. Pure Dart; LocalDb's merge drives it.
//
// The restore order interleaves stages (heart rate, events, heart rate, ...),
// but the screen's stage index only moves forward. So a stage here is a RUN of
// consecutive tables with the same stage, and [stageCount] counts runs. Rows
// are measured in rowids (MAX(rowid) per table, one cheap read each), not row
// counts: a COUNT(*) over a year of 1 Hz rows is the slow thing this avoids,
// and the copy itself advances by rowid.

import 'import_progress.dart';

ImportStage importStageOf(String table) => switch (table) {
      'journal' ||
      'journal_metric' ||
      'journal_field_def' ||
      'lab_result' ||
      'lab_marker_def' ||
      'strength_set' ||
      'exercise_def' ||
      'food_entry' ||
      'food_def' ||
      'med_def' ||
      'med_dose' ||
      'cycle_log' ||
      'cycle_symptom' ||
      'breathing_session' ||
      'observation' =>
        ImportStage.journal,
      'workout_route' ||
      'workout_split' ||
      'workout_suggestions' ||
      'sessions' ||
      'session_sensor' ||
      'activity_suggestions' ||
      'activity_review_meta' ||
      'activity_review_days' ||
      'external_hr' ||
      'imported_workout' ||
      'imported_measurement' =>
        ImportStage.workouts,
      'sleep_override' || 'sleep_nap' || 'vendor_sleep_epoch' =>
        ImportStage.sleep,
      'samples' ||
      'decoded_onehz' ||
      'spectral_archive' ||
      'spectral_archive_status' =>
        ImportStage.heartRate,
      'decoded_rr' => ImportStage.beats,
      'events' || 'band_events' || 'band_battery' || 'notifications' =>
        ImportStage.events,
      'day_result' ||
      'metric_series' ||
      'metric_series_version' ||
      'metric_method' ||
      'baselines' ||
      'live_coverage' ||
      'step_calibration' ||
      'step_calibration_day' =>
        ImportStage.results,
      'raw_archive' ||
      'substrate_archive' ||
      'ecg_reading' ||
      'ecg_reading_packet' ||
      'ecg_raw_packet' ||
      'ecg_gesture_session' =>
        ImportStage.archive,
      _ => ImportStage.other,
    };

class ImportCopyPlan {
  /// [maxRowids] lists the tables to copy in restore order with their
  /// MAX(rowid); tables with nothing to copy (<= 0) are left out.
  ImportCopyPlan(
    Iterable<(String table, int maxRowid)> maxRowids,
    this._emit,
  ) {
    for (final (table, max) in maxRowids) {
      if (max <= 0) continue;
      final stage = importStageOf(table);
      if (_runs.isEmpty || _runs.last.stage != stage) {
        _runs.add(_Run(stage));
      }
      final run = _runs.last;
      _slots[table] = _Slot(_runs.length - 1, run.total, max);
      run.total += max;
    }
  }

  final void Function(ImportProgress p) _emit;
  final List<_Run> _runs = [];
  final Map<String, _Slot> _slots = {};
  String? _current;
  int _lastDone = 0;

  int get stageCount => _runs.length;

  /// [table] is about to copy. Closes the previous table first, so the last
  /// table of a run reports the run complete.
  void start(String table) {
    finish();
    final slot = _slots[table];
    if (slot == null) return;
    _current = table;
    _report(slot, 0);
  }

  /// [table] has committed everything up to rowid [upper].
  void advance(String table, int upper) {
    final slot = _slots[table];
    if (slot == null) return;
    _report(slot, upper);
  }

  /// The table in progress is done (it ended, or was empty or absent).
  void finish() {
    final t = _current;
    if (t == null) return;
    _current = null;
    final slot = _slots[t]!;
    _report(slot, slot.max);
  }

  void _report(_Slot slot, int upper) {
    final run = _runs[slot.run];
    final inTable = upper < 0 ? 0 : (upper > slot.max ? slot.max : upper);
    var done = slot.offset + inTable;
    // Never backwards inside a run, whatever order the copy reports in.
    if (_lastRun == slot.run && done < _lastDone) done = _lastDone;
    _lastRun = slot.run;
    _lastDone = done;
    _emit(ImportCopying(run.stage, done, run.total, slot.run, _runs.length));
  }

  int _lastRun = -1;
}

class _Run {
  _Run(this.stage);
  final ImportStage stage;
  int total = 0;
}

class _Slot {
  _Slot(this.run, this.offset, this.max);
  final int run, offset, max;
}
