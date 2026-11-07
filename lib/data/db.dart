// Local raw-first storage (SQLite via sqflite).
//
// Durable storage layers:
//   decoded_onehz — canonical per-second decoded substrate, keyed
//                   (device_id, ts_ms) since v47 (ts_ms = rec_ts * 1000).
//   decoded_rr    — sparse RR beats for that substrate, keyed
//                   (device_id, ts_ms, beat_index).
//   samples       — legacy header cache kept only for backward-compat fallback.
//
// `counter` (u32 @[3:7]) is still kept as the strap's record id, but analytics
// read from canonical decoded tables keyed by physiological time so replayed or
// duplicated historical seconds cannot bloat compute.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../compute/substrate.dart' show beatTimesMs;
// The ONE thing this layer takes from compute/: the running build's algo
// version, which every day_result read applies as a CEILING (see [dayResult]).
// `show` keeps the rest of the engine out of this namespace.
import '../coach/coach_db.dart' show CoachDb;
import '../compute/derivation_engine.dart'
    show
        kAlgoVersion,
        kOvernightGiveUpSec,
        kPinWakeToleranceSec,
        pinnableNight,
        overnightSettled,
        recoveryStateOf,
        RecoveryStateWire;
import '../compute/sleep_profile_policy.dart' show SleepProfilePolicy;
import '../ble/adapters/_registry.dart' show kAdapterSignals;
import '../ble/adapters/adapter.dart' show NeutralSample;
import '../ble/adapters/signals.dart' show InputSignal;
import '../import/import_container.dart';
import 'coverage_resolver.dart' show CoverageInterval;
import 'day_label.dart';
import 'activity_store.dart';
import 'attach_copy.dart';
import '../models/activity_suggestion.dart';
import '../compute/accepted_naps.dart';
import '../compute/nap_edits.dart' show NapEditKind;
import '../compute/vendor_sleep.dart' show VendorEpoch, VendorNight;
import 'journal_fields.dart';
import 'live_coverage_policy.dart';
import '../compute/step_calibration_fit.dart';
import 'step_calibration.dart';
import '../sync/reset_gate.dart';
import 'med_store.dart';
import 'models.dart';
import 'nutrition_store.dart';
import 'observation.dart';
import 'series_codec.dart';
import 'substrate_archive.dart';

part 'db/admission.dart';
part 'db/derive_store.dart';
part 'db/feature_store.dart';
part 'db/restore.dart';
part 'db/schema.dart';
part 'db/series_reencode.dart';
part 'db/sync_store.dart';

/// The outcome of a database rebuild: why the old file would not open, where it
/// was parked, and how many rows came back per table.
typedef DbRebuild = ({
  String cause,
  String quarantinePath,
  Map<String, int> salvaged,
});

class LocalDb {
  static Database? _db;
  static String dbName = 'openstrap.db';

  /// Workout sensors (adapter ids) whose rule-R6 flag is on, admitted inside
  /// a session window only ([sessionWindowRows]). Loaded from the flags by
  /// `refreshSessionSensorSources` (compute/inputs/canonical.dart); empty
  /// until one is turned on, which leaves every read as it was.
  static Set<String> sessionSensorSources = const {};

  /// The active wearable's adapter id (flag on), loaded with
  /// [sessionSensorSources]: its rows fill a session window around the
  /// strap's span ([sessionWindowRows]). Null with none.
  static String? sessionWearableSource;

  static Future<Database> get instance async {
    final db = _db;
    // `_db != null` is NOT enough: Android can close the underlying
    // SQLiteDatabase on background teardown without our close() ever nulling
    // `_db`. A plain `_db ??=` then keeps handing back that dead handle, and
    // every write throws `DatabaseException(attempt to re-open an already-closed
    // object)` — a sustained crash burst (seen in the wild on background event
    // ingest). Reopen whenever the cached handle isn't actually open.
    if (db != null && db.isOpen) return db;
    return _writerOpening ??= _openWriter();
  }

  static Future<Database>? _writerOpening;

  static Future<Database> _openWriter() async {
    try {
      // A reader must never retain a handle to a closed/replaced writer's file.
      await _retireReader(drainAll: false);
      return _db = await _openOrRebuild();
    } finally {
      _writerOpening = null;
    }
  }

  /// Set when [_openOrRebuild] had to quarantine an unopenable database and
  /// rebuild. Null on every normal launch. AppState reads it so the user is
  /// TOLD what happened and what survived — a rebuild that happens silently is
  /// indistinguishable from data vanishing.
  static DbRebuild? lastRebuild;

  /// What a rebuild tries to save, in the order it tries — most irreplaceable
  /// first, so a salvage that gets cut short (a genuinely corrupt file gives up
  /// partway) has already banked the rows nothing can regenerate.
  ///
  /// Everything in the first block was typed by a human. Nothing re-measures
  /// it, nothing re-derives it, and it is not in the band's flash. The second
  /// block is measured-once data whose raw substrate is pruned at
  /// `rawRetentionDays`, so it is equally unrecoverable in practice. The third
  /// is the 1 Hz substrate: re-syncable in principle, but the band trims its
  /// flash as we ACK, so in practice this is the only copy of those days too.
  static const _salvageTables = [
    // Secondary devices first: tiny, and every device-keyed row below needs
    // its device to still have a name if the salvage stops partway. The
    // primary row is skipped by the merge, as on a restore.
    'device',
    // Hand-entered. The only copy that exists anywhere.
    'journal',
    'journal_metric',
    'journal_field_def',
    'lab_result',
    'lab_marker_def',
    'strength_set',
    'exercise_def',
    'food_entry',
    'food_def',
    'med_def',
    'med_dose',
    'cycle_log',
    'cycle_symptom',
    'sleep_override',
    'sleep_nap',
    // A ring's own hypnogram. Nothing here can re-derive it.
    'vendor_sleep_epoch',
    'workout_suggestions',
    'breathing_session',
    // Vendor, typed-in and imported scalars: a `reports` band trims its own
    // history and the source app may be gone.
    'observation',
    // Owners before their routes: `workout_route` is keyed by a session id
    // or an imported workout's uuid. Saved activities also merge before
    // their ledger so local decisions can guard incoming records before an
    // imported confirmation becomes local too.
    'sessions',
    'session_sensor',
    'activity_suggestions',
    'activity_review_meta',
    'activity_review_days',
    'imported_workout',
    'workout_route',
    'workout_split',
    // The only copy of what a paired sensor measured during a session.
    'external_hr',
    'imported_measurement',
    // User-initiated ECG readings and the band's raw ECG records recovered
    // through history — the band trims its flash on ACK, so these too are
    // the only copy. Parent before child.
    'ecg_reading',
    'ecg_reading_packet',
    'ecg_raw_packet',
    // Derived once, from raw that no longer exists.
    'day_result',
    'metric_series',
    'metric_series_version',
    'metric_method',
    'baselines',
    'step_calibration',
    'step_calibration_day',
    'live_step_calibration',
    'live_step_calibration_run',
    'raw_archive',
    'device_coverage',
    // Step windows. Every day's steps are read from here, and the band's live
    // pedometer windows exist nowhere else.
    'live_coverage',
    'signal_priority',
    'sync_cursor',
    // The retention window. Big, and last for that reason.
    'decoded_onehz',
    'decoded_rr',
    'samples',
    'events',
    'band_events',
    'band_battery',
    // Pruned decoded substrate: the only copy of every day older than the
    // retention window — and the biggest table, merged bucket by bucket, so
    // dead last: nothing above waits on it.
    'substrate_archive',
  ];

  /// [_open], plus the one recovery that exists for a database that will not
  /// open at all.
  ///
  /// `onUpgrade` runs inside ONE exclusive transaction, so a step that throws
  /// rolls the whole ladder back, the on-disk `user_version` never advances,
  /// and the SAME step throws on the next launch, and the next. Every guard in
  /// the ladder above was added reactively, after a build shipped that bricked
  /// somebody — so the ladder will trip again. What was missing was what
  /// happens next: the app sat on the loading screen forever and reinstalling
  /// was the only way out, which takes the hand-typed entries with it.
  ///
  /// So: never delete, never wipe. Move the unopenable file aside, create a
  /// fresh one at the current schema, and merge back everything the old file
  /// will still hand over — [_salvageTables] order, each table guarded on its
  /// own, so one unreadable table costs that table and nothing else. The
  /// quarantined file STAYS on disk: if the salvage got less than everything,
  /// the rest is still in there and can be handed to a human.
  static Future<Database> _openOrRebuild() => _ldbOpenOrRebuild();

  static Future<void> close() => _withReaderInvalidated(() async {
    // A cold open may have started before close, even without a screen lease.
    try {
      await _writerOpening;
    } catch (_) {
      // The opener's caller owns the error. Still close any live handle below.
    }
    final db = _db;
    if (db != null) {
      await db.close();
      if (identical(_db, db)) _db = null;
    }
  });

  static Database? _reader;
  static Database? _readerWriter;
  static Future<Database?>? _readerOpening;
  static Database? _readerFailedFor;
  static bool _foreground = false;
  static int _readerEpoch = 0;
  static Future<void>? _screenBarrier;
  static Future<void>? _readerClosing;
  static final _readLeases = <Completer<void>>{};
  static final _readerLeases = <Completer<void>>{};

  /// Bare acquisition for diagnostics. Screen queries use [withReadExecutor]
  /// so teardown can wait across all awaits in a read.
  static Future<Database> readExecutor() async {
    while (_screenBarrier != null) {
      await _screenBarrier;
    }
    return _acquireReadExecutor();
  }

  static Future<Database> _acquireReadExecutor() async {
    final writer = await (_writerOpening ?? instance);
    // Includes migrations, repair and any rebuild salvage. Existing leases may
    // fall back to this writer while a store change waits for them to finish.
    if (!_foreground || _screenBarrier != null) return writer;
    final current = _reader;
    if (current != null && current.isOpen && identical(_readerWriter, writer)) {
      return current;
    }
    if (identical(_readerFailedFor, writer)) return writer;
    final epoch = _readerEpoch;
    final opening = _readerOpening ??= _openReader(writer, epoch);
    final opened = await opening;
    if (identical(_readerOpening, opening)) _readerOpening = null;
    return _foreground && epoch == _readerEpoch &&
            identical(_db, writer) && identical(opened, _reader)
        ? opened ?? writer
        : writer;
  }

  static Future<Database?> _openReader(Database writer, int epoch) => _ldbOpenReader(writer, epoch);

  static Future<T> withReadExecutor<T>(
    Future<T> Function(DatabaseExecutor db) read,
  ) => _ldbWithReadExecutor<T>(read);

  static Future<void> setForeground(bool foreground) {
    _foreground = foreground;
    return foreground ? Future<void>.value() : _retireReader();
  }

  static Future<void> _retireReader({bool drainAll = true}) => _ldbRetireReader(drainAll: drainAll);

  /// Block new screen leases while a reset/merge/close changes the store.
  /// Existing acquisitions finish on the writer if their reader open goes stale.
  static Future<T> _withReaderInvalidated<T>(Future<T> Function() action) async {
    final previous = _screenBarrier;
    final done = Completer<void>();
    _screenBarrier = done.future;
    try {
      if (previous != null) await previous;
      await _retireReader();
      return await action();
    } finally {
      if (identical(_screenBarrier, done.future)) _screenBarrier = null;
      done.complete();
    }
  }

  /// Replaces only the second connection's open, never the writer's open.
  @visibleForTesting
  static Future<Database> Function(String path)? debugReaderOpener;

  /// Runs a write against a guaranteed-open handle, reopening ONCE if the
  /// cached handle was closed under us mid-write.
  ///
  /// `instance` validates `isOpen` at acquisition, but Android can tear the
  /// SQLiteDatabase down in the window between acquiring the handle and the
  /// write actually executing (a TOCTOU race — worst on background ingest that
  /// awaits non-DB work, e.g. event parsing, between acquiring `db` and using
  /// it). That surfaced as a sustained `DatabaseException(attempt to re-open an
  /// already-closed object)` burst on the `events` insert (Crashlytics 0.9.13,
  /// processState=BACKGROUND). On that exception we drop the dead handle so the
  /// retry reopens. For best-effort ingest ([bestEffort]) a still-closed DB
  /// after the retry is swallowed — the band re-sends these rows and crashing
  /// the app over a non-durable event write is never the right trade. The
  /// durable sync-commit path leaves it false so a genuine failure still throws
  /// and the HISTORY_END ACK is withheld (safe-trim invariant).
  static Future<T?> _guardedWrite<T>(
    Future<T> Function(Database db) op, {
    bool bestEffort = false,
  }) => _ldbGuardedWrite<T>(op, bestEffort: bestEffort);

  /// The live schema version — the ONE place it is declared. Every
  /// `openDatabase` this class performs (the app DB and the day-export DB) must
  /// pass it: sqflite throws `ArgumentError('onCreate must be null if no
  /// version is specified')` BEFORE opening anything when `onCreate` is given
  /// without `version` (sqflite_common database_mixin.dart).
  static const int schemaVersion = 58;

  /// SQLite caps host parameters per statement (`SQLITE_MAX_VARIABLE_NUMBER` —
  /// only 999 on the builds shipped with older Android/iOS). Any `IN (?, ?, …)`
  /// built from row data MUST be chunked below this; a single day of
  /// `decoded_onehz` is 86 400 counters. Same reason `commitSyncBatch` chunks.
  static const int _maxSqlVars = 500;

  /// THE PRIMARY BAND'S `device_id`, and it is reserved permanently.
  ///
  /// Not a migration default — a standing rule, load-bearing twice over:
  ///  * The newest-wins dedupe on `decoded_onehz` only works while every row
  ///    from the one physical band shares one key value, so a post-reboot
  ///    counter reset and a re-drained record still collide.
  ///  * A BLE `remoteId` is NOT a stable identity (per-app CBPeripheral UUID
  ///    on iOS, a rotating RPA on Android). Letting one reach the key would
  ///    fragment one band into N identities across reinstalls.
  ///
  /// A SECONDARY device gets a real id, issued by its adapter from something
  /// the band emits across the handshake — never from the link.
  static const String kPrimaryDeviceId = '';

  /// Prefs key holding `[remoteId, wearing, wearing_set_ts]`: an explicit
  /// wearing choice waiting for the next primary pairing to adopt it. A
  /// forgotten band leaves its own remoteId; a restore onto an install with
  /// no band yet leaves `''`, which whichever band pairs next takes.
  static const String kPendingWornOnPref = 'paired_worn_on';

  /// The `sync_cursor` name for a per-offloading-device bookmark.
  ///
  /// THE PRIMARY KEEPS THE BARE KEY, FOREVER. This is not cosmetic and it is
  /// not a transitional shim. Every install on disk today stores `counter_hw`,
  /// `rec_ts_hw` and `strap_trim` under those exact names; a naive
  /// `'$base:$deviceId'` renders `'rec_ts_hw:'` for the primary ('' is its id —
  /// see [kPrimaryDeviceId]), which is a NEW, EMPTY key. `RecordGate` would
  /// then seed its frontier from 0, the band would re-offer its whole flash,
  /// and `strap_trim` would echo nothing — the "Groundhog Day" re-flood,
  /// delivered by a migration.
  ///
  /// There is deliberately no migration step for this: the primary's keys are
  /// already correct, and only a device that has never had a cursor gets a
  /// suffixed one.
  static String cursorKeyFor(String base, String deviceId) =>
      deviceId == kPrimaryDeviceId ? base : '$base:$deviceId';

  /// Split [items] into `_maxSqlVars`-sized chunks for `IN (…)` binding.
  static Iterable<List<T>> _sqlVarChunks<T>(List<T> items) sync* {
    for (var i = 0; i < items.length; i += _maxSqlVars) {
      yield items.sublist(
        i,
        i + _maxSqlVars > items.length ? items.length : i + _maxSqlVars,
      );
    }
  }

  /// The most the -wal keeps once a checkpoint has emptied it. See [_open].
  static const int walSizeLimitBytes = 32 << 20;

  static Future<Database> _open() => _ldbOpen();

  static Future<void> _repairOpenSchema(Database db) => _ldbRepairOpenSchema(db);

  /// Older WHOOP CSV imports filed the export's absolute skin temp (°C) under
  /// `scalars.skin_temp_z`, which every reader treats as SDs off baseline, so
  /// 33 °C read as +33 SD in the cross-day temp inputs and the skin temp card.
  /// Imported days are finalized with no raw behind them and never re-derive,
  /// so the import fix alone can't heal them: drop the key from those rows.
  /// Best-effort: a failed heal must never fail the open (that quarantines
  /// the database), it just leaves the stale key behind.
  static Future<void> _scrubImportedSkinTempZ(Database db) async {
    try {
      await db.execute(
        "UPDATE day_result SET payload_json = "
        "json_remove(payload_json, '\$.scalars.skin_temp_z') "
        "WHERE payload_json LIKE '%skin_temp_z%' "
        "AND payload_json LIKE '%whoop_export%' "
        'AND json_valid(payload_json) '
        "AND json_extract(payload_json, '\$.source') = 'whoop_export' "
        "AND json_type(payload_json, '\$.scalars.skin_temp_z') IS NOT NULL",
      );
    } catch (_) {
      // best-effort, see above
    }
  }

