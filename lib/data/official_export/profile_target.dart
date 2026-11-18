// GENERATED from the tagged v0.12.2 repaired runtime schema (fixtures/target_schema_62.json):
// the create paths PLUS the on-open repair, never a hand-written downgrade.
// The profile hash binds this list.

/// (type, name, tbl_name, sql) of every object the tagged release creates.
const List<({String type, String name, String table, String sql})>
officialTargetObjects = [
  (type: 'index', name: 'activity_pending', table: 'activity_suggestions', sql: r'''CREATE INDEX activity_pending ON activity_suggestions(status, start_ts)'''),
  (type: 'index', name: 'idx_band_battery_ts', table: 'band_battery', sql: r'''CREATE INDEX idx_band_battery_ts ON band_battery(ts DESC)'''),
  (type: 'index', name: 'idx_band_events_ts', table: 'band_events', sql: r'''CREATE INDEX idx_band_events_ts ON band_events(ts, event_id)'''),
  (type: 'index', name: 'idx_compute_jobs_state_pri', table: 'compute_jobs', sql: r'''CREATE INDEX idx_compute_jobs_state_pri ON compute_jobs(state, priority DESC, updated_at ASC)'''),
  (type: 'index', name: 'idx_coverage_device', table: 'device_coverage', sql: r'''CREATE INDEX idx_coverage_device ON device_coverage(device_id, signal, start_ts DESC)'''),
  (type: 'index', name: 'idx_coverage_window', table: 'device_coverage', sql: r'''CREATE INDEX idx_coverage_window ON device_coverage(signal, start_ts, end_ts)'''),
  (type: 'index', name: 'idx_day_result_day', table: 'day_result', sql: r'''CREATE INDEX idx_day_result_day ON day_result(day_id, algo_version)'''),
  (type: 'index', name: 'idx_decoded_onehz_rects', table: 'decoded_onehz', sql: r'''CREATE INDEX idx_decoded_onehz_rects ON decoded_onehz(rec_ts, counter)'''),
  (type: 'index', name: 'idx_decoded_rr_rects', table: 'decoded_rr', sql: r'''CREATE INDEX idx_decoded_rr_rects ON decoded_rr(rec_ts, beat_index)'''),
  (type: 'index', name: 'idx_ecg_raw_packet_strap', table: 'ecg_raw_packet', sql: r'''CREATE INDEX idx_ecg_raw_packet_strap ON ecg_raw_packet(strap_seconds)'''),
  (type: 'index', name: 'idx_ecg_reading_start', table: 'ecg_reading', sql: r'''CREATE INDEX idx_ecg_reading_start ON ecg_reading(start_ts DESC)'''),
  (type: 'index', name: 'idx_events_ts', table: 'events', sql: r'''CREATE INDEX idx_events_ts ON events(ts)'''),
  (type: 'index', name: 'idx_external_hr_session', table: 'external_hr', sql: r'''CREATE INDEX idx_external_hr_session ON external_hr(session_id)'''),
  (type: 'index', name: 'idx_food_entry_date', table: 'food_entry', sql: r'''CREATE INDEX idx_food_entry_date ON food_entry(date, at_ts)'''),
  (type: 'index', name: 'idx_food_entry_food', table: 'food_entry', sql: r'''CREATE INDEX idx_food_entry_food ON food_entry(food_key, date)'''),
  (type: 'index', name: 'idx_hyrox_segment_workout', table: 'hyrox_segment', sql: r'''CREATE INDEX idx_hyrox_segment_workout ON hyrox_segment(workout_id)'''),
  (type: 'index', name: 'idx_hyrox_session_start', table: 'hyrox_session', sql: r'''CREATE INDEX idx_hyrox_session_start ON hyrox_session(start_ts)'''),
  (type: 'index', name: 'idx_hyrox_session_status', table: 'hyrox_session', sql: r'''CREATE INDEX idx_hyrox_session_status ON hyrox_session(status)'''),
  (type: 'index', name: 'idx_imported_measurement_kind', table: 'imported_measurement', sql: r'''CREATE INDEX idx_imported_measurement_kind ON imported_measurement(kind, ts)'''),
  (type: 'index', name: 'idx_imported_workout_start', table: 'imported_workout', sql: r'''CREATE INDEX idx_imported_workout_start ON imported_workout(start_ts)'''),
  (type: 'index', name: 'idx_journal_metric_field', table: 'journal_metric', sql: r'''CREATE INDEX idx_journal_metric_field ON journal_metric(field, date)'''),
  (type: 'index', name: 'idx_live_coverage_day', table: 'live_coverage', sql: r'''CREATE INDEX idx_live_coverage_day ON live_coverage(day)'''),
  (type: 'index', name: 'idx_med_dose_date', table: 'med_dose', sql: r'''CREATE INDEX idx_med_dose_date ON med_dose(date)'''),
  (type: 'index', name: 'idx_metric_series_key', table: 'metric_series', sql: r'''CREATE INDEX idx_metric_series_key ON metric_series(key, date)'''),
  (type: 'index', name: 'idx_notif_slots_owner', table: 'notif_slots', sql: r'''CREATE UNIQUE INDEX idx_notif_slots_owner ON notif_slots(category, slot)'''),
  (type: 'index', name: 'idx_observation_date', table: 'observation', sql: r'''CREATE INDEX idx_observation_date ON observation(date, source_kind)'''),
  (type: 'index', name: 'idx_observation_identity', table: 'observation', sql: r'''CREATE UNIQUE INDEX idx_observation_identity ON observation(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))'''),
  (type: 'index', name: 'idx_raw_archive_captured', table: 'raw_archive_frames', sql: r'''CREATE INDEX idx_raw_archive_captured ON raw_archive_frames(captured_at DESC)'''),
  (type: 'index', name: 'idx_raw_archive_reason', table: 'raw_archive_frames', sql: r'''CREATE INDEX idx_raw_archive_reason ON raw_archive_frames(reason, device_id)'''),
  (type: 'index', name: 'idx_samples_ts', table: 'samples', sql: r'''CREATE INDEX idx_samples_ts ON samples(ts)'''),
  (type: 'index', name: 'idx_sessions_start', table: 'sessions', sql: r'''CREATE INDEX idx_sessions_start ON sessions(start_ts)'''),
  (type: 'index', name: 'idx_strength_set_ex', table: 'strength_set', sql: r'''CREATE INDEX idx_strength_set_ex ON strength_set(exercise_key, at_ts)'''),
  (type: 'index', name: 'idx_substrate_archive_day', table: 'substrate_archive', sql: r'''CREATE INDEX idx_substrate_archive_day ON substrate_archive(utc_day)'''),
  (type: 'index', name: 'idx_sync_quarantine_created', table: 'sync_quarantine', sql: r'''CREATE INDEX idx_sync_quarantine_created ON sync_quarantine(created_at)'''),
  (type: 'index', name: 'idx_triathlon_segment_workout', table: 'triathlon_segment', sql: r'''CREATE INDEX idx_triathlon_segment_workout ON triathlon_segment(workout_id)'''),
  (type: 'index', name: 'idx_triathlon_session_start', table: 'triathlon_session', sql: r'''CREATE INDEX idx_triathlon_session_start ON triathlon_session(start_ts)'''),
  (type: 'index', name: 'idx_triathlon_session_status', table: 'triathlon_session', sql: r'''CREATE INDEX idx_triathlon_session_status ON triathlon_session(status)'''),
  (type: 'index', name: 'idx_vendor_sleep_epoch_night', table: 'vendor_sleep_epoch', sql: r'''CREATE INDEX idx_vendor_sleep_epoch_night ON vendor_sleep_epoch(night_onset_ts)'''),
  (type: 'index', name: 'idx_workout_route_session', table: 'workout_route', sql: r'''CREATE INDEX idx_workout_route_session ON workout_route(session_id, seq)'''),
  (type: 'table', name: 'activity_review_days', table: 'activity_review_days', sql: r'''CREATE TABLE activity_review_days (
      day_id TEXT PRIMARY KEY, revision INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'activity_review_meta', table: 'activity_review_meta', sql: r'''CREATE TABLE activity_review_meta (
      id INTEGER PRIMARY KEY CHECK(id = 1), activated_at INTEGER NOT NULL,
      revision INTEGER NOT NULL DEFAULT 0, legacy_migrated INTEGER NOT NULL DEFAULT 0,
      alert_after_ts INTEGER NOT NULL DEFAULT 0
    )'''),
  (type: 'table', name: 'activity_suggestions', table: 'activity_suggestions', sql: r'''CREATE TABLE activity_suggestions (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, day_id TEXT NOT NULL,
      start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
      detection_start INTEGER NOT NULL, detection_end INTEGER NOT NULL,
      details_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      revision INTEGER NOT NULL DEFAULT 0, linked_id TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'alarm_schedule', table: 'alarm_schedule', sql: r'''CREATE TABLE alarm_schedule (
        weekday INTEGER NOT NULL,
        hour    INTEGER NOT NULL,
        minute  INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        smart_window_minutes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (weekday)
      )'''),
  (type: 'table', name: 'band_backlog', table: 'band_backlog', sql: r'''CREATE TABLE band_backlog (
        device_id TEXT NOT NULL DEFAULT '',
        ts INTEGER NOT NULL,
        written INTEGER,
        used INTEGER,
        capacity INTEGER,
        trim_page INTEGER,
        wrap_count INTEGER,
        free_records INTEGER,
        device_family TEXT,
        PRIMARY KEY (device_id, ts)
      )'''),
  (type: 'table', name: 'band_battery', table: 'band_battery', sql: r'''CREATE TABLE band_battery (
        device_id TEXT NOT NULL DEFAULT '',
        ts INTEGER NOT NULL,
        battery_pct REAL,
        charging INTEGER,
        wrist_on INTEGER,
        millivolts INTEGER,
        charge_units INTEGER,
        source TEXT NOT NULL,
        PRIMARY KEY (device_id, ts, source)
      )'''),
  (type: 'table', name: 'band_events', table: 'band_events', sql: r'''CREATE TABLE band_events (
        device_id TEXT NOT NULL DEFAULT '',
        hex TEXT NOT NULL,
        event_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        ts INTEGER NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        captured_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, hex)
      )'''),
  (type: 'table', name: 'baselines', table: 'baselines', sql: r'''CREATE TABLE baselines (
        key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'breathing_session', table: 'breathing_session', sql: r'''CREATE TABLE breathing_session (
        started_at INTEGER PRIMARY KEY,
        ended_at INTEGER NOT NULL,
        pattern TEXT NOT NULL,
        seconds INTEGER NOT NULL,
        coherence REAL,
        confidence REAL,
        pre_rmssd REAL,
        post_rmssd REAL
      )'''),
  (type: 'table', name: 'compute_freshness', table: 'compute_freshness', sql: r'''CREATE TABLE compute_freshness (
        key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'compute_jobs', table: 'compute_jobs', sql: r'''CREATE TABLE compute_jobs (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        scope TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        state TEXT NOT NULL,
        reason TEXT,
        depends_on TEXT,
        input_from_ts INTEGER,
        input_to_ts INTEGER,
        algo_version INTEGER,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_run_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'cycle_log', table: 'cycle_log', sql: r'''CREATE TABLE cycle_log (
        date TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        note TEXT
      )'''),
  (type: 'table', name: 'cycle_symptom', table: 'cycle_symptom', sql: r'''CREATE TABLE cycle_symptom (
        date TEXT PRIMARY KEY,
        symptoms_json TEXT NOT NULL,
        note TEXT,
        updated_at INTEGER
      )'''),
  (type: 'table', name: 'day_checkpoint', table: 'day_checkpoint', sql: r'''CREATE TABLE day_checkpoint (day_id TEXT NOT NULL, algo_version INTEGER NOT NULL, fmt INTEGER NOT NULL, ctx_sig TEXT NOT NULL, cp_rec_ts INTEGER NOT NULL, rev_vec BLOB NOT NULL, state BLOB NOT NULL, night_ref TEXT, computed_at INTEGER NOT NULL, PRIMARY KEY(day_id, algo_version))'''),
  (type: 'table', name: 'day_result', table: 'day_result', sql: r'''CREATE TABLE day_result (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        window_json TEXT NOT NULL DEFAULT '{}',
        computed_at INTEGER NOT NULL,
        finalized INTEGER NOT NULL DEFAULT 0,
        rhr REAL,
        rmssd REAL,
        readiness REAL,
        skipped INTEGER NOT NULL DEFAULT 0,
        partial INTEGER NOT NULL DEFAULT 0, imported INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day_id, algo_version)
      )'''),
  (type: 'table', name: 'decoded_onehz', table: 'decoded_onehz', sql: r'''CREATE TABLE decoded_onehz (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        -- NOT re-asserted NOT NULL, deliberately: [_rekeyTableByDevice] copies
        -- this column verbatim out of a table where SQLite never enforced it
        -- (a declared PRIMARY KEY on a legacy rowid table does not imply NOT
        -- NULL), and a constraint failure inside onUpgrade's one exclusive
        -- transaction quarantines the whole database (invariant 11).
        rec_ts INTEGER,
        counter INTEGER NOT NULL,
        hr INTEGER,
        ax REAL,
        ay REAL,
        az REAL,
        spo2_red_raw INTEGER,
        spo2_ir_raw INTEGER,
        skin_temp_raw INTEGER,
        step_count INTEGER,
        step_cadence INTEGER,
        activity_class INTEGER,
        skin_temp_c REAL,
        on_wrist INTEGER,
        hr_valid INTEGER,
        hr_alt INTEGER,
        ambient_raw INTEGER,
        device_family TEXT,
        source TEXT,
        temp_ch2_c REAL,
        temp_ch3_c REAL,
        signal_quality_logvar REAL,
        dyn_accel_g REAL, ts_subsec INTEGER, band_sleep_state INTEGER,
        PRIMARY KEY (device_id, ts_ms)
      )'''),
  (type: 'table', name: 'decoded_rr', table: 'decoded_rr', sql: r'''CREATE TABLE decoded_rr (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        rec_ts INTEGER NOT NULL,
        beat_index INTEGER NOT NULL,
        rr_ts_ms INTEGER NOT NULL,
        rr_ms INTEGER NOT NULL,
        device_family TEXT,
        source TEXT, beat_ts_ms INTEGER,
        PRIMARY KEY (device_id, ts_ms, beat_index)
      )'''),
  (type: 'table', name: 'derive_fingerprint', table: 'derive_fingerprint', sql: r'''CREATE TABLE derive_fingerprint (day_id TEXT PRIMARY KEY, fp TEXT NOT NULL)'''),
  (type: 'table', name: 'derived_day', table: 'derived_day', sql: r'''CREATE TABLE derived_day (
        date TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        version INTEGER NOT NULL,
        last_raw_ts INTEGER NOT NULL,
        computed_at INTEGER NOT NULL,
        rhr REAL,
        rmssd REAL,
        readiness REAL
      )'''),
  (type: 'table', name: 'device', table: 'device', sql: r'''CREATE TABLE device (
        id          TEXT PRIMARY KEY,
        adapter_id  TEXT,
        remote_id   TEXT,
        label       TEXT,
        tier        TEXT,
        first_seen  INTEGER NOT NULL,
        last_seen   INTEGER NOT NULL,
        role        TEXT NOT NULL DEFAULT 'paired',
        wearing     INTEGER NOT NULL DEFAULT 1
      , wearing_set_ts INTEGER, battery_pct INTEGER, battery_ts INTEGER)'''),
  (type: 'table', name: 'device_coverage', table: 'device_coverage', sql: r'''CREATE TABLE device_coverage (
        device_id TEXT NOT NULL,
        signal    TEXT NOT NULL,
        start_ts  INTEGER NOT NULL,
        end_ts    INTEGER NOT NULL,
        PRIMARY KEY (device_id, signal, start_ts)
      )'''),
  (type: 'table', name: 'ecg_raw_packet', table: 'ecg_raw_packet', sql: r'''CREATE TABLE ecg_raw_packet (
        hex           TEXT PRIMARY KEY,
        device_id     TEXT NOT NULL,
        sequence      INTEGER,
        strap_seconds INTEGER,
        strap_subsec  INTEGER,
        captured_at   INTEGER NOT NULL,
        reading_id    TEXT
      )'''),
  (type: 'table', name: 'ecg_reading', table: 'ecg_reading', sql: r'''CREATE TABLE ecg_reading (
        id                    TEXT PRIMARY KEY,
        device_id             TEXT NOT NULL,
        source                TEXT NOT NULL,
        wrist                 TEXT NOT NULL,
        start_ts              INTEGER NOT NULL,
        end_ts                INTEGER NOT NULL,
        strap_terminal_ts     INTEGER,
        strap_terminal_subsec INTEGER,
        result_code           INTEGER NOT NULL,
        category              TEXT NOT NULL,
        avg_hr                INTEGER,
        quality               INTEGER,
        unreadable_mask       INTEGER NOT NULL DEFAULT 0,
        interruptions         INTEGER NOT NULL DEFAULT 0,
        sample_rate_hz        INTEGER NOT NULL DEFAULT 100,
        sample_unit           TEXT NOT NULL DEFAULT 'filtered_input_referred_uv',
        sample_count          INTEGER NOT NULL,
        min_uv                INTEGER,
        max_uv                INTEGER,
        rms_uv                REAL,
        missing_segments      INTEGER NOT NULL DEFAULT 0,
        status                TEXT NOT NULL,
        notes                 TEXT,
        created_at            INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'ecg_reading_packet', table: 'ecg_reading_packet', sql: r'''CREATE TABLE ecg_reading_packet (
        reading_id     TEXT NOT NULL,
        ordinal        INTEGER NOT NULL,
        sequence       INTEGER NOT NULL,
        strap_seconds  INTEGER,
        strap_subsec   INTEGER,
        sample_count   INTEGER NOT NULL,
        samples        BLOB NOT NULL,
        inner_hex      TEXT NOT NULL,
        is_placeholder INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (reading_id, ordinal)
      )'''),
  (type: 'table', name: 'events', table: 'events', sql: r'''CREATE TABLE events (
        device_id TEXT NOT NULL DEFAULT '',
        hex TEXT NOT NULL,
        event_id INTEGER,
        ts INTEGER,
        captured_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, hex)
      )'''),
  (type: 'table', name: 'exercise_def', table: 'exercise_def', sql: r'''CREATE TABLE exercise_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        muscles_json TEXT NOT NULL DEFAULT '{}',
        equipment TEXT NOT NULL DEFAULT '',
        unilateral INTEGER NOT NULL DEFAULT 0,
        custom INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'external_hr', table: 'external_hr', sql: r'''CREATE TABLE external_hr (
        ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        hr INTEGER NOT NULL,
        rr_ms TEXT,
        session_id TEXT,
        PRIMARY KEY (ts, source)
      )'''),
  (type: 'table', name: 'food_def', table: 'food_def', sql: r'''CREATE TABLE food_def (
      key            TEXT PRIMARY KEY,
      label          TEXT NOT NULL,
      brand          TEXT NOT NULL DEFAULT '',
      serving_g      REAL,
      serving_label  TEXT NOT NULL DEFAULT '',
      kcal_100       REAL,
      protein_g_100  REAL,
      carbs_g_100    REAL,
      fat_g_100      REAL,
      fibre_g_100    REAL,
      sugar_g_100    REAL,
      sat_fat_g_100  REAL,
      sodium_mg_100  REAL,
      iron_mg_100    REAL,
      calcium_mg_100 REAL,
      source         TEXT NOT NULL DEFAULT 'manual',
      created_at     INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'food_entry', table: 'food_entry', sql: r'''CREATE TABLE food_entry (
      id            TEXT PRIMARY KEY,
      date          TEXT NOT NULL,
      at_ts         INTEGER,
      meal          TEXT NOT NULL,
      food_key      TEXT,
      label         TEXT NOT NULL,
      quantity      REAL,
      unit          TEXT NOT NULL DEFAULT 'g',
      kcal          REAL,
      protein_g     REAL,
      carbs_g       REAL,
      fat_g         REAL,
      fibre_g       REAL,
      sugar_g       REAL,
      sat_fat_g     REAL,
      sodium_mg     REAL,
      iron_mg       REAL,
      calcium_mg    REAL,
      source        TEXT NOT NULL DEFAULT 'manual',
      confirmed     INTEGER NOT NULL DEFAULT 0,
      note          TEXT NOT NULL DEFAULT '',
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'hyrox_segment', table: 'hyrox_segment', sql: r'''CREATE TABLE hyrox_segment (
      session_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      kind TEXT NOT NULL,
      station TEXT NOT NULL,
      round_index INTEGER,
      planned_distance_m REAL,
      planned_reps INTEGER,
      planned_cal INTEGER,
      goal_sec INTEGER,
      start_ts INTEGER,
      end_ts INTEGER,
      boundary_source TEXT NOT NULL DEFAULT 'unknown',
      workout_id TEXT,
      distance_m REAL,
      distance_source TEXT,
      hr_source TEXT,
      PRIMARY KEY (session_id, idx)
    )'''),
  (type: 'table', name: 'hyrox_session', table: 'hyrox_session', sql: r'''CREATE TABLE hyrox_session (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      preset TEXT NOT NULL,
      status TEXT NOT NULL,
      plan_json TEXT NOT NULL,
      start_ts INTEGER,
      end_ts INTEGER,
      note TEXT NOT NULL DEFAULT '',
      finalized_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      excluded_taps_json TEXT NOT NULL DEFAULT '[]'
    )'''),
  (type: 'table', name: 'imported_measurement', table: 'imported_measurement', sql: r'''CREATE TABLE imported_measurement (
        uuid TEXT PRIMARY KEY,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        source TEXT NOT NULL
      )'''),
  (type: 'table', name: 'imported_workout', table: 'imported_workout', sql: r'''CREATE TABLE imported_workout (
        uuid TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        energy_kcal REAL,
        distance_m REAL,
        steps INTEGER,
        source TEXT NOT NULL
      )'''),
  (type: 'table', name: 'input_rev', table: 'input_rev', sql: r'''CREATE TABLE input_rev (bucket INTEGER PRIMARY KEY, rev INTEGER NOT NULL)'''),
  (type: 'table', name: 'journal', table: 'journal', sql: r'''CREATE TABLE journal (
        date TEXT PRIMARY KEY,
        tags_json TEXT NOT NULL DEFAULT '[]',
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'journal_field_def', table: 'journal_field_def', sql: r'''CREATE TABLE journal_field_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        kind TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        max_value REAL NOT NULL,
        step REAL NOT NULL,
        has_time INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'journal_metric', table: 'journal_metric', sql: r'''CREATE TABLE journal_metric (
        date TEXT NOT NULL,
        field TEXT NOT NULL,
        value REAL NOT NULL,
        at_min INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (date, field)
      )'''),
  (type: 'table', name: 'lab_marker_def', table: 'lab_marker_def', sql: r'''CREATE TABLE lab_marker_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        unit TEXT NOT NULL,
        category TEXT NOT NULL,
        decimals INTEGER NOT NULL DEFAULT 1,
        ref_low REAL,
        ref_high REAL,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'lab_result', table: 'lab_result', sql: r'''CREATE TABLE lab_result (
        marker TEXT NOT NULL,
        taken_on TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (marker, taken_on)
      )'''),
  (type: 'table', name: 'live_coverage', table: 'live_coverage', sql: r'''CREATE TABLE live_coverage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        day TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'band',
        device_id TEXT NOT NULL DEFAULT ''
      )'''),
  (type: 'table', name: 'live_step_calibration', table: 'live_step_calibration', sql: r'''CREATE TABLE live_step_calibration (
        category   TEXT NOT NULL,
        gain       REAL NOT NULL,
        n_runs     INTEGER NOT NULL,
        version    INTEGER NOT NULL,
        updated_ts INTEGER NOT NULL,
        PRIMARY KEY (category)
      )'''),
  (type: 'table', name: 'live_step_calibration_run', table: 'live_step_calibration_run', sql: r'''CREATE TABLE live_step_calibration_run (
        category       TEXT NOT NULL,
        run_ts         INTEGER NOT NULL,
        reference      TEXT NOT NULL,
        expected_steps INTEGER NOT NULL,
        raw_steps      INTEGER NOT NULL,
        cadence_spm    REAL NOT NULL,
        -- Nullable on purpose: a routine whose caller never measured these
        -- stores NULL rather than a fabricated 0.0, which would be
        -- indistinguishable from a real still reading.
        p2p_g          REAL,
        confidence     REAL,
        -- `kLiveStepCounterVersion` that produced raw_steps. NULL = a row
        -- banked before runs were tagged, i.e. the original counter.
        counter_version INTEGER,
        PRIMARY KEY (category, run_ts)
      )'''),
  (type: 'table', name: 'live_workout_tally', table: 'live_workout_tally', sql: r'''CREATE TABLE live_workout_tally (
        workout_id     TEXT PRIMARY KEY,
        updated_ts     INTEGER NOT NULL,
        per_minute_hr  TEXT NOT NULL,
        zone_seconds   TEXT NOT NULL,
        seconds_by_bpm TEXT NOT NULL,
        max_hr_seen    INTEGER NOT NULL DEFAULT 0
      )'''),
  (type: 'table', name: 'med_def', table: 'med_def', sql: r'''CREATE TABLE med_def (
      key           TEXT PRIMARY KEY,
      label         TEXT NOT NULL,
      dose_value    REAL,
      dose_unit     TEXT NOT NULL DEFAULT '',
      kind          TEXT NOT NULL DEFAULT 'medication',
      schedule_json TEXT NOT NULL DEFAULT '[]',
      active        INTEGER NOT NULL DEFAULT 1,
      note          TEXT NOT NULL DEFAULT '',
      created_at    INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'med_dose', table: 'med_dose', sql: r'''CREATE TABLE med_dose (
      med_key     TEXT NOT NULL,
      date        TEXT NOT NULL,
      slot_min    INTEGER NOT NULL,
      taken_ts    INTEGER,
      skipped     INTEGER NOT NULL DEFAULT 0,
      dose_value  REAL,
      note        TEXT NOT NULL DEFAULT '',
      updated_at  INTEGER NOT NULL,
      PRIMARY KEY (med_key, date, slot_min)
    )'''),
  (type: 'table', name: 'metric_method', table: 'metric_method', sql: r'''CREATE TABLE metric_method (
        date TEXT NOT NULL,
        key TEXT NOT NULL,
        method TEXT NOT NULL,
        family TEXT NOT NULL,
        class TEXT NOT NULL,
        PRIMARY KEY (date, key)
      )'''),
  (type: 'table', name: 'metric_series', table: 'metric_series', sql: r'''CREATE TABLE metric_series (
        date TEXT NOT NULL,
        key TEXT NOT NULL,
        value REAL,
        PRIMARY KEY (date, key)
      )'''),
  (type: 'table', name: 'metric_series_version', table: 'metric_series_version', sql: r'''CREATE TABLE metric_series_version (
        date TEXT PRIMARY KEY,
        algo_version INTEGER NOT NULL,
        source TEXT
      , device_family TEXT, coverage_devices TEXT, priority_hash TEXT)'''),
  (type: 'table', name: 'notif_fired', table: 'notif_fired', sql: r'''CREATE TABLE notif_fired (
        key TEXT PRIMARY KEY,
        fired_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'notif_slots', table: 'notif_slots', sql: r'''CREATE TABLE notif_slots (
        category TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        slot INTEGER NOT NULL,
        PRIMARY KEY (category, dedupe_key)
      )'''),
  (type: 'table', name: 'notifications', table: 'notifications', sql: r'''CREATE TABLE notifications (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        date TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        read INTEGER NOT NULL DEFAULT 0
      )'''),
  (type: 'table', name: 'observation', table: 'observation', sql: r'''CREATE TABLE observation (
        device_id    TEXT NOT NULL DEFAULT '',
        ts_ms        INTEGER NOT NULL,
        date         TEXT NOT NULL,
        source_kind  TEXT NOT NULL,
        vendor_key   TEXT,
        key          TEXT,
        value        REAL,
        unit         TEXT,
        attribution  TEXT NOT NULL,
        CHECK (vendor_key IS NOT NULL OR key IS NOT NULL)
      )'''),
  (type: 'table', name: 'raw_archive_frames', table: 'raw_archive_frames', sql: r'''CREATE TABLE raw_archive_frames (
        device_id TEXT NOT NULL DEFAULT '',
        hash BLOB NOT NULL,
        counter INTEGER,
        packet_type INTEGER NOT NULL,
        rec_ts INTEGER,
        captured_at INTEGER NOT NULL,
        reason TEXT NOT NULL,
        hex TEXT,
        frame BLOB,
        UNIQUE (device_id, hash)
      )'''),
  (type: 'table', name: 'samples', table: 'samples', sql: r'''CREATE TABLE samples (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        counter INTEGER,
        ts INTEGER NOT NULL,
        hr INTEGER,
        PRIMARY KEY (device_id, ts_ms)
      )'''),
  (type: 'table', name: 'session_ceiling_rev', table: 'session_ceiling_rev', sql: r'''CREATE TABLE session_ceiling_rev (id INTEGER PRIMARY KEY CHECK (id = 1), rev INTEGER NOT NULL)'''),
  (type: 'table', name: 'session_score_mask', table: 'session_score_mask', sql: r'''CREATE TABLE session_score_mask (session_id TEXT PRIMARY KEY)'''),
  (type: 'table', name: 'session_sensor', table: 'session_sensor', sql: r'''CREATE TABLE session_sensor (session_id TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY (session_id, source))'''),
  (type: 'table', name: 'sessions', table: 'sessions', sql: r'''CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        calories REAL,
        strain REAL,
        max_hr INTEGER,
        duration_min INTEGER,
        zone_min_json TEXT,
        steps INTEGER,
        cadence_spm INTEGER,
        hrr_bpm REAL,
        source TEXT NOT NULL DEFAULT 'manual',
        private INTEGER NOT NULL DEFAULT 0,
        device_family TEXT,
        trace_json TEXT,
        trace_samples INTEGER,
        rpe REAL,
        created_at INTEGER NOT NULL
      , avg_hr INTEGER, vo2max_estimate REAL, end_ts_fabricated INTEGER NOT NULL DEFAULT 0)'''),
  (type: 'table', name: 'signal_priority', table: 'signal_priority', sql: r'''CREATE TABLE signal_priority (
        signal    TEXT NOT NULL,
        device_id TEXT NOT NULL,
        rank      INTEGER NOT NULL,
        user_set  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (signal, device_id)
      )'''),
  (type: 'table', name: 'sleep_nap', table: 'sleep_nap', sql: r'''CREATE TABLE sleep_nap (
        day_id TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL, payload_json TEXT,
        PRIMARY KEY (day_id, start_ts)
      )'''),
  (type: 'table', name: 'sleep_override', table: 'sleep_override', sql: r'''CREATE TABLE sleep_override (
        day_id TEXT PRIMARY KEY,
        onset_ts INTEGER NOT NULL,
        offset_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'sleep_session_candidates', table: 'sleep_session_candidates', sql: r'''CREATE TABLE sleep_session_candidates (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )'''),
  (type: 'table', name: 'step_calibration', table: 'step_calibration', sql: r'''CREATE TABLE step_calibration (
        device_family TEXT NOT NULL,
        wearing       INTEGER NOT NULL,
        factor        REAL NOT NULL,
        n_days        INTEGER NOT NULL,
        version       INTEGER NOT NULL,
        updated_ts    INTEGER NOT NULL,
        PRIMARY KEY (device_family, wearing)
      )'''),
  (type: 'table', name: 'step_calibration_day', table: 'step_calibration_day', sql: r'''CREATE TABLE step_calibration_day (
        day           TEXT NOT NULL,
        device_family TEXT NOT NULL,
        wearing       INTEGER NOT NULL,
        reference_steps INTEGER,
        counter_ticks   INTEGER,
        PRIMARY KEY (day, device_family, wearing)
      )'''),
  (type: 'table', name: 'store_identity', table: 'store_identity', sql: r'''CREATE TABLE store_identity (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL)'''),
  (type: 'table', name: 'strength_set', table: 'strength_set', sql: r'''CREATE TABLE strength_set (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        exercise_key TEXT NOT NULL,
        set_index INTEGER NOT NULL,
        reps INTEGER,
        load_kg REAL,
        rpe INTEGER,
        hold_sec INTEGER,
        rest_sec INTEGER,
        at_ts INTEGER,
        note TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (session_id, seq)
      )'''),
  (type: 'table', name: 'substrate_archive', table: 'substrate_archive', sql: r'''CREATE TABLE substrate_archive (
        device_id     TEXT    NOT NULL DEFAULT '',
        utc_day       INTEGER NOT NULL,
        codec         INTEGER NOT NULL,
        from_ts       INTEGER NOT NULL,
        to_ts         INTEGER NOT NULL,
        onehz_rows    INTEGER NOT NULL,
        rr_rows       INTEGER NOT NULL,
        raw_bytes     INTEGER NOT NULL,
        fingerprint   INTEGER NOT NULL,
        tz_offset_min INTEGER,
        blob          BLOB    NOT NULL,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        PRIMARY KEY (device_id, utc_day)
      )'''),
  (type: 'table', name: 'sync_cursor', table: 'sync_cursor', sql: r'''CREATE TABLE sync_cursor (
        name TEXT PRIMARY KEY,
        value TEXT,
        updated_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'sync_ledger', table: 'sync_ledger', sql: r'''CREATE TABLE sync_ledger (
        chunk_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        acked_at INTEGER,
        last_error TEXT,
        meta_json TEXT NOT NULL DEFAULT '{}'
      )'''),
  (type: 'table', name: 'sync_quarantine', table: 'sync_quarantine', sql: r'''CREATE TABLE sync_quarantine (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        reason TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'table', name: 'triathlon_segment', table: 'triathlon_segment', sql: r'''CREATE TABLE triathlon_segment (
      session_id TEXT NOT NULL,
      idx INTEGER NOT NULL,
      kind TEXT NOT NULL,
      environment TEXT,
      planned_distance_m REAL,
      goal_sec INTEGER,
      start_ts INTEGER,
      end_ts INTEGER,
      boundary_source TEXT NOT NULL DEFAULT 'unknown',
      workout_id TEXT,
      distance_m REAL,
      distance_source TEXT,
      hr_source TEXT,
      PRIMARY KEY (session_id, idx)
    )'''),
  (type: 'table', name: 'triathlon_session', table: 'triathlon_session', sql: r'''CREATE TABLE triathlon_session (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      preset TEXT NOT NULL,
      status TEXT NOT NULL,
      plan_json TEXT NOT NULL,
      start_ts INTEGER,
      end_ts INTEGER,
      note TEXT NOT NULL DEFAULT '',
      finalized_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )'''),
  (type: 'table', name: 'vendor_sleep_epoch', table: 'vendor_sleep_epoch', sql: r'''CREATE TABLE vendor_sleep_epoch (
        device_id TEXT NOT NULL,
        night_onset_ts INTEGER NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        stage TEXT NOT NULL,
        source TEXT NOT NULL,
        decoded_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, start_ts)
      )'''),
  (type: 'table', name: 'wake_day_features', table: 'wake_day_features', sql: r'''CREATE TABLE wake_day_features (
        day_id TEXT NOT NULL,
        algo_version INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        computed_at INTEGER NOT NULL,
        PRIMARY KEY(day_id, algo_version)
      )'''),
  (type: 'table', name: 'workout_route', table: 'workout_route', sql: r'''CREATE TABLE workout_route (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        ts_ms INTEGER NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        alt REAL,
        accuracy REAL, speed REAL,
        PRIMARY KEY (session_id, seq)
      )'''),
  (type: 'table', name: 'workout_split', table: 'workout_split', sql: r'''CREATE TABLE workout_split (
        session_id TEXT NOT NULL,
        km INTEGER NOT NULL,
        meters REAL NOT NULL,
        duration_sec INTEGER NOT NULL,
        avg_hr REAL,
        net_elev_m REAL,
        PRIMARY KEY (session_id, km)
      )'''),
  (type: 'table', name: 'workout_suggestions', table: 'workout_suggestions', sql: r'''CREATE TABLE workout_suggestions (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        avg_bpm INTEGER,
        peak_bpm INTEGER,
        duration_min INTEGER,
        sport TEXT,
        dismissed INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )'''),
  (type: 'trigger', name: 'decoded_onehz_rev_ad', table: 'decoded_onehz', sql: r'''CREATE TRIGGER decoded_onehz_rev_ad
      AFTER DELETE ON decoded_onehz WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_onehz_rev_ai', table: 'decoded_onehz', sql: r'''CREATE TRIGGER decoded_onehz_rev_ai
      AFTER INSERT ON decoded_onehz WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_onehz_rev_au', table: 'decoded_onehz', sql: r'''CREATE TRIGGER decoded_onehz_rev_au
      AFTER UPDATE ON decoded_onehz WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_onehz_rev_au_old', table: 'decoded_onehz', sql: r'''CREATE TRIGGER decoded_onehz_rev_au_old
      AFTER UPDATE ON decoded_onehz WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0 AND (NEW.rec_ts IS NULL OR NEW.rec_ts <= 0 OR NEW.rec_ts / 900 != OLD.rec_ts / 900)
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_rr_rev_ad', table: 'decoded_rr', sql: r'''CREATE TRIGGER decoded_rr_rev_ad
      AFTER DELETE ON decoded_rr WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_rr_rev_ai', table: 'decoded_rr', sql: r'''CREATE TRIGGER decoded_rr_rev_ai
      AFTER INSERT ON decoded_rr WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_rr_rev_au', table: 'decoded_rr', sql: r'''CREATE TRIGGER decoded_rr_rev_au
      AFTER UPDATE ON decoded_rr WHEN NEW.rec_ts IS NOT NULL AND NEW.rec_ts > 0
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT NEW.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = NEW.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = NEW.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'decoded_rr_rev_au_old', table: 'decoded_rr', sql: r'''CREATE TRIGGER decoded_rr_rev_au_old
      AFTER UPDATE ON decoded_rr WHEN OLD.rec_ts IS NOT NULL AND OLD.rec_ts > 0 AND (NEW.rec_ts IS NULL OR NEW.rec_ts <= 0 OR NEW.rec_ts / 900 != OLD.rec_ts / 900)
      BEGIN
        INSERT INTO input_rev(bucket, rev) SELECT OLD.rec_ts / 900, 0
          WHERE NOT EXISTS (SELECT 1 FROM input_rev WHERE bucket = OLD.rec_ts / 900);
        UPDATE input_rev SET rev = rev + 1 WHERE bucket = OLD.rec_ts / 900;
      END'''),
  (type: 'trigger', name: 'raw_archive_delete', table: 'raw_archive_view', sql: r'''CREATE TRIGGER raw_archive_delete INSTEAD OF DELETE ON raw_archive_view BEGIN DELETE FROM raw_archive_frames WHERE device_id = OLD.device_id AND COALESCE(hex, lower(hex(frame))) = OLD.hex; END'''),
  (type: 'trigger', name: 'raw_archive_insert', table: 'raw_archive_view', sql: r'''CREATE TRIGGER raw_archive_insert INSTEAD OF INSERT ON raw_archive_view BEGIN INSERT OR IGNORE INTO raw_archive_frames (device_id, hash, counter, packet_type, rec_ts, captured_at, reason, hex) VALUES (COALESCE(NEW.device_id, ''), CAST('text:' || NEW.hex AS BLOB), NEW.counter, NEW.packet_type, NEW.rec_ts, NEW.captured_at, NEW.reason, NEW.hex); END'''),
  (type: 'trigger', name: 'sessions_ceiling_ad', table: 'sessions', sql: r'''CREATE TRIGGER sessions_ceiling_ad
    AFTER DELETE ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END'''),
  (type: 'trigger', name: 'sessions_ceiling_ai', table: 'sessions', sql: r'''CREATE TRIGGER sessions_ceiling_ai
    AFTER INSERT ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END'''),
  (type: 'trigger', name: 'sessions_ceiling_au', table: 'sessions', sql: r'''CREATE TRIGGER sessions_ceiling_au
    AFTER UPDATE OF id, type, status, start_ts, end_ts ON sessions BEGIN
      INSERT INTO session_ceiling_rev(id, rev) SELECT 1, 0
        WHERE NOT EXISTS (SELECT 1 FROM session_ceiling_rev WHERE id = 1);
      UPDATE session_ceiling_rev SET rev = rev + 1 WHERE id = 1;
    END'''),
  (type: 'trigger', name: 'trg_day_result_imported_ins', table: 'day_result', sql: r'''CREATE TRIGGER trg_day_result_imported_ins AFTER INSERT ON day_result BEGIN UPDATE day_result SET imported = (NEW.payload_json LIKE '%"imported":true%') WHERE rowid = NEW.rowid; END'''),
  (type: 'trigger', name: 'trg_day_result_imported_upd', table: 'day_result', sql: r'''CREATE TRIGGER trg_day_result_imported_upd AFTER UPDATE OF payload_json ON day_result BEGIN UPDATE day_result SET imported = (NEW.payload_json LIKE '%"imported":true%') WHERE rowid = NEW.rowid; END'''),
  (type: 'view', name: 'raw_archive_view', table: 'raw_archive_view', sql: r'''CREATE VIEW raw_archive_view AS SELECT device_id, COALESCE(hex, lower(hex(frame))) AS hex, counter, packet_type, rec_ts, captured_at, reason FROM raw_archive_frames'''),
  (type: 'view', name: 'v_baselines', table: 'v_baselines', sql: r'''CREATE VIEW v_baselines AS
      SELECT key,
             json_extract(payload_json,'$.value')           AS value,
             json_extract(payload_json,'$.mean')            AS mean,
             json_extract(payload_json,'$.z')               AS z,
             json_extract(payload_json,'$.delta')           AS delta,
             json_extract(payload_json,'$.ratio')           AS ratio,
             json_extract(payload_json,'$.n')               AS n,
             updated_at
      FROM baselines'''),
  (type: 'view', name: 'v_daily', table: 'v_daily', sql: r'''CREATE VIEW v_daily AS
      SELECT date,
        MAX(CASE WHEN key='rhr' THEN value END)            AS resting_hr,
        MAX(CASE WHEN key='rmssd' THEN value END)          AS hrv,
        MAX(CASE WHEN key='sdnn' THEN value END)           AS sdnn,
        MAX(CASE WHEN key='readiness' THEN value END)      AS readiness,
        MAX(CASE WHEN key='strain' THEN value END)         AS strain,
        MAX(CASE WHEN key='resp_rate' THEN value END)      AS resp_rate,
        MAX(CASE WHEN key='stress' THEN value END)         AS stress,
        MAX(CASE WHEN key='efficiency' THEN value END)     AS sleep_efficiency,
        MAX(CASE WHEN key='tst_min' THEN value END)        AS sleep_min,
        MAX(CASE WHEN key='deep_min' THEN value END)       AS deep_min,
        MAX(CASE WHEN key='rem_min' THEN value END)        AS rem_min,
        MAX(CASE WHEN key='light_min' THEN value END)      AS light_min,
        MAX(CASE WHEN key='nap_min' THEN value END)        AS nap_min,
        MAX(CASE WHEN key='steps' THEN value END)          AS steps,
        MAX(CASE WHEN key='calories' THEN value END)       AS active_calories,
        MAX(CASE WHEN key='calories_total' THEN value END) AS total_calories,
        MAX(CASE WHEN key='skin_temp_z' THEN value END)    AS skin_temp_z,
        MAX(CASE WHEN key='lf_hf' THEN value END)          AS lf_hf,
        MAX(CASE WHEN key='hrv_cv' THEN value END)         AS hrv_cv,
        MAX(CASE WHEN key='dip_pct' THEN value END)        AS dip_pct,
        MAX(CASE WHEN key='odi_per_hour' THEN value END)   AS odi_per_hour,
        MAX(CASE WHEN key='worn_min' THEN value END)       AS worn_min,
        MAX(CASE WHEN key='hrr_bpm' THEN value END)        AS hrr_bpm,
        MAX(CASE WHEN key='brv_cv' THEN value END)         AS brv_cv,
        MAX(CASE WHEN key='irregular_rhythm_flag' THEN value END) AS irregular_flag
      FROM metric_series GROUP BY date'''),
  (type: 'view', name: 'v_ecg_readings', table: 'v_ecg_readings', sql: r'''CREATE VIEW v_ecg_readings AS
      SELECT id, start_ts, end_ts,
             strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS date,
             wrist, status, category, result_code, avg_hr, quality,
             unreadable_mask, interruptions,
             (end_ts - start_ts) AS duration_s,
             sample_count, sample_rate_hz, sample_unit,
             min_uv, max_uv, rms_uv, missing_segments
      FROM ecg_reading'''),
  (type: 'view', name: 'v_hypnogram', table: 'v_hypnogram', sql: r'''CREATE VIEW v_hypnogram AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result WHERE algo_version <= 124 GROUP BY day_id) m ON r.day_id = m.day_id AND r.algo_version = m.v
        WHERE json_valid(r.payload_json)
      )
      SELECT l.day_id AS date,
             json_extract(e.value,'$.start') AS start_ts,
             json_extract(e.value,'$.end')   AS end_ts,
             json_extract(e.value,'$.stage') AS stage
      FROM latest l, json_each(json_extract(l.payload_json,'$.series.hypnogram')) e'''),
  (type: 'view', name: 'v_insights', table: 'v_insights', sql: r'''CREATE VIEW v_insights AS
      SELECT id, kind, title, body, date, created_at, read FROM notifications'''),
  (type: 'view', name: 'v_metric', table: 'v_metric', sql: r'''CREATE VIEW v_metric AS
      SELECT date, key, value FROM metric_series'''),
  (type: 'view', name: 'v_series', table: 'v_series', sql: r'''CREATE VIEW v_series AS
      WITH latest AS (
        SELECT r.day_id, r.payload_json FROM day_result r
        JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result WHERE algo_version <= 124 GROUP BY day_id) m ON r.day_id = m.day_id AND r.algo_version = m.v
        WHERE json_valid(r.payload_json)
      ),
      curve(sk, pth, vk) AS (
        SELECT 'hr_curve','$.series.hr_curve','$.v'
        UNION ALL SELECT 'strain_curve','$.series.strain_curve','$.v'
        UNION ALL SELECT 'hrv_timeline','$.series.hrv_timeline','$.v'
        UNION ALL SELECT 'hrv_day','$.series.hrv_day','$.v'
        UNION ALL SELECT 'resp_day','$.series.resp_day','$.v'
        UNION ALL SELECT 'skin_temp_day','$.series.skin_temp_day','$.v'
        UNION ALL SELECT 'zone_timeline','$.series.zone_timeline','$.z'
        UNION ALL SELECT 'activity_curve','$.activity_curve','$.v'
      )
      SELECT l.day_id AS date, c.sk AS series,
             json_extract(e.value,'$.t') AS t,
             json_extract(e.value, c.vk) AS v
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth)) e
      WHERE json_type(json_extract(l.payload_json, c.pth)) = 'array'
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + e.key * json_extract(l.payload_json, c.pth||'.dt'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NOT NULL
      UNION ALL
      SELECT l.day_id, c.sk,
             json_extract(l.payload_json, c.pth||'.t0')
               + json_extract(l.payload_json, c.pth||'.to['||e.key||']'),
             e.value
      FROM latest l JOIN curve c
      JOIN json_each(json_extract(l.payload_json, c.pth||'.v')) e
      WHERE json_extract(l.payload_json, c.pth||'.dt') IS NULL
        AND json_extract(l.payload_json, c.pth||'.to') IS NOT NULL
        AND e.key < json_array_length(json_extract(l.payload_json, c.pth||'.to'))'''),
  (type: 'view', name: 'v_sessions', table: 'v_sessions', sql: r'''CREATE VIEW v_sessions AS
      SELECT id, start_ts, end_ts,
             strftime('%Y-%m-%d', start_ts, 'unixepoch', 'localtime') AS date,
             type, status,
             CASE WHEN m.session_id IS NULL THEN calories END AS calories,
             CASE WHEN m.session_id IS NULL THEN strain END AS strain,
             CASE WHEN m.session_id IS NULL THEN max_hr END AS max_hr,
             duration_min, steps,
             CASE WHEN m.session_id IS NULL THEN hrr_bpm END AS hrr_bpm,
             source,
             CASE WHEN m.session_id IS NULL THEN zone_min_json END
               AS zone_min_json
      FROM sessions
      LEFT JOIN session_score_mask m ON m.session_id = sessions.id
      WHERE private = 0'''),
];
