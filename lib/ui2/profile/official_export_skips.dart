// Presentation only. Per-row identities and column names stay in the manifest.
import '../../data/official_export/profile.dart';

/// One line per table/reason, independent of the number of affected records.
/// CLAIM(export-readable-skips): real rich-report screen test pins grouping.
List<String> summarizeOfficialSkips(List<ExportSkip> skipped) {
  final groups =
      <
        (String, String),
        ({String label, String reason, String unit, int count})
      >{};
  final identities = <(String, String), Set<String>>{};
  for (final skip in skipped) {
    if (skip.rows == 0) continue;
    final description = _description(skip);
    final key = (skip.table, description.reason);
    if (skip.identity != null &&
        skip.rows == 1 &&
        !(identities[key] ??= {}).add(skip.identity!)) {
      continue;
    }
    final previous = groups[key];
    groups[key] = (
      label: description.label,
      reason: description.reason,
      unit: description.unit,
      count: (previous?.count ?? 0) + skip.rows,
    );
  }
  return [
    for (final g in groups.values)
      '${g.label}: ${g.count} ${g.unit}${g.count == 1 ? '' : 's'}. ${g.reason}',
  ];
}

({String label, String reason, String unit}) _description(ExportSkip skip) {
  final label = _labels[skip.table] ?? 'Other records';
  final reason = skip.reason;
  if (reason == 'Fork session scores cleared for official recomputation') {
    return (
      label: 'Workout scores',
      reason: 'The official app recomputes them.',
      unit: 'workout',
    );
  }
  final explanation = switch (reason) {
    'Fork computed or operational state is cleared' =>
      'The official app rebuilds this state.',
    'Official importer does not support this table' =>
      'The official app does not support these yet.',
    'Unreviewed source table; official release has no safe mapping' =>
      'Compatibility with the official app has not been verified.',
    'Measured versus estimated provenance is unavailable' =>
      'Recorded and estimated values cannot be distinguished.',
    'Session is live or has no verified actual end' =>
      'The actual workout end is unavailable.',
    'Parent session is not portable' =>
      'The associated workout could not be included.',
    'Fork HR aggregate cleared' ||
    'Fork HR aggregates cleared from dismissed proposal' =>
      'The official app recomputes heart rate summaries.',
    'Unsupported activity kind or undecided proposal' =>
      'Only decided workouts and naps can transfer.',
    'Activity decision JSON is unreadable' =>
      'The saved activity details could not be read.',
    'Computed or unreviewed activity details cleared' =>
      'Extra activity details are not supported.',
    'Automatic nap has no preserved confirmation' =>
      'This suggested nap has no saved confirmation.',
    'Fork nap staging payload cleared; user bounds retained' =>
      'Nap times transfer; the official app recomputes sleep stages.',
    'Pending computed workout proposal' =>
      'This workout suggestion has not been decided.',
    'Review revision reset for official ownership' =>
      'The official app starts its own review history.',
    'Parent evidence was unavailable or skipped' =>
      'The associated recording could not be included.',
    'Deletion windows cannot be read safely' ||
    'Deletion policy is unreadable' =>
      'Saved deletion rules could not be read safely.',
    'Excluded by source deletion policy, or timestamp unavailable for safe filtering' =>
      'Excluded by saved deletion rules or missing recording times.',
    'Unknown codec or corrupt fingerprint' =>
      'The recording format is unsupported or its integrity check failed.',
    'Live second and its complete current beat set override archived data' =>
      'Newer recordings replace these archived seconds.',
    _
        when reason.startsWith('Columns are unsupported') ||
            reason.startsWith('Archive metadata columns') =>
      'Extra details are not supported by this official release.',
    _ when reason.startsWith('Unreviewed source columns') =>
      'Compatibility of these additional details has not been verified.',
    _
        when reason.startsWith('Unsupported device') ||
            reason.startsWith('Unsupported source signal') ||
            reason.startsWith('Unsupported archived device') =>
      'This sensor or signal is not supported by the official app.',
    _ when reason.startsWith('ECG reading uses') =>
      'This ECG result is not supported by the official app.',
    _ when reason.startsWith('Conflicting archive') =>
      'Conflicting recordings cannot be transferred safely.',
    _ when reason.startsWith('Original bucket withheld') =>
      'The original archive cannot be replayed safely; permitted recordings transfer separately.',
    _ when reason.startsWith('Target constraints') =>
      'The official app cannot accept these records.',
    _ when reason.startsWith('Unrecognized deletion') =>
      'Saved deletion rules could not be interpreted safely.',
    _ =>
      'These items could not be transferred safely. See the file manifest for details.',
  };
  return (label: label, reason: explanation, unit: 'record');
}

