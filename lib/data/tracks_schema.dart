// TracksStore owns these records; other sections retain their canonical rows.
import 'package:sqflite/sqflite.dart';
import 'track_presets.dart';

Future<void> createTrackTables(Database db) async {
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_definition ('
    'id TEXT PRIMARY KEY, payload_json TEXT NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_setup_history ('
    'id TEXT PRIMARY KEY, track_id TEXT NOT NULL, start_date TEXT NOT NULL, '
    'end_date TEXT NOT NULL, done INTEGER NOT NULL CHECK (done IN (0,1)), '
    'approx_minute INTEGER, amount REAL, amount_unit TEXT, '
    'CHECK (start_date <= end_date))',
  );
  // v85 (P8a): a taken-daily period's optional local minute, amount and the
  // unit it was entered in. Additive and nullable; old rows keep NULL (unknown).
  // The "done only" rule lives in TrackSetupRange (CLAIM(range-invariants)),
  // not in SQL, so a fresh and a migrated table have the same constraints.
  final historyColumns = {
    for (final column in await db.rawQuery(
      'PRAGMA table_info(track_setup_history)',
    ))
      column['name'] as String,
  };
  if (!historyColumns.contains('approx_minute')) {
    await db.execute(
      'ALTER TABLE track_setup_history ADD COLUMN approx_minute INTEGER',
    );
  }
  if (!historyColumns.contains('amount')) {
    await db.execute('ALTER TABLE track_setup_history ADD COLUMN amount REAL');
  }
  if (!historyColumns.contains('amount_unit')) {
    await db.execute(
      'ALTER TABLE track_setup_history ADD COLUMN amount_unit TEXT',
    );
  }
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_history '
    'ON track_setup_history(track_id, start_date)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_event ('
    'id TEXT PRIMARY KEY, track_id TEXT NOT NULL, date TEXT NOT NULL, '
    'at_ms INTEGER, amount REAL, sub_activity_id TEXT, unit TEXT, source_kind TEXT NOT NULL, '
    'source_id TEXT NOT NULL, UNIQUE(track_id, source_kind, source_id))',
  );
  final columns = await db.rawQuery('PRAGMA table_info(track_event)');
  if (!columns.any((column) => column['name'] == 'unit')) {
    await db.execute('ALTER TABLE track_event ADD COLUMN unit TEXT');
  }
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_track_event_date '
    'ON track_event(date, track_id, at_ms)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_learning ('
    'track_id TEXT PRIMARY KEY, started_ms INTEGER NOT NULL, '
    'state_json TEXT NOT NULL, last_step_date TEXT)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_learning_log ('
    'id INTEGER PRIMARY KEY AUTOINCREMENT, track_id TEXT NOT NULL, '
    'date TEXT NOT NULL, field TEXT NOT NULL, before_value REAL, '
    'after_value REAL, reason TEXT NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_absence ('
    'track_id TEXT NOT NULL, date TEXT NOT NULL, PRIMARY KEY(track_id, date))',
  );
  // v86 (review P8a-R2-2): dates whose logs were deleted. Learning treats them
  // as unknown, overriding "I log every time" and setup-period completeness.
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_unknown_day (date TEXT PRIMARY KEY)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_experiment ('
    'id TEXT PRIMARY KEY, track_id TEXT NOT NULL, start_date TEXT NOT NULL, '
    'end_date TEXT NOT NULL, weeks INTEGER NOT NULL, seed INTEGER NOT NULL, '
    'created_ms INTEGER NOT NULL)',
  );
  await db.execute(
    'CREATE TABLE IF NOT EXISTS track_experiment_day ('
    'experiment_id TEXT NOT NULL, date TEXT NOT NULL, '
    'do_it INTEGER NOT NULL CHECK (do_it IN (0,1)), '
    'PRIMARY KEY(experiment_id, date))',
  );
  // Seed only missing definitions; reopening never overwrites a wearer edit.
  final batch = db.batch();
  for (final preset in trackPresetPayloads.entries) {
    batch.insert('track_definition', {
      'id': preset.key,
      'payload_json': preset.value,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await batch.commit(noResult: true);
  await db.execute('DROP VIEW IF EXISTS track_event_feed');
  // Daily totals are aggregates. Subtract explicit moments and expose only a
  // positive residual, with no invented time. Existing owner rows remain intact.
  await db.execute('''
    CREATE VIEW track_event_feed AS
    SELECT id, track_id, date, at_ms, amount, sub_activity_id, source_kind, source_id, unit
      FROM track_event
    UNION ALL
    SELECT 'journal:' || j.date || ':' || j.field,
      CASE j.field WHEN 'caffeine_mg' THEN 'caffeine' ELSE 'alcohol' END,
      j.date, NULL,
      j.value - CASE WHEN j.field = 'caffeine_mg' THEN COALESCE((
        SELECT SUM(m.caffeine_mg) FROM moment_label m
        WHERE m.date = j.date AND m.label = 'caffeine'), 0) ELSE 0 END
        - COALESCE((SELECT SUM(t.amount) FROM track_event t WHERE t.date = j.date AND
          t.track_id = CASE j.field WHEN 'caffeine_mg' THEN 'caffeine' ELSE 'alcohol' END
          AND (t.unit IS NULL OR t.unit = CASE j.field WHEN 'caffeine_mg' THEN 'mg' ELSE 'units' END)), 0),
      NULL, 'journal', j.date || ':' || j.field, CASE j.field WHEN 'caffeine_mg' THEN 'mg' ELSE 'units' END
      FROM journal_metric j
      WHERE j.field IN ('caffeine_mg', 'alcohol_units') AND j.value >
        CASE WHEN j.field = 'caffeine_mg' THEN COALESCE((
          SELECT SUM(m.caffeine_mg) FROM moment_label m
          WHERE m.date = j.date AND m.label = 'caffeine'), 0) ELSE 0 END
        + COALESCE((SELECT SUM(t.amount) FROM track_event t WHERE t.date = j.date AND
          t.track_id = CASE j.field WHEN 'caffeine_mg' THEN 'caffeine' ELSE 'alcohol' END
          AND (t.unit IS NULL OR t.unit = CASE j.field WHEN 'caffeine_mg' THEN 'mg' ELSE 'units' END)), 0)
    UNION ALL
    SELECT 'moment:' || m.date || ':' || m.hhmm,
      CASE m.label WHEN 'meal' THEN 'late_meal' WHEN 'nap' THEN 'naps'
        WHEN 'workout' THEN 'late_workout' ELSE m.label END,
      m.date, CAST(strftime('%s', m.date || ' ' || m.hhmm || ':00', 'utc') AS INTEGER) * 1000,
      CASE WHEN m.label = 'caffeine' THEN m.caffeine_mg ELSE NULL END,
      NULL, 'moment', m.date || ':' || m.hhmm, CASE m.label WHEN 'caffeine' THEN 'mg' WHEN 'alcohol' THEN 'units' ELSE '' END
      FROM moment_label m
      WHERE m.label IN ('caffeine', 'meal', 'alcohol', 'cannabis', 'nicotine',
        'meditation', 'illness', 'cold', 'sauna', 'late_screens', 'fluids', 'sleep_aids')
      AND (m.label <> 'meal' OR NOT EXISTS (SELECT 1 FROM food_entry f
        WHERE f.date = m.date AND strftime('%H:%M', f.at_ts, 'unixepoch', 'localtime') = m.hhmm))
    UNION ALL
    SELECT 'session:' || s.id, 'late_workout',
      date(s.start_ts, 'unixepoch', 'localtime'), s.start_ts * 1000,
      COALESCE(s.duration_min, (s.end_ts - s.start_ts) / 60.0), s.type, 'session', s.id, 'minutes'
      FROM sessions s WHERE s.status = 'done'
    UNION ALL
    SELECT 'food:' || f.id, 'late_meal', f.date, f.at_ts * 1000,
      f.quantity, f.meal, 'food', f.id, f.unit FROM food_entry f
    UNION ALL
    SELECT 'med:' || d.med_key || ':' || d.date || ':' || d.slot_min,
      'med:' || d.med_key, d.date, d.taken_ts * 1000, d.dose_value,
      NULL, 'med', d.med_key || ':' || d.date || ':' || d.slot_min, COALESCE((SELECT dose_unit FROM med_def WHERE key = d.med_key), '')
      FROM med_dose d WHERE d.taken_ts IS NOT NULL
    UNION ALL
    SELECT 'nap:' || n.day_id || ':' || n.start_ts, 'naps', n.day_id,
      n.start_ts * 1000, (n.end_ts - n.start_ts) / 60.0, NULL,
      'nap', n.day_id || ':' || n.start_ts, 'minutes' FROM sleep_nap n WHERE n.source <> 'rejected'
  ''');
}