  /// Periodic snapshot of a LIVE workout's per-second tallies (per-minute HR
  /// series, zone-seconds, the calorie bpm histogram, the spike-suppressed
  /// peak) — written every ~30s by `AppState._tickWorkout` while a session is
  /// live. On a hard-kill relaunch mid-workout, `_reconcileOrphanedLiveWorkout`
  /// restores from the newest row instead of zeroing strain/calories/zone
  /// minutes back to nothing. Deleted once the workout finishes or is
  /// cancelled — this is scratch state for one in-progress session, never a
  /// historical record.
  static Future<void> _createLiveWorkoutTally(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_workout_tally (
        workout_id     TEXT PRIMARY KEY,
        updated_ts     INTEGER NOT NULL,
        per_minute_hr  TEXT NOT NULL,
        zone_seconds   TEXT NOT NULL,
        seconds_by_bpm TEXT NOT NULL,
        max_hr_seen    INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// Upsert the latest tally snapshot for [workoutId]. Best-effort — a failed
  /// write just means the NEXT periodic tick tries again; it must never take
  /// down the live tick loop itself.
  static Future<void> saveLiveWorkoutTally(Map<String, Object?> row) async {
    final db = await instance;
    await db.insert(
      'live_workout_tally',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The persisted tally row for [workoutId], or null if this session was
  /// never ticked long enough to be snapshotted (or predates this feature).
  static Future<Map<String, Object?>?> liveWorkoutTally(
    String workoutId,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'live_workout_tally',
      where: 'workout_id = ?',
      whereArgs: [workoutId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Drop the tally row for [workoutId] once it is no longer live (finished,
  /// cancelled, or reconciled as stale). Best-effort.
  static Future<void> deleteLiveWorkoutTally(String workoutId) async {
    try {
      final db = await instance;
      await db.delete(
        'live_workout_tally',
        where: 'workout_id = ?',
        whereArgs: [workoutId],
      );
    } catch (_) {
      /* scratch state — a failed cleanup is not worth surfacing */
    }
  }

  /// The column names [table] currently has (empty if the table is absent).
  static Future<Set<String>> _columnsOf(
      DatabaseExecutor db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return {
      for (final c in info)
        if (c['name'] is String) c['name'] as String,
    };
  }

  /// THE ONLY sanctioned way to add a column in a migration step.
  ///
  /// A bare `ALTER TABLE … ADD COLUMN` in the ladder is a latent brick: the
  /// `_create*` helpers are MODERNIZED IN PLACE (they always emit the current
  /// DDL), so any DB old enough to have a table created by a LATER-numbered
  /// step already has the column an EARLIER-numbered ALTER tries to add. That
  /// throws "duplicate column name", and since `onUpgrade` runs inside ONE
  /// exclusive transaction the entire ladder rolls back and `openDatabase`
  /// rethrows — the app is stuck on the loading screen on EVERY launch, with no
  /// way out. Check first; swallow a lost race (SQLite does statement-level
  /// rollback, so a caught failure never poisons the surrounding transaction).
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String ddlType,
  ) async {
    if ((await _columnsOf(db, table)).contains(column)) return;
    try {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $ddlType');
    } catch (_) {
      /* another opener won the race — the column exists now */
    }
  }

  /// v34: the per-second fields a gen5 band computes on its own and reports in
  /// every record — its pedometer's cumulative step count and cadence, its
  /// activity class, a calibrated skin temperature in °C, its on-wrist
  /// determination, and the HR-validity flag plus the second HR byte that
  /// corroborates the primary one. They used to be decoded and dropped.
  ///
  /// v42 adds `ambient_raw` here rather than in its own helper. It is the other
  /// direction (gen4-only — gen5 has no per-second equivalent), but it needs
  /// the exact same treatment for the exact same reason: the mid-ladder
  /// `_backfillDecodedStore` writes through `_queueDecodedOneHz`, which names
  /// the column, so every rebuild path has to hand it back before the backfill
  /// runs or the whole exclusive ladder rolls back. That is what this helper is
  /// for, and every rebuild already calls it.
  ///
  /// Additive and safe on a populated DB: eight nullable columns, no rewrite of
  /// the (million-row) table, no backfill. Existing rows read NULL — which is
  /// the truth for them, since the values were never stored. `skin_temp_raw`,
  /// `skin_contact` and the `spo2_*` columns are deliberately left alone; they
  /// hold real historical data regardless of what the names now suggest.
  static Future<void> _ensureDecodedOneHzBandFields(Database db) => _ldbEnsureDecodedOneHzBandFields(db);

  /// v41: `device_family` — WHICH STRAP MEASURED THIS ROW.
  ///
  /// Stamped AT INGEST from the link that produced it (`ble_engine` pins the
  /// generation at service discovery), because that is the only moment anyone
  /// actually knows. It is never inferred from the data afterwards and never
  /// backfilled with a guess: a gen4 skin-temp ADC count and a gen5 centi-°C
  /// reading share `decoded_onehz`'s columns, so a wrong stamp is worse than no
  /// stamp. Existing rows — and anything imported, which came from no link at
  /// all — read NULL, meaning UNKNOWN PROVENANCE, which readers must treat as
  /// its own case (analytics: `calibrationFor` → null → refuse) rather than as
  /// gen4.
  ///
  /// Nullable TEXT, no DEFAULT, ever: a default would turn "we don't know" into
  /// a claim about the sensor.
  static Future<void> _ensureDeviceFamilyColumns(Database db) async {
    for (final t in const ['decoded_onehz', 'decoded_rr', 'sessions']) {
      await _addColumnIfMissing(db, t, 'device_family', 'TEXT');
    }
  }

  /// v43: `source` — WHICH SENSOR PRODUCED THIS ROW, as distinct from which
  /// strap generation ([_ensureDeviceFamilyColumns]).
  ///
  /// NULL means the band — every row ever written before this column existed,
  /// every import, every raw replay, and every byte the WHOOP link will ever
  /// deliver. A non-NULL value means a peripheral that is NOT the band (today:
  /// a standard Bluetooth heart-rate sensor, `0x180D`).
  ///
  /// This lands BEFORE the first 0x180D byte does, and it exists for exactly
  /// one reason: resting HR from a chest strap and resting HR from wrist PPG
  /// differ SYSTEMATICALLY. Quietly folding both into one baseline puts a step
  /// change into every long-horizon number the app keeps, which surfaces to the
  /// user as readiness reading wrong with no visible cause and no way to find
  /// it. So every read that feeds a baseline, a derive page or the data edge
  /// filters on provenance, and the filter is in place while the answer is
  /// still trivially "all of them".
  ///
  /// THE COLUMN IS AN ADMISSION FLAG, NOT A PROVENANCE ID — see the
  /// SUBSTRATE ADMISSION block at the top of this file, which states the
  /// non-overlap rule for all three provenance columns and owns the two SQL
  /// fragments ([derivableSourceSql], [kPrimaryBandSourceSql]) that every
  /// reader must use instead of writing the predicate by hand.
  ///
  /// Nullable TEXT, no DEFAULT: the same reason `device_family` has none.
  static Future<void> _ensureSourceColumns(Database db) async {
    for (final t in const ['decoded_onehz', 'decoded_rr']) {
      await _addColumnIfMissing(db, t, 'source', 'TEXT');
    }
  }

  /// `decoded_rr.beat_ts_ms` — where the beat actually was, beside the
  /// whole-second `rr_ts_ms` rather than instead of it. NULL on every row
  /// written before this column existed, and that NULL is the honest value: the
  /// sub-second it is built from was never stored and the frames it could be
  /// re-read from are pruned. See [beatTimesMs].
  ///
  /// Not a ladder rung, same as `dyn_accel_g`: `_ensureDecodedStore` runs from
  /// `_repairOpenSchema` on every open, so an existing install gets the column
  /// for one PRAGMA without spending a schema version.
  static Future<void> _ensureBeatTimeColumn(Database db) =>
      _addColumnIfMissing(db, 'decoded_rr', 'beat_ts_ms', 'INTEGER');


  /// v46: retire what v34 banked into `on_wrist` / `hr_valid`, and any
  /// `skin_temp_c` that is really the sensor's unavailable sentinel.
  ///
  /// v34 filled `on_wrist` from gen5 v18 body 60 bits 0-1 and `hr_valid` from
  /// body 15 bit7. Both readings are disproven: bits 0-1 are the primary-flags
  /// bit-8 snapshot (not wear), and bit7 toggles ~50/50 independently of HR
  /// presence across 1,587,671 retained records (not validity). `skin_temp_c`
  /// could likewise hold the AS6221 -50.00 °C unavailable/error code, which is
  /// not a temperature. The writer stopped emitting all three
  /// (`sampleFromGen5Historical`); this clears what it already stored, so no
  /// future reader can pick up a confident answer the data never supported.
  ///
  /// DDL-NEUTRAL on purpose: the columns stay, nullable, exactly as v34 created
  /// them, so a fresh install and an upgraded one still end at the same schema
  /// (the fields remain the right shape should an honest source ever appear).
  /// Idempotent — a second run matches no rows. Cheap enough for the iOS
  /// open-database watchdog: `decoded_onehz` is bounded by `rawRetentionDays`,
  /// this is one scan, and it writes only the rows that carry a value.
  static Future<void> _retireDisprovenOneHzColumns(Database db) async {
    final have = await _columnsOf(db, 'decoded_onehz');
    // Pre-v34 tables never had the columns; nothing to retire.
    if (!have.contains('on_wrist')) return;
    await db.execute(
      'UPDATE decoded_onehz SET '
      'on_wrist = NULL, '
      'hr_valid = NULL, '
      'skin_temp_c = CASE WHEN skin_temp_c <= -49.995 THEN NULL '
      'ELSE skin_temp_c END '
      'WHERE on_wrist IS NOT NULL OR hr_valid IS NOT NULL '
      'OR skin_temp_c <= -49.995',
    );
  }

  static Future<void> _ensureDayResultSkippedColumn(Database db) =>
      _addColumnIfMissing(
        db,
        'day_result',
        'skipped',
        'INTEGER NOT NULL DEFAULT 0',
      );

  static Future<void> _ensureDayResultPartialColumn(Database db) =>
      _addColumnIfMissing(
        db,
        'day_result',
        'partial',
        'INTEGER NOT NULL DEFAULT 0',
      );

  // ── MENSTRUAL SYMPTOM LOG ──────────────────────────────────────────────────
  static Future<void> _createCycleSymptom(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cycle_symptom (
        date TEXT PRIMARY KEY,
        symptoms_json TEXT NOT NULL,
        note TEXT,
        updated_at INTEGER
      )
    ''');
  }

  /// Upsert the symptom set for [date] (empty list clears the row).
  static Future<void> putCycleSymptoms(
    String date,
    List<String> symptoms, {
    String? note,
  }) async {
    final db = await instance;
    if (symptoms.isEmpty && (note == null || note.isEmpty)) {
      await db.delete('cycle_symptom', where: 'date = ?', whereArgs: [date]);
      return;
    }
    await db.insert('cycle_symptom', {
      'date': date,
      'symptoms_json': jsonEncode(symptoms),
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Flip one symptom on [date] against what is STORED, inside one
  /// transaction. The screen used to toggle against its last loaded snapshot
  /// and hand the whole list to [putCycleSymptoms]; a second chip tapped before
  /// the reload landed was computed from the same snapshot, and its REPLACE
  /// wiped the first. It also passed no note, so every tap erased the day's
  /// note. Returns the list now stored.
  static Future<List<String>> toggleCycleSymptom(
    String date,
    String symptom,
  ) => _ldbToggleCycleSymptom(date, symptom);

  /// All symptom rows (newest first): {date, symptoms_json, note}.
  static Future<List<Map<String, dynamic>>> cycleSymptoms() async {
    final db = await instance;
    return db.query('cycle_symptom', orderBy: 'date DESC');
  }

  // ── RESUMABLE-SYNC CURSOR (durable KV) ──────────────────────────────────────
  // A tiny key→value store for sync bookkeeping that must survive process death.
  // Keys we use (durable resumable-sync cursor semantics):
  //   strap_trim       — hex of the last ACKed HISTORY_END 8-byte token
  //   counter_hw       — highest record `counter` we have durably persisted
  //   rec_ts_hw        — highest record `rec_ts` (epoch sec) durably persisted
  //   data_range_lo/hi — strap's own oldest/newest banked record unix (GET_DATA_RANGE)
  // The "safe-trim invariant" is: persist decoded+raw → persist this cursor →
  // ACK with-response. The band only trims its flash once the ACK is link-layer
  // confirmed, so a crash anywhere before the ACK re-delivers the batch.
  static Future<void> _createSyncCursor(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursor (
        name TEXT PRIMARY KEY,
        value TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  // ── SLEEP OVERRIDE (manual / confirmed sleep windows) ───────────────────────
  // The user's word on when they slept — either typed in manually (Approach 1)
  // or a confirmation of the HR-led fallback's proposal (Approach 2). Stored
  // SEPARATELY from the derived day_result so it survives finalization AND any
  // kAlgoVersion bump: the engine re-applies it on every derive of that day.
  //   source: 'manual'    — user typed the times
  //           'confirmed' — user accepted the fallback's proposed window
  // Times are epoch SECONDS (phone clock; raw rec_ts is SET_CLOCK'd to match).
  /// The cross-isolate fire-once claim ledger for notification dedupeKeys.
  ///
  /// SharedPreferences CANNOT enforce fire-once across isolates, however fresh
  /// its reads: a check and a record are two independent operations, so the
  /// foreground derive isolate and the WorkManager background derive isolate
  /// can both read "not fired" before either writes, and both alert. SQLite
  /// can: `INSERT OR IGNORE` against a PRIMARY KEY is ONE atomic statement, and
  /// writers are serialised (a single native handle per process, and SQLite's
  /// own write lock across handles), so for a given key exactly one caller ever
  /// observes `changes() == 1`. That caller owns the fire; everyone else backs
  /// off. See [claimNotifFired] and lib/notify/fired_keys.dart.
  static Future<void> _createNotifFired(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notif_fired (
        key TEXT PRIMARY KEY,
        fired_at INTEGER NOT NULL
      )
    ''');
  }

  /// The cross-isolate OS-notification-id slot allocator (see
  /// [claimNotifSlot] and lib/notify/notification_ids.dart).
  ///
  /// Same root cause as [_createNotifFired]: SharedPreferences' read-then-write
  /// has no atomicity across isolates, so two derivation isolates allocating a
  /// slot for two different dedupeKeys in the same category band at nearly the
  /// same instant can both read the same free candidate and both write it,
  /// producing the same OS notification id and silently dropping one alert.
  /// The UNIQUE index on `(category, slot)` is what makes an allocation
  /// atomic: `INSERT OR IGNORE` either claims the slot or fails, there is no
  /// window where two writers both believe they own it.
  static Future<void> _createNotifSlots(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notif_slots (
        category TEXT NOT NULL,
        dedupe_key TEXT NOT NULL,
        slot INTEGER NOT NULL,
        PRIMARY KEY (category, dedupe_key)
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_notif_slots_owner '
      'ON notif_slots(category, slot)',
    );
  }

  /// Atomically claim [key] for a one-time OS notification fire.
  ///
  /// Returns true iff THIS caller won the claim (the row did not exist and we
  /// inserted it). A concurrent claimant — in this isolate or the other
  /// derivation isolate — gets false and MUST NOT present.
  ///
  /// Throws if the claim can't be decided, deliberately: the caller falls back
  /// to the best-effort store rather than treating an unusable DB as "already
  /// fired", which would silently swallow every notification on the device.
  static Future<bool> claimNotifFired(String key, {int? firedAtMs}) async {
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final won = await _guardedWrite<bool>((db) async {
      return db.transaction<bool>((txn) async {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [key, now],
        );
        // changes() reports rows touched by the statement just executed on this
        // connection; inside the transaction that is unambiguously our INSERT.
        final n = Sqflite.firstIntValue(await txn.rawQuery('SELECT changes()'));
        return n == 1;
      });
    });
    if (won == null) throw StateError('notif_fired: claim undecided');
    return won;
  }

  /// Give back a claim taken by [claimNotifFired] — used when the present did
  /// NOT actually happen (permission denied, OS error), so a later attempt can
  /// still fire. Best-effort: never throws into the notification path.
  static Future<void> releaseNotifFired(String key) async {
    await _guardedWrite<int>(
      (db) => db.delete('notif_fired', where: 'key = ?', whereArgs: [key]),
      bestEffort: true,
    );
  }

  /// Whether [key] has already been claimed (read-only; does not claim).
  static Future<bool> notifFiredExists(String key) async {
    final db = await instance;
    final rows = await db.query(
      'notif_fired',
      columns: ['key'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Atomically get-or-allocate the OS notification id slot for
  /// `(category, dedupeKey)`. Returns the existing slot if one is already
  /// owned; otherwise probes `bandSize` candidates starting at [startAt] and
  /// claims the first free one via `INSERT OR IGNORE` against the
  /// `(category, slot)` UNIQUE index. [startAt] is only a hint for where to
  /// start probing; correctness comes from the UNIQUE index, not from it
  /// being fresh — a stale hint just means a few wasted probes, never a
  /// collision.
  ///
  /// Throws if the claim can't be decided — same contract as
  /// [claimNotifFired] — so the caller falls back to the best-effort
  /// SharedPreferences scheme rather than silently misallocating.
  static Future<int> claimNotifSlot(
    String category,
    String dedupeKey, {
    required int startAt,
    required int bandSize,
    int maxProbes = 1024,
  }) => _ldbClaimNotifSlot(category, dedupeKey, startAt: startAt, bandSize: bandSize, maxProbes: maxProbes);

  /// Seed claims for [keys] without taking ownership — used once to carry the
  /// legacy SharedPreferences fired-key list over, so keys that already fired
  /// under the old store don't re-fire on the upgrade.
  static Future<void> seedNotifFired(
    Iterable<String> keys, {
    int? firedAtMs,
  }) async {
    if (keys.isEmpty) return;
    final now = firedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    await _guardedWrite<void>((db) async {
      final batch = db.batch();
      for (final k in keys) {
        batch.rawInsert(
          'INSERT OR IGNORE INTO notif_fired(key, fired_at) VALUES(?, ?)',
          [k, now],
        );
      }
      await batch.commit(noResult: true);
    }, bestEffort: true);
  }

  /// Drop dated claims whose leading "YYYY-MM-DD" is before [cutoffDate].
  ///
  /// Undated keys (e.g. `alarm_fired:<epoch>`) are left alone: they have no day
  /// to expire against, and they're rare enough to be self-limiting. Matches
  /// the retention semantics of the SharedPreferences fallback exactly.
  static Future<void> pruneNotifFired(String cutoffDate) async {
    await _guardedWrite<int>(
      (db) => db.rawDelete(
        "DELETE FROM notif_fired "
        "WHERE substr(key, 1, 10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "
        "AND substr(key, 1, 10) < ?",
        [cutoffDate],
      ),
      bestEffort: true,
    );
  }

  // ── alarm_schedule — the weekly wake-alarm schedule ─────────────────────

  static Future<void> _createAlarmSchedule(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS alarm_schedule (
        weekday INTEGER NOT NULL,
        hour    INTEGER NOT NULL,
        minute  INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        smart_window_minutes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (weekday)
      )
    ''');
  }

  /// Every configured weekday row, in no particular order — callers that care
  /// about weekday order (the UI, [nextAlarmOccurrence]) sort/fill it
  /// themselves. A weekday absent from this list has never been configured;
  /// it is NOT the same as a row with `enabled = 0`, and callers must not
  /// collapse the two (see `AlarmScheduleEntry` / `fillDefaultAlarmSchedule`
  /// in state/alarm_schedule.dart, which is where that distinction is made).
  static Future<List<Map<String, Object?>>> alarmScheduleRows() async {
    final db = await instance;
    return db.query('alarm_schedule');
  }

  // ── WHOOP MG ECG ────────────────────────────────────────────────────────────
  // Three tables. `ecg_reading` is one user-initiated Labrador reading — the
  // band-reported result, not a phone-side diagnosis. `ecg_reading_packet` is
  // the accepted R17 window, one row per accepted packet in order, with the
  // exact signed-i16-LE samples as a BLOB (the first BLOB column in this
  // schema — every other payload is hex TEXT; the sample block is the one
  // place a compact binary earns it) plus the exact inner hex, and a
  // placeholder row for the ONE empty segment the official accumulator
  // inserts at a sequence jump. `ecg_raw_packet` is the raw R16 record the
  // band saved and ordinary history later delivered — kept byte-exact, keyed
  // by its bytes, never decoded here.
  //
  // UNITS. start_ts / end_ts / strap_terminal_ts / strap_seconds are SECONDS
  // (epoch or strap); created_at / captured_at are epoch MILLISECONDS — the
  // same split raw_archive / RawRecord already use. `sample_unit` names what
  // the samples are (filtered, input-referred integer microvolts); no lead or
  // polarity is claimed anywhere.
  //
  // NO FOREIGN KEYS: this database never enables PRAGMA foreign_keys, so a
  // REFERENCES clause would be inert. The reading→packet cascade is manual,
  // inside one transaction ([deleteEcgReading]) — the same discipline
  // decoded_onehz/decoded_rr use.
  static Future<void> _createEcgTables(Database db) => _ldbCreateEcgTables(db);

  /// Step calibration: one profile per (device_family, wearing), and the
  /// per-day observations it is fitted from.
  static Future<void> _createStepCalibration(Database db) => _ldbCreateStepCalibration(db);

  /// Tag column for calibration runs, and drop the runs and profiles the
  /// current step counter did not produce.
  ///
  /// On the every-open repair path rather than behind a schema version: the
  /// column is additive, and the clear has to run again after a restore, which
  /// can merge an older backup's untagged runs back in. Both tables hold a
  /// handful of rows, so this is cheap.
  ///
  /// Cleared rather than kept-and-ignored because a stale run is not evidence
  /// for anything this build computes, and leaving it would make the
  /// calibration screen count routines that no longer contribute to the fit.
  static Future<void> _ensureLiveStepCalibrationCounterVersion(
    Database db,
  ) => _ldbEnsureLiveStepCalibrationCounterVersion(db);

  /// Idempotent by key. NULL reference_steps = the phone did not cover the day.
  static Future<void> putStepCalibrationDay({
    required String day,
    required String deviceFamily,
    required int wearing,
    int? referenceSteps,
    int? counterTicks,
  }) => _ldbPutStepCalibrationDay(day: day, deviceFamily: deviceFamily, wearing: wearing, referenceSteps: referenceSteps, counterTicks: counterTicks);

  /// Observed days for one (family, wearing) pair, most recent first.
  static Future<List<Map<String, Object?>>> stepCalibrationDays(
    String deviceFamily,
    int wearing, {
    int limit = 30,
  }) async {
    final db = await instance;
    return db.query(
      'step_calibration_day',
      where: 'device_family = ? AND wearing = ?',
      whereArgs: [deviceFamily, wearing],
      orderBy: 'day DESC',
      limit: limit,
    );
  }

  /// Sets `device.wearing` and stamps `wearing_set_ts` only on a real change
  /// (re-picking the same location must not invalidate learned days).
  /// Returns rows updated; 0 means the device row is gone.
  static Future<int> setDeviceWearing(
    int wearing, [
    String id = kPrimaryDeviceId,
  ]) async {
    final db = await instance;
    return db.rawUpdate(
      'UPDATE device SET wearing = ?, wearing_set_ts = '
      'CASE WHEN wearing = ? THEN wearing_set_ts ELSE ? END '
      'WHERE id = ?',
      [
        wearing,
        wearing,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        id,
      ],
    );
  }

  /// Carry an EARLIER explicit wearing choice onto a row that has none of its
  /// own (`wearing_set_ts IS NULL`: fresh after a forget/re-pair, or a restore
  /// target nobody has set yet). The stamp is kept, not renewed — the days
  /// before it stay refused exactly as they were. Without this the row's
  /// DEFAULT silently says wrist while the arm profile survives, and wrist
  /// days start learning from arm-worn data.
  static const String _adoptWearingSql =
      'UPDATE device SET wearing = ?, wearing_set_ts = ? '
      'WHERE id = ? AND wearing_set_ts IS NULL';

  /// [executor] includes adoption in the caller's pairing transaction.
  static Future<int> adoptDeviceWearing(
    int wearing,
    int setTs, [
    String id = kPrimaryDeviceId,
    DatabaseExecutor? executor,
  ]) async {
    final db = executor ?? await instance;
    return db.rawUpdate(_adoptWearingSql, [wearing, setTs, id]);
  }

  /// Raw `device.wearing`, null when there is no device row.
  static Future<int?> deviceWearingRaw([String id = kPrimaryDeviceId]) async {
    final row = await deviceRow(id);
    return (row?['wearing'] as num?)?.toInt();
  }

  /// The stored profile for a (family, wearing) pair, or null when none was
  /// learned or the stored version is not this code's.
  static Future<StepCalibrationProfile?> stepCalibrationProfile(
    String deviceFamily,
    int wearing,
  ) => _ldbStepCalibrationProfile(deviceFamily, wearing);

  static Future<void> putStepCalibrationProfile(
    StepCalibrationProfile p,
  ) async {
    final db = await instance;
    await db.insert(
      'step_calibration',
      {
        'device_family': p.deviceFamily,
        'wearing': p.wearing,
        'factor': p.factor,
        'n_days': p.nDays,
        'version': p.version,
        'updated_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── live 100 Hz pedometer calibration (per activity family) ───────────────

  /// Admitted calibration runs, newest first. Read back into the pure fit; the
  /// stored rows are the evidence the gain is a ratio of sums over.
  static Future<List<StepCalibrationRun>> liveStepCalibrationRuns({
    DatabaseExecutor? exec,
  }) => _ldbLiveStepCalibrationRuns(exec: exec);

  /// Bank one run. The caller must have admitted it first — a refused run is a
  /// claim about the routine, not evidence, and storing it would let it weigh on
  /// every later refit.
  ///
  /// Idempotent by (category, run_ts): re-banking the same routine replaces its
  /// row rather than counting it twice.
  static Future<void> putLiveStepCalibrationRun(
    StepCalibrationRun r, {
    required int runTs,
    DatabaseExecutor? exec,
  }) => _ldbPutLiveStepCalibrationRun(r, runTs: runTs, exec: exec);

  /// Bank one accepted calibration run and refit the family it belongs to.
  ///
  /// ONE call from the calibration screen, because the two writes must not be
  /// performed by hand in two places: a run stored without the profile it
  /// implies — or the reverse — leaves the app correcting with a gain that does
  /// not match the evidence that produced it, and nothing downstream could tell.
  ///
  /// The caller must clear [AppState.invalidateLiveStepCalibration] afterwards,
  /// or a walk already in progress would bank with the previous gain.
  ///
  /// Returns the refitted profile, so the screen can show the wearer the number
  /// their routine just produced instead of a generic acknowledgement.
  static Future<LiveStepGainProfile> bankLiveStepCalibrationRun(
    StepCalibrationRun run, {
    required int runTs,
    DateTime? now,
  }) => _ldbBankLiveStepCalibrationRun(run, runTs: runTs, now: now);

  /// Serialises calibration saves — see [bankLiveStepCalibrationRun].
  static Future<void> _liveStepGainLock = Future<void>.value();

  /// Recompute and store one family's gain from every admitted run on record.
  ///
  /// Separate from the banking call so a torn state is REPAIRABLE: if a save
  /// ever leaves a run durable without the profile it implies — a process kill
  /// between the two writes, a failed refit — running this again derives the
  /// right answer from the rows, because both sides are idempotent by key and
  /// the fit is a pure function of the stored evidence.
  static Future<LiveStepGainProfile> refitLiveStepGain(
    StepCategory category, {
    DateTime? now,
    DatabaseExecutor? exec,
  }) async {
    final rows = await liveStepCalibrationRuns(exec: exec);
    final profile = estimateLiveStepGain(
      category,
      rows,
      now: now ?? DateTime.now(),
    );
    await putLiveStepGainProfile(profile, exec: exec);
    return profile;
  }

  /// Refit every family that has stored runs. A restore merges the backup's
  /// runs into this phone's and its profile rows over this phone's, so neither
  /// side's stored gain describes the combined evidence until this runs.
  static Future<void> refitAllLiveStepGains({DateTime? now}) {
    final chained = _liveStepGainLock.then((_) async {
      final db = await instance;
      await db.transaction((txn) async {
        final runs = await liveStepCalibrationRuns(exec: txn);
        final categories = {for (final r in runs) r.category};
        for (final c in categories) {
          await putLiveStepGainProfile(
            estimateLiveStepGain(c, runs, now: now ?? DateTime.now()),
            exec: txn,
          );
        }
      });
    });
    _liveStepGainLock = chained.then((_) {}, onError: (_) {});
    return chained;
  }

  /// The stored gain for one family, or null when none was fitted or the stored
  /// version is not this code's. Null means "behave exactly as before" — never
  /// a fabricated 1.0 that hides a mismatch.
  static Future<LiveStepGainProfile?> liveStepGainProfile(
    StepCategory category,
  ) => _ldbLiveStepGainProfile(category);

  static Future<void> putLiveStepGainProfile(
    LiveStepGainProfile p, {
    DatabaseExecutor? exec,
  }) async {
    final db = exec ?? await instance;
    await db.insert(
      'live_step_calibration',
      {
        'category': p.category.key,
        'gain': p.gain,
        'n_runs': p.nRuns,
        'version': p.version,
        'updated_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Persist one accepted reading and its packets ATOMICALLY. Throws on any
  /// failure (including an id collision — a re-save of the same reading is a
  /// bug, not a merge), and the caller must not present a completed reading
  /// unless this returned. [packets] are inserted in list order as ordinals
  /// 0..n-1; a placeholder packet carries an empty BLOB and empty inner_hex.
  static Future<void> insertEcgReading(
    Map<String, Object?> reading,
    List<Map<String, Object?>> packets,
  ) => _ldbInsertEcgReading(reading, packets);

  /// Saved readings, newest first, WITHOUT packets.
  static Future<List<Map<String, Object?>>> listEcgReadings({
    int limit = 200,
  }) async {
    final db = await instance;
    return db.query('ecg_reading', orderBy: 'start_ts DESC', limit: limit);
  }

  /// One reading row, or null.
  static Future<Map<String, Object?>?> ecgReading(String id) async {
    final db = await instance;
    final r = await db.query('ecg_reading', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  /// The accepted packets of [id] in ordinal order (placeholders included).
  static Future<List<Map<String, Object?>>> ecgReadingPackets(
    String id,
  ) async {
    final db = await instance;
    return db.query(
      'ecg_reading_packet',
      where: 'reading_id = ?',
      whereArgs: [id],
      orderBy: 'ordinal ASC',
    );
  }

  /// Delete a reading and ITS packets in one transaction (manual cascade —
  /// see [_createEcgTables]). Raw R16 rows are independent history evidence
  /// and are not deleted with a reading; their association is cleared.
  static Future<void> deleteEcgReading(String id) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete(
        'ecg_reading_packet',
        where: 'reading_id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'ecg_raw_packet',
        {'reading_id': null},
        where: 'reading_id = ?',
        whereArgs: [id],
      );
      await txn.delete('ecg_reading', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Update the free-text notes of a reading.
  static Future<void> setEcgReadingNotes(String id, String? notes) async {
    final db = await instance;
    await db.update(
      'ecg_reading',
      {'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// How many raw R16 records history has recovered (diagnostics).
  static Future<int> ecgRawPacketCount() async {
    final db = await instance;
    final r = await db.rawQuery('SELECT COUNT(*) AS n FROM ecg_raw_packet');
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Upsert one weekday's slot. [weekday] is 0=Mon..6=Sun (see
  /// `_createAlarmSchedule`'s doc); out-of-range values are the caller's bug,
  /// not something this layer silently clamps.
  static Future<void> setAlarmScheduleDay({
    required int weekday,
    required int hour,
    required int minute,
    required bool enabled,
    int smartWindowMinutes = 0,
  }) => _ldbSetAlarmScheduleDay(weekday: weekday, hour: hour, minute: minute, enabled: enabled, smartWindowMinutes: smartWindowMinutes);

  /// Wipe the whole weekly schedule — the "Cancel-all" half of disabling the
  /// alarm (see AppState.disableAlarm), so a cancelled alarm cannot silently
  /// re-arm itself from a schedule the user thought they'd cleared.
  static Future<void> clearAlarmSchedule() async {
    final db = await instance;
    await db.delete('alarm_schedule');
  }

  /// `decoded_onehz` rows with `rec_ts` (unix seconds) in
  /// `[sinceEpochSec, untilEpochSec]`, oldest first — hr + accel only. Used by
  /// the Smart Wake Window check (state/smart_wake.dart) to read a short
  /// recent slice and the resting baseline that precedes it. No LIMIT: every
  /// call site passes a window measured in single-digit minutes to ~90
  /// minutes, at 1 row/sec that is at most a few thousand rows.
  ///
  /// Rows with a null hr/ax/ay/az are excluded: those columns are legitimately
  /// nullable (a v25 record with no usable gravity vector, see the
  /// v25-exclusion note near `FirmwareAwareR24Decoder().decode`'s call site),
  /// and `SmartWakeSample.fromRow` requires all four non-null.
  static Future<List<Map<String, Object?>>> onehzHrAccelBetween(
    int sinceEpochSec,
    int untilEpochSec,
  ) async {
    final db = await instance;
    return db.query(
      'decoded_onehz',
      columns: const ['rec_ts', 'hr', 'ax', 'ay', 'az'],
      where: 'rec_ts >= ? AND rec_ts <= ? '
          'AND hr IS NOT NULL AND ax IS NOT NULL AND ay IS NOT NULL AND az IS NOT NULL',
      whereArgs: [sinceEpochSec, untilEpochSec],
      orderBy: 'rec_ts ASC',
    );
  }

  /// sleep_nap — the user's edits to a day's naps.
  ///
  /// Separate from `sleep_override` on purpose: that table means "the main
  /// sleep window for this day", which is one thing, while naps are a list.
  /// Widening its primary key would have made "the main sleep" and "a nap"
  /// indistinguishable in storage.
  ///
  /// Edits are stored SEPARATELY from the detector's output and replayed over
  /// it on every derivation. The detector improves; a day re-derived under a
  /// better stager should still respect "there was no nap here", and baking
  /// the edit into the result would freeze the old detection alongside it.
  ///
  /// `source` is 'manual' (a nap the user logged) or 'rejected' (a detected
  /// one they removed — the window is stored so it keeps suppressing that nap
  /// even after the detector's bounds shift by a minute).
  static Future<void> _createSleepNap(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_nap (
        day_id TEXT NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (day_id, start_ts)
      )
    ''');
  }

  /// A band's own hypnogram, one row per epoch, stages already in our
  /// `stages4` words. `night_onset_ts` chains an epoch onto the night of the
  /// same device's epoch that ended at most [_kVendorNightChainSec] before it.
  /// Read only by the `vendor_staged` sleep rung, after its plausibility gate.
  static Future<void> _createVendorSleepEpoch(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vendor_sleep_epoch (
        device_id TEXT NOT NULL,
        night_onset_ts INTEGER NOT NULL,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        stage TEXT NOT NULL,
        source TEXT NOT NULL,
        decoded_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, start_ts)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_vendor_sleep_epoch_night '
        'ON vendor_sleep_epoch(night_onset_ts)');
  }

  static const int _kVendorNightChainSec = 30 * 60;

  /// Bank [epochs] for [deviceId]. REPLACE on (device, start): a re-read page
  /// overwrites itself. A night re-read with its epochs moved (a ring that
  /// anchors its night at the end, re-closing it later) replaces every epoch
  /// of the device's that the new ones overlap, so the two never stack. With
  /// [wholeNights] (a band that only ever sends whole nights) the overlapped
  /// stored night goes entire, its epochs outside the new ones included.
  ///
  /// With [resetGeneration] (a sensor session's writes) this runs on the
  /// commit gate and is refused there once a "delete everything" has started
  /// since, exactly as [commitSyncBatch] is: [wipeAll] is on the same gate, so
  /// nothing checked before the reset can land after the wipe.
  static Future<void> putVendorSleepEpochs(
    List<VendorEpoch> epochs, {
    required String deviceId,
    required String source,
    bool wholeNights = false,
    int? resetGeneration,
  }) {
    if (resetGeneration == null) {
      return _putVendorSleepEpochs(epochs,
          deviceId: deviceId, source: source, wholeNights: wholeNights);
    }
    return _withCommitGate(() {
      _refuseAfterReset(resetGeneration);
      return _putVendorSleepEpochs(epochs,
          deviceId: deviceId, source: source, wholeNights: wholeNights);
    });
  }

  static void _refuseAfterReset(int resetGeneration) {
    if (ResetGate.changedSince(resetGeneration)) {
      throw StateError('data reset in progress');
    }
  }

  static Future<void> _putVendorSleepEpochs(
    List<VendorEpoch> epochs, {
    required String deviceId,
    required String source,
    required bool wholeNights,
  }) => _ldbPutVendorSleepEpochs(epochs, deviceId: deviceId, source: source, wholeNights: wholeNights);

  /// `{device id -> end of its newest banked vendor sleep epoch}`.
  static Future<Map<String, int>> lastVendorSleepEndTsByDevice() async {
    final db = await instance;
    return {
      for (final r in await db.rawQuery('SELECT device_id, MAX(end_ts) AS t '
          'FROM vendor_sleep_epoch GROUP BY device_id'))
        r['device_id'] as String: (r['t'] as num).toInt(),
    };
  }

  /// Every banked vendor night whose onset is in [[fromSec], [toSec]).
  static Future<List<VendorNight>> vendorSleepNights(
      int fromSec, int toSec) => _ldbVendorSleepNights(fromSec, toSec);

  static Future<void> _createSleepOverride(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sleep_override (
        day_id TEXT PRIMARY KEY,
        onset_ts INTEGER NOT NULL,
        offset_ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Upsert the user's sleep window for [dayId] (local date label). [source] is
  /// 'manual' or 'confirmed'. Replaces any prior override for that day.
  static Future<void> putSleepOverride({
    required String dayId,
    required int onsetTs,
    required int offsetTs,
    required String source,
  }) async {
    final db = await instance;
    await db.insert('sleep_override', {
      'day_id': dayId,
      'onset_ts': onsetTs,
      'offset_ts': offsetTs,
      'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await releaseFrozenHeadline(dayId);
  }

  /// A sleep correction to the pinned day is the user's word, not drift: drop
  /// the morning pin so the re-derive pins the corrected readiness instead of
  /// holding the old night's value until midnight.
  static Future<void> releaseFrozenHeadline(String dayId) async {
    if ((await frozenHeadline())?.day == dayId) {
      await deleteCursor(kFrozenHeadlineCursor);
    }
  }

  /// The user's sleep window for [dayId], or null if none.
  static Future<Map<String, dynamic>?> getSleepOverride(String dayId) async {
    final db = await instance;
    final rows = await db.query(
      'sleep_override',
      where: 'day_id = ?',
      whereArgs: [dayId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Remove the override for [dayId] (revert to auto detection).
  static Future<void> deleteSleepOverride(String dayId) async {
    final db = await instance;
    await db.delete('sleep_override', where: 'day_id = ?', whereArgs: [dayId]);
    await releaseFrozenHeadline(dayId);
  }

  /// Every day that currently has a user override — these must be force-derived
  /// even when finalized, so an edit to a locked day actually takes effect.
  static Future<Set<String>> sleepOverrideDays() async {
    final db = await instance;
    final rows = await db.query('sleep_override', columns: ['day_id']);
    return {for (final r in rows) r['day_id'] as String};
  }

  // ── IMPORTED MEASUREMENTS FROM DEVICES WE ARE NOT ───────────────────────────
  /// Readings a CLEARED device took and wrote to the phone's health store: a
  /// blood-pressure cuff, a CGM, a thermometer.
  ///
  /// THE WHOLE VALUE IS THAT OPENSTRAP DID NOT MEASURE IT. The source name is
  /// mandatory and travels with every row, and these never blend into a
  /// composite of ours — there is no "combined" anything, and no derived number
  /// takes one of these as an input.
  ///
  /// ⚠️ READ-ONLY INPUTS TO DISPLAY. NEVER TRAINING TARGETS. ⚠️
  /// The moment a cuff series exists in the same database as a wrist PPG
  /// series, someone will want to fit a wrist→blood-pressure mapping on it.
  /// That is a cuffless-blood-pressure claim from a device cleared for nothing
  /// of the kind, and that path ends at a regulator's warning letter. These
  /// rows may be SHOWN next to ours and may never be REGRESSED against ours.
  /// This comment lives here, at the table, and not only in a document,
  /// because the document is not what the next person reads.
  ///
  /// Keyed by the store's own record uuid, so re-reading the same window is
  /// idempotent and an edit made in the source app lands as an update.
  /// Readings taken by a device that is CLEARED to take them — a BP cuff, a
  /// CGM, a thermometer. `source` is NOT NULL because the whole value of these
  /// rows is that OpenStrap did not measure them.
  ///
  /// READ-ONLY INPUTS TO DISPLAY. NEVER TRAINING TARGETS. the moment a cuff
  /// series and a wrist PPG series live in one database, the obvious next idea
  /// is to fit one to the other — and a wrist→BP mapping is a cuffless blood
  /// pressure claim from an uncleared device, which is the exact category that
  /// earned WHOOP an FDA Warning Letter in Jul 2025 (trend-only, no units, and
  /// the general-wellness defence was rejected anyway). so: this table may be
  /// JOINed for display. it may not be joined to `decoded_onehz`, `decoded_rr`
  /// or `metric_series` to fit, calibrate, validate or regress anything of
  /// ours, and no derived value may take one of these rows as an input.
  ///
  /// NEVER BLENDED either — no combined series, no averaging an imported
  /// reading with one of ours, no "your blood pressure" without the cuff's name
  /// attached. see health/health_measurement_import.dart, which states the same
  /// guard on the write side; it is in both places on purpose.
  static Future<void> _createImportedMeasurement(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_measurement (
        uuid TEXT PRIMARY KEY,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT NOT NULL,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_measurement_kind '
      'ON imported_measurement(kind, ts)',
    );
  }

  /// Upsert imported readings. Idempotent on the source store's uuid.
  static Future<int> putImportedMeasurements(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return 0;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'imported_measurement',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

  /// Imported readings of one kind, newest first. The caller renders the
  /// `source` with the value; a row without its source is not renderable.
  static Future<List<Map<String, dynamic>>> importedMeasurements(
    String kind, {
    int limit = 200,
  }) async {
    final db = await instance;
    return db.query(
      'imported_measurement',
      where: 'kind = ?',
      whereArgs: [kind],
      orderBy: 'ts DESC',
      limit: limit,
    );
  }

  // ── DEVICES (the things that measure) ─────────────────────────────────────
  /// The devices this phone knows about, one row each.
  ///
  /// Until now a "device" was TWO SharedPreferences scalars (`paired_remote_id`
  /// / `paired_serial`), which can hold exactly one band, carries no state
  /// beside the id, and cannot be joined to anything. `decoded_onehz`,
  /// `decoded_rr` and `samples` have been keyed by `device_id` since v47 with
  /// nothing on the other end of that key — this is the other end.
  ///
  /// `id` IS the `device_id` those tables carry, so [kPrimaryDeviceId] (`''`)
  /// is this table's primary row, permanently (ASSUMPTIONS A1). That is what
  /// keeps an unstable BLE `remoteId` — a per-app CBPeripheral UUID on iOS, a
  /// rotating RPA on Android — out of the key: it lives in `remote_id`, a plain
  /// column that may change under the same row as often as the OS likes.
  ///
  ///  * `adapter_id` — the `BandEntry.id` from the registry (`gen4`/`gen5`), or
  ///    NULL when the link has not said yet. NULL is a refusal, not a default:
  ///    every metric that looks its constants up per family abstains on it
  ///    rather than borrowing gen4's numbers, and the device screen says so.
  ///  * `label` — the band's own advertising name / serial, already passed
  ///    through `cleanDeviceLabel`. Never junk, never a placeholder.
  ///  * `tier` — the `SourceTier` enum NAME (measurement quality, which is the
  ///    only thing that decides precedence between two sources).
  ///  * `first_seen` / `last_seen` — epoch seconds.
  ///
  /// ponytail: no `UPSERT`. `INSERT … ON CONFLICT DO UPDATE` needs SQLite 3.24
  /// and minSdk 26 ships 3.18 (the same floor the `observation` index reasons
  /// about), so [upsertDevice] is INSERT OR IGNORE + UPDATE.
  static Future<void> _createDevice(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device (
        id          TEXT PRIMARY KEY,
        adapter_id  TEXT,
        remote_id   TEXT,
        label       TEXT,
        tier        TEXT,
        first_seen  INTEGER NOT NULL,
        last_seen   INTEGER NOT NULL,
        role        TEXT NOT NULL DEFAULT 'paired',
        wearing     INTEGER NOT NULL DEFAULT 1
      )
    ''');
  }

  /// Record that [id] exists and was seen now. Every field except [id] is
  /// COALESCED, so a caller that only knows the remote id cannot blank out a
  /// label or an adapter another caller already established.
  ///
  /// [clearAdapterId] is the one deliberate exception, and it exists because
  /// COALESCE is wrong in exactly one case: this row is the PRIMARY band
  /// permanently (`id` is `''`), so pairing a DIFFERENT band reuses it, and a
  /// null [adapterId] would then leave the FORGOTTEN band's family on the new
  /// one. `PairedDevice.save` passes it when the remote id changed and the
  /// caller does not know the new band's family. It is ignored when
  /// [adapterId] is non-null — a caller that knows wins over one that clears.
  /// Fires whenever a paired device's row changes after pairing (a sync
  /// committed data, or the device reported its battery), so the screens
  /// listing devices can re-read them.
  static final StreamController<String> deviceRowChanged =
      StreamController<String>.broadcast();

  /// A sync with [id] committed data: stamp `last_seen` now.
  static Future<void> markDeviceSynced(String id) async {
    if (id == kPrimaryDeviceId) return;
    final db = await instance;
    final n = await db.rawUpdate('UPDATE device SET last_seen = ? WHERE id = ?',
        [DateTime.now().millisecondsSinceEpoch ~/ 1000, id]);
    if (n > 0) deviceRowChanged.add(id);
  }

  /// [id] reported its battery level.
  static Future<void> setDeviceBattery(String id, int pct) async {
    if (id == kPrimaryDeviceId || pct < 0 || pct > 100) return;
    final db = await instance;
    final n = await db.rawUpdate(
        'UPDATE device SET battery_pct = ?, battery_ts = ? WHERE id = ?',
        [pct, DateTime.now().millisecondsSinceEpoch ~/ 1000, id]);
    if (n > 0) deviceRowChanged.add(id);
  }

  /// [executor] includes the upsert in the caller's persistence transaction.
  static Future<void> upsertDevice({
    String id = kPrimaryDeviceId,
    String? adapterId,
    String? remoteId,
    String? label,
    String? tier,
    bool clearAdapterId = false,
    DatabaseExecutor? executor,
  }) => _ldbUpsertDevice(id: id, adapterId: adapterId, remoteId: remoteId, label: label, tier: tier, clearAdapterId: clearAdapterId, executor: executor);

  /// One device row, or null when this phone has never seen it.
  static Future<Map<String, Object?>?> deviceRow([
    String id = kPrimaryDeviceId,
  ]) async {
    final db = await instance;
    final r = await db.query('device', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  /// Every device this phone knows about, most recently seen first.
  static Future<List<Map<String, Object?>>> deviceRows() async {
    final db = await instance;
    return db.query('device', orderBy: 'last_seen DESC');
  }

  /// Forget one device. The MEASUREMENTS it wrote are untouched — "this
  /// removes the source, not the data", which is what the forget dialog
  /// promises and what `decoded_*` keeping its `device_id` makes possible.
  ///
  /// Its `signal_priority` rows go with it, in the same transaction. The
  /// resolver's band-day filter drops a paired non-derivable device by its
  /// adapter, and a forgotten id has no row to read an adapter from, so a
  /// surviving user-set rank would make the forgotten device a candidate
  /// again: it would own every window its `device_coverage` spans, masking
  /// the band's HR/RR there while its own rows never load on a band day.
  /// The primary slot keeps its rows — it is refilled by whichever band
  /// pairs next and is always a candidate anyway.
  static Future<void> deleteDevice([String id = kPrimaryDeviceId]) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('device', where: 'id = ?', whereArgs: [id]);
      if (id != kPrimaryDeviceId) {
        await txn.delete(
          'signal_priority',
          where: 'device_id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  // ── OBSERVATIONS (vendor-computed / typed-in / imported scalars) ───────────
  /// Everything that is NOT a raw sensor sample and NOT computed by us:
  /// a `reports` band's own conclusions, the user's typed-in numbers, and
  /// another app's history. See docs/OBSERVATION_SPEC.md.
  ///
  /// THE SINGLE INVARIANT, and it is the whole safety story: **nothing reads
  /// this table into a baseline, into a trend that also carries derived
  /// values, or into any input to a derivation.** Held the same way
  /// `imported_measurement` holds its own version of the rule — a SEPARATE
  /// table, so the only way to violate it is to name it somewhere new, and
  /// `observation_isolation_test.dart` fails the moment anyone does. If it is
  /// ever violated the failure is SILENT: an unexplained step change in a
  /// long-horizon number, months later, with no way to tell which day broke it.
  ///
  /// IDENTITY IS AN EXPRESSION INDEX, NOT A PRIMARY KEY, and that is not a
  /// stylistic choice. The spec's key is
  /// `(device_id, ts_ms, source_kind, COALESCE(vendor_key, key))`, and SQLite
  /// takes no expression in a table-level PRIMARY KEY. The two obvious repairs
  /// both fail:
  ///
  ///  * A `GENERATED ALWAYS AS (COALESCE(...)) STORED` column is rejected
  ///    outright — "generated columns cannot be part of the PRIMARY KEY" — and
  ///    generated columns need SQLite 3.31 (2020) besides, which minSdk 26
  ///    (Android 8 ships 3.18) does not have.
  ///  * A plain composite `PRIMARY KEY (…, vendor_key, key)` COMPILES AND IS
  ///    WRONG. A PRIMARY KEY on a rowid table is a UNIQUE INDEX, and SQLite
  ///    treats NULLs in one as DISTINCT — so two rows with the same
  ///    `vendor_key` and a NULL `key` do not collide, `INSERT OR REPLACE` does
  ///    not replace, and a re-import silently doubles every composite it
  ///    carries. Proven, not assumed.
  ///
  /// A UNIQUE INDEX may hold an expression (SQLite 3.9, 2015 — safely below
  /// the Android 8 floor), `INSERT OR REPLACE` resolves against it exactly as
  /// it would against a PRIMARY KEY, and `COALESCE` is non-NULL whenever the
  /// CHECK holds, so the NULL-distinctness trap never arms. The CHECK is what
  /// makes that true, which is why it is a DB constraint and not a Dart assert.
  ///
  /// `device_id = ''` is the primary band, permanently — the standing rule
  /// established for `decoded_onehz` at v47, and for the same reason: a BLE
  /// remoteId is not a stable identity.
  ///
  /// ponytail: scalars only (`value REAL` + `unit TEXT`). A vendor hypnogram
  /// or a vendor GPS track is not a scalar and has no consumer — give it a
  /// table of its own when something is actually going to read it.
  static Future<void> _createObservation(Database db) => _ldbCreateObservation(db);

  /// Upsert observations. Idempotent on `(device_id, ts_ms, source_kind, name)`
  /// so re-running an import re-states rather than duplicates.
  ///
  /// `date` comes from [dayLabelOf] and nowhere else — the day model is LOCAL
  /// calendar days, and a label computed any other way is wrong for 23 h/25 h
  /// DST days and for every user whose local date differs from UTC's.
  ///
  /// There is deliberately NO reader here yet. Nothing writes observations
  /// either: the adapter seam that will is phase 4, and wiring an existing
  /// importer into this table today would move numbers users already see.
  ///
  /// [resetGeneration]: as for [putVendorSleepEpochs], on the commit gate.
  static Future<int> putObservations(
    List<Observation> rows, {
    String deviceId = kPrimaryDeviceId,
    Map<String, String> cursors = const {},
    int? resetGeneration,
  }) {
    if (resetGeneration == null) {
      return _putObservations(rows, deviceId: deviceId, cursors: cursors);
    }
    return _withCommitGate(() {
      _refuseAfterReset(resetGeneration);
      return _putObservations(rows, deviceId: deviceId, cursors: cursors);
    });
  }

  static Future<int> _putObservations(
    List<Observation> rows, {
    required String deviceId,
    required Map<String, String> cursors,
  }) => _ldbPutObservations(rows, deviceId: deviceId, cursors: cursors);

  /// One observation. [putObservations] is the batch this delegates to.
  static Future<int> putObservation(
    Observation o, {
    String deviceId = kPrimaryDeviceId,
  }) => putObservations([o], deviceId: deviceId);

  /// VENDOR SCALARS FOR ONE DAY, for DISPLAY ONLY.
  ///
  /// The first reader this table has ever had. Read
  /// `test/observation_isolation_test.dart` before adding a second: nothing may
  /// read `observation` into a baseline, into a trend that also holds derived
  /// values, or into any input to a derivation (OBSERVATION_SPEC §3). This
  /// returns rows carrying their own `attribution` precisely so a caller
  /// CANNOT render one as ours — the vendor's name travels with the number
  /// and the UI has no shape for it without one.
  ///
  /// Ordered by `attribution, name` so the same day renders in the same order
  /// on every build.
  static Future<List<Map<String, Object?>>> observationsForDay(
    String date,
  ) async {
    final db = await instance;
    return db.query(
      'observation',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'attribution ASC, COALESCE(vendor_key, key) ASC',
    );
  }

  /// One device's own stored values under [key] from [fromMs] on, keyed by
  /// timestamp — for a link carrying a running total forward across
  /// sessions (a watch that never re-sends what it already delivered). Reads
  /// back only what that same device wrote; never an input to a derivation.
  static Future<Map<int, num>> deviceObservationValues(
    String deviceId,
    String key, {
    int fromMs = 0,
  }) async {
    final db = await instance;
    final rows = await db.query(
      'observation',
      columns: ['ts_ms', 'value'],
      where: 'device_id = ? AND key = ? AND ts_ms >= ?',
      whereArgs: [deviceId, key, fromMs],
    );
    return {
      for (final r in rows)
        if (r['value'] != null) r['ts_ms'] as int: r['value'] as num,
    };
  }

  // ── IMPORTED WORKOUTS (Apple Health / Health Connect) ──────────────────────
  /// A workout some OTHER app recorded, held in its own table for the same
  /// reason `imported_measurement` is: so that it CANNOT become one of ours.
  ///
  /// It is deliberately NOT a row in `sessions`. Everything that reads
  /// `sessions` treats what it finds as measured — strain, the day rollup, the
  /// workout list, the personal records — and a table this app does not own is
  /// the wrong input to every one of them. A separate table makes that
  /// structural instead of a flag someone has to remember to check: there is no
  /// WHERE clause to forget, because the rows are not there.
  ///
  /// DISPLAY ONLY, and `source` is NOT NULL for it — a workout shown without
  /// the app that recorded it is a workout this app is implicitly claiming.
  ///
  /// `uuid` is the health store's own identifier, so a re-import updates in
  /// place rather than stacking duplicates of the same run.
  ///
  /// ROUTES REUSE `workout_route`, keyed by this uuid as its `session_id`. That
  /// table is an opaque-id → lat/lng store with no notion of who measured it,
  /// and a coordinate is not an input to any metric, so there is nothing to
  /// keep apart. What it buys is the existing map: no second route table, no
  /// second reader, no second renderer. [deleteImportedWorkout] cascades, since
  /// [deleteSession] never sees these ids.
  static Future<void> _createImportedWorkout(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_workout (
        uuid TEXT PRIMARY KEY,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        energy_kcal REAL,
        distance_m REAL,
        steps INTEGER,
        source TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_imported_workout_start '
      'ON imported_workout(start_ts)',
    );
  }

  /// Upsert imported workouts. Idempotent on the health store's uuid.
  static Future<int> putImportedWorkouts(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return 0;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'imported_workout',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    return rows.length;
  }

  /// Imported workouts, newest first.
  static Future<List<Map<String, dynamic>>> importedWorkouts({
    int limit = 200,
  }) async {
    final db = await instance;
    return db.query(
      'imported_workout',
      orderBy: 'start_ts DESC',
      limit: limit,
    );
  }

  /// Drop one imported workout AND its route. `deleteSession` cannot do this —
  /// these ids are never in `sessions` — so without the cascade here every
  /// lat/lng point of a removed import would stay on disk unreachable.
  static Future<void> deleteImportedWorkout(String uuid) async {
    final db = await instance;
    await db.delete('imported_workout', where: 'uuid = ?', whereArgs: [uuid]);
    await db.delete(
      'workout_route',
      where: 'session_id = ?',
      whereArgs: [uuid],
    );
  }

  /// Replace an imported workout with the band session scored over its window
  /// (#325). Its route, if the store had one, moves to [sessionId] instead of
  /// being dropped; the row itself goes, so the workout is listed once.
  static Future<void> supersedeImportedWorkout(
    String uuid,
    String sessionId,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      // A session that already has its own route keeps it whole: moving only
      // the non-colliding points would splice two routes into one.
      await txn.rawUpdate(
          'UPDATE workout_route SET session_id = ? WHERE session_id = ? '
          'AND NOT EXISTS (SELECT 1 FROM workout_route WHERE session_id = ?)',
          [sessionId, uuid, sessionId]);
      await txn.delete('workout_route',
          where: 'session_id = ?', whereArgs: [uuid]);
      await txn.delete('imported_workout',
          where: 'uuid = ?', whereArgs: [uuid]);
    });
  }

  /// Drop every imported workout whose source is one of [sources], AND its
  /// route, like [deleteImportedWorkout].
  static Future<void> deleteImportedWorkoutsFrom(Set<String> sources) async {
    if (sources.isEmpty) return;
    final db = await instance;
    final marks = List.filled(sources.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.delete(
        'workout_route',
        where: 'session_id IN (SELECT uuid FROM imported_workout '
            'WHERE source IN ($marks))',
        whereArgs: [...sources],
      );
      await txn.delete(
        'imported_workout',
        where: 'source IN ($marks)',
        whereArgs: [...sources],
      );
    });
  }

  /// Drop every imported workout that starts inside [[startSec], [endSec]]
  /// but whose uuid is not in [present], AND its route, like
  /// [deleteImportedWorkout]. Returns how many went.
  ///
  /// The window is the one the store was just read over: a uuid it no longer
  /// returns there was deleted in the health app, and the upsert alone would
  /// keep listing it (and counting it toward the week) forever. Rows outside
  /// the window are left alone, since the read says nothing about them.
  static Future<int> deleteImportedWorkoutsMissing(
    int startSec,
    int endSec,
    Set<String> present,
  ) => _ldbDeleteImportedWorkoutsMissing(startSec, endSec, present);

  // ── EXTERNAL HEART-RATE SENSOR (0x180D) ─────────────────────────────────────
  /// What a standard Bluetooth heart-rate sensor delivered during ONE workout.
  ///
  /// A SCRATCH LEDGER, deliberately: this is not the substrate. Nothing derives
  /// from it, no baseline reads it, no daily number is computed from it. It
  /// exists so a session can show the sensor's HR and RR *durations* next to
  /// the band's, and so the first question — does a second GATT link fight the
  /// band's? — can be answered against real rows.
  ///
  /// `source` is NOT NULL and carries the peripheral's advertised name, because
  /// the whole point is that the reader always knows this did not come from the
  /// wrist. `rr_ms` is a JSON list of BEAT DURATIONS in milliseconds as the
  /// sensor reported them in one notification — durations, not beat times: a
  /// sub-second beat timeline is a change to `decoded_rr`'s key and to every
  /// consumer of beat times, and is out of scope here.
  ///
  /// One row per (second, sensor). A sensor notifies about once per second; two
  /// notifications inside the same second REPLACE, which loses a beat count but
  /// never invents one.
  static Future<void> _createExternalHr(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS external_hr (
        ts INTEGER NOT NULL,
        source TEXT NOT NULL,
        hr INTEGER NOT NULL,
        rr_ms TEXT,
        session_id TEXT,
        PRIMARY KEY (ts, source)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_external_hr_session '
      'ON external_hr(session_id)',
    );
  }

  /// Append one notification's worth of external-sensor HR. Batched by the
  /// caller: a sensor notifies ~1 Hz and a one-insert-per-beat transaction on
  /// the UI isolate is the same mistake `commitSyncBatch` chunks around.
  static Future<void> appendExternalHr(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert(
          'external_hr',
          r,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Everything an external sensor logged for one session, in time order.
  static Future<List<Map<String, dynamic>>> externalHrForSession(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'external_hr',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ts ASC',
    );
  }

  // ── 100 Hz STEP COVERAGE ────────────────────────────────────────────────────
  // Device-time windows the live AN-2554 pedometer actually counted (real steps).
  // The 1 Hz estimate excludes any minute that falls inside one of these windows
  // — 100 Hz is the real count and always wins; we never count a minute twice.
  // Times are device epoch SECONDS (same clock as raw_records.rec_ts, since the
  // band's RTC is SET_CLOCK'd to phone time on connect). `day` = local date label
  // of the window start (for per-day step attribution).
  //
  // HISTORICAL ROWS. Databases written before the window derivation was fixed
  // contain ZERO-WIDTH rows (`end_ts == start_ts`) — the old writer took both
  // ends from a band record timestamp that does not advance during a live
  // session. They are left as they are: their real durations were never
  // recorded, and widening them after the fact would replace one wrong extent
  // with another while silently changing already-derived days. Readers must
  // tolerate them — `coverageWindowsOverlapping` matches them (`end_ts >= lo`)
  // and the derivation's minute test (`s + 60 > start && s < end`) still
  // excludes the minute containing the row, so such a row under-excludes but
  // never crashes or double-adds its steps.
  static Future<void> _createLiveCoverage(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS live_coverage (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        start_ts INTEGER NOT NULL,
        end_ts INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        day TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT '$kStepSourceBand',
        device_id TEXT NOT NULL DEFAULT '$kPrimaryDeviceId'
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_live_coverage_day ON live_coverage(day)',
    );
  }

  /// device_coverage — WHEN a device was physically emitting a signal. NEVER a
  /// conclusion, never a value, never physiology: five integers saying "this
  /// device produced `signal` rows across [start_ts, end_ts)".
  ///
  /// WHY IT IS A TABLE AND NOT A DERIVE-TIME COMPUTATION. The 1 Hz substrate is
  /// pruned at `rawRetentionDays`, so "what was recording last March" cannot
  /// be reconstructed from rows — they are gone. This is written at INGEST and
  /// survives the prune, which makes it the only artifact that can answer the
  /// question at all. Five integers per few hours per device: a decade of two
  /// devices is well under a megabyte.
  ///
  /// NOT PRUNED by retention, for the `band_battery` reason
  /// (`pruneDecodedBeforeRecTs`): a retention cap on a series whose only use is
  /// comparing a day to the days around it destroys it.
  ///
  /// `signal` is an `InputSignal.name` — an INPUT the device emits, never a
  /// metric key. See `ble/adapters/signals.dart`: a metric key here would make
  /// this a capability table, which is the thing that file exists to refuse.
  ///
  /// INTERVALS FROM ONE DEVICE MAY OVERLAP. The key is only `start_ts`, and
  /// `mergeFrom` can import a foreign export's intervals over local ones. Every
  /// reader must union same-device intervals rather than assume disjointness.
  static Future<void> _createDeviceCoverage(DatabaseExecutor db) => _ldbCreateDeviceCoverage(db);

  /// signal_priority — the user's explicit per-signal device order.
  ///
  /// SPARSE BY CONSTRUCTION, and that is the whole design. No row for a
  /// (signal, device) means "use the physics ladder" — `rankSources()` in
  /// `ui2/profile/devices.dart`. A user who never touches a control has ZERO
  /// rows here and gets exactly today's behaviour, which is what makes this
  /// table free for every single-device install.
  ///
  /// `user_set = 1` means the user reordered this signal. It is what the
  /// one-tap reset deletes and what `priority_hash` hashes. Rows are written
  /// only from the point of evidence (the filter row under a chart) or the
  /// device screen's per-signal reorder list — never as an N x M settings grid.
  ///
  /// `signal` is an `InputSignal.name`, same as `device_coverage.signal`.
  /// Priority for a METRIC has no meaning: readiness has four inputs.
  static Future<void> _createSignalPriority(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS signal_priority (
        signal    TEXT NOT NULL,
        device_id TEXT NOT NULL,
        rank      INTEGER NOT NULL,
        user_set  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (signal, device_id)
      )
    ''');
  }

  /// v51 step 6: coverage intervals for the substrate rows that survive.
  ///
  /// WHAT IT CLAIMS, AND WHAT IT REFUSES TO CLAIM. Only the days
  /// `decoded_onehz` / `decoded_rr` still hold, which is `rawRetentionDays`
  /// plus whatever `_maxRawHoldDays` has held back. A day already pruned gets
  /// NO coverage row. That is correct and it is the honest answer: we do not
  /// know what was recording, so we do not claim.
  ///
  /// NO WINDOW FUNCTIONS. minSdk 26 ships SQLite 3.18; ROW_NUMBER() landed in
  /// 3.25, so the textbook gaps-and-islands query throws `no such function`
  /// inside onUpgrade's ONE exclusive transaction and quarantines the
  /// database. Instead: GROUP BY a 60-second bucket server-side (the
  /// resolver's own grid, so nothing is lost), then coalesce adjacent buckets
  /// in Dart.
  ///
  /// BOUNDED, which is what makes it safe on the launch path:
  /// `rawRetentionDays` days x 1,440 minutes x 5 signals rows worst case, and
  /// in practice far fewer.
  ///
  /// SIGNALS ARE READ OFF COLUMNS, one predicate each, and each predicate says
  /// only what the column says. There is deliberately no `ppgGreen` and no
  /// `accelHighRate`: neither has a `decoded_onehz` column, so there is
  /// nothing to read and a claim would be invented. `vendorScalars` is not a
  /// raw signal and lives in `observation`.
  static Future<void> _backfillDeviceCoverage(Database db) => _ldbBackfillDeviceCoverage(db);

  /// The ingest-time writer §6.5 describes: extend or open a coverage
  /// interval for every signal THIS BATCH actually carried a non-null value
  /// for — never off an adapter's declared capability, because a declared
  /// signal that arrived absent must not produce a coverage claim (the
  /// "declared-but-absent is worse than missing" rule).
  ///
  /// Runs inside the SAME transaction [commitSyncBatch] durably commits the
  /// rows in, so an interval can never claim a second whose row did not
  /// commit — the safe-trim invariant covers both.
  ///
  /// PER-SIGNAL SPANS, NOT THE BATCH SPAN. Each signal's interval is built
  /// from the SECONDS THAT SIGNAL WAS ACTUALLY IN, the way
  /// [_backfillDeviceCoverage] builds its intervals off each predicate's own
  /// rows. Giving every "present somewhere in this batch" signal the whole
  /// `[first, last)` span is the bug that shape avoids: one RR-bearing record
  /// followed by ten HR-only minutes claimed ten minutes of `rrIntervals`
  /// coverage, and `resolveOwnership` would then hand this device seconds it
  /// never measured that signal in.
  ///
  /// [sampleSecs] is parallel to [samples] and carries each record's `rec_ts`
  /// — the same value [_queueDecodedOneHz] keys its row on, so an interval and
  /// the rows it describes are on one clock. Neutrals carry their own.
  static Future<void> _extendCoverageVia(
    DatabaseExecutor txn, {
    required String deviceId,
    required List<Sample?> samples,
    required List<int> sampleSecs,
    List<NeutralSample>? neutrals,
    Map<String, int>? toleranceSec,
    String? deviceFamily,
  }) => _ldbExtendCoverageVia(txn, deviceId: deviceId, samples: samples, sampleSecs: sampleSecs, neutrals: neutrals, toleranceSec: toleranceSec, deviceFamily: deviceFamily);

  /// Ensure `live_coverage.source` exists (v27).
  ///
  /// Uses the shared guarded helper — an unguarded ALTER TABLE on an
  /// already-migrated db bricks the upgrade (that has bitten this file twice).
  static Future<void> _ensureLiveCoverageSource(Database db) async {
    await _addColumnIfMissing(
      db,
      'live_coverage',
      'source',
      "TEXT NOT NULL DEFAULT '$kStepSourceBand'",
    );
  }

  /// Ensure `live_coverage.device_id` exists (v49).
  ///
  /// WHICH SENSOR counted, not which KIND of sensor — `source` already says
  /// band-or-phone. Without it two straps on the same 3,000-step walk both
  /// rank 2 in [resolveDaySteps], skip each other's overlap subtraction, and
  /// the day publishes 6,000: the resolver has handled that since the ladder
  /// gained `CoverageSpan.deviceId`, and could never fire because this column
  /// did not exist. Existing rows take the DEFAULT — the primary band — which
  /// is exactly what they have always meant, so no day's total moves.
  static Future<void> _ensureLiveCoverageDeviceId(Database db) async {
    await _addColumnIfMissing(
      db,
      'live_coverage',
      'device_id',
      "TEXT NOT NULL DEFAULT '$kPrimaryDeviceId'",
    );
  }

  /// Step-count provenance for a `live_coverage` row.
  ///
  /// These are never summed together — see [liveStepsForDay].
  static const String kStepSourceBand = 'band'; // band 100 Hz AN-2554 (wrist)
  static const String kStepSourcePhone = 'phone'; // phone pedometer (pocket)

  /// Record a real 100 Hz step window (device-time seconds) + its step count.
  ///
  /// The window is normalised by [sanitizeCoverageWindow] first: a zero-width
  /// window that claims steps is REPAIRED (widened to the duration those steps
  /// physically imply) rather than dropped, because dropping it would lose a
  /// real 100 Hz count; an inverted window is rejected. See that function for
  /// the reasoning. This is a guard, not the derivation — the caller is
  /// expected to have measured a real window (see
  /// `deriveLiveCoverageWindow`); it exists so an upstream regression cannot
  /// silently reintroduce degenerate rows.
  static Future<void> addLiveCoverage(
    int startTs,
    int endTs,
    int steps,
    String day, {
    String source = kStepSourceBand,
    // WHICH physical sensor counted (see [_ensureLiveCoverageDeviceId]). The
    // phone is the primary device's own pedometer, so it keeps `''` too —
    // `source` is what tells wrist from pocket.
    String deviceId = kPrimaryDeviceId,
  }) => _ldbAddLiveCoverage(startTs, endTs, steps, day, source: source, deviceId: deviceId);

  /// Replace ALL phone-pedometer rows for [day] with [windows], atomically.
  ///
  /// Phone step data is a re-readable snapshot, not an append-only stream: the
  /// same day can be synced repeatedly as it fills in. So the phone sync is
  /// delete-then-insert scoped to `source = 'phone'`, which is idempotent by
  /// construction and needs no window-clipping. Band rows are untouched.
  ///
  /// A `steps == 0` window IS stored, deliberately — it is not "nothing to
  /// say", it is the phone confirming it saw no motion over that hour, which
  /// `resolveDaySteps`'s confirmed-still check uses to veto a wrist
  /// false-positive over the same window. Only a negative count (never
  /// produced by the reader) or an inverted window is dropped.
  static Future<void> replacePhoneCoverageForDay(
    String day,
    List<({int startTs, int endTs, int steps})> windows,
  ) => _ldbReplacePhoneCoverageForDay(day, windows);

  /// True when a coverage row for exactly this window already exists.
  ///
  /// `live_coverage` is an append-only SUM (no uniqueness on the window), so a
  /// replayed write double-counts the day's real steps. The orphaned-session
  /// recovery uses this to stay idempotent: a process killed AFTER
  /// `_finalizeLivePedometer` wrote coverage but BEFORE it cleared the
  /// checkpoint would otherwise re-add the same bout on the next launch.
  static Future<bool> hasLiveCoverageWindow(int startTs, int endTs) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT 1 FROM live_coverage WHERE start_ts = ? AND end_ts = ? LIMIT 1',
      [startTs, endTs],
    );
    return r.isNotEmpty;
  }

  /// Phone-sourced steps already banked for [day].
  ///
  /// Used by the pedometer sync to tell "this day really had no steps" from
  /// "this read came back empty" before it replaces a day wholesale — see
  /// [replacePhoneCoverageForDay], which is delete-then-insert.
  ///
  /// Also the UI's source discriminator: it is the same quantity
  /// [liveStepsForDay] tests to decide which source owns the day, so a screen
  /// can ask "did the phone actually cover today?" instead of approximating it
  /// with "is the toggle on". Those differ exactly when the toggle is on and
  /// the phone has no data, where the band still owns the day.
  static Future<int> phoneStepsForDay(String day) async {
    final db = await instance;
    final r = await db.rawQuery(
      'SELECT COALESCE(SUM(steps),0) s FROM live_coverage '
      'WHERE day = ? AND source = ?',
      [day, kStepSourcePhone],
    );
    return (r.first['s'] as num?)?.toInt() ?? 0;
  }

  /// [day]'s banked phone windows, so a re-sync can keep the ones for an hour
  /// the sensor no longer covers (see `PhonePedometer.syncDay`).
  static Future<List<({int startTs, int endTs, int steps})>>
      phoneCoverageForDay(String day) async {
    final db = await instance;
    final rows = await db.query(
      'live_coverage',
      columns: ['start_ts', 'end_ts', 'steps'],
      where: 'day = ? AND source = ?',
      whereArgs: [day, kStepSourcePhone],
    );
    return [
      for (final r in rows)
        (
          startTs: (r['start_ts'] as num).toInt(),
          endTs: (r['end_ts'] as num).toInt(),
          steps: (r['steps'] as num).toInt(),
        ),
    ];
  }

  /// Drop every phone-sourced coverage row (the user turned phone steps off).
  /// Band rows are untouched, so days fall back to the band count.
  static Future<int> clearPhoneCoverage() async {
    final db = await instance;
    return db.delete(
      'live_coverage',
      where: 'source = ?',
      whereArgs: [kStepSourcePhone],
    );
  }

  /// [day]'s real pedometer steps, resolved PER WINDOW and split by sensor.
  ///
  /// Phone and band counts are never blindly added: both count the same walk,
  /// one from the pocket and one from the wrist, so summing a day whole doubles
  /// it. But they are not alternatives either — the strap streams only while a
  /// session runs, so it can only ever cover workout minutes, and letting
  /// either source take a whole day it only partly covered is the bug this
  /// replaces (it reported 622 steps against the phone's 18,856 on a real
  /// export). Each SPAN goes to the best source that actually covered it, and
  /// the spans sum. [resolveDaySteps] owns that decision, including why a wide
  /// band span with no gait in it does NOT outrank the phone (a wrist counter
  /// is documented emitting 22-27 false steps/min during dishes, reaching and
  /// driving while missing slow walking — O'Connell 2017,
  /// doi:10.1371/journal.pone.0169616).
  static Future<ResolvedDaySteps> resolvedStepsForDay(String day) => _ldbResolvedStepsForDay(day);

  /// [day]'s resolved step TOTAL. See [resolvedStepsForDay] for the split.
  static Future<int> liveStepsForDay(String day) async =>
      (await resolvedStepsForDay(day)).total;

  /// Coverage windows ([startSec, endSec]) overlapping [loSec, hiSec), for ONE
  /// [source] (band by default).
  ///
  /// The 1 Hz-estimate exclusion this originally served is gone along with the
  /// estimator. Its only remaining caller is the NOOP importer, which reads back
  /// the spans it has already banked so `stepRuns` can clip them out and a
  /// re-import over an overlapping span cannot double-count.
  ///
  /// THE SOURCE FILTER IS LOAD-BEARING for that caller. Phone-pedometer rows now
  /// share this table and cover the same wall-clock hours, so an unfiltered read
  /// let a user with phone steps enabled import a NOOP backup whose BAND step
  /// runs were clipped against the PHONE's windows and silently dropped — the
  /// import reporting success while banking nothing for those days. Band clips
  /// against band. Phone coverage needs no clipping at all: it is replaced
  /// wholesale per day (see [replacePhoneCoverageForDay]).
  static Future<List<List<int>>> coverageWindowsOverlapping(
    int loSec,
    int hiSec, {
    String source = kStepSourceBand,
  }) async {
    final db = await instance;
    final rows = await db.query(
      'live_coverage',
      where: 'end_ts >= ? AND start_ts < ? AND source = ?',
      whereArgs: [loSec, hiSec, source],
    );
    return [
      for (final r in rows)
        [(r['start_ts'] as num).toInt(), (r['end_ts'] as num).toInt()],
    ];
  }

  /// Spans ([startSec, endSec]) in [loSec, hiSec) during which the band was NOT
  /// on the wrist, from the strap's own WRIST_OFF/WRIST_ON events.
  ///
  /// A band sitting on a table is PERFECTLY still and reads as deep rest to any
  /// motion-based detector — it is the dominant nap false positive. The strap
  /// already tells us; these events have been decoded and persisted all along,
  /// and `AdvancedSleepStager.detectSleep` has always accepted a `wristOff`
  /// argument, but nothing ever supplied one.
  ///
  /// State is carried in from BEFORE [loSec] so a window that opens mid-removal
  /// is still covered, and an unterminated removal extends to [hiSec] rather
  /// than being dropped (absent evidence of return is not evidence of return).
  static Future<List<List<int>>> wristOffSpans(
    int loSec,
    int hiSec, {
    required String deviceId,
  }) =>
      _toggleSpans(
        loSec,
        hiSec,
        onId: proto.EventId.wristOn,
        offId: proto.EventId.wristOff,
        deviceId: deviceId,
      );

  /// Spans ([startSec, endSec]) in [loSec, hiSec) during which the band was on
  /// the charger — off-wrist by definition, and motionless.
  static Future<List<List<int>>> chargingSpans(
    int loSec,
    int hiSec, {
    required String deviceId,
  }) =>
      _toggleSpans(
        loSec,
        hiSec,
        onId: proto.EventId.chargingOff,
        offId: proto.EventId.chargingOn,
        deviceId: deviceId,
      );

  /// Build "state active" spans from a pair of toggle events, clipped to
  /// [loSec, hiSec). [offId] opens a span; [onId] closes it.
  ///
  /// [deviceId] is required, not optional-with-default: without it, one
  /// device's charging spans mask a DIFFERENT device's worn night — put band
  /// B on the charger and band A's real sleep gets excluded as "charging",
  /// silently, and it survives the raw prune into the baselines.
  static Future<List<List<int>>> _toggleSpans(
    int loSec,
    int hiSec, {
    required int onId,
    required int offId,
    required String deviceId,
  }) => _ldbToggleSpans(loSec, hiSec, onId: onId, offId: offId, deviceId: deviceId);

  /// Read a sync-cursor value (null if unset).
  static Future<String?> getCursor(String name, {DatabaseExecutor? txn}) async {
    final db = txn ?? await instance;
    final rows = await db.query(
      'sync_cursor',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<int?> getCursorInt(String name) async {
    final v = await getCursor(name);
    return v == null ? null : int.tryParse(v);
  }

  /// The primary device's durable record frontier (`rec_ts_hw`), or null when
  /// no record has been banked. Builds before the commit guard could persist
  /// '0' from a record-less commit, so a non-positive value reads as unset.
  static Future<int?> getRecordFrontier() async {
    final v = await getCursorInt('rec_ts_hw');
    return (v == null || v <= 0) ? null : v;
  }

  /// Read a cursor int through a specific executor (used inside a transaction so
  /// the read shares the open txn instead of contending on the global handle).
  static Future<int?> _cursorIntVia(DatabaseExecutor ex, String name) async {
    final rows = await ex.query(
      'sync_cursor',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return int.tryParse(rows.first['value'] as String? ?? '');
  }

  /// Upsert a sync-cursor value. Caller may pass a [txn] so the cursor write
  /// shares the SAME transaction as the raw batch — keeping "persist raw then
  /// persist cursor" atomic before the band is ACKed.
  static Future<void> setCursor(
    String name,
    String value, {
    DatabaseExecutor? txn,
  }) async {
    final ex = txn ?? await instance;
    await ex.insert('sync_cursor', {
      'name': name,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Drop a sync-cursor row so a later [getCursor] sees it as unset again.
  /// Used when forgetting a device whose cursor must not outlive the row it
  /// was tracking — a re-paired device otherwise inherits stale progress.
  static Future<void> deleteCursor(String name) async {
    final db = await instance;
    await db.delete('sync_cursor', where: 'name = ?', whereArgs: [name]);
  }

  /// Cursor holding the FROZEN morning readiness headline (see #128): the
  /// day-tagged value pinned once today's overnight first settles on a genuinely
  /// complete night, so the Today hero + recovery story stop drifting through
  /// the day. Day-tagged so it survives restarts and is ignored on a new day.
  static const String kFrozenHeadlineCursor = 'frozen_headline';

  /// Cursor holding the highest `rec_ts` cutoff the raw prune has applied.
  /// Only ever raised; the derive engine refuses to re-derive a day whose
  /// window reaches below it.
  static const String kDecodedPrunedBeforeCursor = 'decoded_pruned_before';

  /// The pinned morning readiness headline (day + value), or null if unset /
  /// unparseable. The `day` must be compared to today's label by the caller — a
  /// pin left over from a previous day must NOT be surfaced.
  ///
  /// Null, too, when the pinned day has no `day_result`: the pin is a cursor,
  /// not a day row, and an orphan (its day deleted) would put a deleted day's
  /// readiness back on the ring, the recovery chart, the log and the push.
  /// `deleteDays` clears a matching pin; an orphan found here however it arose
  /// (an older build's delete, say) is removed, not just masked, so it cannot
  /// come back as the pin once that day is derived again.
  static Future<({String day, int value, int? wakeSec})?> frozenHeadline() => _ldbFrozenHeadline();

  /// Test seam: awaited between [frozenHeadline] finding an orphan pin and
  /// clearing it, so a test can land a new pin in that gap.
  @visibleForTesting
  static Future<void> Function()? debugBeforeOrphanPinClear;

  /// The one reader of the frozen-headline cursor's JSON.
  static ({String day, int value, int? wakeSec})? _parseFrozenHeadline(
    Object? raw,
  ) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['day'] is String && d['value'] is num) {
        final wake = d['wake_sec'];
        return (
          day: d['day'] as String,
          value: (d['value'] as num).round(),
          wakeSec: wake is num ? wake.toInt() : null,
        );
      }
    } catch (_) {
      /* malformed → treat as unset */
    }
    return null;
  }

  /// The pinned headline for [day], or null unless the pin describes [day]'s
  /// CURRENT night: its wake within [kPinWakeToleranceSec] of the stored
  /// window's. A pin with no wake (older builds) never qualifies, so the live
  /// final value shows instead of a possibly partial-night pin.
  static Future<int?> headlinePinFor(String day) => _ldbHeadlinePinFor(day);

  /// Cursor holding the last FINAL headline readiness shown for a day, plus the
  /// one it replaced, so a changed number is announced instead of silently
  /// swapped ("Updated 8:12 · 2 → 28").
  static const String kHeadlineShownCursor = 'headline_shown';

  /// Record that [value] is the final headline served for [day]; returns the
  /// day's latest change `{from, to, at}` (at = epoch ms) or null if the number
  /// has not changed since it was first shown.
  static Future<Map<String, int>?> noteHeadlineShown(
          String day, int value) => _ldbNoteHeadlineShown(day, value);

  /// Pin [value] as the frozen readiness headline for [day] (overwrites any
  /// prior pin — first-complete-settle-per-day is enforced by the caller).
  /// [wakeSec] is the wake of the night it was pinned on.
  static Future<void> setFrozenHeadline(String day, int value, {int? wakeSec}) =>
      setCursor(
        kFrozenHeadlineCursor,
        jsonEncode({
          'day': day,
          'value': value,
          'wake_sec': ?wakeSec,
        }),
      );

  /// Persist a sync batch atomically: the raw records, their samples, AND the
  /// continuation cursor in ONE transaction. This is the durable half of the
  /// safe-trim invariant — it MUST return before the engine writes the ACK frame.
  /// Advances counter_hw / rec_ts_hw to the batch max so a restart resumes cleanly.
  ///
  /// [onCheckpoint], if given, is called synchronously at each of the three
  /// phases (decoded+archive queued, decoded+archive committed, cursor
  /// advanced) — field diagnosability without giving up the single-txn
  /// atomicity: the checkpoint calls are pure logging, wrapped so a
  /// misbehaving callback can never abort a real commit. db.dart itself stays
  /// logging-framework-free (no Flutter dependency); callers pass their own
  /// logger (e.g. ble_engine.dart's `_log`, background_sync.dart's `debugPrint`).
  /// Times the ACK-gating commit ran at a weaker durability level than
  /// intended, because `PRAGMA synchronous=FULL` was refused or did not stick.
  /// Not fatal (see the pragma block below) but never silent.
  static int _syncFullDowngrades = 0;

  /// Read-only view of [_syncFullDowngrades] for diagnostics/tests.
  static int get syncFullDowngrades => _syncFullDowngrades;

  /// Serialises the ACK-gating commit process-wide.
  ///
  /// `PRAGMA synchronous` is PER-CONNECTION and there is one sqflite
  /// connection per isolate, so two overlapping [commitSyncBatch] calls
  /// interleave their FULL/NORMAL brackets: the inner one's `finally` restores
  /// NORMAL while the outer transaction is still open, and the outer commit —
  /// the one an ACK is about to be written for — silently runs at NORMAL. Two
  /// bands offloading at once is the concurrency this exists for; today the
  /// offload processor is single-flight and BandOwnership yields the headless
  /// drain, which is the serialization this replaces with a mechanism.
  ///
  /// Same shape as `withScanLock` (`lib/ble/ble_state.dart`), copied rather
  /// than imported because that file depends on Flutter and this one must not.
  ///
  /// ponytail: ONE global lock, so two bands' commits queue rather than run
  /// concurrently. That is correct anyway — they share one SQLite write lock —
  /// and per-device locks would not help. Revisit only if a measured
  /// throughput problem appears, which needs two simultaneously-offloading
  /// bands and has never been observed.
  // No refcount: the gate serialises, so the bracket is never nested. A count
  // would be dead code whose only reachable state is a leak.
  static Future<void> _commitGate = Future.value();

  static Future<T> _withCommitGate<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _commitGate = _commitGate.then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<void> commitSyncBatch(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    /// Rows from a band with no framed record to decode — a notify sensor's
    /// beats, a ring's stamped temperature. Queued into the SAME transaction
    /// as [raws], so a source with no flash still gets the one durable write
    /// path and the one conflict policy. Null on every WHOOP commit, where it
    /// costs exactly one null check.
    List<NeutralSample>? neutrals,
    // WHOOP MG raw ECG (R16) records recovered by this burst. Same
    // transaction as everything else here — they have no other durable home.
    List<EcgRawPacket>? ecgRawPackets,
    void Function(String)? onCheckpoint,
    String? deviceFamily,
    String deviceId = kPrimaryDeviceId,
    // Per-signal (InputSignal.name) tolerance for the coverage writer's
    // "still the same interval" gap check. db.dart cannot read a
    // BandAdapter's declared cadence (it imports nothing from lib/ble/), so
    // the host supplies it; a signal absent from the map defaults to
    // 2*kBucket (120s) inside [_extendCoverageVia].
    Map<String, int>? coverageToleranceSec,
    // [ResetGate.generation] when the writing session began. Checked inside
    // the commit gate, where it cannot be raced: a batch from a session that
    // started before a "delete everything" is refused even once the reset has
    // finished and the gate is down again. Null checks only that no reset is
    // running right now.
    int? resetGeneration,
  }) => _ldbCommitSyncBatch(raws, samples, trimToken: trimToken, extraCursors: extraCursors, archives: archives, neutrals: neutrals, ecgRawPackets: ecgRawPackets, onCheckpoint: onCheckpoint, deviceFamily: deviceFamily, deviceId: deviceId, coverageToleranceSec: coverageToleranceSec, resetGeneration: resetGeneration);

  static Future<void> _commitSyncBatchLocked(
    List<RawRecord> raws,
    List<Sample?> samples, {
    String? trimToken,
    Map<String, String>? extraCursors,
    List<ArchiveRecord>? archives,
    List<NeutralSample>? neutrals,
    // WHOOP MG raw ECG (R16) records recovered by this burst. Same
    // transaction as everything else here — they have no other durable home.
    List<EcgRawPacket>? ecgRawPackets,
    void Function(String)? onCheckpoint,
    // Which strap this batch came off, from the LIVE LINK (the engine pins it at
    // service discovery). Null = the caller could not name it, which lands as
    // NULL = unknown provenance. Never defaulted to gen4.
    String? deviceFamily,
    // WHICH PHYSICAL DEVICE these rows belong to (see [kPrimaryDeviceId]).
    String deviceId = kPrimaryDeviceId,
    Map<String, int>? coverageToleranceSec,
    int? resetGeneration,
  }) => _ldbCommitSyncBatchLocked(raws, samples, trimToken: trimToken, extraCursors: extraCursors, archives: archives, neutrals: neutrals, ecgRawPackets: ecgRawPackets, onCheckpoint: onCheckpoint, deviceFamily: deviceFamily, deviceId: deviceId, coverageToleranceSec: coverageToleranceSec, resetGeneration: resetGeneration);

  // ── DERIVED STORE (permanent, rich) ────────────────────────────────────────
  // The on-device analytics output, keyed by physiological day (wake-to-wake;
  // the `date` label is edge-supplied, display-only). These rows are PERMANENT —
  // raw is pruned after derivation (rawRetentionDays) but the derived bundle is
  // the long-term system of record the UI reads from. See lib/compute/.
  static Future<void> _createDerived(Database db) => _ldbCreateDerived(db);

  /// metric_series_version — which build's maths produced a day's scalars.
  ///
  /// `day_result` is versioned (PK day_id, algo_version); `metric_series` is
  /// not, and cannot become so — `v_metric` and `v_daily` are pivots over it
  /// and `v_daily` is in the coach's allow-list, so widening the PK changes
  /// what the coach sees. So the stamp lives beside it, one row per day.
  ///
  /// WHAT IT IS FOR. Days lock at finalized ~48 h after wake and are never
  /// recomputed on a bump, and the 1 Hz substrate is gone at
  /// `rawRetentionDays`, so a March day physically cannot be re-derived in
  /// December. `kAlgoVersion` moved 65 → 66 → 68 inside two weeks. A 12-month
  /// chart therefore splices values from several different algorithms with
  /// nothing marking the seams. This does NOT make those values comparable —
  /// nothing can. It makes the incomparability VISIBLE, so a change-point
  /// search can refuse to run across a seam instead of reporting the day the
  /// maths changed as a finding about the user.
  static Future<void> _createMetricSeriesVersion(DatabaseExecutor db) => _ldbCreateMetricSeriesVersion(db);

  /// Backfill the stamp from `day_result`, which has carried the version all
  /// along. `INSERT OR IGNORE`, so a stamp already written by [putDayResult]
  /// wins — that one is exact, this one infers.
  ///
  /// `skipped`/`partial` rows are excluded because those passes do not write
  /// `metric_series` at all (see [putDayResult]), so their version never
  /// produced the values being stamped. MAX per day is the same rule the serve
  /// seam uses; it is only wrong for a day last written by a ROLLED-BACK build,
  /// and going forward [putDayResult] records that case exactly.
  static Future<void> _backfillMetricSeriesVersion(Database db) async {
    // `day_result` may not exist yet on an upgrade path that has not reached
    // the rung which creates it (or on a DB that never had it). A SELECT from a
    // missing table throws, and a throw inside onUpgrade rolls the WHOLE ladder
    // back and quarantines the user's database — the standing trap this file is
    // full of guards against. Nothing to infer from, so infer nothing.
    if ((await _columnsOf(db, 'day_result')).isEmpty) return;
    await db.execute(
      'INSERT OR IGNORE INTO metric_series_version (date, algo_version) '
      'SELECT day_id, MAX(algo_version) FROM day_result '
      'WHERE skipped = 0 AND partial = 0 GROUP BY day_id',
    );
  }

  /// `{date -> method family}` for [key]'s stored values (`metric_method`).
  /// A day with no row is absent: unknown, never guessed.
  static Future<Map<String, String>> metricFamilies(String key) async {
    final db = await instance;
    return {
      for (final r in await db.query('metric_method',
          columns: ['date', 'family'], where: 'key = ?', whereArgs: [key]))
        r['date'] as String: r['family'] as String,
    };
  }

  /// The dates whose stored [key] is a wearable's estimate, or a row its
  /// column serves as unavailable (`metric_method.class`): not a measurement
  /// a plain trend line may draw.
  static Future<Set<String>> metricNotOursDates(String key, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    return {
      for (final r in await db.query('metric_method',
          columns: ['date'],
          where: "key = ? AND class IN ('estimated', 'unavailable')",
          whereArgs: [key]))
        r['date'] as String,
    };
  }

  /// The algo version behind each day's `metric_series` scalars, oldest first.
  /// Days with no stamp are simply absent — never guessed at.
  static Future<List<Map<String, dynamic>>> metricSeriesVersions({DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    return db.query('metric_series_version', orderBy: 'date ASC');
  }

  // ── VERSIONED IMMUTABLE DERIVED STORE (ARCHITECTURE_V2 invariant 6) ─────────
  // day_result — one row per (physiological day, algo_version). Derived rows are
  // IMMUTABLE per version: an algo_version bump writes a NEW row (never mutates).
  // The serve seam reads the LATEST algo_version per day_id. A day stays
  // recomputable for ~48 h after its wake (finalized=0); then it LOCKS
  // (finalized=1) and is no longer recomputed even on a version bump.
  static Future<void> _createDayResult(Database db) => _ldbCreateDayResult(db);

  /// journal_metric — the numeric half of a journal entry.
  ///
  /// The `journal` table holds a tag set and a note, which can only ever
  /// answer "did this happen today". A field that carries a NUMBER — three
  /// coffees, 700 ml of water, mood 4 out of 5 — carries a dose, and that is
  /// usually the actual question. Kept in its own table rather than as columns
  /// on `journal` so a user-defined field costs a row, not a migration.
  ///
  /// One row per (day, field): the value is the day's TOTAL for a dose-like
  /// field and the day's single reading for a rating.
  ///
  /// `at_min` is local minutes past midnight for the LATEST occurrence, and is
  /// null for anything without a meaningful time. It exists because when a
  /// dose landed can matter more than its size — the sleep-relevant fact about
  /// caffeine is the last cup, not the total.
  static Future<void> _createJournalMetric(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_metric (
        date TEXT NOT NULL,
        field TEXT NOT NULL,
        value REAL NOT NULL,
        at_min INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (date, field)
      )
    ''');
    // Correlations read one field across every day, so the index is on the
    // field first — the primary key already covers day-scoped reads.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_journal_metric_field '
      'ON journal_metric(field, date)',
    );
  }

  /// journal_field_def — definitions for USER-INVENTED numeric fields only.
  ///
  /// Built-in fields live in `lib/data/journal_fields.dart` as code, because a
  /// definition that ships with the app should not be editable data. A custom
  /// field has nowhere else to record what its number means, and without a
  /// unit and a ceiling its values render as bare numbers and its entry has no
  /// bounds — so it gets a row.
  ///
  /// Deleting a definition deliberately does NOT delete its history: those
  /// readings were still real. They render unlabelled until the field is
  /// defined again.
  static Future<void> _createJournalFieldDef(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS journal_field_def (
        key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        kind TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        max_value REAL NOT NULL,
        step REAL NOT NULL,
        has_time INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// lab_result — hand-entered blood work, and definitions for user-defined
  /// markers.
  ///
  /// Keyed on (marker, taken_on) so re-entering the same draw corrects it
  /// rather than stacking duplicates; two genuinely different draws on one day
  /// are rare enough that correcting a typo is the case worth optimising for.
  ///
  /// `unit` is stored per row rather than looked up from the catalogue, so a
  /// value keeps the unit it was entered under even if a later release changes
  /// the marker's canonical unit. Silently reinterpreting 400 ng/mL as
  /// 400 nmol/L would be a fabrication of the worst kind.
  ///
  /// NOT day-scoped, NOT pruned, and deliberately NOT removed by `deleteDays`.
  /// A lab result belongs to the date the blood was drawn, not to a band-data
  /// day. "Delete this day" in the data manager is about reclaiming space from
  /// sensor data; a blood test is neither sensor data nor large, it was typed
  /// in by hand on a different screen, and it has its own delete there. Losing
  /// a year-old blood panel because the band data from that date was cleared
  /// would be a genuinely surprising deletion.
  ///
  /// Indexed by its PRIMARY KEY alone — `(marker, taken_on)` already gives
  /// SQLite an implicit index on exactly the columns every read here filters
  /// and orders by, so a second one would only be another b-tree to maintain.
  static Future<void> _createLabTables(Database db) => _ldbCreateLabTables(db);

  /// breathing_session — one row per completed paced-breathing session.
  ///
  /// The coherence score was computed live and then thrown away, so the
  /// feature could tell you how a session went and never whether it was going
  /// anywhere. A score is only meaningful for a pattern that is TRYING to
  /// drive heart-rate oscillation at the paced frequency, so `coherence` is
  /// null for the others rather than a number that grades box breathing on
  /// resonance breathing's exam.
  ///
  /// `pre_rmssd` / `post_rmssd` (MIND-06) are RMSSD over the two QUIET windows
  /// either side of the paced block — never during it. RMSSD rises during slow
  /// breathing as a mechanical consequence of respiratory sinus arrhythmia, so
  /// a during-session number measures the pacing, not any effect of it. Only
  /// the pre→post pair carries information, and only across many sessions.
  /// Both null on every session run without the windows, which is the default.
  static Future<void> _createBreathingSessions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS breathing_session (
        started_at INTEGER PRIMARY KEY,
        ended_at INTEGER NOT NULL,
        pattern TEXT NOT NULL,
        seconds INTEGER NOT NULL,
        coherence REAL,
        confidence REAL,
        pre_rmssd REAL,
        post_rmssd REAL
      )
    ''');
  }

  /// The MIND-06 window columns on an existing `breathing_session`.
  ///
  /// Additive only, and NOT a ladder rung: `_addColumnIfMissing` is a no-op on
  /// a table this build has not created yet and costs one PRAGMA at open, so
  /// the onOpen repair covers every existing install without spending a schema
  /// version that three other branches are also reaching for.
  static Future<void> _ensureBreathingWindowColumns(Database db) async {
    await _addColumnIfMissing(db, 'breathing_session', 'pre_rmssd', 'REAL');
    await _addColumnIfMissing(db, 'breathing_session', 'post_rmssd', 'REAL');
  }

  /// strength_set / exercise_def — the sets a lift is made of.
  ///
  /// Nothing measures a bench press, so this is the one part of a workout the
  /// user types, and until now there was nowhere to put it: `sessions` has no
  /// exercise, set, rep, load or RPE column, which made every number on the
  /// strength screens unbacked. Hangs off `sessions.id` so strain, calories,
  /// zones and heart rate keep coming from the existing pipeline rather than
  /// being duplicated here.
  ///
  /// `load_kg` is NULLABLE and that is the whole point: a bodyweight pull-up
  /// stored as 0 would make session volume (Σ load × reps) report zero for a
  /// real session. Volume is derived on read and excludes null-load sets,
  /// which the UI states in as many words.
  ///
  /// Derived on read, never stored: total volume, set/rep counts, 1RM
  /// estimates, "vs last session", PR detection.
  static Future<void> _createStrengthTables(Database db) => _ldbCreateStrengthTables(db);

  /// Append the sets of one strength session, in log order. Idempotent by
  /// (session_id, seq) so a re-save of the same session replaces rather than
  /// duplicates.
  static Future<void> saveStrengthSets(
    String sessionId,
    List<Map<String, Object?>> sets,
  ) async {
    if (sets.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      for (var i = 0; i < sets.length; i++) {
        await txn.insert('strength_set', {
          ...sets[i],
          'session_id': sessionId,
          'seq': i,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<List<Map<String, Object?>>> strengthSets(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'strength_set',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
    );
  }

  /// The most recent sets logged for one exercise, newest first — the
  /// substrate for "previous" and "best" on the live screen.
  static Future<List<Map<String, Object?>>> recentSetsFor(
    String exerciseKey, {
    int limit = 60,
  }) async {
    final db = await instance;
    return db.query(
      'strength_set',
      where: 'exercise_key = ?',
      whereArgs: [exerciseKey],
      orderBy: 'at_ts DESC',
      limit: limit,
    );
  }

  /// Newest-set and heaviest-set candidates per logged exercise, in two
  /// queries. The caller keeps the first row per key (most reps wins a tie).
  /// No window functions: minSdk 26 can ship SQLite older than 3.25.
  static Future<({
    List<Map<String, Object?>> previous,
    List<Map<String, Object?>> best,
  })> strengthHistoryCandidates() => _ldbStrengthHistoryCandidates();

  // ── USER-DATA STORE (journal / cycle / workouts / notifications) ────────────
  // On-device user-entered + locally-generated data. All keyed for idempotent
  // upserts; none of it round-trips to a server (cloud excised).
  static Future<void> _createUserTables(Database db) => _ldbCreateUserTables(db);

  static Future<void> _createSyncState(DatabaseExecutor db) => _ldbCreateSyncState(db);

  static Future<void> _createComputeState(Database db) => _ldbCreateComputeState(db);

  static Future<void> _createPrimitiveArtifacts(Database db) => _ldbCreatePrimitiveArtifacts(db);

  static Future<void> _ensureSyncStateSchema(Database db) async {
    await _ensureSyncCursorSchema(db);
    await _ensureSyncLedgerSchema(db);
    await _ensureSyncQuarantineSchema(db);
  }

  static Future<void> _dropRawStore(Database db) async {
    await db.execute('DROP TABLE IF EXISTS raw_records');
  }

  /// v42 — THE FROZEN SESSION TRACE. Everything the detail screen draws that is
  /// rebuilt from the 1 Hz substrate on every open: the minute HR curve, the
  /// zone bands, drift, time-to-peak, the recovery curve. `decoded_onehz` is
  /// pruned at `rawRetentionDays`, so every one of those went permanently blank
  /// on a session's fourth day — the summary scalars survived in their own
  /// columns and the whole chart half of the screen did not.
  ///
  /// `trace_samples` is the 1 Hz sample COUNT the trace was built from, kept
  /// with it so a session the band only partly handed over reads as partial
  /// instead of drawing a confident thin line over a sync gap. NOT backfilled —
  /// those seconds are gone; a session that aged out before this shipped has no
  /// trace and never will.
  ///
  /// Its own helper, and NOT [_ensureSessionSchema], because the ladder rung
  /// must not run that one: it also creates an index, which throws on a DB
  /// whose `sessions` table this ladder has not created yet, and a throw inside
  /// onUpgrade quarantines the whole database. `_addColumnIfMissing` is a no-op
  /// on a missing table.
  static Future<void> _ensureSessionTraceColumns(Database db) async {
    await _addColumnIfMissing(db, 'sessions', 'trace_json', 'TEXT');
    await _addColumnIfMissing(db, 'sessions', 'trace_samples', 'INTEGER');
  }

  static Future<void> _ensureSessionSchema(Database db) => _ldbEnsureSessionSchema(db);

  // ── WORKOUT SUGGESTIONS (opt-in auto-detect) ───────────────────────────────
  static Future<void> _createWorkoutSuggestions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_suggestions (
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
      )
    ''');
  }

  static Future<void> putWorkoutSuggestion(Map<String, dynamic> row) async {
    await ActivityStore(await instance).reconcile(ActivityKind.workout, [row]);
  }

  static Future<List<Map<String, dynamic>>> activeWorkoutSuggestions() async => [
    for (final s in await ActivityStore(await instance).pending())
      if (s.kind == ActivityKind.workout) {
        ...s.details, 'id': s.id, 'start_ts': s.startTs, 'end_ts': s.endTs,
      },
  ];

  static Future<void> dismissWorkoutSuggestion(String id) async {
    final store = ActivityStore(await instance);
    final suggestion = await store.get(id);
    if (suggestion != null) await store.discard(suggestion);
  }

  // ── COACH READ-ONLY SQL VIEWS (derived-only) ───────────────────────────────
  // Re-created on every open (DROP+CREATE) so a view-shape change takes effect on
  // upgrade. These flatten DERIVED data only; the coach's read-only SQL layer is
  // allow-listed to these views and can never reach raw_records / decoded_*.
  // Every view over day_result selects the LATEST algo_version per day_id.
  static Future<void> _ensureCoachViews(Database db) => _ldbEnsureCoachViews(db);

  /// Run a rename → recreate → copy legacy-shape migration ATOMICALLY and
  /// IDEMPOTENTLY.
  ///
  /// The three callers below used to do `ALTER … RENAME`, then `CREATE`, then a
  /// row-by-row copy, then `DROP` — all OUTSIDE any transaction. That is fine
  /// under `onUpgrade` (sqflite wraps the whole ladder in one exclusive txn) but
  /// these also run from `_repairOpenSchema` in `onOpen`, which is NOT wrapped.
  /// A crash / OS kill between the rename and the end of the copy left
  /// `<table>` present AND correctly shaped, so the next open hit the
  /// "already current" early-return and `<table>_legacy` sat there orphaned with
  /// its rows never migrated — losing `strap_trim` / `counter_hw` / `rec_ts_hw`,
  /// i.e. the whole resumable-sync cursor and the safe-trim high-water.
  ///
  /// Now: one transaction — which sqflite JOINS to the already-open `onUpgrade`
  /// transaction when called from the ladder, and opens for real from `onOpen`
  /// — plus an explicit RESUME of an orphan left behind by any older build.
  ///
  /// [isCurrent] decides whether an existing `<table>` is already the new shape.
  /// [copy] must be idempotent (INSERT OR REPLACE on a natural key); set
  /// [copyOnlyIntoEmpty] for a destination with no natural key (autoincrement
  /// id), where re-running a resume would otherwise duplicate rows.
  static Future<void> _migrateLegacyTable(
    Database db, {
    required String table,
    required bool Function(Set<String> columns) isCurrent,
    required Future<void> Function(DatabaseExecutor ex) create,
    required Future<void> Function(
      DatabaseExecutor ex,
      List<Map<String, Object?>> legacyRows,
      int nowMs,
    )
    copy,
    bool copyOnlyIntoEmpty = false,
  }) => _ldbMigrateLegacyTable(db, table: table, isCurrent: isCurrent, create: create, copy: copy, copyOnlyIntoEmpty: copyOnlyIntoEmpty);

  static Future<void> _ensureSyncCursorSchema(Database db) => _ldbEnsureSyncCursorSchema(db);

  static Future<void> _ensureSyncLedgerSchema(Database db) => _ldbEnsureSyncLedgerSchema(db);

  static Future<void> _ensureSyncQuarantineSchema(Database db) => _ldbEnsureSyncQuarantineSchema(db);

  // samples — LEGACY header-only record index (counter, ts, hr). Retained only
  // so pre-v11 databases stay readable if decoded_onehz backfill was partial.
  // New writes should go to decoded_onehz instead.
  //
  // v47: re-keyed off `counter` for the same reason decoded_onehz was re-keyed
  // off it at v33 and off rec_ts now — `counter` is a WHOOP FLASH RECORD
  // COUNTER, so a second offloading band's counter 500 is a different reading
  // that collides with the first band's. The insert is IGNORE, so the collision
  // DROPPED the newer row rather than replacing the older one, and
  // [latestSample]'s fallback then served a stale second.
  static Future<void> _createSamples(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS samples (
        device_id TEXT NOT NULL DEFAULT '',
        ts_ms INTEGER NOT NULL DEFAULT 0,
        counter INTEGER,
        ts INTEGER NOT NULL,
        hr INTEGER,
        PRIMARY KEY (device_id, ts_ms)
      )
    ''');
  }

  // decoded_onehz / decoded_rr — durable canonical decoded substrate. This is
  // the canonical query surface for on-device analytics: one row per real
  // second (`rec_ts`) plus sparse RR beats for that second, keyed
  // `(device_id, ts_ms)` since v47. raw_records was dropped at v19, so no
  // complete raw-record replay ledger remains behind this store — the v44
  // [redriveArchivedRecords] pass re-decodes only selected, previously
  // undecodable `raw_archive` records — and it is pruned at
  // `rawRetentionDays`.
  static Future<void> _createDecodedStore(Database db) => _ldbCreateDecodedStore(db);

  /// Rebuild the decoded substrate into noop-style canonical time-keyed rows:
  /// keep exactly one decoded row per record second and one RR beat per
  /// (second, beat_index). (When this ran, older duplicate counters stayed in
  /// raw_records for forensics; that table was dropped at v19.)
  static Future<void> _rebuildCanonicalDecodedStore(Database db) => _ldbRebuildCanonicalDecodedStore(db);

  /// v33: re-key the decoded store off the volatile record `counter` onto rec_ts.
  ///
  /// Rebuilds BOTH decoded tables FROM THE EXISTING decoded tables ONLY. It must
  /// NOT backfill from raw_records (that table is DROPped — a raw-backfill would
  /// zero the store, total loss). Existing rows have a unique rec_ts, so the copy
  /// loses nothing; any pre-fix duplicate counters collapse to newest-wins per
  /// rec_ts. Idempotent: a crash mid-migration re-runs cleanly (the temp tables
  /// are dropped up front, and every write is INSERT OR REPLACE keyed on identity).
  ///
  /// All copies are INSERT ... SELECT (server-side, ZERO host-bound variables),
  /// so the iOS SQLITE_MAX_VARIABLE_NUMBER (999) never applies — no chunking is
  /// needed. Mirrors [_rebuildCanonicalDecodedStore]'s rename-aside shape.
  /// v39: drop `NOT NULL` from the six SENSOR columns of `decoded_onehz`.
  ///
  /// SQLite cannot relax a constraint in place, so this is the standard
  /// rebuild — same shape as [_rekeyDecodedStoreByRecTs], but `decoded_rr` is
  /// untouched and no row is rewritten: the copy is a straight column-for-column
  /// SELECT, so it is safe on a populated table and existing values (including
  /// the historical fabricated zeros, which readers already treat as absent)
  /// survive verbatim. A pre-v34 DB reaching this step has already had the band
  /// columns added by the v34 rung above, so the explicit column list is valid.
  static Future<void> _relaxDecodedSensorNulls(Database db) => _ldbRelaxDecodedSensorNulls(db);

  /// One `CREATE TABLE (…)` body reconstructed from a live `PRAGMA
  /// table_info`, for the rebuild-aside migrations in this file.
  ///
  /// DERIVED, NEVER HARDCODED. These tables' column sets are genuinely in flux
  /// (`ambient_raw` v42, `device_family` v41, `source` + the MT-12 channels
  /// v43, `ts_subsec` / `band_sleep_state` off-ladder), and a hardcoded list
  /// silently DROPS every column added after it was written — data loss, in a
  /// rung that runs once and cannot be re-run.
  ///
  /// THE PRIMARY KEY IS THE PART THAT NEEDS CARE. `PRAGMA table_info.pk` is a
  /// 1-based POSITION, not a flag, so a composite key reports several columns.
  /// A one-column key is emitted INLINE (`x INTEGER PRIMARY KEY`) because that
  /// is the only spelling that keeps SQLite's rowid-alias behaviour; anything
  /// wider must be a table-level `PRIMARY KEY (a, b)` clause, and emitting the
  /// inline form for each of them instead throws "table has more than one
  /// primary key".
  ///
  /// [prepend] columns are emitted first, verbatim, and are NOT in [info] — a
  /// re-key adds its new key columns that way. [primaryKey] replaces the old
  /// key entirely; omit it to carry the table's own key across.
  /// [dropNotNull] relaxes named columns. Nothing here ever ADDS a constraint:
  /// a constraint failure inside `onUpgrade`'s single exclusive transaction
  /// rolls the whole ladder back and quarantines the database (invariant 11),
  /// so a rebuild may only ever loosen.
  static String _rebuildDdlBody(
    List<Map<String, Object?>> info, {
    Set<String> dropNotNull = const {},
    List<String> prepend = const [],
    List<String>? primaryKey,
  }) => _ldbRebuildDdlBody(info, dropNotNull: dropNotNull, prepend: prepend, primaryKey: primaryKey);

  /// v47: put `device_id` in front of the key of every table whose identity was
  /// a WHOOP-shaped quantity — a record second, or the band's flash counter.
  ///
  /// WHY THIS ONE IS NOT DEFERRABLE. `decoded_onehz` was `rec_ts INTEGER
  /// PRIMARY KEY` written with REPLACE and `decoded_rr` was cleared by an
  /// unscoped `DELETE … WHERE rec_ts = ?`, so a second device measuring the
  /// same second did not merge with the first — it DELETED it, row and beats.
  /// No ledger keeps the raw bytes a decoded row came from (`raw_records` was
  /// dropped at v19), so an evicted row could not be rebuilt (only seconds the
  /// v44 pass re-drove from `raw_archive` still have their source bytes).
  /// Every other item on the band-agnostic roadmap can be done after a second
  /// device has written; this one cannot.
  ///
  /// WHAT IT DOES NOT CHANGE. Every existing row is copied under
  /// `device_id = ''` with `ts_ms = rec_ts * 1000`, which is exactly as unique
  /// as `rec_ts` was — one row per second per device, same newest-wins REPLACE,
  /// same dedupe. No stored value is rewritten and no derived number moves, so
  /// there is no `kAlgoVersion` bump with it.
  ///
  /// Cheap enough for the launch-path CPU watchdog `onUpgrade` runs inside:
  /// the decoded store is retention-capped at `rawRetentionDays`, ~86 k rows a
  /// day, and every copy is a server-side `INSERT … SELECT` with zero
  /// host-bound variables (so the iOS `SQLITE_MAX_VARIABLE_NUMBER` never
  /// applies and no chunking is needed).
  static Future<void> _rekeyStoresByDeviceId(Database db) async {
    await _rekeyTableByDevice(db, 'decoded_onehz');
    await _rekeyTableByDevice(db, 'decoded_rr', keyTail: const ['beat_index']);
    await _rekeyTableByDevice(db, 'samples', timeCol: 'ts');
  }

  /// The rename-aside rebuild behind [_rekeyStoresByDeviceId], for one table.
  ///
  /// Self-skipping and idempotent: a table that already carries `device_id` is
  /// left alone (so a fresh install at v47+ does no work at all), the temp
  /// table is dropped up front so a crash mid-migration re-runs cleanly, and
  /// the copy is keyed on identity.
  static Future<void> _rekeyTableByDevice(
    Database db,
    String table, {
    String timeCol = 'rec_ts',
    List<String> keyTail = const [],
  }) => _ldbRekeyTableByDevice(db, table, timeCol: timeCol, keyTail: keyTail);

  /// v51: put `device_id` in front of a content-keyed or time-keyed table's PK.
  ///
  /// Self-skipping and idempotent, the same three ways [_rekeyTableByDevice]
  /// is: a table that already carries `device_id` is left alone (so a fresh
  /// install at v51+ does no work), an absent table returns early (its
  /// current DDL already carries the new key), and the temp table is dropped
  /// up front so a crash mid-migration re-runs cleanly.
  ///
  /// Every existing row is copied under `device_id = ''` (kPrimaryDeviceId) —
  /// the primary band, which is exactly what those rows have always meant. No
  /// value is rewritten and no derived number can move, which is why this
  /// ships without a kAlgoVersion bump.
  ///
  /// INSERT OR IGNORE, not REPLACE: the old key was already unique, so the
  /// copy cannot collide, and IGNORE is the conflict policy every one of
  /// these tables is written with in production (`insertEvent`,
  /// `archiveRawRecord`, `insertBandBatterySample`). Matching it means a
  /// re-run cannot evict a row.
  static Future<void> _rekeyByDeviceIdV51(
    Database db,
    String table, {
    required List<String> keyTail,
  }) => _ldbRekeyByDeviceIdV51(db, table, keyTail: keyTail);

  /// v43 (SLP-05): drop `NOT NULL` from `decoded_onehz.hr`.
  ///
  /// See [_createDecodedStore] for WHY. This is the same rebuild shape as
  /// [_relaxDecodedSensorNulls] with one difference: the new table's DDL is
  /// DERIVED from the old table's `PRAGMA table_info` rather than hardcoded.
  /// That column set is genuinely in flux (`ambient_raw` at v42, `device_family`
  /// at v41, `source` and the MT-12 channels at v43, and whatever lands next),
  /// and a hardcoded list here silently DROPS any column added after it was
  /// written — data loss, in a rung that runs once and cannot be re-run. The
  /// copy is column-for-column with no row rewritten, so it is safe on a
  /// populated table and existing values (including the historical `hr = 0`
  /// rows, which every reader already treats as absent) survive verbatim.
  ///
  /// Self-skipping: a database whose `hr` is already nullable — every fresh
  /// create at v43+ — does no work at all. That also keeps it cheap under the
  /// launch-path CPU watchdog `onUpgrade` runs inside (invariant 11); the table
  /// is retention-capped at `rawRetentionDays`, so the one-time copy is
  /// bounded.
  static Future<void> _relaxDecodedHrNull(Database db) => _ldbRelaxDecodedHrNull(db);

  static Future<void> _rekeyDecodedStoreByRecTs(Database db) => _ldbRekeyDecodedStoreByRecTs(db);

  // raw_records — keyed by the band's per-record u32 `counter` (the natural
  // idempotency key; re-draining the same flash region inserts nothing new). Only
  // the 1 Hz historical substrate (0x2F / R24) is persisted here — LIVE high-rate
  // frames are ephemeral (routed to an in-memory sink, never stored). Keying by
  // counter instead of the full hex string roughly HALVES on-disk size.
  static Future<void> _createRaw(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_records (
        counter INTEGER PRIMARY KEY,
        hex TEXT NOT NULL,
        packet_type INTEGER,
        captured_at INTEGER NOT NULL,
        rec_ts INTEGER NOT NULL DEFAULT 0,
        uploaded INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_unuploaded ON raw_records(uploaded, captured_at) WHERE uploaded = 0',
    );
    // rec_ts is the bucketing/window key for the DerivationEngine.
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_rects ON raw_records(rec_ts)',
    );
  }

  /// Add the additive `rec_ts` column to an EXISTING raw_records table (upgrade
  /// path only). NOT NULL with a DEFAULT 0 so legacy rows are well-formed until
  /// the backfill rewrites them.
  /// GUARDED (see [_addColumnIfMissing]): the step-3 rebuild already creates
  /// raw_records from the CURRENT `_createRaw` DDL, which carries rec_ts — so on
  /// an oldV <= 2 upgrade this column is already there.
  static Future<void> _addRecTsColumn(Database db) => _addColumnIfMissing(
    db,
    'raw_records',
    'rec_ts',
    'INTEGER NOT NULL DEFAULT 0',
  );

  /// Backfill `rec_ts` for every existing raw row by decoding its hex once. Runs
  /// inside the migration on a populated DB. Falls back to captured_at/1000 when a
  /// frame is undecodable or yields a non-positive ts — rec_ts is never left at 0.
  static Future<void> _backfillRecTs(Database db) => _ldbBackfillRecTs(db);

  /// Decode a frame's REAL record timestamp (epoch seconds) from its inner hex.
  /// Cheap (reads the ts field only via the protocol decoders). Returns
  /// [fallbackSec] when undecodable or the decoded ts is non-positive — so callers
  /// never store a 0/negative rec_ts. Used at insert and during the v6 backfill.
  static int decodeRecTs(String hex, {required int fallbackSec}) {
    // Historical type-24 carries the canonical ts; decodeRecord covers 0x28/R10/R24.
    try {
      final s = proto.decodeRecord(hex);
      if (s != null && s.ts > 0) return s.ts;
    } catch (_) {
      /* fall through */
    }
    // RR-bearing live frames (0x28) as a secondary path.
    try {
      final rr = proto.realtimeRr(hex);
      if (rr != null && rr.ts > 0) return rr.ts;
    } catch (_) {
      /* fall through */
    }
    return fallbackSec;
  }

  static Future<void> _writeCaptureFreshness(
    DatabaseExecutor txn,
    List<RawRecord> raws,
  ) => _ldbWriteCaptureFreshness(txn, raws);

  // Canonical LOCAL day label — shared with the UI/coach via day_label.dart so
  // every layer computes "today" identically (never in UTC).
  static String _localDayLabel(DateTime dt) => dayLabelOf(dt);

  static String _localDayLabelFromEpoch(int epochSec) =>
      _localDayLabel(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000));

  /// Gen4 historical R10-lite (hr-only, no accel/optical) must stay out of
  /// `decoded_onehz` — they belong in the legacy `samples` table only.
  ///
  /// Matched on the hex prefix rather than decoded bytes: this runs once per
  /// record inside the offload transaction, and parsing 240 hex chars to read
  /// two of them costs ~13 ms per 50k records plus a Uint8List of garbage each.
  static final _gen4R10LitePrefix =
      '${proto.PacketType.historicalData.toRadixString(16).padLeft(2, '0')}'
      '${proto.Record.r10.toRadixString(16).padLeft(2, '0')}';
  static bool _isGen4R10LiteHistorical(String hex) =>
      hex.length >= 4 &&
      hex.substring(0, 4).toLowerCase() == _gen4R10LitePrefix;

  static Sample? _decodeOneHzSample(RawRecord raw, {Sample? preferred}) => _ldbDecodeOneHzSample(raw, preferred: preferred);

  /// Queues the decoded_onehz + decoded_rr writes for one raw onto [batch].
  /// Returns the number of batch operations added, so a caller committing a
  /// large offload can chunk the batch to bound the native argument-list size
  /// (see [commitSyncBatch]).
  static int _queueDecodedOneHz(
    Batch batch,
    RawRecord raw,
    Sample? sample, {
    String? deviceFamily,
    String deviceId = kPrimaryDeviceId,
    // TRUE ONLY FROM A MID-LADDER REPLAY, and it is not a style choice. This
    // map is also written by `_backfillDecodedStore` (rungs oldV<11 / oldV<20)
    // and `redriveArchivedRecords` (rung oldV<44), both of which run BEFORE the
    // v47 rung hands `device_id` / `ts_ms` back — and naming a column that does
    // not exist yet throws inside onUpgrade's one exclusive transaction and
    // quarantines the whole database. Their rows are re-keyed by
    // [_rekeyTableByDevice] a few rungs later, from `rec_ts`, which is the same
    // value this path would have written.
    //
    // The default is FALSE and the key columns are named, deliberately: the
    // opposite default would let a forgotten argument write every row at
    // ('', 0), where REPLACE collapses the entire store to ONE row.
    bool preDeviceKey = false,
  }) => _ldbQueueDecodedOneHz(batch, raw, sample, deviceFamily: deviceFamily, deviceId: deviceId, preDeviceKey: preDeviceKey);

  /// `rec_ts` for one raw+decoded pair.
  ///
  /// `??` substitutes on NULL only, and `rec_ts` determines the primary key
  /// (`ts_ms = rec_ts * 1000` under `(device_id, ts_ms)`). The
  /// legacy `raw_records.rec_ts` column is `NOT NULL DEFAULT 0`, so every
  /// undated row [_backfillDecodedStore] replays arrives here as an explicit
  /// 0 — which under the old counter PK coexisted harmlessly and under this
  /// one REPLACE-evicts all the others down to a single row. Same `> 0`
  /// fallback [_recTsFor] uses (the decoded sample already carries the
  /// timestamp, so going through it would re-decode the hex for nothing).
  static int _recTsFrom(RawRecord raw, Sample decoded) {
    final rawRecTs = raw.recTs;
    return (rawRecTs != null && rawRecTs > 0) ? rawRecTs : decoded.tsEpoch;
  }


  /// Replaces this second's RR beats. Returns the ops queued.
  ///
  /// Clear the second before reinserting so a SHRINKING beat count can't strand
  /// stale high-index beats. The child's key extends the parent's `(device_id,
  /// ts_ms)`, so this single DELETE of the writing device's second replaces the
  /// old counter-based orphan guard. (The mid-ladder replay that runs before
  /// v47 adds the device key — [preDeviceKey] — can only clear by `rec_ts`,
  /// because no other key exists yet.)
  static int _queueRrBeats(
    Batch batch,
    int recTs,
    Sample decoded, {
    String? deviceFamily,
    String deviceId = kPrimaryDeviceId,
    bool preDeviceKey = false,
  }) => _ldbQueueRrBeats(batch, recTs, decoded, deviceFamily: deviceFamily, deviceId: deviceId, preDeviceKey: preDeviceKey);

  /// Queue one [NeutralSample] — a row from a band with no framed record to
  /// decode — plus its beats. Returns the op count, same contract as
  /// [_queueDecodedOneHz]. The union of `hrs_link._flush` and
  /// `oura_link._commit`'s bodies, not new logic — see M1 spec §9.3.
  ///
  /// REPLACE, not IGNORE, for the same reason [_queueDecodedOneHz] uses it: a
  /// re-read of the same range is idempotent by design on a fetch-by-cursor
  /// band.
  ///
  /// `beat_ts_ms` is [NeutralSample.beatTsMs] when the host timed the beats
  /// (an arrival-stamped strap, off its own beat chain), NULL otherwise.
  ///
  /// `counter` is 0. It is a WHOOP flash-record number this class of band does
  /// not have; nothing reads the column except `ORDER BY rec_ts, counter`.
  /// ponytail: make it nullable when db.dart is next open for a schema
  /// change — the note was already carried in both files this merges.
  static int _queueNeutralOneHz(
    Batch batch,
    NeutralSample n, {
    // NOT nullable, unlike the framed path's: see the refusal in
    // [_commitSyncBatchLocked] — an unnamed `source` reads as the primary band.
    required String deviceFamily,
    required String deviceId,
  }) => _ldbQueueNeutralOneHz(batch, n, deviceFamily: deviceFamily, deviceId: deviceId);

  static Future<void> _backfillDecodedStore(Database db) => _ldbBackfillDecodedStore(db);

  // Events (wrist on/off, charging, battery, double-tap, …) — live OR from sync.
  // Keyed by the full frame hex so re-delivered identical events dedupe. Retained
  // until uploaded, then deleted (same guarantee as raw_records).
  static Future<void> _createEvents(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        device_id TEXT NOT NULL DEFAULT '$kPrimaryDeviceId',
        hex TEXT NOT NULL,
        event_id INTEGER,
        ts INTEGER,
        captured_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    // The PK is the frame hex, so a `ts` window (the timeline's day query, and
    // the retention prune) was a full table scan. Cheap to build — `events` is
    // pruned to the retention window.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)');
  }

  // band_events / band_battery — structured local history for device-state
  // signals that were previously only ephemeral or raw-only. Additive beside
  // the upload-queue `events` table.
  static Future<void> _createBandSignals(Database db) => _ldbCreateBandSignals(db);

  /// band_backlog — the strap's own ring-buffer bookkeeping, one row per
  /// connect. `pages_behind` is fully parsed by the protocol
  /// (`control.dart:652`) and arrives on a response edge already reads; until
  /// now it had zero readers anywhere in the app and was decoded and dropped.
  ///
  /// DEVICE STATE, NOT PHYSIOLOGY. It can claim exactly what it says: how much
  /// the band is still holding, and whether its ring has wrapped. That is the
  /// one distinction the app currently cannot draw — a STALLED offload versus
  /// an idle one — and `wrap_count` moving between two connects is a hard fact
  /// that data was overwritten before we ever saw it.
  ///
  /// NOT PRUNED, for the band_battery reason: a retention cap on a series whose
  /// only use is comparing today's reading to the last one destroys it. Six
  /// narrow columns per connect is not a storage problem.
  ///
  /// `device_family` rides along because a page and a record mean different
  /// things on different straps — `free_records` on gen4 and on gen5 must never
  /// be put on the same axis or divided by the same records-per-day.
  ///
  /// `batchId` is deliberately NOT stored: it is a ring wrap count, not a
  /// unique batch id, so nothing here may be used to dedupe a batch.
  static Future<void> _createBandBacklog(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS band_backlog (
        device_id TEXT NOT NULL DEFAULT '$kPrimaryDeviceId',
        ts INTEGER NOT NULL,
        written INTEGER,
        used INTEGER,
        capacity INTEGER,
        trim_page INTEGER,
        wrap_count INTEGER,
        free_records INTEGER,
        device_family TEXT,
        PRIMARY KEY (device_id, ts)
      )
    ''');
  }

  /// Record one connect's `pages_behind` reading. [ts] is epoch SECONDS.
  ///
  /// LOGGING ONLY for now, by instruction: no copy, no notification, no
  /// headroom estimate. `free_records / records-per-day` is the headroom in
  /// days and `wrap_count` moving means a loss already happened, but the
  /// records-per-day divisor is per-device and has to be established from real
  /// logged data before any number goes in front of a user. This is what
  /// establishes it.
  static Future<void> putBandBacklog({
    required int ts,
    String deviceId = kPrimaryDeviceId,
    int? written,
    int? used,
    int? capacity,
    int? trimPage,
    int? wrapCount,
    int? freeRecords,
    String? deviceFamily,
  }) => _ldbPutBandBacklog(ts: ts, deviceId: deviceId, written: written, used: used, capacity: capacity, trimPage: trimPage, wrapCount: wrapCount, freeRecords: freeRecords, deviceFamily: deviceFamily);

  /// The most recent [limit] backlog readings, newest first. [deviceId] scopes
  /// to one device when given; the one caller (ble_engine.dart) passes none in
  /// M3, so this still returns the newest row from any device — what a
  /// single-device install has always got.
  static Future<List<Map<String, dynamic>>> bandBacklog({
    int limit = 60,
    String? deviceId,
  }) async {
    final db = await instance;
    return db.query(
      'band_backlog',
      where: deviceId == null ? null : 'device_id = ?',
      whereArgs: deviceId == null ? null : [deviceId],
      orderBy: 'ts DESC',
      limit: limit,
    );
  }

  /// Additive: add the `millivolts` column to an existing band_battery table.
  /// Guarded — the column already exists on fresh installs (see _createBandSignals)
  /// and ALTER … ADD COLUMN throws if it's already there.
  static Future<void> _ensureBandBatteryMillivolts(Database db) =>
      _addColumnIfMissing(db, 'band_battery', 'millivolts', 'INTEGER');

  /// Additive: the strap's own charge counter. Same guard, same reason as
  /// [_ensureBandBatteryMillivolts]. See [extendedChargeUnits] for what it is
  /// and — more importantly — what it is not.
  static Future<void> _ensureBandBatteryChargeUnits(Database db) =>
      _addColumnIfMissing(db, 'band_battery', 'charge_units', 'INTEGER');

  /// Replay stored band events into `band_battery`.
  ///
  /// The point of running this at all: the writer added alongside it only fills
  /// the series from here forward, and `batteryHealth` reports a full-charge
  /// voltage and a charge count that only mean anything ACROSS the life of the
  /// pack. Everything needed to fill the past is already on disk — `band_events`
  /// keeps the whole frame — so an existing install gets its history rather than
  /// starting the series at this upgrade.
  ///
  /// BOUNDED, because this runs inside `openDatabase` under iOS's CPU watchdog
  /// (invariant 11): the two ids together are ~2,400 rows over 9 days on the
  /// largest real export, and non-charge/wear band events are pruned at the
  /// retention edge anyway, so the cap is a backstop and not the normal case.
  /// INSERT OR IGNORE, so it can never overwrite a row the live writer already
  /// wrote.
  static Future<void> _backfillBandBatteryFromEvents(DatabaseExecutor db) => _ldbBackfillBandBatteryFromEvents(db);

  /// The `(device_id, hex)`-keyed table the ladder rungs below v58 build and
  /// re-key ([_rekeyByDeviceIdV51]). Only the ladder creates it now; the open
  /// pass converts it into [rawArchiveTable] ([_ensureRawArchiveStore]).
  static Future<void> _createLegacyRawArchive(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raw_archive (
        device_id TEXT NOT NULL DEFAULT '$kPrimaryDeviceId',
        hex TEXT NOT NULL,
        counter INTEGER,
        packet_type INTEGER NOT NULL,
        rec_ts INTEGER,
        captured_at INTEGER NOT NULL,
        reason TEXT NOT NULL,
        PRIMARY KEY (device_id, hex)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_raw_archive_captured '
      'ON raw_archive(captured_at DESC)',
    );
  }

  /// Where archived frames are stored: [_createRawArchiveFrames]. Readers keep
  /// reading the `raw_archive` view, which gives the frame back as `hex`.
  static const String rawArchiveTable = 'raw_archive_frames';

  /// A pre-conversion `raw_archive` table, renamed aside on open and moved
  /// into [rawArchiveTable] in pages by [migrateLegacyRawArchive].
  static const String _rawArchiveLegacy = 'raw_archive_legacy';

  /// The view every reader goes through ([_ensureRawArchiveView]). NOT named
  /// `raw_archive`: an older build opening this file after a rollback runs
  /// `CREATE TABLE IF NOT EXISTS raw_archive` and then `CREATE INDEX IF NOT
  /// EXISTS idx_raw_archive_captured ON raw_archive`, and SQLite refuses to
  /// index a view before it looks at the name, so a view under the old name
  /// failed that open and got the database quarantined. With the name free,
  /// the old build makes itself an empty table, the index line is a no-op
  /// (the name is taken by [rawArchiveTable]'s), and the next open of this
  /// build folds whatever it wrote back in ([_ensureRawArchiveStore]).
  static const String rawArchiveView = 'raw_archive_view';

  /// The frame as the `raw_archive` view's `hex` column: the stored text for a
  /// frame kept verbatim, else the bytes in lowercase hex — exactly the
  /// string [rawArchiveRow] was handed.
  static const String _rawArchiveHexSql = 'COALESCE(hex, lower(hex(frame)))';

  /// Durable archive for historical records we received but could not decode
  /// (unknown/unsupported version). Thinned to a stated SAMPLE RATE behind the
  /// retention edge and otherwise kept forever — the point is that a future
  /// firmware's records survive until we understand the format, and a sample is
  /// what a decode needs. See [thinRawArchiveBefore] for the numbers. Keyed by
  /// frame CONTENT (`hash`), like `events`/`band_events` — NOT by `counter`.
  /// The strap resets its record counter to ~0 on every reboot, so two
  /// DISTINCT undecodable frames from different boots can collide on a reused
  /// counter; a `counter`-PK + IGNORE silently DROPPED the second, in the one
  /// table whose whole purpose is to never lose a frame. Keying on the bytes
  /// means an identical re-flood (missed-ACK redelivery) still dedups, while
  /// genuinely distinct frames both survive a counter collision. `counter` is
  /// retained as a plain forensic column.
  ///
  /// THE BYTES, NOT THEIR HEX, AND KEYED BY A HASH. The table this replaces
  /// stored each frame as hex TEXT under `PRIMARY KEY (device_id, hex)` on a
  /// rowid table, so every frame was written twice — once in the row and once
  /// in the key's autoindex — at two characters a byte: a 2,128-byte WHOOP MG
  /// v20 frame cost ~9 KB, ~10,500 of them a day. Here it is one BLOB under a
  /// 20-byte SHA-1 of it, ~4.2 KB a frame (a 2.2 KB row cannot share a 4 KB
  /// page with a second one, so each takes a page). `frame` is last so a
  /// scan of the small columns (thinning, stats) never walks its overflow
  /// pages. A rowid table still: [_mergeFromDbFile] pages restores by rowid.
  ///
  /// `hex` keeps the text verbatim, with `frame` NULL, when it is not the
  /// canonical lowercase hex of some bytes — so nothing is ever rewritten on
  /// the way in, whatever a caller handed over.
  static Future<void> _createRawArchiveFrames(Database db) => _ldbCreateRawArchiveFrames(db);

  /// `raw_archive` as every reader has always seen it, over [rawArchiveTable]
  /// (and the legacy table while [migrateLegacyRawArchive] is still moving
  /// it). The INSTEAD OF triggers keep plain inserts and deletes against the
  /// old name working — an older build after a rollback, a test fixture —
  /// with the text itself as the key: correct, just without the size saving.
  /// Everything in this build writes through [rawArchiveRow] instead.
  static Future<void> _ensureRawArchiveView(DatabaseExecutor db) => _ldbEnsureRawArchiveView(db);

  /// `'table'`, `'view'`, … for [name] in sqlite_master, or null.
  static Future<String?> _objectType(DatabaseExecutor db, String name) async {
    final rows = await db.rawQuery(
      'SELECT type FROM sqlite_master WHERE name = ? LIMIT 1',
      [name],
    );
    return rows.isEmpty ? null : rows.first['type'] as String?;
  }

  /// The archive store, on every open. A database still holding the old
  /// `raw_archive` TABLE has it renamed aside — O(1), no row touched, so safe
  /// under the launch watchdog (invariant 11) — and the rows move later, in
  /// pages, off the open path ([migrateLegacyRawArchive]). The view unions
  /// both until then, so no reader ever sees a frame missing.
  static Future<void> _ensureRawArchiveStore(Database db) => _ldbEnsureRawArchiveStore(db);

  /// [hex] as bytes when it is canonical lowercase hex (even length, 0-9a-f),
  /// else null — so `lower(hex(frame))` gives back exactly [hex].
  static Uint8List? _canonicalHexBytes(String hex) {
    final n = hex.length;
    if (n == 0 || n.isOdd) return null;
    final out = Uint8List(n >> 1);
    int nibble(int c) {
      if (c >= 0x30 && c <= 0x39) return c - 0x30;
      if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
      return -1;
    }

    for (var i = 0; i < n; i += 2) {
      final hi = nibble(hex.codeUnitAt(i)), lo = nibble(hex.codeUnitAt(i + 1));
      if (hi < 0 || lo < 0) return null;
      out[i >> 1] = (hi << 4) | lo;
    }
    return out;
  }

  /// The [rawArchiveTable] row for one archived frame. Every writer in this
  /// build goes through here (the drain commit, the fallback path, the
  /// legacy move, a restore), so the key is always the same function of the
  /// frame: SHA-1 of the bytes, or of the text when it is kept verbatim.
  static Map<String, Object?> rawArchiveRow({
    required String deviceId,
    required String hex,
    required int? counter,
    required int packetType,
    required int? recTs,
    required int capturedAt,
    required String reason,
  }) => _ldbRawArchiveRow(deviceId: deviceId, hex: hex, counter: counter, packetType: packetType, recTs: recTs, capturedAt: capturedAt, reason: reason);

  /// Move the renamed-aside legacy archive into [rawArchiveTable], 500 rows a
  /// transaction: each page is inserted and deleted from the legacy table in
  /// the same commit, so a kill between pages loses nothing and repeats
  /// nothing. Once it is empty the legacy table is dropped and the view
  /// rebuilt over the new table alone. Returns rows moved; stops after the
  /// first page past [budget], or when [shouldStop] says a band offload has
  /// started (its commits would queue behind these pages), and resumes on
  /// the next call.
  static Future<int> migrateLegacyRawArchive({
    Duration? budget,
    bool Function()? shouldStop,
  }) => _ldbMigrateLegacyRawArchive(budget: budget, shouldStop: shouldStop);

  /// One compressed, verified bucket of pruned decoded substrate per
  /// (device_id, utc_day) — see substrate_archive.dart. `utc_day` is
  /// `rec_ts ~/ 86400`, an absolute storage partition and NEVER a day label.
  ///
  /// A rowid table on purpose (not WITHOUT ROWID): [_mergeFromDbFile] pages
  /// every restored table by rowid.
  static Future<void> _createSubstrateArchive(Database db) => _ldbCreateSubstrateArchive(db);

  /// [deviceId] is required, not defaulted — a default here is exactly how a
  /// second device's events would silently keep landing on the primary's key.
  /// Every caller names the device explicitly; see the M3 spec's call-site
  /// table for why each one is correct in M3 (a marked `kPrimaryDeviceId`
  /// today, a real per-session id from M2 onward).
  static Future<void> insertEvent(
    int eventId,
    int ts,
    String hex, {
    required String deviceId,
    // Required, not defaulted: a default of gen4 is exactly how every gen5
    // BATTERY_PACK_INFO / condition-report / haptics event was stored as a
    // bare `EVENT_<id>` with an empty payload.
    required proto.BandProfile profile,
  }) => _ldbInsertEvent(eventId, ts, hex, deviceId: deviceId, profile: profile);

  /// The `band_battery` row an incoming band event carries, or null when it
  /// carries none.
  ///
  /// WHY THIS EXISTS. `band_battery.millivolts` has had a column, a reader
  /// ([batteryHealth]) and a rendered widget since it was added, and NO WRITER:
  /// the only insert was AppState's `DeviceState` tick, which has no voltage.
  /// It was 0-filled on all four real exports (0 of 433 / 413 / 626 / 171 rows),
  /// so the device screen's charge-history line has been blank on every install
  /// there has ever been. The number was on the wire the whole time — the band
  /// sends BATTERY_LEVEL every few minutes and the protocol already decodes
  /// `battery_mv` out of it; nothing carried it the last four inches into the
  /// series table. This is that write, on the funnel every event already goes
  /// through (live AND headless — see AppState._onLiveEvent and
  /// background_sync).
  ///
  /// Two events land here, under two SOURCES rather than one merged row: they
  /// arrive 1:1 at the same strap second, and `band_battery` is keyed
  /// `(ts, source)`, so one source would make each overwrite the other's
  /// columns. Split, each row states only what its own event said.
  ///
  ///  * BATTERY_LEVEL — `battery_pct` / `millivolts` / `charging`, all three
  ///    already decoded by the protocol. Source `band_event`.
  ///  * EXTENDED_BATTERY_INFORMATION — [extendedChargeUnits]. Source
  ///    `band_event_ext`.
  ///
  /// ON THE `charging` FLAG. It rides on the BATTERY_LEVEL row (the event's own
  /// byte), NOT on a chargingOn/chargingOff transition, and the strap can
  /// replay these out of its flash backlog hours late — which is exactly why
  /// [batteryHealth] counts charge edges PER SOURCE and takes the max rather
  /// than walking one interleaved series.
  @visibleForTesting
  static Map<String, Object?>? batteryRowFromEvent(proto.EventInfo e) => _ldbBatteryRowFromEvent(e);

  /// EXTENDED_BATTERY_INFORMATION. Named here rather than taken from
  /// `proto.EventId` because the sealed protocol has no constant for it.
  static const int kExtendedBatteryInfoEventId = 63;

  /// The strap's own charge counter out of an EXTENDED_BATTERY_INFORMATION
  /// body, or null when the body is not one this reads.
  ///
  /// WHAT THE EVIDENCE IS. The event arrives paired 1:1 with BATTERY_LEVEL and
  /// its body was dropped whole (`payload_json = '{}'` on 3,372 stored rows
  /// across the four real exports). Decoding the stored bodies and joining each
  /// to the BATTERY_LEVEL it arrived beside:
  ///
  ///   rev 3 (gen5/MG, 12-byte body), u16 LE @ [9]:
  ///     r = +1.0000 against `battery_pct` over 263 pairs (whoop-mg) and 85
  ///     (whoop-5); range 977-1915 against 50.9-99.7 %, i.e. 977/1915 = 0.5100
  ///     against 0.5106 — the same quantity at ~19x the resolution of the
  ///     deci-percent.
  ///   rev 1 (gen4, 28-byte body), u16 LE @ [11]:
  ///     r = +0.9992 against `battery_pct` over 273 pairs; range 790-1750.
  ///     (That body ALSO carries the millivolts at [5], r = +1.0000 against
  ///     BATTERY_LEVEL's own `battery_mv`. Not read here — it is the same
  ///     number from the same second, and one source for it is enough.)
  ///
  /// WHAT IS NOT CLAIMED. THE UNIT IS UNPINNED. It is linear in state of
  /// charge and that is the whole claim — it is not mAh, not coulombs, not a
  /// capacity, and it must never be rendered with a unit or compared against a
  /// cell spec. What a ratio of two of them supports (this reading over the
  /// full-charge reading) is a fraction, which needs no unit; anything else
  /// needs a unit nobody has established. The two signed words at [1] and [3]
  /// are negative while discharging and look like instantaneous and averaged
  /// current — deliberately NOT decoded, for the same reason: a current in
  /// unknown units is a number that invites "mA" and cannot support it.
  @visibleForTesting
  static int? extendedChargeUnits(Uint8List body) {
    if (body.isEmpty) return null;
    // Offset is per BODY REVISION, never per length: a future revision that
    // happens to be 12 or 28 bytes long would otherwise be read at an offset
    // that was only ever verified for this one.
    final at = switch (body[0]) {
      3 => 9, // gen5 / MG
      1 => 11, // gen4
      _ => null,
    };
    if (at == null || body.length < at + 2) return null;
    final units = body[at] | (body[at + 1] << 8);
    // 0 is the absent/uninitialised read, not a flat pack — a strap reporting a
    // real battery level in the same second has not measured zero charge.
    return units > 0 ? units : null;
  }

  /// [deviceId] is REQUIRED and not defaulted. `band_battery` is keyed
  /// `(device_id, ts, source)` with `ConflictAlgorithm.ignore`, so a writer
  /// that omitted it let SQLite apply the primary-device default: a secondary
  /// device's sample would be stored under the band and silently dropped on
  /// the collision. Naming the originating device is the caller's job.
  static Future<void> insertBandBatterySample({
    required int ts,
    required String deviceId,
    double? batteryPct,
    bool? charging,
    bool? wristOn,
    int? millivolts,
    required String source,
  }) => _ldbInsertBandBatterySample(ts: ts, deviceId: deviceId, batteryPct: batteryPct, charging: charging, wristOn: wristOn, millivolts: millivolts, source: source);

  /// Recent battery samples (newest first), for the battery-health series.
  static Future<List<Map<String, dynamic>>> recentBandBatterySamples({
    int limit = 500,
  }) async {
    final db = await instance;
    return db.query('band_battery', orderBy: 'ts DESC', limit: limit);
  }

  /// A simple, honest battery-health readout derived from the stored series.
  ///   - `full_charge_mv`: the highest millivolts ever seen while charging (a
  ///     pack's full-charge voltage sags over its life);
  ///   - `charge_cycles`: how many times the band has been put on the charger
  ///     (a coarse proxy — a top-up is not a cycle);
  ///   - `latest_pct` / `latest_mv`: the most recent sample.
  /// All fields are nullable (absent input → null, never fabricated).
  ///
  /// BOTH LIFETIME FACTS COME OUT OF SQL, NOT A ROW WINDOW. They only mean
  /// anything across the life of the pack, and the row window they used to be
  /// computed over was a `LIMIT` on a table that now takes a row every few
  /// minutes rather than every few state changes — the same window that used to
  /// span a month would span days, quietly shrinking "the highest ever seen"
  /// into "the highest this week".
  ///
  /// `charge_cycles` counts CHARGING_ON events rather than rising edges in this
  /// series, which is both cheaper and truer: the events are one of the four ids
  /// `band_events` keeps forever, so the count is lifetime; and an edge walk
  /// over a SAMPLED series misses any charge that began and ended between two
  /// samples, while double-counting one that two sources disagree about at the
  /// boundary — a real hazard now that the strap's own (replayable, possibly
  /// hours-late) battery events land in the same table as the live device tick.
  static Future<Map<String, dynamic>> batteryHealth({
    int lookback = 2000,
  }) => _ldbBatteryHealth(lookback: lookback);

  /// Persist an undecodable historical record to the durable archive (kept,
  /// except the thinning in [thinRawArchiveBefore]). Used by the immediate
  /// fallback path; the drain path archives inside the same commit transaction
  /// as the batch (see [commitSyncBatch]).
  ///
  /// [deviceId] is written EXPLICITLY rather than left to the column default,
  /// which is the same rule [insertEvent] states: `raw_archive` is keyed
  /// `(device_id, hex)`, so a row that lands on the primary's key when it came
  /// off another device is a frame the primary can evict. It defaults because
  /// the only wiring today is `BleEngine`'s `ArchiveSink`, and that engine
  /// drives the primary band and nothing else (`_cursorDeviceId`); a secondary
  /// device's frames go through `BandHost` → [commitSyncBatch], which already
  /// names its device.
  static Future<void> archiveRawRecord(
    ArchiveRecord a, {
    String deviceId = kPrimaryDeviceId,
  }) async {
    final db = await instance;
    await db.insert(
      rawArchiveTable,
      rawArchiveRow(
        deviceId: deviceId,
        hex: a.hex,
        counter: a.counter,
        packetType: a.packetType,
        recTs: a.recTs,
        capturedAt: a.capturedAt,
        reason: a.reason,
      ),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// The `raw_archive.reason` values [redriveArchivedRecords] will retry.
  ///
  /// A reason names the RECORD VERSION a build could not decode, and only the
  /// per-second records map onto 1 Hz rows at all: gen5's v20/v21/v26 and
  /// gen4's v25 are deep buffers this build IDENTIFIES correctly and
  /// deliberately does not store as seconds (see `_ingestHistoricalFrame`), so
  /// retrying them re-reads half a gigabyte of hex to re-learn the same answer.
  /// MEASURED on the real MG export: `undecodable_rec_v20` alone is 115,672
  /// rows and 492 MB. A future format that becomes re-drivable gets a line
  /// here, by name.
  static const List<String> redrivableArchiveReasons = [
    // gen5's per-second summary. 1,035 of these sit in the MG export, archived
    // before this month's decoder fixes under a gravity window that was gen4's
    // — 0.5-1.8 g on a NORMALISED vector, applied to gen5's raw per-axis means.
    // All 1,035 decode today, gravity included.
    'undecodable_rec_v18',
    // The same records under a reason string an older build wrote and nothing
    // writes any more. Both labels are stale, which is the whole point.
    'partial_decode_v18_no_gravity',
    // gen4's R24, for symmetry — a record the R24 chain rejected once may
    // decode under a later firmware fallback. Zero rows carry it on any of the
    // three real exports; it costs nothing to include and is the case this
    // would otherwise have to be rewritten for.
    'undecodable_rec_v24',
    // gen4 1 Hz records from older firmware, archived by builds that predate
    // the v12 decode path. The current decoder reads them (the 88-byte form
    // through the short-frame fallback). Can be large, so the launch-path
    // ladder rung skips it; [redriveArchiveOnce] replays it from a derive.
    'undecodable_rec_v12',
  ];

  /// What the oldV<44 ladder rung replays inside `onUpgrade`: the small,
  /// bounded reasons only. v12 can be a million rows on one install, which
  /// does not belong on the launch path.
  static const List<String> _ladderRedriveReasons = [
    'undecodable_rec_v18',
    'partial_decode_v18_no_gravity',
    'undecodable_rec_v24',
  ];

  /// `compute_freshness` key: [startSec, endSec) windows of days the user
  /// deleted, which an archive re-drive must not refill.
  static const String kRedriveExcludedKey = 'redrive_excluded_windows';

  /// `[[start, end], ...]` JSON as windows; null when unreadable.
  static List<(int, int)>? _parseWindows(Object? json) {
    try {
      return [
        for (final w in jsonDecode(json as String) as List)
          (((w as List)[0] as num).toInt(), (w[1] as num).toInt()),
      ];
    } catch (_) {
      return null;
    }
  }

  /// [windows] sorted, with overlapping or touching ones merged.
  static List<(int, int)> _mergeWindows(List<(int, int)> windows) {
    final sorted = [...windows]..sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(int, int)>[];
    for (final w in sorted) {
      if (out.isNotEmpty && w.$1 <= out.last.$2) {
        if (w.$2 > out.last.$2) out[out.length - 1] = (out.last.$1, w.$2);
      } else {
        out.add(w);
      }
    }
    return out;
  }

  /// `compute_freshness` key for [redriveArchiveOnce].
  static const String kArchiveRedriveKey = 'archive_redrive_v12_v1';

  /// Marks a [_redrive] resume position that is a [rawArchiveTable] rowid.
  static const String _redriveRowidCursor = '\u0000rowid';

  /// One-shot replay of every [redrivableArchiveReasons] row, off the launch
  /// path (called from a heavy derive). Marked done only after it finishes,
  /// so an interrupted pass repeats; the replay skips seconds already decoded,
  /// so a repeat is safe.
  ///
  /// Bounded per call by [budget]: a million archived frames take minutes on a
  /// phone, and a derive holds its latch while this runs. An unfinished pass
  /// stores where it stopped and the next call resumes there.
  static Future<int> redriveArchiveOnce({
    Duration budget = const Duration(seconds: 20),
  }) => _ldbRedriveArchiveOnce(budget: budget);

  /// Drop an unfinished [redriveArchiveOnce]'s resume point before a VACUUM.
  /// That position is a [rawArchiveTable] rowid, and the table has no
  /// INTEGER PRIMARY KEY, so VACUUM is free to renumber it: resuming there
  /// could skip frames. The replay skips seconds already decoded, so starting
  /// over from the top only costs time.
  static Future<void> _resetRedriveResume() async {
    final row = await computeFreshness(kArchiveRedriveKey);
    if (row?['payload_json'] case final String j) {
      final v = jsonDecode(j);
      if (v is! Map || v['done'] == true || v['after_hex'] == null) return;
      await putComputeFreshness(
        kArchiveRedriveKey,
        jsonEncode({'recovered': v['recovered'] ?? 0}),
      );
    }
  }

  /// GATES 4b — replay the archive through the CURRENT decoders, into
  /// `decoded_onehz` / `decoded_rr`. Returns the seconds recovered.
  ///
  /// `raw_archive` holds frames a BUILD could not turn into a [Sample]. That is
  /// a statement about the build, not about the bytes — and nothing ever went
  /// back to re-read them, so the archive silently became a graveyard rather
  /// than the recovery store it was created to be. On the real MG export that
  /// is 1,035 seconds of gen5 history the app already owns, carrying HR, R-R,
  /// steps, sleep state and a skin temperature populated on 1,035 of 1,035.
  ///
  /// Run ONCE, from the migration ladder: off the ACK-critical sync path, and
  /// never on the launch path of a DB that has already had it.
  ///
  /// THREE THINGS IT DOES NOT DO:
  ///
  ///  * It does not touch a second `decoded_onehz` already holds.
  ///    [_queueDecodedOneHz] writes REPLACE (newest-wins, for a re-offload of a
  ///    live second) and a replay is the opposite case: a frame that FAILED to
  ///    decode must never evict one that succeeded. Collisions are skipped.
  ///  * It does not stamp `device_family`. A replay has no live link to ask,
  ///    and the record version does not answer it either — v18 exists on BOTH
  ///    generations (gen4 lists v7/v9/v18 as unconfirmed field maps). NULL is
  ///    the documented value for exactly this case, and the metrics that need
  ///    the family will correctly refuse rather than assume gen4.
  ///  * It does not delete, thin or relabel the archived row. The bytes stay
  ///    exactly where they are, under the reason they were captured with.
  static Future<int> redriveArchivedRecords(
    Database db, {
    List<String> reasons = redrivableArchiveReasons,
  }) async =>
      (await _redrive(db, reasons: reasons)).recovered;

  /// [redriveArchivedRecords] from a resume point, stopping after the first
  /// page that ends past [budget]. `resume` is null once the archive is done.
  static Future<({int recovered, (String, String)? resume})> _redrive(
    Database db, {
    required List<String> reasons,
    String startHex = '',
    String startDevice = '',
    Duration? budget,
    bool honourDeletions = false,
  }) => _ldbRedrive(db, reasons: reasons, startHex: startHex, startDevice: startDevice, budget: budget, honourDeletions: honourDeletions);

  /// One in this many `undecodable_rec_v20` frames is kept behind the retention
  /// edge. A STATED RATE, not a byte budget, so what survives is auditable: a
  /// future decode gets 1 record a minute of whatever the band was banking,
  /// which is a sample, not a recording.
  ///
  /// Sampled on `counter`, which resets to ~0 on a band reboot — that makes the
  /// sample slightly uneven across reboots and does not matter at all; what it
  /// buys is a rule you can re-run and get the same rows back.
  static const int rawArchiveKeepEvery = 60;

  /// The one `reason` this thinning applies to, and the reason it exists.
  ///
  /// MEASURED on the real MG export: `undecodable_rec_v20` is 115,672 rows of
  /// 4,256-char hex = 492 MB of the 538 MB `raw_archive` holds, banked in 11
  /// days. That is ~45 MB/day, ~16 GB/year, and `auto_backup.dart` gzips the
  /// whole database on a schedule. Nothing else in the table is close: v26 is
  /// 25,804 rows for 3.9 MB and gen4's v25 is 28,395 rows for 4.3 MB — both
  /// 152-char frames, and v25 is a channel we have since identified, so
  /// thinning either would cost real evidence and save nothing. One `reason`,
  /// one WHERE clause. A future format that turns out to be this big gets its
  /// own line here, by name — the diagnostics already break the table down by
  /// reason, so it shows up before it hurts.
  static const String _thinnedArchiveReason = 'undecodable_rec_v20';

  /// Thin the undecodable archive: drop all but 1-in-[rawArchiveKeepEvery]
  /// `undecodable_rec_v20` frames captured before [beforeMs]. Returns the rows
  /// deleted.
  ///
  /// Gated on `captured_at` and NOT `rec_ts`: `rec_ts` is NULL for every row in
  /// this table on all three real exports (142,511 of 142,511), which is not an
  /// accident — we archive a frame precisely BECAUSE we could not decode it, so
  /// we never learned its record time. When we received it is the only time we
  /// have.
  ///
  /// Called only from [pruneDecodedBeforeRecTs], so full-rate frames live
  /// exactly as long as the 1 Hz substrate they arrived with, and the sample
  /// lives forever.
  static Future<int> thinRawArchiveBefore(int beforeMs) async {
    final db = await instance;
    return db.transaction((txn) => _thinRawArchiveVia(txn, beforeMs));
  }

  static Future<int> _thinRawArchiveVia(
    DatabaseExecutor txn,
    int beforeMs,
  ) => _ldbThinRawArchiveVia(txn, beforeMs);

  /// How many undecodable records we've archived, and by reason — for the sync
  /// diagnostics ("clean sync" honesty: N records set aside, not lost).
  static Future<Map<String, dynamic>> rawArchiveStats() => _ldbRawArchiveStats();

  static Future<Map<String, dynamic>?> latestBandBatterySample() async {
    final db = await instance;
    final rows = await db.query('band_battery', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<Map<String, dynamic>> bandSignalsStats() => _ldbBandSignalsStats();

  /// The OLDEST [limit] queued events — an upload-queue drain head, and ONLY
  /// that. Never use it to answer "what happened on day X": once `events` holds
  /// more than [limit] rows the page can't reach recent days at all (the same
  /// oldest-N-vs-trailing-N shape as the `metricSeries(limit:)` outage). Use
  /// [eventsInRange] for a day/window query.
  static Future<List<Map<String, dynamic>>> unuploadedEvents({
    int limit = 500,
  }) async {
    final db = await instance;
    return db.query('events', orderBy: 'ts ASC', limit: limit);
  }

  /// Events whose `ts` (epoch SECONDS) is in the half-open window
  /// `[fromTs, toTs)`, oldest first. Bounded BY THE WINDOW, not by an unrelated
  /// global page, so a day's markers can never be crowded out by older rows.
  /// [limit] is a defensive cap on a pathological window only.
  static Future<List<Map<String, dynamic>>> eventsInRange(
    int fromTs,
    int toTs, {
    int limit = 5000,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await instance;
    return db.query(
      'events',
      where: 'ts >= ? AND ts < ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'ts ASC',
      limit: limit,
    );
  }

  /// Whether an ALARM_SET (event 56) row landed at or after [sinceMs]
  /// (`captured_at`, device receive time — the band's own `ts` can be
  /// RTC-skewed). The headless alarm-arm path (background_sync.dart) polls
  /// this for a short grace window to confirm a SET actually latched before
  /// the background connection closes, since there's no live AppState there
  /// to catch a late event 56 the way the foreground confirmation machine
  /// does.
  static Future<bool> alarmSetConfirmedSince(int sinceMs) async {
    final db = await instance;
    final rows = await db.query(
      'events',
      where: 'event_id = ? AND captured_at >= ?',
      whereArgs: [56, sinceMs],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> deleteEvents(List<String> hexes) async {
    if (hexes.isEmpty) return;
    final db = await instance;
    final placeholders = List.filled(hexes.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM events WHERE hex IN ($placeholders)',
      hexes,
    );
  }

  /// Store a raw record (+ optional decoded sample). Idempotent on frame hex.
  /// Raw is written FIRST (raw-first invariant). Returns true if newly inserted.
  /// LIVE packets pass sample=null — the backend field-decodes them from raw.
  /// Resolve the rec_ts (epoch sec) to store: reuse the already-decoded value from
  /// [raw] (ble_engine sets it from the record it parsed) to avoid a double-decode,
  /// else decode the hex here, else fall back to captured_at/1000.
  static int _recTsFor(RawRecord raw) {
    if (raw.recTs != null && raw.recTs! > 0) return raw.recTs!;
    return decodeRecTs(raw.hex, fallbackSec: raw.capturedAt ~/ 1000);
  }

  static Future<bool> insertRecord(RawRecord raw, Sample? sample) async {
    final db = await instance;
    var inserted = false;
    await db.transaction((txn) async {
      final batch = txn.batch();
      _queueDecodedOneHz(batch, raw, sample);
      await batch.commit(noResult: true);
      inserted = true;
    });
    return inserted;
  }

  /// Insert many records in ONE transaction. During a historical drain this is
  /// far faster than a transaction-per-record (one fsync instead of thousands).
  /// `samples` is now purely an ingest carrier for decoded fields; rows are
  /// persisted into decoded_onehz/decoded_rr, not into the legacy `samples`
  /// table. Raw-first is preserved — callers flush this before ACKing a sync batch.
  static Future<void> insertRecordsBatch(
    List<RawRecord> raws,
    List<Sample?> samples,
  ) async {
    if (raws.isEmpty) return;
    final db = await instance;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < raws.length; i++) {
        final raw = raws[i];
        final sample = samples[i];
        _queueDecodedOneHz(batch, raw, sample);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> putSyncLedger(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert(
      'sync_ledger',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> syncLedgerEntry([
    String chunkId = 'capture',
    DatabaseExecutor? txn,
  ]) async {
    final db = txn ?? await instance;
    final rows = await db.query(
      'sync_ledger',
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Merge a diagnostic/sync snapshot into the durable capture ledger row.
  /// `meta_json` is treated as a shallow object and patched, not replaced.
  static Future<void> upsertSyncLedgerEntry({
    String chunkId = 'capture',
    String kind = 'historical',
    required String status,
    int? ackedAt,
    String? lastError,
    Map<String, dynamic>? metaPatch,
    DatabaseExecutor? txn,
  }) => _ldbUpsertSyncLedgerEntry(chunkId: chunkId, kind: kind, status: status, ackedAt: ackedAt, lastError: lastError, metaPatch: metaPatch, txn: txn);

  /// Commit related diagnostic ledger rows together after the trim ACK.
  static Future<void> syncLedgerTransaction(
    Future<void> Function(Transaction txn) body,
  ) async {
    final db = await instance;
    await db.transaction(body);
  }

  static Future<List<Map<String, dynamic>>> syncLedger() async {
    final db = await instance;
    return db.query('sync_ledger', orderBy: 'created_at ASC');
  }

  static Future<void> quarantineSyncChunk({
    required String kind,
    required String payloadJson,
    required String reason,
  }) async {
    final db = await instance;
    await db.insert('sync_quarantine', {
      'kind': kind,
      'payload_json': payloadJson,
      'reason': reason,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Previously write-only: `quarantineSyncChunk` had no reader anywhere,
  /// so a persistently-stuck batch was recorded but never actually
  /// retrievable for diagnosis. Append-only audit trail (like `raw_archive`)
  /// — never pruned here, resolution is implicit once the same token finally
  /// ACKs (see the `batch:$tokenHex` sync_ledger row transitioning to
  /// `acked`), not a deletion of the quarantine record.
  static Future<List<Map<String, dynamic>>> quarantinedSyncChunks() async {
    final db = await instance;
    return db.query('sync_quarantine', orderBy: 'created_at DESC');
  }

  /// Columns [Sample.fromDecodedRow] reads. Deliberately NOT `*`: the accel /
  /// spo2 / raw-skin-temp columns are bulk and nothing on these two paths uses
  /// them (the derive path has its own wider query).
  static const List<String> _decodedSampleColumns = [
    'counter',
    'rec_ts',
    'hr',
    'step_count',
    'step_cadence',
    'activity_class',
    'skin_temp_c',
    'on_wrist',
    'hr_valid',
    'hr_alt',
  ];

  /// [kPrimaryBandSourceSql], and the `samples` fallback below is why: that
  /// table has no `source` column at all, so it can only ever hold the band's
  /// rows. Returning gated decoded rows from one branch and ungated legacy rows
  /// from the other under one [Sample] type would make the provenance of the
  /// result depend on which branch fired. (No production caller today — only
  /// tests reach this; gated with its sibling rather than left as the one
  /// decoded read whose answer changes when a strap is paired.)
  static Future<List<Sample>> samplesInRange(int fromTs, int toTs) => _ldbSamplesInRange(fromTs, toTs);

  /// [kPrimaryBandSourceSql], for the [samplesInRange] reason above AND for its
  /// own: its one caller keeps this as `lastSynced`, whose `tsEpoch` is the
  /// fallback frontier behind the `rec_ts_hw` cursor — i.e. "how fresh is the
  /// BAND". A peripheral sensor's second would make a band that has not synced
  /// in two days read as current.
  static Future<Sample?> latestSample() async {
    final db = await instance;
    final decodedRows = await db.query(
      'decoded_onehz',
      columns: _decodedSampleColumns,
      where: kPrimaryBandSourceSql,
      orderBy: 'rec_ts DESC, counter DESC',
      limit: 1,
    );
    if (decodedRows.isNotEmpty) {
      return Sample.fromDecodedRow(decodedRows.first);
    }
    final rows = await db.query('samples', orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : Sample.fromDbMap(rows.first);
  }

  static Future<Map<String, int>> counts() async {
    final db = await instance;
    final oneHz =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_onehz'),
        ) ??
        0;
    final rr =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM decoded_rr'),
        ) ??
        0;
    return {
      'raw': oneHz,
      'pending': 0,
      'decoded_onehz': oneHz,
      'decoded_rr': rr,
    };
  }

  /// `(firstRecTs, lastRecTs)` in unix seconds over canonical decoded 1 Hz rows,
  /// or `(null, null)` when nothing has been decoded yet.
  ///
  /// Its ONE production caller is [decodedRecTsMaxByDay], which uses it purely
  /// as the span to walk — so this is an ADMISSION read ([derivableSourceSql]),
  /// not a band-edge one. Band-only here would clip a verified second source's
  /// days out of derivation entirely, before any of them reached the day walk.
  /// (The old doc comment claimed the onboarding progress bar; that call site
  /// is gone.)
  static Future<(int?, int?)> firstAndLastRecordTs() async {
    final db = await instance;
    final rows = await db.rawQuery(
      // rec_ts > 0, matching rawStats()/lastDecodedRecTs() — a stray rec_ts=0
      // row (e.g. via _queueDecodedOneHz's `raw.recTs ?? decoded.tsEpoch`,
      // which only substitutes on null, not on an explicit 0) would otherwise
      // make MIN(rec_ts) return 0 and render "Data from Jan 1" (1970 epoch).
      'SELECT MIN(rec_ts) AS lo, MAX(rec_ts) AS hi FROM decoded_onehz '
      'WHERE rec_ts > 0 AND ${derivableSourceSql()}',
    );
    if (rows.isEmpty) return (null, null);
    final lo = (rows.first['lo'] as num?)?.toInt();
    final hi = (rows.first['hi'] as num?)?.toInt();
    return (lo, hi);
  }

  /// `{localDayLabel -> MAX(rec_ts)}` over canonical decoded 1 Hz rows, grouped
  /// by the LOCAL calendar day of the record's real time.
  ///
  /// One bounded `MAX(rec_ts)` per local day in the retained span, NOT one
  /// `GROUP BY strftime(…, 'localtime')` over the whole table. That grouping key
  /// is a function of the column, so SQLite could use no index for it: it was a
  /// full scan of every retained second plus a temp b-tree — 91 ms on a 3-day
  /// (259 k row) table on desktop, and the derive calls this up to three times
  /// a pass. `rec_ts` leads the `idx_decoded_onehz_rects (rec_ts, counter)`
  /// index, so a bounded `MAX(rec_ts) WHERE rec_ts >= a AND rec_ts < b` is a single index seek, and
  /// the span is bounded by `rawRetentionDays` in any healthy install.
  ///
  /// The day walk goes through [localDayEndSec] rather than `+ 86400` for the
  /// reason that helper documents: a local calendar day is 23 h on a
  /// spring-forward and 25 h on a fall-back, and the old `strftime('localtime')`
  /// grouping got that right, so the replacement has to as well.
  static Future<Map<String, int>> decodedRecTsMaxByDay() => _ldbDecodedRecTsMaxByDay();

  /// Decoded 1 Hz frames in record-time order. This is the preferred derive
  /// read path: smaller than raw hex, directly queryable, and already split into
  /// canonical columns.
  static Future<List<Map<String, dynamic>>> decodedOneHzBatchByRecTsRange({
    required int limit,
    required int fromRecTs,
    required int toRecTs,
    int? afterRecTs,
    int? afterCounter,
  }) => _ldbDecodedOneHzBatchByRecTsRange(limit: limit, fromRecTs: fromRecTs, toRecTs: toRecTs, afterRecTs: afterRecTs, afterCounter: afterCounter);

  /// Sparse RR beats for one contiguous decoded 1 Hz page, by its rec_ts window.
  ///
  /// [fromRecTs] / [toRecTs] are the page's first and last record seconds (the
  /// page is ordered `rec_ts ASC`, so first = min, last = max). A beat carries
  /// its decoded_onehz parent's rec_ts, so `[fromRecTs, toRecTs]` on
  /// decoded_rr's rec_ts index contains exactly the page's beats — bounded,
  /// indexed, and immune to the strap's reboot counter reset (the old counter-span read could degenerate to
  /// `counter >= high AND counter <= low` = zero rows, silently dropping a whole
  /// page's RR).
  static Future<List<Map<String, dynamic>>> decodedRrByRecTsRange({
    required int fromRecTs,
    required int toRecTs,
  }) => _ldbDecodedRrByRecTsRange(fromRecTs: fromRecTs, toRecTs: toRecTs);

  // ── M5: the resolver's two reads (device_coverage / signal_priority) ───────

  /// Devices that declare [signal], highest priority first. ALSO the
  /// candidate list: a device with no row here does not declare the signal,
  /// so it is not competing (candidacy before rank).
  ///
  /// The user's explicit order and the physics-seeded order live in the same
  /// table and differ only by `user_set`, so ORDER BY rank is the whole
  /// chain — the row IS the decision. Ties broken by device_id so the order
  /// is TOTAL (a re-derive must get the same answer every run, and that only
  /// holds if the sort keys reach a total order — see
  /// live_coverage_policy.dart's steps resolver for the same lesson).
  static Future<List<String>> signalPriority(InputSignal signal) async {
    final db = await instance;
    final rows = await db.query(
      'signal_priority',
      columns: ['device_id'],
      where: 'signal = ?',
      whereArgs: [signal.name],
      orderBy: 'rank ASC, device_id ASC',
    );
    return [for (final r in rows) r['device_id'] as String];
  }

  /// THE USER'S OWN ORDER for one signal. Rewrites the whole signal's rows in
  /// one transaction: a partial order is not an order, and two writers each
  /// setting one rank is how two devices end up rank 0.
  ///
  /// `user_set = 1` on every row this writes. That flag is the ONLY thing the
  /// one-tap reset reads (it deletes the signal's `user_set = 1` rows and lets
  /// the physics ladder answer again) and the only thing that distinguishes a
  /// preference from a seeded default (final-plan §4.5).
  ///
  /// [order] is highest priority FIRST. Ranks are written 0..n-1 densely, so
  /// the stored order is readable without a second sort.
  ///
  /// Takes an [InputSignal], not a `String`, for the same reason
  /// [signalPriority] does: the stored key is `signal.name`, and a caller
  /// reaching for `signal.toString()` would write `InputSignal.hr1Hz`, which
  /// never matches what the reader binds. The table is sparse by design, so
  /// that failure is invisible — the preference simply does nothing.
  static Future<void> setSignalPriority(
    InputSignal signal,
    List<String> order,
  ) async {
    final db = await instance;
    final name = signal.name;
    await db.transaction((txn) async {
      await txn.delete('signal_priority', where: 'signal = ?', whereArgs: [name]);
      for (var i = 0; i < order.length; i++) {
        await txn.insert('signal_priority', {
          'signal': name,
          'device_id': order[i],
          'rank': i,
          'user_set': 1,
        });
      }
    });
  }

  /// Back to physics for one signal. NOT a write of the computed order — that
  /// would freeze today's ladder into the table and stop tracking the adapter
  /// declarations it is derived from.
  static Future<void> clearSignalPriority(InputSignal signal) async {
    final db = await instance;
    await db.delete(
      'signal_priority',
      where: 'signal = ? AND user_set = 1',
      whereArgs: [signal.name],
    );
  }

  /// The signals whose order the USER set by hand, so the editor can offer a
  /// reset for exactly those. Beside the other `signal_priority` accessors so
  /// no screen has to open the raw handle and name the `user_set` column
  /// itself — a rename would otherwise break a UI file the migration author
  /// has no reason to open.
  static Future<Set<String>> userSetSignals() async {
    final db = await instance;
    final rows = await db.query(
      'signal_priority',
      columns: ['signal'],
      where: 'user_set = 1',
      distinct: true,
    );
    return {for (final r in rows) r['signal'] as String};
  }

  /// `{signal: [deviceId, …]}`, highest first, for every signal that has rows.
  /// Sparse: an absent signal falls through to `rankSources()` (§4.5's ladder).
  static Future<Map<String, List<String>>> signalPriorities() async {
    final db = await instance;
    final rows = await db.query('signal_priority', orderBy: 'signal ASC, rank ASC, device_id ASC');
    final out = <String, List<String>>{};
    for (final r in rows) {
      (out[r['signal'] as String] ??= []).add(r['device_id'] as String);
    }
    return out;
  }

  /// [signal]'s coverage intervals overlapping [from, to), every device.
  static Future<List<CoverageInterval>> coverageIntervals(
    InputSignal signal,
    int from,
    int to,
  ) => _ldbCoverageIntervals(signal, from, to);

  /// WHICH DEVICES WERE PHYSICALLY RECORDING each LOCAL day in a window, per
  /// signal — from `device_coverage`, which is written at ingest and never
  /// pruned, so this answers for days whose 1 Hz substrate went at
  /// `rawRetentionDays`.
  ///
  /// NOT the same question as `metric_series_version.coverage_devices`. That
  /// says which devices FED THE NUMBER; this says which were recording. They
  /// differ whenever a device was covered but lost arbitration, and the
  /// difference is exactly what separates "your ring reported nothing for
  /// eleven minutes" from "nothing was on your body" (final-plan §6.2).
  ///
  /// [signals] are `InputSignal.name` strings. An empty list returns an empty
  /// map rather than every signal — a caller that did not say what it needs is
  /// not asking for everything.
  static Future<Map<String, List<String>>> coverageDevicesByDay({
    required List<String> signals,
    required int fromSec,
    required int toSec,
    DatabaseExecutor? executor,
  }) => _ldbCoverageDevicesByDay(signals: signals, fromSec: fromSec, toSec: toSec, executor: executor);

  // ── VERSIONED DERIVED STORE I/O (day_result; main isolate only) ─────────────

  /// Upsert one (day_id, algo_version) result + its indexed scalars in one
  /// transaction. Immutable PER VERSION: a version bump writes a new row. The
  /// `finalized` flag locks a day from further recompute (~48 h after wake).
  static Future<void> putDayResult({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
    required String windowJson,
    bool finalized = false,
    bool skipped = false,
    // A day whose offloaded second-half compute (naps/workouts/HRR/wear/
    // curves/wake-features) failed or timed out AFTER the headline scalars
    // already succeeded — the row is real (not a skip marker) so headline
    // scalars still display, but it must never count as "derived" for the
    // raw-pruning guard (see dayResultIds). Callers should also avoid passing
    // `finalized: true` alongside `partial: true` unless there genuinely is
    // no raw substrate to ever retry from (e.g. the force-finalized import
    // path), since a finalized row is never revisited on a version bump.
    bool partial = false,
    double? rhr,
    double? rmssd,
    double? readiness,
    Map<String, double?> series = const {},
    // WHO produced these scalars — 'band' for a day this app derived from 1 Hz
    // records, a vendor tag for an importer. NULL is the default and means
    // UNKNOWN; it is never filled in with a guess, because the whole point of
    // the column is that a guessed provenance is worse than none. See
    // [_createMetricSeriesVersion].
    String? source,
    // Per series key: the method, method family and class behind the stored
    // value (`metric_method`). Null writes nothing.
    ({String method, String family, String cls}) Function(String key)?
        seriesMethod,
    // WHICH BAND'S UNITS these scalars are in — the substrate's own
    // `device_family` stamp, which is already null when the window spans two
    // straps or carries no stamp at all. Same rule as [source]: never guessed.
    // See [_createMetricSeriesVersion] and [foreignFamilyDates].
    String? deviceFamily,
    // M5: the day's contributor set (`daySub.deviceIds`, comma-joined,
    // sorted for determinism) — '' alone for every single-device install
    // today. Null, never guessed, same discipline as [deviceFamily].
    String? coverageDevices,
    // M5: the priority order in force when this day derived — the STRING a
    // change-point search can refuse across (`coverage_resolver.dart
    // .priorityKey`), not a hash. Column is named `priority_hash` (already
    // migrated in by M3); this stores the readable string under that name
    // rather than renaming a shipped column.
    String? priorityHash,
  }) => _ldbPutDayResult(dayId: dayId, algoVersion: algoVersion, payloadJson: payloadJson, windowJson: windowJson, finalized: finalized, skipped: skipped, partial: partial, rhr: rhr, rmssd: rmssd, readiness: readiness, series: series, source: source, seriesMethod: seriesMethod, deviceFamily: deviceFamily, coverageDevices: coverageDevices, priorityHash: priorityHash);

  /// The version a `day_result` read is allowed to serve at most: the algo
  /// version of the build doing the reading.
  ///
  /// `PRIMARY KEY (day_id, algo_version)` makes versions SIBLINGS, not
  /// replacements, so a day can hold several generations at once. Picking the
  /// highest one present is right on the way up and wrong on the way down: a
  /// user who rolls back a store build, or leaves TestFlight for release, has
  /// rows from a version this build no longer implements, and `MAX()` serves
  /// them forever. A re-derive does not repair it — it writes a row at the
  /// LOWER version that `MAX()` then ignores — so day-detail (reading the
  /// bundle) and trends (reading the unversioned, always-overwritten
  /// `metric_series`) disagree about the same day permanently. Worse, if the
  /// newer version reinterpreted a field under the same key, the older UI reads
  /// it as a real number.
  ///
  /// A ceiling, not an equality test: rows from OLDER versions are still
  /// served, which is the existing (correct) behaviour for a day whose raw has
  /// aged out and which therefore never gets a fresh-version row. The rows
  /// above the ceiling are not deleted either — re-upgrading brings them back.
  ///
  /// `local_repository_impl.crossDayStaleReason` applies the same discipline to
  /// the cross-day artifact, with a comment calling the ungated case "the bug".
  static const int _servedAlgoCeiling = kAlgoVersion;

  /// The served-version join, in SQL: bind a `day_result r` to its highest row
  /// at or below [_servedAlgoCeiling]. Every reader (and the coach views) uses
  /// THIS rather than writing its own `MAX(algo_version)` — the pattern had
  /// already reappeared at five readers and two views, and the ceiling has to
  /// be on all of them or it is on none of them.
  static const String _servedDayJoin = 'JOIN ($_servedVersions) m $_servedOn';
  static const String _servedVersions =
      'SELECT day_id, MAX(algo_version) AS v FROM day_result '
      'WHERE algo_version <= $_servedAlgoCeiling GROUP BY day_id';
  static const String _servedOn =
      'ON r.day_id = m.day_id AND r.algo_version = m.v';

  /// [_servedDayJoin] for the newest N days only (bind N). A LIMIT on the
  /// outer query comes after the join and its sort, so SQLite fetched and
  /// sorted EVERY day's row, bundle and all, to return N: a 30-day read went
  /// from ~60 ms to 250-600 ms between 30 and 730 days of history. Choosing
  /// the days first, from the covering index, leaves N rows to fetch.
  static const String _servedNewestDaysJoin =
      'JOIN ($_servedVersions ORDER BY day_id DESC LIMIT ?) m $_servedOn';

  /// The result row for one day_id at the highest version this build serves
  /// (see [_servedAlgoCeiling]), with a normalized `date` alias for callers.
  /// Null if absent.
  /// Minute means of `skin_temp_raw` and `ambient_raw` over the band's own
  /// rows in [fromSec, toSec), oldest first, minutes holding both only. Feeds
  /// the WHOOP 4 ambient check ([skinTempAmbientR]).
  static Future<List<(int, double, double)>> skinTempAmbientMinutes(
    int fromSec,
    int toSec,
  ) => _ldbSkinTempAmbientMinutes(fromSec, toSec);

  /// `compute_freshness` key holding the band firmware this install has seen.
  static const String kBandFirmwareKey = 'band_firmware';

  /// Record the firmware the band reported on this connection: the current
  /// version and when it was last seen, plus one entry per version change, so
  /// a firmware-specific problem in an exported database can be traced.
  /// Best-effort; never throws into the BLE path.
  static Future<void> noteBandFirmware(String fw, {int? nowSec}) =>
      _updateFreshnessJson(kBandFirmwareKey, (m) {
        final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final history = [
          for (final e in (m['history'] as List?) ?? const [])
            if (e is Map) e.cast<String, dynamic>(),
        ];
        if (history.isEmpty || history.last['fw'] != fw) {
          history.add({'fw': fw, 'first_seen': now});
        }
        // Bounded: firmware changes a handful of times a year.
        final kept = history.length > 20
            ? history.sublist(history.length - 20)
            : history;
        return {'fw': fw, 'last_seen': now, 'history': kept};
      });

  /// `compute_freshness` key marking the raw-free next-night nap cleanup
  /// (compute/nap_overlap_cleanup.dart) as applied. Cleared by an import.
  /// v2: the v1 pass skipped every day the readiness backfill had restamped
  /// at v112+, so installs that already ran it run it once more.
  static const String kNapNextNightCleanupKey = 'nap_next_night_cleanup_v2';

  /// `compute_freshness` key for [bumpUsageCounter]'s local counts.
  static const String kUsageCountersKey = 'usage_counters';

  /// Count one local event (`coach_open`, `health_upload_ok`, ...). Stays on
  /// the phone; it leaves only inside the database a user chose to contribute.
  /// Best-effort; never throws.
  static Future<void> bumpUsageCounter(String name) =>
      _updateFreshnessJson(kUsageCountersKey,
          (m) => {...m, name: ((m[name] as num?)?.toInt() ?? 0) + 1});

  /// Read-modify-write of one JSON `compute_freshness` row inside a single
  /// exclusive transaction, so two callers cannot overwrite each other.
  /// Best-effort; never throws.
  static Future<void> _updateFreshnessJson(
    String key,
    Map<String, dynamic> Function(Map<String, dynamic> current) update,
  ) => _ldbUpdateFreshnessJson(key, update);

  /// Replace one stored bundle's JSON in place, same version. For raw-free
  /// one-shot heals of fields that only live in the bundle.
  static Future<void> rewriteDayPayload(
    String dayId,
    int algoVersion,
    String payloadJson,
  ) async {
    final db = await instance;
    await db.update(
      'day_result',
      {'payload_json': payloadJson},
      where: 'day_id = ? AND algo_version = ?',
      whereArgs: [dayId, algoVersion],
    );
  }

  static Future<Map<String, dynamic>?> dayResult(String dayId, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    final rows = await db.query(
      'day_result',
      where: 'day_id = ? AND algo_version <= ?',
      whereArgs: [dayId, _servedAlgoCeiling],
      orderBy: 'algo_version DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _withDate(rows.first);
  }

  /// The two numbers a re-derive needs to keep a stored night on the clock it
  /// was lived on: the served row's sleep onset instant (ms) and the
  /// `sleep_onset_sec` clock it froze. Read with json_extract, so the bundle is
  /// never decoded on the calling isolate — a re-derive runs this for every
  /// day. Null when the day has no served row, the row is a skip marker, or
  /// the payload is malformed.
  static Future<({num? onsetMs, num? onsetClockSec})?> storedNightClock(
      String dayId) => _ldbStoredNightClock(dayId);

  /// The `readiness_absent_diag` diagnostic off [day]'s stored bundle — per
  /// input `{value, baseline_n}` plus the composite's own `note`. Produced on
  /// every day readiness comes back absent; null when [day] is null, has no
  /// stored bundle, or scored normally (no diag is written on a scored day).
  ///
  /// ONE reader, not two: this used to be a private copy inside
  /// `readiness_detail.dart` (the only place that read it); Home's "not
  /// scored" card needed the exact same lookup for the exact same reason, and
  /// a second copy is how the two screens' explanations drift apart.
  ///
  /// Best effort: a failed read is null, not a throw. It only explains an
  /// absence, so it must never take down the screen load that asked for it.
  static Future<Map<String, dynamic>?> readinessAbsentDiag(String? day) async {
    if (day == null) return null;
    try {
      final payload = (await dayResult(day))?['payload_json'];
      if (payload is! String || !payload.contains('"readiness_absent_diag"')) {
        return null;
      }
      final b = jsonDecode(payload);
      final diag = b is Map ? b['readiness_absent_diag'] : null;
      return diag is Map ? diag.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// The most recent day (highest day_id label), latest version, or null.
  static Future<Map<String, dynamic>?> latestDayResult() async {
    final rows = await recentDayResults(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// The N most recent days (newest day_id first), each at its LATEST version.
  static Future<List<Map<String, dynamic>>> recentDayResults(int limit, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    // For each day_id pick MAX(algo_version), then join back for the full row.
    final rows = await db.rawQuery(
      'SELECT r.* FROM day_result r '
      '$_servedNewestDaysJoin '
      'ORDER BY r.day_id DESC',
      [limit],
    );
    return [for (final r in rows) _withDate(r)];
  }

  /// The N most recent days at their served version — EVERY column except the
  /// two big JSON blobs. Newest day_id first.
  ///
  /// The payload-free half of [recentDayResults]. `SELECT r.*` drags
  /// `payload_json` (~88 KB a day) for every row, so a caller that only needs
  /// "which days, at what version, finalized or not" was moving tens of MB of
  /// Dart strings to read a few scalars — measured at ~35 MB for a 400-day
  /// health-export pass, before the caller then decoded and RETAINED a bundle
  /// per day (~298 MB RSS). Fetch the bundle for one day at a time with
  /// [dayResult] and let each one go.
  static Future<List<Map<String, dynamic>>> recentDayResultsMeta(
    int limit,
  ) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT r.day_id, r.algo_version, r.computed_at, r.finalized, '
      'r.skipped, r.partial, r.rhr, r.rmssd, r.readiness '
      'FROM day_result r '
      '$_servedNewestDaysJoin '
      'ORDER BY r.day_id DESC',
      [limit],
    );
    return [for (final r in rows) _withDate(r)];
  }

  /// The N most recent days at their served version, newest day_id first,
  /// each carrying `day_id`/`date` plus the numeric `scalars.<key>` value for
  /// every name in [keys] — extracted IN SQLite, so no payload crosses the
  /// platform channel and nothing is decoded on the calling isolate.
  ///
  /// For a caller that wants a handful of scalars across months of days.
  /// Doing it with [recentDayResults] moves ~88 KB of payload per day and then
  /// expands every compact curve back into per-sample maps on the UI isolate
  /// to read three numbers — the same work that, run over 90 bundles, was
  /// measured as a multi-second main-isolate hang.
  ///
  /// Every served day comes back. A day whose payload is malformed, lacks the
  /// key, or holds a non-number there gets null for that key — what decoding
  /// the bundle and reading `scalars[key] is num` gave.
  static Future<List<Map<String, dynamic>>> recentDayScalars(
    int limit,
    List<String> keys,
  ) => _ldbRecentDayScalars(limit, keys);

  /// `{day_id -> served algo_version}` for every day, payload-free.
  ///
  /// One query instead of a `dayResult()` per day: a caller walking history to
  /// ask "what version is this day at" was doing an N+1 that pulled a full
  /// bundle each time to read one integer.
  static Future<Map<String, int>> dayResultVersions() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT day_id, MAX(algo_version) AS v FROM day_result '
      'WHERE algo_version <= ? GROUP BY day_id',
      [_servedAlgoCeiling],
    );
    return {
      for (final r in rows)
        if (r['day_id'] is String && r['v'] is num)
          r['day_id'] as String: (r['v'] as num).toInt(),
    };
  }

  /// The stored sleep WINDOW for each of the [limit] most recent days, newest
  /// first, WITHOUT touching `payload_json`.
  ///
  /// `day_result.window_json` already holds the sleep window (a bare
  /// `SleepWindow.toJson()`, `{onset_ms, offset_ms, …}`) in its own column, so
  /// onset/offset are one small projected read — no bundle decode, no per-day
  /// round trip. Rows: `{day_id, window_json}`. [before] keeps only days
  /// strictly earlier than that day_id.
  static Future<List<Map<String, dynamic>>> sleepWindowRows(int limit,
      {String? before, DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    // Stream the served versions newest first from the covering day/version
    // index. CROSS JOIN keeps that stream outside the row lookup, so SQLite
    // can stop after N non-skipped days instead of fetching and sorting every
    // day's row (whose skipped column sits after the large payload).
    // The limit MUST follow skipped: a newer skip must neither consume a slot
    // nor fall back to an older non-skipped version of the same day.
    return db.rawQuery(
      'SELECT r.day_id AS day_id, r.window_json AS window_json '
      'FROM ($_servedVersions ORDER BY day_id DESC) m '
      'CROSS JOIN day_result r $_servedOn '
      'WHERE r.skipped = 0 '
      '${before == null ? '' : 'AND m.day_id < ? '}'
      'ORDER BY m.day_id DESC LIMIT ?',
      [?before, limit],
    );
  }

  /// One day's stored `window_json` (see [sleepWindowRows]), or null.
  static Future<String?> sleepWindowJsonFor(String dayId) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT r.window_json AS window_json '
      'FROM day_result r '
      '$_servedDayJoin '
      'WHERE r.skipped = 0 AND r.day_id = ? LIMIT 1',
      [dayId],
    );
    return rows.isEmpty ? null : rows.first['window_json'] as String?;
  }

  /// Every day_id that has a `day_result` row at its LATEST algo_version, newest
  /// first — WITHOUT touching `payload_json`.
  ///
  /// `recentDayResults()` does `SELECT r.*`, which drags the whole bundle
  /// (hr_curve / hypnogram / HRV series, tens of KB a day) across the isolate
  /// boundary. Screens that only need "which days exist" must use this instead:
  /// over a multi-year history the payload variant is hundreds of MB.
  static Future<List<String>> dayResultDayIdsDesc() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT day_id FROM day_result WHERE algo_version <= ? '
      'GROUP BY day_id ORDER BY day_id DESC',
      [_servedAlgoCeiling],
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    ];
  }

  /// Day labels whose LATEST-version bundle records a real sleep total
  /// (`sleep.accounting.value.tst_sec` present). Extracted IN SQLite via
  /// json_extract, so only the scalar crosses the boundary — never the payload.
  static Future<Set<String>> daysWithSleepTst() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      '$_servedDayJoin '
      // json_valid() first: json_extract() ERRORS on a malformed payload, and a
      // corrupt bundle must degrade to "no sleep that day", never take out the
      // whole Records screen.
      'WHERE json_valid(r.payload_json) '
      "AND json_extract(r.payload_json, '\$.sleep.accounting.value.tst_sec') "
      'IS NOT NULL',
    );
    return {
      for (final r in rows)
        if (r['day_id'] is String) r['day_id'] as String,
    };
  }

  /// Every day label ('YYYY-MM-DD') the lookback screen can actually RENDER —
  /// exactly the days [dayResult]/`_bundleForDate` would return a real bundle
  /// for, newest first. That is: the LATEST-`algo_version` `day_result` row per
  /// day that is NOT a derivation skip-marker. A day whose minute-detail was
  /// pruned still qualifies (its curves live in the persisted bundle payload,
  /// so it renders a summary); but a raw-only day (`decoded_onehz` with no
  /// derived row) and a skip-marker day both render EMPTY, so neither must
  /// bound navigation. Skips are excluded via the `skipped` column, which
  /// `_markDaySkipped` sets alongside the `{skipped:true}` payload.
  static Future<List<String>> availableDayIds({DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    // Latest version per day (matches [dayResult]), then drop skip-markers.
    final rows = await db.rawQuery(
      'SELECT r.day_id FROM day_result r '
      '$_servedDayJoin '
      'WHERE r.skipped = 0 '
      'ORDER BY r.day_id DESC',
    );
    return [
      for (final r in rows)
        if (r['day_id'] is String && (r['day_id'] as String).isNotEmpty)
          r['day_id'] as String,
    ];
  }

  /// The set of day_id labels that already have a REAL, COMPLETE result at
  /// [algoVersion]. Used by the raw-pruning guard to decide what's safe to
  /// prune - a day that only ever got a skip-marker (its derivation threw)
  /// or a partial row (headline scalars only; the offloaded second-half
  /// blocks failed/timed out) must NOT count as "derived" here, or its raw
  /// substrate gets pruned with no way left to ever fill in the missing
  /// data correctly.
  static Future<Set<String>> dayResultIds(int algoVersion) async {
    final db = await instance;
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: 'algo_version = ? AND skipped = 0 AND partial = 0',
      whereArgs: [algoVersion],
    );
    return {for (final r in rows) r['day_id'] as String};
  }

  /// Every stored input a derive of [dayId] reads, as one string, or null
  /// when the derive can depend on the wall clock (a session with no end,
  /// which activity review treats as running until now). The derivation
  /// engine hashes this with the profile, the algorithm version, the data
  /// edge and the baseline history, and skips a day whose hash has not moved
  /// since a derive that changed nothing it reads (see
  /// `DerivationEngine._dayInputFingerprint`).
  ///
  /// CONSERVATIVE BY CONSTRUCTION: windows are wider than any one the derive
  /// loads ([fromSec]..[toSec] is the night search through the nap buffer
  /// with a day of slack either side), whole small tables are read where the
  /// derive reads part of them, and the only columns left out are write
  /// stamps (`computed_at`, `updated_at`, `updated_ts`) and the device row's
  /// battery/last-seen readings, none of which a derive reads. Over-reading
  /// costs a derive that could have been skipped; under-reading would serve
  /// a stale day, so anything in doubt is in.
  static Future<String?> dayInputSignature({
    required String dayId,
    required String prevDayId,
    required String nextDayId,
    required int fromSec,
    required int toSec,
    required String? wearableDeviceId,
  }) => _ldbDayInputSignature(dayId: dayId, prevDayId: prevDayId, nextDayId: nextDayId, fromSec: fromSec, toSec: toSec, wearableDeviceId: wearableDeviceId);

  /// The input fingerprint the last derive of [dayId] stored, when that
  /// derive changed nothing it reads — see `DerivationEngine`'s skip.
  static Future<String?> deriveFingerprint(String dayId) async {
    final db = await instance;
    final r = await db.query(_deriveFingerprintTable,
        columns: ['fp'], where: 'day_id = ?', whereArgs: [dayId], limit: 1);
    return r.isEmpty ? null : r.first['fp'] as String?;
  }

  /// Store (or, with null, clear) [dayId]'s fingerprint. Rows two months
  /// older than [dayId] go with it: only days still re-deriving are ever
  /// looked up. Measured from the day, not the wall clock, so a backfill of
  /// old days does not delete its own rows.
  static Future<void> putDeriveFingerprint(String dayId, String? fp) async {
    final db = await instance;
    await db.transaction((txn) async {
      if (fp == null) {
        await txn.delete(_deriveFingerprintTable,
            where: 'day_id = ?', whereArgs: [dayId]);
        return;
      }
      await txn.insert(_deriveFingerprintTable, {'day_id': dayId, 'fp': fp},
          conflictAlgorithm: ConflictAlgorithm.replace);
      final t = DateTime.tryParse(dayId);
      if (t != null) {
        await txn.delete(_deriveFingerprintTable,
            where: 'day_id < ?',
            whereArgs: [dayLabelOf(DateTime(t.year, t.month - 2, t.day))]);
      }
    });
  }

  static const String _deriveFingerprintTable = 'derive_fingerprint';

  /// One row per day: the fingerprint above. Recomputable bookkeeping —
  /// losing it costs one derive per day — so additive on the open pass with
  /// no version bump, like the other repair-path tables.
  static Future<void> _createDeriveFingerprint(Database db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_deriveFingerprintTable '
      '(day_id TEXT PRIMARY KEY, fp TEXT NOT NULL)',
    );
  }

  /// The set of day_id labels that are FINALIZED at [algoVersion] (locked). A
  /// finalized day is never recomputed even on a version bump.
  ///
  /// An imported snapshot never locks: importers finalize a date the band has
  /// no rows for yet, and band rows for it arriving later must still derive
  /// and replace the snapshot ([isMeasuredDayRow]). Every caller intersects
  /// this with days that have raw, so a raw-less import is still left alone.
  ///
  /// Read off [_dayResultFinalizedIndex] once [_ensureDayResultImportedFlag]
  /// has filled `day_result.imported`. The LIKE it replaces read every
  /// finalized day's whole bundle — and `finalized` itself sits after
  /// `payload_json` in the row, so even the plain column test walked each
  /// bundle's overflow pages — several times per derive pass.
  static Future<Set<String>> finalizedDayIds(int algoVersion) async {
    final db = await instance;
    final indexed = await _ensureDayResultImportedFlag(db);
    final rows = await db.query(
      'day_result',
      columns: ['day_id'],
      where: indexed
          ? 'algo_version = ? AND finalized = 1 AND imported = 0'
          : 'algo_version = ? AND finalized = 1 '
              'AND payload_json NOT LIKE $_importedPayloadLike',
      whereArgs: [algoVersion],
    );
    return {for (final r in rows) r['day_id'] as String};
  }

  /// The one test for "this bundle is an imported snapshot". The `imported`
  /// column is computed from it by trigger, so the column and the old scan
  /// cannot disagree about a row.
  static const String _importedPayloadLike = "'%\"imported\":true%'";

  /// Covering index for [finalizedDayIds]. Created only once every existing
  /// row's `imported` is filled, so its presence is also the "backfill done"
  /// marker: a database restored from a file without it backfills again.
  static const String _dayResultFinalizedIndex = 'idx_day_result_finalized';

  /// `day_result.imported` and the triggers that keep it equal to
  /// [_importedPayloadLike] on every insert and payload update — whichever
  /// path writes the row (derive, import, restore merge, raw SQL). Cheap and
  /// idempotent: ADD COLUMN with a constant default rewrites nothing, so this
  /// is safe on the every-open repair path. The backfill of existing rows is
  /// NOT here; see [_ensureDayResultImportedFlag].
  static Future<void> _ensureDayResultImportedColumn(Database db) => _ldbEnsureDayResultImportedColumn(db);

  /// True once `day_result.imported` is trustworthy for every row and
  /// [_dayResultFinalizedIndex] exists. The first call on a database that
  /// predates the column fills it in pages of 200 rows, each its own short
  /// statement, then builds the index — off `openDatabase`, so a long history
  /// never runs it under the launch watchdog. Rows written meanwhile are
  /// already right (the triggers), and re-filling one recomputes the same
  /// value, so a concurrent derive cannot race it. Any failure leaves the
  /// index absent and the caller on the old scan; the next call resumes.
  static Future<bool> _ensureDayResultImportedFlag(Database db) => _ldbEnsureDayResultImportedFlag(db);

  /// Normalize a day_result row to also carry a `date` key (== day_id) so legacy
  /// readers that keyed on `date` keep working.
  static Map<String, dynamic> _withDate(Map<String, dynamic> row) {
    final m = Map<String, dynamic>.from(row);
    m['date'] = m['day_id'];
    return m;
  }

  /// Write a consistent, compacted snapshot of the DB to a temp file for export.
  /// Uses `VACUUM INTO` (NOT a raw file copy) so the snapshot is transactionally
  /// consistent — a plain copy of a live SQLite file can produce torn pages
  /// (a corrupt export). VACUUM INTO also defragments, so the file is small.
  /// SQLite older than 3.27 has no VACUUM INTO (Android 8-10: the framework
  /// ships 3.18/3.22 and sqflite uses it), so there the copy is built table by
  /// table through [attachCopy] instead, inside one read transaction.
  ///
  /// [includeSubstrateArchive] false empties `substrate_archive` in the COPY
  /// (never the live database). Automatic backups pass false: they keep five
  /// rotating copies, and the archive is already deflated, so gzip cannot
  /// shrink it — a year of history would cost its full size five times over.
  /// A manual export keeps it, which is the lossless copy the user asked for.
  ///
  /// [into] puts the copy somewhere other than the temp root; the manual
  /// export uses its own folder so it can prune its old copies without
  /// touching snapshots other features are still working on.
  static Future<String> exportCopy({
    bool includeSubstrateArchive = true,
    Directory? into,
  }) => _ldbExportCopy(includeSubstrateArchive: includeSubstrateArchive, into: into);

  /// Test seam: fail [exportCopy] after the copy exists, before it is cleaned.
  @visibleForTesting
  static bool debugFailExportStrip = false;

  /// Test seam: take the pre-3.27 [attachCopy] path even on a newer SQLite.
  @visibleForTesting
  static bool debugForceAttachExport = false;

  static bool? _vacuumInto;

  static Future<bool> _vacuumIntoSupported(Database db) async {
    final cached = _vacuumInto;
    if (cached != null) return cached;
    final v = await db.rawQuery('SELECT sqlite_version() AS v');
    return _vacuumInto = sqliteHasVacuumInto(v.first['v'] as String);
  }

  /// Whether SQLite [version] ("3.22.0") parses `VACUUM INTO` (3.27.0+).
  @visibleForTesting
  static bool sqliteHasVacuumInto(String version) {
    final parts = [
      for (final x in version.trim().split('.')) int.tryParse(x) ?? 0,
    ];
    final major = parts.isNotEmpty ? parts[0] : 0;
    final minor = parts.length > 1 ? parts[1] : 0;
    return major > 3 || (major == 3 && minor >= 27);
  }

  /// The database file plus its `-wal`: what the user's storage settings
  /// show it costing. After a VACUUM in WAL mode the WAL can be as big as the
  /// file until a checkpoint truncates it.
  static Future<int> databaseBytesOnDisk() async {
    final path = p.join(await getDatabasesPath(), dbName);
    var total = 0;
    for (final f in [File(path), File('$path-wal')]) {
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  /// Rewrite the file without its free pages, then hand the WAL's copy of
  /// that rewrite back to the filesystem. The caller gates it (free space,
  /// nothing else in flight); see [vacuumIfBloated] for why this is a one-off
  /// VACUUM and not `auto_vacuum`. The checkpoint is a `rawQuery`: the PRAGMA
  /// returns a row, which `execute` refuses on iOS's sqflite.
  ///
  /// True when the WAL was truncated too. A reader still holding a snapshot
  /// does not make the checkpoint throw: it returns busy = 1 in its first
  /// column and leaves the WAL as it was, so the row is read, and tried once
  /// more after a moment.
  static Future<bool> vacuumAndCheckpoint() async {
    final db = await instance;
    await _resetRedriveResume();
    await db.execute('VACUUM');
    // VACUUM renumbers every btree root page; see [vacuumIfBloated].
    await CoachDb.close();
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (checkpointCompleted(
          await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)'))) {
        return true;
      }
    }
    return false;
  }

  /// Whether a `PRAGMA wal_checkpoint` result row says it finished: its first
  /// column is 1 when the checkpoint was blocked.
  @visibleForTesting
  static bool checkpointCompleted(List<Map<String, Object?>> rows) =>
      rows.isEmpty || rows.first.values.first != 1;

  static Future<int> databaseFileBytes() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, dbName);
    final f = File(path);
    if (!await f.exists()) return 0;
    return await f.length();
  }

  static Future<List<Map<String, dynamic>>> dataHistoryDays() => _ldbDataHistoryDays();

  /// The half-open LOCAL window `[startSec, endSec)` covering day [dayId].
  ///
  /// `endSec` is the NEXT local midnight, NOT `startSec + 86400`: a local
  /// calendar day is 23 h on spring-forward and 25 h on fall-back. With the
  /// flat +86400 this returned a window that overran into the next day's first
  /// hour (deleteDays silently deleted the following day's first hour of
  /// decoded_onehz / sessions / band_* / events) or fell an hour short
  /// (fall-back left the last hour behind, and the export dropped it). Shared
  /// with the UI/coach via day_label.dart so every layer agrees.
  static (int, int) _localDayWindow(String dayId) {
    final lo = localDayStartSec(dayId);
    final hi = localDayEndSec(dayId);
    if (lo == null || hi == null) {
      throw ArgumentError.value(dayId, 'dayId', 'not a YYYY-MM-DD day label');
    }
    return (lo, hi);
  }

  static Future<String> exportDaysDb(Set<String> dayIds) => _ldbExportDaysDb(dayIds);

  /// Drops what a derive wrote for [dayIds] and nothing the user or a device
  /// wrote: for a day whose only source was just switched off, so a re-derive
  /// that finds nothing leaves nothing behind.
  static Future<void> clearDerivedDays(Set<String> dayIds) => _ldbClearDerivedDays(dayIds);

  static Future<int> deleteDays(Set<String> dayIds) => _ldbDeleteDays(dayIds);

  /// Empty EVERY table — the honest reading of "Delete everything".
  ///
  /// Enumerated from `sqlite_master`, never from a hand-written list. The
  /// hand-written list is exactly how the old reset missed about twenty tables
  /// (labs, nutrition, medication, breathing sessions, strength sets, the
  /// rolling baselines) while telling the user it had deleted them: a table
  /// added later has to be REMEMBERED here, and it never is. This way a new
  /// table cannot escape the wipe by being forgotten.
  ///
  /// `sync_cursor` IS cleared, deliberately. It is the band's "you already have
  /// everything up to here" mark, and the band trims its flash as we ACK — so
  /// the history is unrecoverable either way, cursor or no cursor. Keeping it
  /// would only leave a wiped phone silently draining nothing on the next sync,
  /// because every record the band still holds sits behind the frontier. A
  /// reset that leaves the cursor is not a reset.
  ///
  /// The SCHEMA is untouched: no DROP, no re-open, no re-migration (migrations
  /// run inside `openDatabase` on iOS's CPU watchdog — not somewhere to be on
  /// the tail of a destructive user action). Views are `type='view'` and are
  /// not matched; the sqlite/Android internal tables are skipped by name.
  ///
  /// Runs on the sync-commit gate, so it cannot interleave with a band batch
  /// that is mid-commit, and a batch queued behind it sees the reset and
  /// refuses (see [_commitSyncBatchLocked]).
  static Future<int> wipeAll() =>
      _withReaderInvalidated(() => _withCommitGate(_wipeAllLocked));

  static Future<int> _wipeAllLocked() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
    );
    var deleted = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        final t = r['name'];
        if (t is String) deleted += await txn.delete(t);
      }
    });
    return deleted;
  }

  /// Every table this database owns, for callers that need to reason about the
  /// whole store rather than one part of it (the reset test, [wipeAll]).
  static Future<List<String>> tableNames() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata' "
      'ORDER BY name',
    );
    return [for (final r in rows) r['name'] as String];
  }

  /// True when [dayId] holds a day this device DERIVED ITSELF from real 1 Hz —
  /// as opposed to absent, a skip marker, or an earlier import.
  ///
  /// THE guard every import must pass before writing a day. `putDayResult` is
  /// INSERT OR REPLACE and imports write `finalized: 1`, so overwriting a
  /// measured day both destroys it and locks the replacement in — the raw it
  /// came from is pruned within days, and `DerivationEngine` never revisits a
  /// finalized row. Irreversible, and there is no per-source undo.
  ///
  /// It lived as a private static inside `WhoopImporter`, which is why exactly
  /// one of the four import paths honoured it.
  static Future<bool> isMeasuredDay(String dayId) async =>
      isMeasuredDayRow(await dayResult(dayId));

  /// [isMeasuredDay] over an already-fetched row. Pure.
  static bool isMeasuredDayRow(Map<String, dynamic>? row) {
    if (row == null) return false;
    if (((row['skipped'] as num?) ?? 0).toInt() == 1) return false;
    try {
      final p = SeriesCodec.decodePayloadJson(
        (row['payload_json'] as String?) ?? '{}',
      );
      if (p != null) {
        if (p['skipped'] == true) return false;
        // A prior import (any importer) is replaceable — all of them are
        // snapshots, none of them is measured on-device data.
        if (p['imported'] == true) return false;
      }
    } catch (_) {
      // Present but unreadable — treat as real and refuse to clobber it.
      return true;
    }
    return true;
  }

  /// SQL selecting the `date` of every day whose scalars were IMPORTED.
  /// A fragment so the mask and the filters that apply it cannot drift apart.
  ///
  /// TWO SIGNALS, because the exact one is younger than the data:
  ///
  ///  * `metric_series_version.source` — precise, but the column only exists
  ///    from schema v43 and is deliberately NEVER retro-filled (a guessed
  ///    provenance is worse than none). Every day written before v43 reads
  ///    NULL, which is most of any real user's history.
  ///  * `day_result.payload_json`'s `"imported": true` — the marker BOTH
  ///    importers have written since they existed, and the same flag
  ///    [isMeasuredDayRow] tests on the write path.
  ///
  /// The second is what makes a NULL `source` DECIDABLE rather than ambiguous:
  /// NULL means "the column did not exist yet", not "unknown vendor", and the
  /// bundle behind that day still says who wrote it. So NULL is resolved
  /// against the payload rather than treated as suspect — dropping every
  /// NULL-source day would delete the user's genuine pre-v43 history from
  /// their own baselines, i.e. fabricate a baseline out of a short recent
  /// window, which is the worse fault of the two.
  ///
  /// A substring match, not `json_extract`: `jsonEncode` emits no spaces and
  /// this app is the only writer of the flag, so the literal is exact, and it
  /// does not assume a JSON1-enabled sqlite on every platform we ship to.
  ///
  /// The `IS NOT NULL` guards are not decoration. SQLite does not enforce NOT
  /// NULL on a declared PRIMARY KEY column of a legacy rowid table, and a
  /// single NULL inside a `NOT IN (…)` list makes the whole predicate NULL for
  /// EVERY row — one stray row would silently empty every baseline in the app
  /// rather than filter one day out of it.
  /// THE SERVED VERSION ONLY on the `day_result` half, for the same reason
  /// every other reader uses [_servedDayJoin]: `PRIMARY KEY (day_id,
  /// algo_version)` makes versions siblings, so an imported day that the band
  /// LATER re-derived keeps its old imported row sitting beside the new
  /// measured one. Testing every row made that day imported FOREVER — masked
  /// out of the baselines it is now entitled to be in, with no way back
  /// short of deleting the superseded row. `metric_series_version` needs no
  /// such guard: it is `PRIMARY KEY (date)` and the last writer replaces it,
  /// which is exactly why the stamp exists.
  static const String _importedDatesSql =
      'SELECT date FROM metric_series_version '
      "WHERE date IS NOT NULL AND source IS NOT NULL AND source <> 'band' "
      'UNION '
      'SELECT r.day_id FROM day_result r '
      '$_servedDayJoin '
      "WHERE r.day_id IS NOT NULL AND r.payload_json LIKE '%\"imported\":true%'";

  /// [_importedDatesSql] as a per-row test on the `metric_series` row being
  /// read: true when that row's day is NOT imported. Same two questions, same
  /// served-version rule, but asked only of the rows the query actually walks.
  /// `date NOT IN (_importedDatesSql)` built the whole imported set first, and
  /// that set is a LIKE over every stored day bundle — two baseline reads on
  /// Home went from ~2 ms at 30 days of history to ~42 ms each at 730. With
  /// the newest-first `(key, date)` index walk and a LIMIT, this touches only
  /// the days returned (plus any imported ones skipped on the way).
  @visibleForTesting
  static const String notImportedRowSql =
      'metric_series.date IS NOT NULL '
      'AND NOT EXISTS (SELECT 1 FROM metric_series_version v '
      'WHERE v.date = metric_series.date AND v.source IS NOT NULL '
      "AND v.source <> 'band') "
      'AND NOT EXISTS (SELECT 1 FROM day_result r '
      'WHERE r.day_id = metric_series.date '
      'AND r.algo_version = (SELECT MAX(x.algo_version) FROM day_result x '
      'WHERE x.day_id = metric_series.date '
      'AND x.algo_version <= $_servedAlgoCeiling) '
      "AND r.payload_json LIKE '%\"imported\":true%')";

  /// Day labels whose stored scalars are ANOTHER vendor's derived numbers.
  ///
  /// THE MASK for every baseline read, and the inverse of [isMeasuredDay]:
  /// that one guards the WRITE path (an import must not clobber a measured
  /// day), and nothing guarded the read path — so imported days were feeding
  /// the readiness and illness baselines the user's own scores are measured
  /// against. A window that mixes them is not a baseline of this person.
  ///
  /// Returned as a set rather than applied inside each query on purpose: the
  /// scan behind it is over `day_result.payload_json` (whole day bundles), so
  /// a caller reading several series takes it ONCE and filters in Dart.
  static Future<Set<String>> importedDates() async {
    final db = await instance;
    return {
      for (final r in await db.rawQuery(_importedDatesSql)) r['date'] as String,
    };
  }

  /// The `metric_series` keys whose stored VALUES ARE IN THE BAND'S OWN UNITS,
  /// so a day measured by a different band family is not on the same scale as
  /// today's and must not sit in the same baseline.
  ///
  /// DELIBERATELY SHORT, and it is a list of UNIT MISMATCHES, not of things
  /// that got noisier. `skin_temp_adc` is a gen4 thermistor ADC COUNT on one
  /// side of a strap swap and a gen5 CENTI-DEGREE reading on the other — the
  /// same key holding two different quantities, which is a wrong number, not a
  /// less precise one. `rhr` and `rmssd` off a different wrist sensor are the
  /// same quantity measured slightly differently: masking those would delete
  /// the user's history from their own baseline to fix a bias smaller than the
  /// window it is measured over. Nothing joins this set without a measured unit
  /// difference behind it.
  static const Set<String> familySeamKeys = {'skin_temp_adc'};

  /// Day labels whose scalars were measured by a DIFFERENT band family than the
  /// most recent stamped day — the mask for [familySeamKeys] baselines.
  ///
  /// Two properties that make this safe to apply unconditionally:
  ///  * A NULL stamp is never foreign. Unknown provenance is its own case (see
  ///    [_createMetricSeriesVersion]); every day written before the column
  ///    existed reads NULL, and dropping those would delete a real user's whole
  ///    history from their own baseline.
  ///  * A single-family user gets the EMPTY SET, because nothing differs from
  ///    the newest stamp. So this changes no number until a strap actually
  ///    changes generation.
  ///
  /// [ignore] are families that take no part in the seam, neither masked nor
  /// deciding the newest stamp: the wearables, whose baselines are split by
  /// their own family instead. Without it a ring's newest day would mask a
  /// band user's whole skin-temperature history.
  static Future<Set<String>> foreignFamilyDates({
    Iterable<String> ignore = const [],
  }) => _ldbForeignFamilyDates(ignore: ignore);

  /// Import another device's exported OpenStrap DB ([path], from [exportCopy] +
  /// share) by MERGING its rows into this one (INSERT-OR-REPLACE). Covers derived
  /// results, the metric series, user data, and the raw ledger so the receiving
  /// device has the full history (and can re-derive). Same app ⇒ same schema; a
  /// table missing in the source is skipped. Locally FINALIZED day_result rows
  /// are protected — an import never overwrites them. Returns per-table counts
  /// of rows actually copied.
  ///
  /// The picked file may be COMPRESSED. Auto-backups are written gzipped, so
  /// the file a user reinstalling onto a new phone reaches for is a `.db.gz`,
  /// and handing that straight to `openDatabase` fails with "file is not a
  /// database" — the app could write backups it could not restore. Detected by
  /// MAGIC BYTES, not by extension: a file manager or a sync client that
  /// renames on the way through is exactly the situation a restore has to
  /// survive. Plain `.db` files (older backups, and `exportCopy` output) take
  /// the same path they always did.
  static Future<Map<String, int>> importFromDbFile(String path) => _ldbImportFromDbFile(path);

  /// Merge every table [tables] names from the database file at [path] into
  /// this one.
  ///
  /// [only] overrides the table list and its ORDER — used by [_openOrRebuild],
  /// which wants the irreplaceable tables first. [tolerant] isolates each table
  /// behind its own catch: a rebuild salvaging a genuinely damaged file must
  /// lose that table and keep going, where a user-initiated restore of a file
  /// they chose must still fail loudly rather than report a partial success.
  /// Every table a backup restore (and the tolerant rebuild salvage)
  /// merges, in order: independent tables first; all use INSERT OR
  /// REPLACE so re-import is safe.
  static const List<String> _restoreTables = [
      // Hand-entered rows first. Nothing regenerates these, so if a merge is
      // ever cut short (an OOM, a damaged source) they are the ones already
      // banked. They were also simply MISSING here until now — nutrition,
      // medication, strength sets, symptoms and routes did not survive a
      // backup/restore round trip at all, the same omission `wipeAll` documents.
      'journal',
      'journal_metric',
      'journal_field_def',
      'lab_result',
      'lab_marker_def',
      'strength_set',
      'exercise_def',
      'food_entry',
      'food_def',
      'med_def',
      'med_dose',
      'cycle_log',
      'cycle_symptom',
      'breathing_session',
      // Vendor-computed, typed-in and imported scalars. In the hand-entered
      // block because a third of it IS hand-entered and nothing regenerates
      // any of it — a `reports` band trims its own history, and the app whose
      // export the imported rows came from may be uninstalled by now.
      'observation',
      'workout_route',
      'workout_split',
      // The user's sleep corrections. These are the ONLY copy of them — the
      // detector's output is deliberately not baked in, so a restore that
      // skipped these would silently reinstate every nap the user had deleted
      // and lose every one they logged.
      'sleep_override',
      'sleep_nap',
      // A ring's own hypnogram. Nothing here can re-derive it.
      'vendor_sleep_epoch',
      'workout_suggestions',
      // Keep the decision merge after both kinds of accepted activity.
      'sessions',
      'session_sensor',
      'activity_suggestions',
      'activity_review_meta',
      'activity_review_days',
      'samples',
      'events',
      'decoded_onehz',
      'decoded_rr',
      // The only copy of what a paired sensor measured during a session — the
      // band cannot re-deliver it, so a restore that skipped it loses it.
      'external_hr',
      // Re-readable from the health store, but only for as long as that app is
      // installed and that permission is granted — cheaper to carry.
      'imported_measurement',
      // Same reasoning, and more so: a route is thousands of points that the
      // source app may have deleted since. `workout_route` is already in this
      // list above and carries the imported routes too.
      'imported_workout',
      // The archive of frames we could not decode (kept, except the thinning
      // in [thinRawArchiveBefore]). exportCopy() is a whole-database
      // VACUUM INTO, so these rows DO leave the device —
      // leaving the table out here meant a backup/restore round trip silently
      // dropped them, in the one table whose entire purpose is that a frame is
      // never lost. Keyed by `hex`, so two same-counter frames from different
      // boots both survive the merge.
      'raw_archive',
      'band_events',
      'band_battery',
      'day_result',
      'metric_series',
      'metric_series_version',
      'metric_method',
      // Every day's step windows. Append-only with an AUTOINCREMENT id, so the
      // merge drops the id and skips windows already here (see below).
      'live_coverage',
      'notifications',
      'baselines',
      // Calibration observations cannot be rebuilt once raw is pruned.
      'step_calibration',
      'step_calibration_day',
      'live_step_calibration',
      'live_step_calibration_run',
      // The devices this phone knows about — so a SECONDARY device's identity
      // survives a backup/restore round trip rather than leaving its rows in
      // `decoded_onehz` pointing at a `device_id` nothing can name. The PRIMARY
      // row is deliberately skipped on the way in; see the guard below.
      'device',
      'device_coverage',
      'signal_priority',
      // WHOOP MG ECG: a user-initiated reading, its exact accepted packets
      // and the raw R16 records history recovered for it. None regenerates —
      // the band trimmed its copy on ACK. Parent before child so a restore
      // cut short never leaves packets without their reading.
      'ecg_reading',
      'ecg_reading_packet',
      'ecg_raw_packet',
      'sync_cursor',
      // The compressed copy of pruned decoded substrate. Merged, not
      // replaced: see [SubstrateArchive.restoreRows] — local wins, a restore
      // can only add seconds. Last: the biggest and slowest table, so a
      // restore cut short has already landed everything above it.
      'substrate_archive',
  ];

  /// Restore tables whose rows the user edits in place, keyed the way the
  /// app writes them, with the column that says when (null: none — the local
  /// row wins). `journal_metric` and `strength_set` are keyed by their SET
  /// (one day's fields, one session's sets), because the app rewrites each
  /// as a whole and a row-by-row merge splices two versions together.
  static const Map<String, (List<String>, String?)> _restoreEditedKeys = {
    'journal': (['date'], 'updated_at'),
    'journal_metric': (['date'], 'updated_at'),
    'lab_result': (['marker', 'taken_on'], 'updated_at'),
    'cycle_symptom': (['date'], 'updated_at'),
    'sleep_override': (['day_id'], 'created_at'),
    // A dose slot is re-marked in place (taken, skipped, cleared), so an older
    // backup would flip a dose logged since back to what it said then.
    'med_dose': (['med_key', 'date', 'slot_min'], 'updated_at'),
    // A retimed schedule moves its past doses to the new minute, so the
    // backup's old schedule would leave every dose logged since at a minute
    // no slot reads, and bring the old reminder back. No edit stamp: local wins.
    'med_def': (['key'], null),
    // Edited in place from the food log; `update` restamps `updated_at`.
    'food_entry': (['id'], 'updated_at'),
    // Refit from every admissible finalized day, so an older backup's profile
    // was fit from fewer days and would scale counter steps by a stale factor
    // until the next refit.
    'step_calibration': (['device_family', 'wearing'], 'updated_ts'),
    'cycle_log': (['date'], null),
    'sessions': (['id'], null),
    'strength_set': (['session_id'], null),
  };

  /// `raw_archive` out of a backup, whichever layout wrote it: the frame
  /// store of this build, the hex-keyed table of an older one, or both (a
  /// file saved mid-move). Every row is rebuilt through [rawArchiveRow], so a
  /// frame already here, or in the backup twice, lands once. Paged on rowid,
  /// like every other table the merge reads. Returns rows offered.
  static Future<int> _mergeRawArchive(Database src, Database db) => _ldbMergeRawArchive(src, db);

  @visibleForTesting
  static List<String> get restoreTablesForTest => _restoreTables;

  @visibleForTesting
  static List<String> get salvageTablesForTest => _salvageTables;

  /// Forces the existing per-row merge for the bulk-restore equivalence tests.
  @visibleForTesting
  static bool debugRowByRowMerge = false;

  @visibleForTesting
  static Future<Map<String, int>> debugMergeRowByRow(String path) async {
    final previous = debugRowByRowMerge;
    debugRowByRowMerge = true;
    try {
      return await _mergeFromDbFile(path);
    } finally {
      debugRowByRowMerge = previous;
    }
  }

  static Future<Map<String, int>> _mergeFromDbFile(
    String path, {
    List<String>? only,
    bool tolerant = false,
  }) => _withReaderInvalidated(() =>
      _mergeFromDbFileImpl(path, only: only, tolerant: tolerant));

  static Future<Map<String, int>> _mergeFromDbFileImpl(
    String path, {
    List<String>? only,
    bool tolerant = false,
  }) => _ldbMergeFromDbFileImpl(path, only: only, tolerant: tolerant);

  // ── diagnostics (read-only summaries for the Diagnostics screen) ────────────

  /// Raw store summary: total rows, rec_ts span (real record time, sec, >0 only),
  /// per-packet_type counts, and the captured_at span (ms) for comparison.
  static Future<Map<String, dynamic>> rawStats() => _ldbRawStats();

  static Future<List<Map<String, dynamic>>> tableStorageStats() => _ldbTableStorageStats();

  static Future<bool> _dbstatAvailable(Database db) async {
    try {
      await db.rawQuery(
        "SELECT SUM(pgsize) AS bytes FROM dbstat WHERE name = 'decoded_onehz'",
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> _tableBytesViaDbstat(Database db, String table) async {
    try {
      final row = (await db.rawQuery(
        'SELECT SUM(pgsize) AS bytes FROM dbstat WHERE name = ?',
        [table],
      )).first;
      return (row['bytes'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _tableBytesApprox(Database db, String table) async {
    try {
      final cols = await db.rawQuery('PRAGMA table_info($table)');
      if (cols.isEmpty) return 0;
      final expr = cols
          .map((c) {
            final name = c['name']?.toString() ?? '';
            return 'IFNULL(LENGTH($name), 0)';
          })
          .join(' + ');
      final row = (await db.rawQuery(
        'SELECT SUM($expr) AS bytes FROM $table',
      )).first;
      return (row['bytes'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> schemaHealth() => _ldbSchemaHealth();

  static Future<Map<String, dynamic>?> syncLedgerSummary([
    String chunkId = 'capture',
  ]) => _ldbSyncLedgerSummary(chunkId);

  /// Derived store summary: distinct days, how many are skipped markers (latest
  /// version), the latest day label, and the most recent (up to 14) day labels.
  static Future<Map<String, dynamic>> derivedStats() => _ldbDerivedStats();

  /// Recent latest-version day rows with lightweight status fields used by the
  /// metrics diagnostics view.
  static Future<List<Map<String, dynamic>>> recentDayDiagnostics(
    int limit,
  ) => _ldbRecentDayDiagnostics(limit);

  /// Count non-null series points for each requested metric key.
  static Future<Map<String, int>> metricSeriesCounts(List<String> keys) async {
    if (keys.isEmpty) return const {};
    final db = await instance;
    final out = <String, int>{};
    for (final key in keys) {
      out[key] =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM metric_series WHERE key = ? AND value IS NOT NULL'
              '${_validSql(key)}',
              [key],
            ),
          ) ??
          0;
    }
    return out;
  }

  /// Cross-day rollup presence + day count, read from the `crossday` baseline.
  static Future<Map<String, dynamic>?> crossDayStats() async {
    final r = await baseline('crossday');
    final json = r?['payload_json'];
    if (json is! String) return {'present': false};
    try {
      final p = jsonDecode(json);
      final nDays = p is Map ? p['n_days'] : null;
      return {'present': true, 'n_days': nDays};
    } catch (_) {
      return {'present': false};
    }
  }

  /// Single metric_series value for one (date, key), or null.
  static Future<double?> metricValueOn(String date, String key) async {
    final db = await instance;
    final rows = await db.query(
      'metric_series',
      where: 'date = ? AND key = ?',
      whereArgs: [date, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['value'] as num?)?.toDouble();
  }

  /// The FROZEN personal movement floor (g, dynAmp units) + when it was frozen.
  ///
  /// Persisted rather than recomputed because a floor that keeps tracking the
  /// user cancels the trend it exists to report — see the derivation-engine
  /// comment for the measured before/after. Returns null until enrollment
  /// completes, which is the estimator's signal to abstain.
  static Future<({double floorG, String frozenOn, int days})?>
  getMovementFloor() async {
    final row = await baseline('movement_floor');
    final raw = row?['payload_json'];
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      final f = (d['floor_g'] as num?)?.toDouble();
      final on = d['frozen_on'] as String?;
      if (f == null || !f.isFinite || f <= 0 || on == null) return null;
      return (floorG: f, frozenOn: on, days: (d['days'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  static Future<void> putMovementFloor({
    required double floorG,
    required String frozenOn,
    required int days,
  }) => putBaseline(
    'movement_floor',
    jsonEncode({'floor_g': floorG, 'frozen_on': frozenOn, 'days': days}),
  );

  /// Write ONE (date, key) scalar into the canonical series store.
  ///
  /// The bulk path is [putDayResult]'s `series` map, which writes a whole day's
  /// scalars alongside its bundle. This is for the case where a series row has
  /// to be corrected on its own — a day whose bundle is gone but whose trend
  /// point is still on screen (see `strain_backfill.dart`).
  static Future<void> putMetricSeriesValue(
    String date,
    String key,
    double? value,
  ) async {
    final db = await instance;
    await db.insert('metric_series', {
      'date': date,
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// A long-format metric series (oldest first) for trends/sparklines.
  ///
  /// [measuredOnly] drops days another vendor's export wrote (see
  /// [importedDates]). OFF by default: a trend line is a picture of the user's
  /// history and imported days belong in it. Turn it ON for anything that
  /// COMPUTES against the series — a baseline, a personal percentile, a
  /// seed-versus-band comparison — where a foreign algorithm's output is not
  /// the same measurement.
  static Future<List<Map<String, dynamic>>> metricSeries(
    String key, {
    int? limit,
    bool measuredOnly = false,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await instance;
    return db.query(
      'metric_series',
      where: 'key = ? AND value IS NOT NULL${_validSql(key)}'
          '${measuredOnly ? ' AND $notImportedRowSql' : ''}',
      whereArgs: [key],
      orderBy: 'date ASC',
      limit: limit,
    );
  }

  /// Drops stored `spo2` rows that are not a blood oxygen percentage: WHOOP export
  /// cells outside 70-100 banked before the importer dropped them, and the old
  /// cloud_v2 importer's relative index, written under the same key.
  static String _validSql(String key) => key != 'spo2'
      ? ''
      : ' AND value BETWEEN 70 AND 100 AND date NOT IN ('
          'SELECT r.day_id FROM day_result r $_servedDayJoin '
          "WHERE r.day_id IS NOT NULL AND r.payload_json LIKE '%\"source\":\"cloud_v2\"%')";

  /// The TRAILING [n] non-null values for [key] — the newest n days, returned
  /// oldest→newest. Unlike [metricSeries] (which is `date ASC LIMIT n`, i.e. the
  /// OLDEST n days), this is the right window for a rolling baseline. Because
  /// metric_series is keyed `(date, key)` with REPLACE, there is exactly one row
  /// per day, so the result is inherently de-duplicated.
  ///
  /// [measuredOnly] defaults ON here, unlike [metricSeries]: this helper exists
  /// to build a rolling baseline, and a baseline blended with another vendor's
  /// derived numbers is not a baseline of this person (see [importedDates]).
  ///
  /// [before] (a `yyyy-MM-dd` day label) limits the window to days strictly
  /// before it, so a past day is measured against its own trailing baseline
  /// rather than today's, and never against itself.
  static Future<List<double>> trailingSeriesValues(
    String key,
    int n, {
    bool measuredOnly = true,
    String? before,
  }) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT value FROM metric_series '
      'WHERE key = ? AND value IS NOT NULL '
      '${before != null ? 'AND date < ? ' : ''}'
      '${measuredOnly ? 'AND $notImportedRowSql ' : ''}'
      'ORDER BY date DESC LIMIT ?',
      [key, ?before, n],
    );
    return [for (final r in rows.reversed) (r['value'] as num).toDouble()];
  }

  static Future<Map<String, dynamic>?> baseline(String key, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    final rows = await db.query(
      'baselines',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> activityReviewRevision() async {
    final rows = await (await instance).query('activity_review_meta', columns: ['revision']);
    return rows.isEmpty ? 0 : rows.single['revision'] as int;
  }

  /// A calculation started before a review must never publish over it.
  static Future<bool> putReviewedBaseline(String key, String payloadJson, int expectedRevision) async {
    return (await instance).transaction((tx) async {
      final rows = await tx.query('activity_review_meta', columns: ['revision']);
      final revision = rows.isEmpty ? 0 : rows.single['revision'] as int;
      if (revision != expectedRevision) return false;
      await tx.insert('baselines', {'key': key, 'payload_json': payloadJson,
        'updated_at': DateTime.now().millisecondsSinceEpoch}, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  static Future<void> putBaseline(String key, String payloadJson) async {
    final db = await instance;
    await db.insert('baselines', {
      'key': key,
      'payload_json': payloadJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Atomically read-modify-write one `baselines` row.
  ///
  /// [transform] receives the current `payload_json` (null when the row does
  /// not exist) and returns the replacement, or null to leave the row alone.
  ///
  /// Needed because a Dart-level lock CANNOT serialize this. Derivation runs in
  /// more than one isolate — Android headless sync wakes construct their own
  /// `DerivationEngine` in a separate background isolate — and a `static`
  /// mutex has one copy per isolate. Two isolates would each read the same
  /// payload, merge into it, and write back, dropping the other's changes.
  /// That matters most for accumulator payloads like `sleep_user_profile`,
  /// where a lost write also loses the record of
  /// which days were already folded.
  ///
  /// `exclusive: true` issues BEGIN IMMEDIATE, taking SQLite's write lock up
  /// front rather than on first write. Without it a deferred transaction that
  /// reads and then writes can fail to upgrade under WAL when another
  /// connection holds the write lock. The lock is cross-connection and
  /// therefore cross-isolate, which is exactly the guarantee a Dart static
  /// cannot give.
  static Future<void> updateBaseline(
    String key,
    String? Function(String? current) transform,
  ) => _ldbUpdateBaseline(key, transform);

  static Future<Map<String, dynamic>?> computeFreshness(String key) async {
    final db = await instance;
    final rows = await db.query(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Every `compute_freshness` key starting with [prefix] — for per-day
  /// markers (`<prefix><YYYY-MM-DD>`), which are one row each so concurrent
  /// day derives never read-modify-write a shared list.
  static Future<Set<String>> computeFreshnessKeys(String prefix) async {
    final db = await instance;
    final rows = await db.query(
      'compute_freshness',
      columns: ['key'],
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [prefix.length, prefix],
    );
    return {for (final r in rows) r['key'] as String};
  }

  static Future<void> deleteComputeFreshness(String key) async {
    final db = await instance;
    await db.delete('compute_freshness', where: 'key = ?', whereArgs: [key]);
  }

  /// Bookkeeping key for the one-time walk in [reencodeLegacyDayResults].
  static const String kReencodeCursorKey = 'series_reencode';

  /// Test seam: awaited inside [reencodeLegacyDayResults] between the batch
  /// prepare and the write transaction. Null in production, and the only cost
  /// there is one null check per batch.
  ///
  /// It exists because the race the compare-and-set guards is a placement
  /// problem, not a timing one: a competing derive has to land in that exact
  /// window. Pinning it with a sleep meant the test asserted a real property
  /// only as long as the runner stayed inside the delay, which is the shape of
  /// a test that passes on a laptop and goes red on a loaded CI box.
  @visibleForTesting
  static Future<void> Function()? debugAfterReencodePrepare;

  /// Re-encode a BOUNDED batch of pre-codec `day_result` rows into the compact
  /// curve format, newest first. Returns how many rows were rewritten.
  ///
  /// WHY A BACKFILL AT ALL. `SeriesCodec` reads the legacy shape forever, so
  /// nothing breaks without this — but a user's existing history would stay at
  /// ~88 KB/day while only new days shrank, and `day_result` is precisely the
  /// store that grows without bound. This converts the back catalogue once.
  ///
  /// WHERE IT RUNS. Called from the derivation engine's post-derive
  /// housekeeping, beside `pruneSupersededIntermediates` — off the path to a
  /// durable commit, and NEVER inside a migration: `onUpgrade` runs inside
  /// `openDatabase` under iOS's CPU watchdog, where rewriting a year of bundles
  /// would be a launch hang (invariant 11).
  ///
  /// A FORWARD-ONLY CURSOR, not a rescan. Progress is stored in
  /// `compute_freshness`, so each call walks strictly older days than the last
  /// and the whole history costs one pass. Re-scanning from the newest day
  /// every time would re-read (and re-parse) every already-converted bundle
  /// forever — tens of MB of I/O per derivation.
  ///
  /// IMMUTABILITY. `day_result` rows are immutable PER VERSION, meaning their
  /// derived VALUES never change without a `kAlgoVersion` bump. This rewrite
  /// changes only how those same values are spelled, and every row is gated on
  /// [SeriesCodec.verifyLossless] before it is touched — a bundle whose
  /// round-trip is not provably exact is skipped and left legacy. Nothing but
  /// `payload_json` is written: `computed_at`, `finalized`, `partial` and the
  /// indexed scalars are untouched, so no day is re-finalized or re-dated.
  static Future<int> reencodeLegacyDayResults({int limit = 40}) => _ldbReencodeLegacyDayResults(limit: limit);

  static Future<void> putComputeFreshness(
    String key,
    String payloadJson, {
    DatabaseExecutor? txn,
  }) async {
    final db = txn ?? await instance;
    await db.insert('compute_freshness', {
      'key': key,
      'payload_json': payloadJson,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String localDayLabelNow() => todayLabel();

  /// `payload_json` of the exact row [recentDayResultsMeta] served for
  /// [dayId], or null.
  static Future<Object?> _servedPayloadJson(
    String dayId,
    Object? algoVersion,
  ) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT payload_json FROM day_result WHERE day_id = ? AND algo_version = ?',
      [dayId, algoVersion],
    );
    return rows.isEmpty ? null : rows.first['payload_json'];
  }

  /// The three [rawStats] fields freshness reads. [rawStats] also counts
  /// `samples` and takes MIN(rec_ts) for the diagnostics screen, which a
  /// derive pass has no use for.
  static Future<Map<String, dynamic>> _freshnessRawStats() => _ldbFreshnessRawStats();

  static Future<void> refreshComputeFreshness() => _ldbRefreshComputeFreshness();

  static Future<List<Map<String, dynamic>>> computeJobs({
    String? state,
    int limit = 50,
  }) async {
    final db = await instance;
    return db.query(
      'compute_jobs',
      where: state == null ? null : 'state = ?',
      whereArgs: state == null ? null : [state],
      orderBy: 'priority DESC, updated_at ASC',
      limit: limit,
    );
  }

  static Future<void> recoverComputeJobs() async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'compute_jobs',
      {'state': 'queued', 'updated_at': now},
      where: 'state = ?',
      whereArgs: ['running'],
    );
  }

  static Future<void> enqueueDeriveJob({
    required String type,
    required String reason,
  }) => _ldbEnqueueDeriveJob(type: type, reason: reason);

  static Future<Map<String, dynamic>?> takeNextComputeJob() => _ldbTakeNextComputeJob();

  /// Put a claimed job back on the queue without counting it as an attempt.
  ///
  /// Used when a gate closes DURING acquisition: `_drain()` clears the gate,
  /// awaits [takeNextComputeJob], and by the time that returns a workout may
  /// have started. The job is already marked `running`, so it has to be handed
  /// back explicitly or it sits claimed until the next [recoverComputeJobs].
  /// The attempt increment is undone too — being deferred is not a failure.
  static Future<void> requeueComputeJob(String id) async {
    final db = await instance;
    await db.rawUpdate(
      'UPDATE compute_jobs SET state = ?, '
      'attempts = MAX(attempts - 1, 0), updated_at = ? WHERE id = ?',
      ['queued', DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  static Future<void> completeComputeJob(String id) async {
    final db = await instance;
    await db.delete('compute_jobs', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> failComputeJob(String id, String error) async {
    final db = await instance;
    await db.update(
      'compute_jobs',
      {
        'state': 'failed',
        'reason': error,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<Map<String, dynamic>?> sleepSessionCandidate(
    String dayId,
    int algoVersion,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'sleep_session_candidates',
      where: 'day_id = ? AND algo_version = ?',
      whereArgs: [dayId, algoVersion],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putSleepSessionCandidate({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
  }) async {
    final db = await instance;
    await db.insert('sleep_session_candidates', {
      'day_id': dayId,
      'algo_version': algoVersion,
      'payload_json': payloadJson,
      'computed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> wakeDayFeatures(
    String dayId, [
    int? algoVersion,
  ]) async {
    final db = await instance;
    final rows = await db.query(
      'wake_day_features',
      where: algoVersion == null
          ? 'day_id = ?'
          : 'day_id = ? AND algo_version = ?',
      whereArgs: algoVersion == null ? [dayId] : [dayId, algoVersion],
      orderBy: algoVersion == null ? 'algo_version DESC' : null,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putWakeDayFeatures({
    required String dayId,
    required int algoVersion,
    required String payloadJson,
  }) async {
    final db = await instance;
    await db.insert('wake_day_features', {
      'day_id': dayId,
      'algo_version': algoVersion,
      'payload_json': payloadJson,
      'computed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── journal I/O ─────────────────────────────────────────────────────────────

  /// Upsert one day's journal (tags JSON + note). Idempotent on date.
  static Future<void> putJournal(
    String date,
    String tagsJson,
    String note,
  ) async {
    final db = await instance;
    await db.insert('journal', {
      'date': date,
      'tags_json': tagsJson,
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Recent journal rows, newest first. [sinceDaysEpoch] (a YYYY-MM-DD label) is
  /// an optional inclusive lower bound on `date`.
  static Future<List<Map<String, dynamic>>> journalRows({
    String? sinceDaysEpoch,
  }) async {
    final db = await instance;
    if (sinceDaysEpoch != null) {
      return db.query(
        'journal',
        where: 'date >= ?',
        whereArgs: [sinceDaysEpoch],
        orderBy: 'date DESC',
      );
    }
    return db.query('journal', orderBy: 'date DESC');
  }

  /// Replace one day's numeric journal fields.
  ///
  /// The map IS the day: a field that is absent from [fields] is DELETED for
  /// that date, not left behind. Clearing a value the user cleared matters
  /// more than it sounds — a stale "3 coffees" that survives an edit becomes a
  /// data point the user never entered, and correlations are exactly where
  /// that does damage.
  ///
  /// Written in one transaction so a day is never half-updated.
  static Future<void> putJournalMetrics(
    String date,
    Map<String, JournalMetricValue> fields,
  ) async {
    final db = await instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete('journal_metric', where: 'date = ?', whereArgs: [date]);
      for (final e in fields.entries) {
        await txn.insert('journal_metric', {
          'date': date,
          'field': e.key,
          'value': e.value.value,
          'at_min': e.value.atMinuteOfDay,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// One day's numeric fields, or an empty map when nothing was recorded.
  static Future<Map<String, JournalMetricValue>> journalMetricsForDay(
    String date,
  ) async {
    final db = await instance;
    final rows = await db.query(
      'journal_metric',
      where: 'date = ?',
      whereArgs: [date],
    );
    return {
      for (final r in rows)
        r['field'] as String: JournalMetricValue(
          (r['value'] as num).toDouble(),
          atMinuteOfDay: (r['at_min'] as num?)?.toInt(),
        ),
    };
  }

  /// Numeric journal fields per day, oldest first, for the correlation pass.
  /// [sinceDaysEpoch] is an optional inclusive lower bound on `date`.
  static Future<Map<String, Map<String, JournalMetricValue>>>
  journalMetricsByDay({String? sinceDaysEpoch}) => _ldbJournalMetricsByDay(sinceDaysEpoch: sinceDaysEpoch);

  /// Every field name that has ever been recorded, so a user-defined field
  /// keeps appearing in the editor after the day it was invented on.
  static Future<List<String>> journalMetricFields() async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT DISTINCT field FROM journal_metric ORDER BY field ASC',
    );
    return [for (final r in rows) r['field'] as String];
  }

  /// Custom field definitions, ordered by label.
  static Future<List<JournalFieldSpec>> journalFieldDefs() => _ldbJournalFieldDefs();

  /// Create-only. A conflicting key THROWS instead of replacing: REPLACE
  /// would silently rewrite another definition's metadata (label, unit, kind)
  /// while its recorded history stayed — a field that means something else
  /// wearing the old rows. The UI rejects duplicates before it gets here; the
  /// throw is the race/programmatic-caller backstop.
  static Future<void> putJournalFieldDef(JournalFieldSpec spec) => _ldbPutJournalFieldDef(spec);

  static Future<Map<String, int>> applyPendingActivityReviews() => _ldbApplyPendingActivityReviews();

  static Future<void> finishActivityReviews(Map<String, int> revisions) async {
    final db = await instance;
    await db.transaction((tx) async {
      for (final e in revisions.entries) {
        await tx.delete('activity_review_days', where: 'day_id = ? AND revision = ?', whereArgs: [e.key, e.value]);
      }
    });
  }

  // ── nap edits ─────────────────────────────────────────────────────────────

  /// Log a nap the detector missed, or suppress one it invented.
  static Future<void> putNapEdit({
    required String dayId,
    required int startTs,
    required int endTs,
    required String source,
  }) => _ldbPutNapEdit(dayId: dayId, startTs: startTs, endTs: endTs, source: source);

  static Future<void> deleteNapEdit(String dayId, int startTs) => _ldbDeleteNapEdit(dayId, startTs);

  /// Whether [startTs, endTs) overlaps a main sleep already derived — the
  /// check [putNapEdit] enforces for a logged nap, readable ahead of the write
  /// so the entry screen can say why in the user's language.
  static Future<bool> napOverlapsMainSleep(int startTs, int endTs) async =>
      ActivityStore.overlapsMainSleep(await instance, startTs, endTs);

  /// Drops [dayId]'s `legacy` nap edits overlapping [startSec, endSec). Logged,
  /// confirmed and rejected edits are left alone.
  static Future<int> deleteLegacyNapsOverlapping(
      String dayId, int startSec, int endSec) async {
    final db = await instance;
    return db.delete('sleep_nap',
        where: "day_id = ? AND source = 'legacy' AND start_ts < ? AND end_ts > ?",
        whereArgs: [dayId, endSec, startSec]);
  }

  static Future<List<Map<String, dynamic>>> napEdits(String dayId) async {
    final db = await instance;
    return db.query(
      'sleep_nap',
      where: 'day_id = ?',
      whereArgs: [dayId],
      orderBy: 'start_ts ASC',
    );
  }

  /// Every day carrying a nap edit. Force-derived alongside the sleep-override
  /// days for the same reason: an edit to a finalized day has to take effect.
  static Future<Set<String>> napEditDays() async {
    final db = await instance;
    final rows = await db.query('sleep_nap', columns: ['day_id']);
    return {for (final r in rows) r['day_id'] as String};
  }

  // ── breathing sessions ────────────────────────────────────────────────────

  static Future<void> putBreathingSession({
    required int startedAt,
    required int endedAt,
    required String pattern,
    required int seconds,
    double? coherence,
    double? confidence,
  }) async {
    final db = await instance;
    await db.insert('breathing_session', {
      'started_at': startedAt,
      'ended_at': endedAt,
      'pattern': pattern,
      'seconds': seconds,
      'coherence': coherence,
      'confidence': confidence,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// MIND-06 — attach the quiet-window RMSSDs to an already-banked session.
  ///
  /// A separate write because the two windows outlive the paced block by two
  /// minutes: the row is banked when the pacing stops, and the post window is
  /// still running then. An UPDATE rather than a second insert, so a session
  /// that was too short to bank at all stays unbanked (`changes` is 0 and
  /// nothing is created behind it).
  ///
  /// A window that produced no usable estimate writes NULL rather than being
  /// skipped — "we measured and could not read it" and "we never measured" are
  /// the same row here, and both are absent, which is what the paired test
  /// drops.
  static Future<void> updateBreathingWindows({
    required int startedAt,
    double? preRmssd,
    double? postRmssd,
  }) async {
    final db = await instance;
    await db.update(
      'breathing_session',
      {'pre_rmssd': preRmssd, 'post_rmssd': postRmssd},
      where: 'started_at = ?',
      whereArgs: [startedAt],
    );
  }

  /// Recent sessions, newest first.
  static Future<List<Map<String, dynamic>>> breathingSessions({
    int limit = 30,
  }) async {
    final db = await instance;
    return db.query(
      'breathing_session',
      orderBy: 'started_at DESC',
      limit: limit,
    );
  }

  // ── lab results ───────────────────────────────────────────────────────────

  /// Upsert one result. Idempotent on (marker, date drawn), so re-entering a
  /// value corrects it instead of stacking a near-duplicate.
  static Future<void> putLabResult({
    required String marker,
    required String takenOn,
    required double value,
    required String unit,
    String note = '',
  }) async {
    final db = await instance;
    await db.insert('lab_result', {
      'marker': marker,
      'taken_on': takenOn,
      'value': value,
      'unit': unit,
      'note': note,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteLabResult(String marker, String takenOn) async {
    final db = await instance;
    await db.delete(
      'lab_result',
      where: 'marker = ? AND taken_on = ?',
      whereArgs: [marker, takenOn],
    );
  }

  /// Every result, newest draw first. [marker] narrows to one series.
  static Future<List<Map<String, dynamic>>> labResults({String? marker}) async {
    final db = await instance;
    return db.query(
      'lab_result',
      where: marker == null ? null : 'marker = ?',
      whereArgs: marker == null ? null : [marker],
      orderBy: 'taken_on DESC',
    );
  }

  /// Custom marker definitions, by label.
  static Future<List<Map<String, dynamic>>> labMarkerDefs() async {
    final db = await instance;
    return db.query('lab_marker_def', orderBy: 'label ASC');
  }

  static Future<void> putLabMarkerDef(Map<String, dynamic> row) async {
    final db = await instance;
    await db.insert('lab_marker_def', {
      ...row,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Forget a custom field's DEFINITION. Its recorded values are deliberately
  /// left alone — they were real readings, and deleting a label should not
  /// delete history.
  static Future<void> deleteJournalFieldDef(String key) async {
    final db = await instance;
    await db.delete('journal_field_def', where: 'key = ?', whereArgs: [key]);
  }

  /// Forget a custom marker's DEFINITION. Its results are left alone — those
  /// were real draws, and each row already carries its own unit, so they stay
  /// readable without it.
  static Future<void> deleteLabMarkerDef(String key) async {
    final db = await instance;
    await db.delete('lab_marker_def', where: 'key = ?', whereArgs: [key]);
  }

  // ── cycle log I/O ─────────────────────────────────────────────────────────────

  static Future<void> putCycleLog(
    String date,
    String kind, {
    String? note,
  }) async {
    final db = await instance;
    await db.insert('cycle_log', {
      'date': date,
      'kind': kind,
      'note': note,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteCycleLog(String date) async {
    final db = await instance;
    await db.delete('cycle_log', where: 'date = ?', whereArgs: [date]);
  }

  /// All cycle markers, oldest first.
  static Future<List<Map<String, dynamic>>> cycleLogs() async {
    final db = await instance;
    return db.query('cycle_log', orderBy: 'date ASC');
  }

  // ── sessions (workouts) I/O ────────────────────────────────────────────────

  /// Upsert a workout session row (INSERT OR REPLACE — idempotent on id).
  static Future<void> putSession(Map<String, dynamic> row) async {
    final db = await instance;
    await db.transaction((tx) async {
      await tx.insert('sessions', row, conflictAlgorithm: ConflictAlgorithm.replace);
      final start = row['start_ts'] as int?;
      if (start != null) {
        await ActivityStore.supersede(tx, ActivityKind.workout, start,
          (row['end_ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
    });
  }

  /// Move a session's window. Not `putSession`: the row's type correction,
  /// RPE and private flag must survive. What was measured over the OLD window
  /// (the frozen HR trace, average HR, zone minutes) belongs to other seconds,
  /// so it goes; a re-score fills it again if the new window is still on
  /// record. Returns the number of rows changed.
  static Future<int> setSessionWindow(String id, int startTs, int? endTs) => _ldbSetSessionWindow(id, startTs, endTs);

  /// Update ONLY a session's derived score columns.
  ///
  /// Deliberately not `putSession`: that is INSERT-OR-REPLACE over the whole
  /// row, so a re-score computed from a snapshot would also rewrite columns it
  /// never read — `hrr_bpm` (backfilled by the derivation engine) and `type`
  /// (the athlete correcting a mislabelled workout) are both written by their
  /// own narrow UPDATEs and would be reverted. Returns the number of rows
  /// changed (0 when the session has since been deleted).
  static Future<int> setSessionScores(
    String id, {
    required double? strain,
    required double? calories,
    required int? maxHr,
    required String zoneMinJson,
    int? avgHr,
    String? traceJson,
    int? traceSamples,
  }) => _ldbSetSessionScores(id, strain: strain, calories: calories, maxHr: maxHr, zoneMinJson: zoneMinJson, avgHr: avgHr, traceJson: traceJson, traceSamples: traceSamples);

  /// Whether a [source] session already starts at [startTs], under any id.
  static Future<bool> hasSessionStartingAt(String source, int startTs) async {
    final db = await instance;
    final rows = await db.query('sessions',
        columns: ['id'],
        where: 'source = ? AND start_ts = ?',
        whereArgs: [source, startTs],
        limit: 1);
    return rows.isNotEmpty;
  }

  static Future<Map<String, dynamic>?> session(String id) async {
    final db = await instance;
    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The one session row (if any) still `status='live'` — i.e. its
  /// `stopWorkout`/finalize write never happened, most likely because the app
  /// was killed mid-workout. On a healthy run there is at most one (a second
  /// `startWorkout` can't begin while `activeWorkout` is already set), but a
  /// crash could in principle strand more than one across restarts, so this
  /// returns every match, newest first, rather than assuming exactly one.
  /// Used at startup to reconcile the orphaned-live-workout bug (issue: "can't
  /// stop workout, only delete" — activeWorkout was never rehydrated from this
  /// row, so the in-app stop control was unreachable after a restart).
  static Future<List<Map<String, dynamic>>> liveSessions() async {
    final db = await instance;
    return db.query(
      'sessions',
      where: "status = 'live'",
      orderBy: 'start_ts DESC',
    );
  }

  /// Sessions whose `start_ts` (epoch SECONDS) is in [fromTs, toTs], newest first.
  /// How many FINISHED sessions exist, ever. Counted in SQL: the Workouts tab
  /// awaits this while it opens, and it used to pull every session row an
  /// install had ever written (full payload, sorted) back across the platform
  /// channel to add up one integer.
  static Future<int> finishedSessionCount() async {
    final db = await instance;
    final r = await db.rawQuery(
      "SELECT COUNT(*) c FROM sessions WHERE status IS NOT 'live'",
    );
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  /// TS-03 — the highest heart rate the band has ever OBSERVED on this user,
  /// and the local day it was held on. Null when no day ever produced one.
  ///
  /// Every value in the `hr_ceiling_bpm` series already passed the hold +
  /// corroborating-motion guard in analytics' `observed_max_hr.dart`. THE MAX
  /// MUST ONLY EVER BE TAKEN OVER THAT SERIES: a max over `sessions.max_hr`
  /// would be one PPG artifact away from dragging every zone boundary in the
  /// app up forever, with nothing on screen to say why.
  ///
  /// All-time, not a trailing window. This is "highest we've seen"; a ceiling
  /// that silently aged out of a window would move every zone edge with no
  /// visible cause. The date rides along so an old one is attributable.
  static Future<({double bpm, String date})?> observedHrCeiling() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT date, value FROM metric_series "
      "WHERE key = 'hr_ceiling_bpm' AND value IS NOT NULL "
      'ORDER BY value DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final d = rows.first['date'], v = rows.first['value'];
    if (d is! String || v is! num) return null;
    return (bpm: v.toDouble(), date: d);
  }

  /// The `device_family` of the most recent session that carries one, or null.
  ///
  /// The zone ceiling is a per-family constant, so a screen that prints zone
  /// EDGES has to say which strap they belong to — and it has to be able to say
  /// it for a user who has not synced in a week (`decoded_onehz` is pruned at
  /// `rawRetentionDays`; `sessions` is not). NULL is unknown and stays unknown:
  /// a pre-schema-41 session, an import and a raw replay all carry none, and an
  /// uncalibrated strap is never gen4 with a different badge.
  static Future<String?> latestSessionDeviceFamily() async {
    final db = await instance;
    final rows = await db.rawQuery(
      "SELECT device_family FROM sessions "
      "WHERE device_family IS NOT NULL AND device_family <> '' "
      'ORDER BY start_ts DESC LIMIT 1',
    );
    return rows.isEmpty ? null : rows.first['device_family'] as String?;
  }

  static Future<List<Map<String, dynamic>>> sessionsInRange(
    int fromTs,
    int toTs, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await instance;
    return withoutFlagOffScores(await db.query(
      'sessions',
      where: 'start_ts >= ? AND start_ts <= ?',
      whereArgs: [fromTs, toTs],
      orderBy: 'start_ts DESC',
    ), executor: db);
  }

  /// What a session's sensor scored: served empty, not stored empty.
  static const List<String> _sensorScoreColumns = [
    'calories',
    'strain',
    'max_hr',
    'avg_hr',
    'vo2max_estimate',
    'zone_min_json',
    'hrr_bpm',
    'trace_json',
    'trace_samples',
  ];

  /// [rows] with the scored columns ([_sensorScoreColumns]) empty on each
  /// finished session whose window's worn seconds all came from a device
  /// whose flag is now off: not the band, no flagged-on workout sensor
  /// ([sessionSensorSources]), not the active wearable (rule R6). The stored
  /// row is untouched, so turning the flag back on serves it again. A window
  /// with no worn rows left (pruned, or hand-entered) keeps its score.
  ///
  /// ponytail: one window scan per session; batch it into one join if a long
  /// session list gets slow.
  static Future<List<Map<String, dynamic>>> withoutFlagOffScores(
      List<Map<String, dynamic>> rows, {DatabaseExecutor? executor}) async {
    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      out.add(await _flagOffOnly(r, executor: executor)
          ? {...r, for (final c in _sensorScoreColumns) c: null}
          : r);
    }
    return out;
  }

  /// Whether finished session [r]'s window has worn seconds and every one of
  /// them came from a device whose flag is now off (see
  /// [withoutFlagOffScores]).
  static Future<bool> _flagOffOnly(Map<String, dynamic> r,
      {DatabaseExecutor? executor}) => _ldbFlagOffOnly(r, executor: executor);

  /// Rewrites `session_score_mask` to the finished sessions
  /// [withoutFlagOffScores] would serve empty, so `v_sessions` (the coach's
  /// SQL and the CSV export) blanks the same scores. Run before reading it:
  /// the mask follows the flags and the substrate, neither of which a view
  /// can see.
  ///
  /// ponytail: rescans every finished session per call; keep it incremental
  /// if a long history makes coach queries slow.
  static Future<void> refreshSessionScoreMask() async {
    final db = await instance;
    final ids = [
      for (final r in await db.query('sessions',
          columns: ['id', 'start_ts', 'end_ts', 'status'],
          where: "status = 'done'"))
        if (await _flagOffOnly(r)) r['id'],
    ];
    await db.transaction((txn) async {
      await txn.delete('session_score_mask');
      for (final id in ids) {
        await txn.insert('session_score_mask', {'session_id': id});
      }
    });
  }

  /// Every workout sensor stamped on session [id] ([stampSessionSensor]).
  static Future<Set<String>> sessionSensorsOf(Object? id,
      {DatabaseExecutor? executor}) async => {
        for (final r in await (executor ?? await instance).query('session_sensor',
            columns: ['source'], where: 'session_id = ?', whereArgs: [id]))
          r['source'] as String,
      };

  /// Records that workout sensor [source] (an adapter id) scored session
  /// [id], so [withoutFlagOffScores] serves the score empty while that
  /// sensor's flag is off, after its raw rows are gone too. One row per
  /// sensor: a later one adds to the stamp, it does not replace it.
  static Future<void> stampSessionSensor(String id, String source) async {
    final db = await instance;
    await db.insert('session_sensor', {'session_id': id, 'source': source},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> deleteSession(String id) async {
    final db = await instance;
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
    await db.delete('session_sensor',
        where: 'session_id = ?', whereArgs: [id]);
    // Cascade: a route belongs to its session (on-device only, no FK enforced).
    await db.delete('workout_route', where: 'session_id = ?', whereArgs: [id]);
    // …and its frozen per-km splits (CV-01), same reason.
    await db.delete('workout_split', where: 'session_id = ?', whereArgs: [id]);
    // …and so do its typed sets. These used to survive the delete, so a
    // mistyped 200 kg set on a deleted workout kept coming back as "previous"
    // and "best" on the strength screen (recentSetsFor reads strength_set with
    // no session-existence filter) and kept exporting under a dead session_id.
    await db.delete('strength_set', where: 'session_id = ?', whereArgs: [id]);
  }

  // ── workout GPS routes (run/ride/walk) I/O ─────────────────────────────────
  // Recorded on-device only; never uploaded. Ordered by seq within a session.

  static Future<void> _createWorkoutRoute(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_route (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        ts_ms INTEGER NOT NULL,
        lat REAL NOT NULL,
        lng REAL NOT NULL,
        alt REAL,
        accuracy REAL,
        PRIMARY KEY (session_id, seq)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_workout_route_session '
      'ON workout_route(session_id, seq)',
    );
  }

  /// workout_split — per-KILOMETRE splits, frozen at finalize (CV-01 / TS-07).
  ///
  /// WHY A TABLE AND NOT A QUERY. A split's `avg_hr` is computed on demand by
  /// joining the route against `decoded_onehz`, which is gone at
  /// `rawRetentionDays`. So there is NO retroactive index here and never can
  /// be: this write is the whole gate, it is FORWARD-ONLY, and it produces its
  /// first honest chart 8-12 weeks after it ships. Nothing reads this table
  /// yet.
  ///
  /// `net_elev_m` is the elevation change over the WHOLE kilometre, not a
  /// per-point sum. GPS altitude error is tens of metres pointwise and there is
  /// no barometer in this stack, so a 1 m-deadband ascent total would be mostly
  /// noise; the net over a km is the only elevation figure the fix supports.
  /// NULL when any point in the split carried no altitude — never 0, which
  /// would read as "flat".
  ///
  /// Kilometres only. The UI also renders miles, but that is a display unit for
  /// the same route; a second stored copy of the same run in different bins is
  /// not a second measurement.
  static Future<void> _createWorkoutSplit(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS workout_split (
        session_id TEXT NOT NULL,
        km INTEGER NOT NULL,
        meters REAL NOT NULL,
        duration_sec INTEGER NOT NULL,
        avg_hr REAL,
        net_elev_m REAL,
        PRIMARY KEY (session_id, km)
      )
    ''');
  }

  /// Replace the stored splits for one session (empty list clears them).
  /// INSERT OR REPLACE on (session_id, km), so a later pass over a fuller
  /// window overwrites rather than duplicating.
  static Future<void> putWorkoutSplits(
    String sessionId,
    List<Map<String, Object?>> rows,
  ) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete(
        'workout_split',
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      for (final r in rows) {
        await txn.insert('workout_split', {
          'session_id': sessionId,
          ...r,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// The stored splits for one session, in order. Empty when the session
  /// predates this table or had no route — never inferred.
  static Future<List<Map<String, dynamic>>> workoutSplits(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'workout_split',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'km ASC',
    );
  }

  /// Additive: add the `speed` column (smoothed instantaneous m/s) to an
  /// existing workout_route table. Guarded — fresh installs get it from
  /// _createWorkoutRoute directly once that's updated; ALTER … ADD COLUMN
  /// throws if it's already there.
  static Future<void> _ensureWorkoutRouteSpeed(Database db) =>
      _addColumnIfMissing(db, 'workout_route', 'speed', 'REAL');

  /// Append a batch of route rows (INSERT OR REPLACE — idempotent on
  /// (session_id, seq)). Each row is a [RoutePoint.toRow] map.
  static Future<void> appendRoutePoints(
    String sessionId,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final db = await instance;
    final batch = db.batch();
    for (final r in rows) {
      batch.insert(
        'workout_route',
        r,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// All route rows for a session, ordered by seq.
  static Future<List<Map<String, dynamic>>> routePoints(
    String sessionId,
  ) async {
    final db = await instance;
    return db.query(
      'workout_route',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
    );
  }

  /// True when a session has any recorded route points (cheap existence check).
  static Future<bool> sessionHasRoute(String sessionId) async {
    final db = await instance;
    final rows = await db.rawQuery(
      'SELECT 1 FROM workout_route WHERE session_id = ? LIMIT 1',
      [sessionId],
    );
    return rows.isNotEmpty;
  }

  /// 1 Hz heart-rate samples in [fromTs, toTs] (epoch SECONDS), ascending, used
  /// to colour a route and average HR per split. Only worn seconds (hr > 0).
  ///
  /// Admitted rows only ([derivableSourceSql]), for the same reason
  /// [sessionHrStats] states below: an unverified adapter writes its own
  /// seconds into this table with `source` set, and averaging the two together
  /// reports a session HR that is neither sensor's. Today nothing writes a
  /// non-null source, so this filter is a no-op — it is here so the six call
  /// sites are already correct on the day one does.
  static Future<List<Map<String, dynamic>>> hrSamplesInRange(
    int fromTs,
    int toTs,
  ) => _ldbHrSamplesInRange(fromTs, toTs);

  /// Every session in [fromTs, toTs] (epoch SECONDS) with the worn rows of
  /// its window a session read keeps ([sessionWindowRows]), ascending. Only
  /// with a workout sensor flagged on; a session with none is absent, as from
  /// the band-only joins.
  static Future<Map<String, List<Map<String, Object?>>>> _sessionWindows(
    int fromTs,
    int toTs,
  ) => _ldbSessionWindows(fromTs, toTs);

  /// Per-session HR aggregates over the 1 Hz substrate for every session in
  /// [fromTs, toTs] (epoch SECONDS): {session_id: {n, avg_hr, min_hr, max_hr}}.
  /// One indexed range join — powers the workout list's avg-bpm / no-data
  /// heuristic without a query per row. Sessions whose window has been pruned
  /// (14-day raw retention) simply don't appear.
  /// [maxHrCeiling] / [minHrFloor] physiologically bound the SQL MAX/MIN(d.hr):
  /// a coarse guard so a gross artefact can't define a session that has no
  /// on-read smoothed extreme (imported/legacy rows). Spike-suppressed
  /// max/min come from [sessionHrSamplesBySession] + the shared smoother; these
  /// aggregates are a last fallback only. 0/unset disables each bound.
  static Future<Map<String, Map<String, num>>> sessionHrStats(
    int fromTs,
    int toTs, {
    int maxHrCeiling = 0,
    int minHrFloor = 0,
  }) => _ldbSessionHrStats(fromTs, toTs, maxHrCeiling: maxHrCeiling, minHrFloor: minHrFloor);

  /// Worn 1 Hz HR samples for every session in [fromTs, toTs] (epoch SECONDS),
  /// grouped {session_id: [hr, …]} in ascending time — one indexed range join.
  /// Feeds the workout list's spike-suppressed max (the shared smoother runs in
  /// the repo, not here). Sessions whose window has been pruned (14-day raw
  /// retention) simply don't appear, and the caller falls back to the stored
  /// column.
  static Future<Map<String, List<int>>> sessionHrSamplesBySession(
    int fromTs,
    int toTs,
  ) => _ldbSessionHrSamplesBySession(fromTs, toTs);

  /// Backfill a session's heart-rate-recovery (bpm), computed retrospectively
  /// from the 1 Hz substrate around the session's end during derivation.
  static Future<void> setSessionHrr(String id, double hrrBpm) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'hrr_bpm': hrrBpm},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Backfill a session's submax VO2max estimate, computed once from a
  /// completed route km split (see `_submaxVo2maxFromSplits`). Never called
  /// with null — a session that didn't qualify simply never writes here and
  /// stays NULL, the honest "no estimate" state.
  static Future<void> setSessionVo2max(String id, double vo2max) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'vo2max_estimate': vo2max},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> setSessionType(String id, String type) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'type': type},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Mark a session private (or not). Its own narrow UPDATE for the same reason
  /// [setSessionType] is one: `putSession` is INSERT-OR-REPLACE over the whole
  /// row, so a re-score would revert a flag it never read.
  static Future<void> setSessionPrivate(String id, bool private) async {
    final db = await instance;
    await db.update(
      'sessions',
      {'private': private ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Set (or clear, with null) a session's self-reported RPE. Its own narrow
  /// UPDATE for the same reason [setSessionType] is one, and because the user's
  /// own word must survive every re-score.
  ///
  /// The caller must pass what the user actually chose. There is no default and
  /// no pre-selection: an unrated session stays NULL forever, which is the
  /// honest reading of "they skipped it".
  static Future<void> setSessionRpe(String id, double? rpe) async {
    final db = await instance;
    await db.update('sessions', {'rpe': rpe}, where: 'id = ?', whereArgs: [id]);
  }

  // NOTE: the in-app notifications feed (putNotification/notifications/
  // markNotificationsRead/unreadCount, + the `notifications` table) was
  // removed — OS-level notifications (NotificationCenter.emit's
  // NotificationService.presentEvent path) are the only surface now. The
  // `notifications` table itself is left in the schema (unused, harmless)
  // rather than risk a DROP TABLE migration for no real benefit.

  // ── decoded retention ───────────────────────────────────────────────────────

  /// Delete decoded substrate / structured band signals / events whose RECORD
  /// TIME (epoch seconds) is strictly before [cutoffSec].
  ///
  /// [cursorName], when given, is raised to [cutoffSec] in the same
  /// transaction, never lowered — and, with archiving on, to each bucket's
  /// upper bound inside that bucket's own transaction, so it never trails a
  /// delete that has already committed. It is raised to [cutoffSec] even when
  /// a bucket's archive failed and its rows were kept live for the next pass:
  /// overstating what is gone is the safe direction — `rescanDayIds` and
  /// `windowTruncatedByPrune` then keep that day's stored result rather than
  /// re-derive it from a partly-live window.
  ///
  /// ARCHIVE, THEN DELETE. With [archive] enabled (read from the database when
  /// null), every `decoded_onehz` / `decoded_rr` row with `rec_ts > 0` goes
  /// through [SubstrateArchive.archiveAndDeleteBefore] first: one transaction
  /// per (device_id, utc_day) bucket, deleted only once its compressed copy
  /// has been written and read back. A bucket that fails stays live for the
  /// next pass unless it lies wholly behind [hardFloorSec] (the end of the
  /// bounded raw hold), where it is deleted unarchived as before. Rows with
  /// `rec_ts <= 0` cannot be placed on any day and are deleted unarchived.
  /// [log] receives the per-bucket failures (this file has no logger).
  /// [shouldYield] stops the archive step for this pass (see
  /// [SubstrateArchive.archiveAndDeleteBefore]); the rows it did not reach
  /// stay live and are archived next pass.
  ///
  /// Never runs during an offload — the only caller is inside the derive
  /// pass, which the scheduler holds while one is active — so the
  /// commit-before-ACK ordering of the drain is untouched.
  static Future<int> pruneDecodedBeforeRecTs(
    int cutoffSec, {
    String? cursorName,
    SubstrateArchivePolicy? archive,
    int? hardFloorSec,
    void Function(String message)? log,
    bool Function()? shouldYield,
    int? maxArchiveBuckets,
  }) => _ldbPruneDecodedBeforeRecTs(cutoffSec, cursorName: cursorName, archive: archive, hardFloorSec: hardFloorSec, log: log, shouldYield: shouldYield, maxArchiveBuckets: maxArchiveBuckets);

  /// How long pruned substrate is archived. Lives in `compute_freshness`, not
  /// SharedPreferences, so the foreground engine and every headless one read
  /// the same value. [SubstrateArchivePolicy.defaults] when unset.
  static Future<SubstrateArchivePolicy> substrateArchivePolicy() async =>
      SubstrateArchive.readPolicy(await instance);

  /// Switching archiving off purges the archive at once, in the same
  /// transaction as the setting — a partly-kept archive would leave holes
  /// nothing could explain later.
  static Future<void> setSubstrateArchivePolicy(
    SubstrateArchivePolicy policy,
  ) async => SubstrateArchive.writePolicy(await instance, policy);

  /// Drop archive buckets older than [policy] keeps, in whole UTC days behind
  /// the data edge [dataNowSec]. Returns buckets deleted.
  static Future<int> evictSubstrateArchive(
    SubstrateArchivePolicy policy,
    int dataNowSec,
  ) async => SubstrateArchive.evict(await instance, policy, dataNowSec);

  /// The data edge the archive window is measured from: the newest band
  /// reading, or, on a restored database with an archive but no decoded rows
  /// yet, the archive's own newest reading — without it a shorter window
  /// would be saved and nothing ever deleted. Null only with neither.
  static Future<int?> substrateArchiveEdge() async {
    final band = await lastDecodedRecTs();
    if (band != null) return band;
    final newest = (await substrateArchiveStats())['newest_to_ts'];
    return newest is num ? newest.toInt() : null;
  }

  /// `{buckets, bytes, raw_bytes, oldest_from_ts, newest_to_ts}` of the
  /// substrate archive.
  static Future<Map<String, Object?>> substrateArchiveStats() async =>
      SubstrateArchive.stats(await instance);

  /// Raise cursor [name] to [sec] on [txn]; never lowers it.
  static Future<void> _raiseCursorVia(
    Transaction txn,
    String name,
    int sec,
  ) async {
    final previous = await _cursorIntVia(txn, name);
    if (previous == null || sec > previous) {
      await setCursor(name, '$sec', txn: txn);
    }
  }

  /// Bytes SQLite is holding in the free page list — deleted, reusable, and
  /// invisible to the user, who sees only the file size.
  static Future<int> freelistBytes() async {
    final db = await instance;
    final free =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA freelist_count')) ?? 0;
    final pageSize =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA page_size')) ?? 4096;
    return free * pageSize;
  }

  /// Return free pages to the FILESYSTEM when there are enough of them to be
  /// worth a full rewrite. Returns the bytes reclaimed, or 0 if it declined.
  ///
  /// A delete only moves pages to the freelist; the file never shrinks below
  /// its all-time high-water mark. That is normally fine — the freelist is
  /// reused by the next day's ingest, so steady state is bounded — but two
  /// things put a permanent step in the mark: an install that let the substrate
  /// backlog build before the retention prune ran on every derive, and the v39
  /// migrations, each of which builds a full shadow copy of `decoded_onehz`
  /// before dropping the original. A 170 MB file stays 170 MB forever.
  ///
  /// WHY A FULL `VACUUM` AND NOT `auto_vacuum`:
  ///   * `auto_vacuum` cannot be turned on for an existing database without a
  ///     full `VACUUM` anyway, so it does not avoid this cost — it adds to it.
  ///   * `auto_vacuum=FULL` moves pages on EVERY commit, on a store taking
  ///     ~86 400 inserts a day. `INCREMENTAL` is cheaper but still adds
  ///     pointer-map pages to every write.
  ///   * Both would tax the hottest write path in the app, forever, to fix
  ///     something that happens once.
  ///
  /// A full `VACUUM` rewrites the whole file under an exclusive lock and needs
  /// roughly twice the file size free on disk, so it must NEVER run on the
  /// sync/ACK path, during a live session, or in the background. That gating is
  /// the caller's job — see `AppState._maybeReclaimDiskSpace`, which runs it
  /// only on a foreground heavy derive with nothing else in flight.
  static Future<int> vacuumIfBloated({int minFreeBytes = 64 << 20}) => _ldbVacuumIfBloated(minFreeBytes: minFreeBytes);

  /// Drop recomputable per-day intermediates left behind by superseded
  /// algorithm versions.
  ///
  /// `sleep_session_candidates` and `wake_day_features` are keyed
  /// (day_id, algo_version), so every kAlgoVersion bump writes a whole new
  /// generation beside the old one and nothing ever removed the old one — the
  /// tables grow without bound across releases. Neither is durable ledger:
  /// both are derived from `decoded_*` and rewritten whenever a day is
  /// re-derived.
  ///
  /// [keepVersions] generations are retained per day_id, newest first.
  /// Keeping more than one matters: a user on a GitHub release can roll back
  /// to the previous build, and pruning down to only the current version
  /// would leave that build with nothing to read for a day it never
  /// re-derives (raw retention is `rawRetentionDays`; a day older than that
  /// only gets a fresh-version row if something forces a re-derive).
  ///
  /// Scoped PER day_id, not table-wide. A table-wide "keep the 2 highest
  /// versions present ANYWHERE" cutoff deletes a day's only cached
  /// generation the moment any two OTHER days reach newer versions — not
  /// when this day does — because a day whose raw substrate has already
  /// aged out never re-enters the derive pipeline to write a newer row of
  /// its own. That silently orphaned still-needed rows for days that can
  /// never be re-derived.
  static Future<int> pruneSupersededIntermediates({
    int keepVersions = 2,
  }) => _ldbPruneSupersededIntermediates(keepVersions: keepVersions);

  /// The DATA EDGE — the timestamp (epoch seconds) of the last canonical 1 Hz
  /// record we've durably stored.
  static Future<int?> lastDecodedRecTs() => _ldbLastDecodedRecTs();
}