const _labels = {
  'activity_review_days': 'Activity review days',
  'activity_review_meta': 'Activity review history',
  'activity_suggestions': 'Activity decisions',
  'alarm_schedule': 'Alarms',
  'assumed_water': 'Water estimates',
  'backup_files': 'Saved files',
  'backup_prefs': 'Settings',
  'band_backlog': 'Band sync history',
  'band_battery': 'Battery readings',
  'band_events': 'Band events',
  'baselines': 'Personal baselines',
  'breathing_session': 'Breathing sessions',
  'compute_freshness': 'Computation history',
  'compute_jobs': 'Computation jobs',
  'cycle_log': 'Cycle entries',
  'cycle_symptom': 'Cycle symptoms',
  'day_checkpoint': 'Day checkpoints',
  'day_manifest': 'Day recording inventory',
  'day_result': 'Daily scores',
  'decoded_onehz': 'Sensor recordings',
  'decoded_rr': 'Heart beat recordings',
  'derived_day': 'Daily calculations',
  'device': 'Sensors',
  'device_coverage': 'Sensor recording windows',
  'ecg_gesture_session': 'ECG capture sessions',
  'ecg_raw_packet': 'ECG raw recordings',
  'ecg_reading': 'ECG reading details',
  'ecg_reading_packet': 'ECG samples',
  'events': 'Recorded events',
  'exercise_def': 'Exercises',
  'external_hr': 'External heart rate',
  'food_def': 'Foods',
  'food_entry': 'Food entries',
  'group_row': 'Record groups',
  'import_journal': 'Import history',
  'imported_measurement': 'Imported measurements',
  'imported_workout': 'Imported workouts',
  'input_rev': 'Recording change history',
  'input_rev_bulk': 'Bulk recording change history',
  'input_revision': 'Recording change counters',
  'journal': 'Journal entries',
  'journal_field_def': 'Journal fields',
  'journal_metric': 'Journal measurements',
  'lab_marker_def': 'Lab markers',
  'lab_result': 'Lab results',
  'last_result': 'Recent calculations',
  'live_coverage': 'Live recording windows',
  'live_workout_tally': 'Live workout totals',
  'med_def': 'Medications',
  'med_dose': 'Medication doses',
  'metric_method': 'Calculation methods',
  'metric_series': 'Metric history',
  'metric_series_version': 'Metric history',
  'moment_label': 'Moment labels',
  'notif_fired': 'Notification history',
  'notif_slots': 'Notification scheduling',
  'notifications': 'Notifications',
  'observation': 'Observations',
  'pulse_alert': 'Pulse alerts',
  'raw_archive': 'Archived band recordings',
  'raw_records': 'Band recordings',
  'row_rev': 'Record change history',
  'samples': 'Heart rate samples',
  'session_score_mask': 'Workout score settings',
  'session_sensor': 'Workout sensors',
  'sessions': 'Workout details',
  'signal_priority': 'Sensor priorities',
  'sleep_nap': 'Naps',
  'sleep_override': 'Sleep edits',
  'sleep_session_candidates': 'Sleep suggestions',
  'spectral_archive': 'Spectral recordings',
  'spectral_archive_status': 'Spectral recording history',
  'step_calibration': 'Step calibration',
  'step_calibration_day': 'Step calibration days',
  'store_rev': 'Storage change history',
  'strength_set': 'Strength sets',
  'substrate_archive': 'Archived sensor recordings',
  'symptom_entry': 'Symptoms',
  'sync_cursor': 'Sync progress',
  'sync_ledger': 'Sync history',
  'sync_quarantine': 'Quarantined sync records',
  'track_absence': 'Track absences',
  'track_definition': 'Tracks',
  'track_event': 'Track entries',
  'track_experiment': 'Track experiments',
  'track_experiment_day': 'Track experiment days',
  'track_learning': 'Track learning',
  'track_learning_log': 'Track learning history',
  'track_setup_history': 'Track settings history',
  'track_unknown_day': 'Track days',
  'vendor_sleep_epoch': 'Imported sleep stages',
  'wake_confirmation': 'Wake confirmations',
  'wake_day_features': 'Wake calculations',
  'wake_evidence': 'Wake recordings',
  'wake_meta': 'Wake settings',
  'wake_trace': 'Wake history',
  'water_moment': 'Water entries',
  'workout_route': 'Workout routes',
  'workout_split': 'Workout splits',
  'workout_suggestions': 'Workout suggestions',
};
