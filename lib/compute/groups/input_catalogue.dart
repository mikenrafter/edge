// input_catalogue.dart — every input a calculation group may read (design 06
// phase 1c): its id, where it is stored or set, and how a change is scoped.
//
// One owner: this file. `GroupDecl.inputs` reference these ids; the revision
// triggers (lib/data/db/input_revision_store.dart) are generated from the
// `tables` below; `InputReads.note` (input_read_tracker.dart) takes these ids.
// Rows follow the inventory in edge.research/design/06-phase1-plan.md section 3.
//
// Analytics' groups (openstrap_analytics at the current pin) declare no
// `inputs` yet, and 1c does not touch the pin. [kGroupInputs] is therefore the
// edge-side declaration of every group's inputs, merged with whatever a group
// carries itself by [declaredInputs].

import 'group_types.dart';

// Deliberately NOT inputs (checked against the derive's reads at 1c):
//  * `import_journal` (D38): import bookkeeping. It records that a restore ran
//    and how far it got; no calculation group reads it.
//  * The user tables restored by D37 (`alarm_schedule`, `symptom_entry`,
//    `moment_label`, `assumed_water`, `notif_fired`): the derive does not read
//    them (alarms and fired-keys are device/notification state; moment labels,
//    symptom entries and assumed water feed screens and the coach, not a
//    group). If a group starts reading one, add it here with its setter.

/// How a change to an input is scoped in `input_revision`.
enum InputGranularity {
  /// One revision per local day label (`scope` = the day).
  day,

  /// One revision for the whole input (`scope` = '').
  global,
}

enum InputKind {
  /// Bumped by triggers on [InputSpec.tables].
  table,

  /// Bumped by an explicit `bumpInputRev` call at the setter.
  setter,

  /// The existing `input_rev` 15-minute buckets, exposed as one source.
  decoded,
}

/// A table that carries an input, and the SQL for the affected day.
class InputTable {
  const InputTable(this.name,
      {this.dayExpr,
      this.updateOf = const <String>[],
      this.readMarkers = const <String>[]});

  final String name;

  /// For a table only SOME of whose rows are the input (`raw_archive` holds
  /// band records too; `sync_cursor` holds every cursor): substrings that a
  /// read of those rows' SQL or arguments carries. The SQL-logging backstop
  /// (test/groups/input_read_tracking_test.dart) counts a read of the table as
  /// a read of the input only when one of them appears. Empty = every read.
  final List<String> readMarkers;

  /// When non-empty, the UPDATE trigger fires only for these columns (a table
  /// whose other columns churn without changing the input, like `last_seen`).
  final List<String> updateOf;

  /// SQL expression for the affected day label of a changed row, with `{r}` for
  /// the row alias (`NEW` or `OLD`). Null for a global input.
  final String? dayExpr;
}

class InputSpec {
  const InputSpec(
    this.id,
    this.kind,
    this.granularity, {
    this.tables = const <InputTable>[],
    this.setterFiles = const <String>[],
    this.inventoryRow,
  });

  /// Stable; also the `input_revision.source`. Never reused.
  final String id;
  final InputKind kind;
  final InputGranularity granularity;
  final List<InputTable> tables;

  /// For [InputKind.setter]: repo files that must call `bumpInputRev(id, ...)`.
  final List<String> setterFiles;

  /// The section 3 inventory row this input belongs to.
  final String? inventoryRow;
}


String _dayOf(String col) =>
    "strftime('%Y-%m-%d', {r}.$col, 'unixepoch', 'localtime')";

final List<InputSpec> kInputCatalogue = <InputSpec>[
  const InputSpec('decoded', InputKind.decoded, InputGranularity.day,
      tables: [InputTable('decoded_onehz'), InputTable('decoded_rr')],
      inventoryRow: 'decoded 1 Hz and RR'),
  InputSpec('step_coverage', InputKind.table, InputGranularity.day,
      tables: const [InputTable('live_coverage', dayExpr: '{r}.day')],
      inventoryRow: 'phone step coverage'),
  const InputSpec('wearing', InputKind.table, InputGranularity.global,
      tables: [
        InputTable('device', updateOf: ['wearing', 'wearing_set_ts']),
      ],
      inventoryRow: 'wearing location'),
  const InputSpec('step_calibration', InputKind.table, InputGranularity.global,
      tables: [InputTable('step_calibration')],
      inventoryRow: 'step calibration'),
  InputSpec('step_calibration_day', InputKind.table, InputGranularity.day,
      tables: const [
        InputTable('step_calibration_day', dayExpr: '{r}.day'),
      ],
      inventoryRow: 'step calibration'),
  const InputSpec('device_coverage', InputKind.table, InputGranularity.global,
      // `signal_priority` is the rank half of the same resolver input.
      tables: [InputTable('device_coverage'), InputTable('signal_priority')],
      inventoryRow: 'device priority and coverage'),
  InputSpec('events', InputKind.table, InputGranularity.day,
      // `band_events` is what wristOffSpans/chargingSpans actually read (the
      // plan names `events`); both are triggered.
      tables: [
        InputTable('events', dayExpr: _dayOf('ts')),
        InputTable('band_events', dayExpr: _dayOf('ts')),
      ],
      inventoryRow: 'wrist-off and charging events'),
  InputSpec('sleep_override', InputKind.table, InputGranularity.day,
      tables: const [InputTable('sleep_override', dayExpr: '{r}.day_id')],
      inventoryRow: 'sleep overrides and wake confirmations'),
  InputSpec('wake_confirmation', InputKind.table, InputGranularity.day,
      tables: const [InputTable('wake_confirmation', dayExpr: '{r}.day_id')],
      inventoryRow: 'sleep overrides and wake confirmations'),
  InputSpec('vendor_sleep_epoch', InputKind.table, InputGranularity.day,
      tables: [InputTable('vendor_sleep_epoch', dayExpr: _dayOf('night_onset_ts'))],
      inventoryRow: 'vendor and wearable sleep nights'),
  InputSpec('sessions', InputKind.table, InputGranularity.day,
      tables: [InputTable('sessions', dayExpr: _dayOf('start_ts'))],
      inventoryRow: 'sessions and nap edits'),
  InputSpec('session_score_mask', InputKind.table, InputGranularity.day,
      tables: [
        InputTable('session_score_mask',
            dayExpr: "(SELECT strftime('%Y-%m-%d', start_ts, 'unixepoch', "
                "'localtime') FROM sessions WHERE id = {r}.session_id)"),
      ],
      inventoryRow: 'sessions and nap edits'),
  InputSpec('sleep_nap', InputKind.table, InputGranularity.day,
      tables: const [InputTable('sleep_nap', dayExpr: '{r}.day_id')],
      inventoryRow: 'sessions and nap edits'),
  const InputSpec('baselines', InputKind.table, InputGranularity.global,
      tables: [InputTable('baselines')],
      inventoryRow: 'baselines and history'),
  InputSpec('metric_series', InputKind.table, InputGranularity.day,
      tables: const [InputTable('metric_series', dayExpr: '{r}.date')],
      inventoryRow: 'baselines and history'),
  InputSpec('cycle_log', InputKind.table, InputGranularity.day,
      tables: const [InputTable('cycle_log', dayExpr: '{r}.date')],
      inventoryRow: 'cycle log and journal'),
  InputSpec('journal', InputKind.table, InputGranularity.day,
      tables: const [InputTable('journal', dayExpr: '{r}.date')],
      inventoryRow: 'cycle log and journal'),
  InputSpec('cycle_symptom', InputKind.table, InputGranularity.day,
      tables: const [InputTable('cycle_symptom', dayExpr: '{r}.date')],
      inventoryRow: 'cycle log and journal'),
  const InputSpec('profile', InputKind.setter, InputGranularity.global,
      setterFiles: ['lib/state/app_state.dart'], inventoryRow: 'profile'),
  const InputSpec('policy', InputKind.setter, InputGranularity.global,
      setterFiles: ['lib/state/prefs.dart'],
      inventoryRow: 'calc policies and settings'),
];

/// Group id -> the inputs it reads (analytics groups cannot carry `inputs` at
/// the current pin). Checked against a real derive by
/// test/groups/input_read_tracking_test.dart: every tracked read is declared
/// here, and every declaration is read or listed as conditional.
const Map<String, List<InputDecl>> kGroupInputs = <String, List<InputDecl>>{
  'sleep.stage': [
    InputDecl('decoded', InputScope.dayAndNext),
    InputDecl('events', InputScope.dayAndNext),
    InputDecl('sleep_override', InputScope.day),
    InputDecl('wake_confirmation', InputScope.day),
    InputDecl('vendor_sleep_epoch', InputScope.dayAndNext),
    InputDecl('wearing', InputScope.global),
    InputDecl('device_coverage', InputScope.global),
  ],
  'hrv.freq': [InputDecl('decoded', InputScope.dayAndNext)],
  'night.rhythm': [InputDecl('decoded', InputScope.dayAndNext)],
  'day.blocks': [
    InputDecl('decoded', InputScope.day),
    InputDecl('events', InputScope.day),
    InputDecl('sessions', InputScope.day),
    InputDecl('sleep_nap', InputScope.day),
  ],
  'readiness.stress_illness': [
    InputDecl('decoded', InputScope.range),
    InputDecl('baselines', InputScope.global),
    InputDecl('metric_series', InputScope.range),
    InputDecl('profile', InputScope.global),
  ],
  'activity.load': [
    InputDecl('decoded', InputScope.day),
    InputDecl('sessions', InputScope.day),
    InputDecl('session_score_mask', InputScope.day),
    InputDecl('step_coverage', InputScope.day),
    InputDecl('step_calibration', InputScope.global),
    InputDecl('step_calibration_day', InputScope.range),
    InputDecl('wearing', InputScope.global),
    InputDecl('device_coverage', InputScope.global),
    InputDecl('profile', InputScope.global),
  ],
  'body.spo2_temp_coverage': [
    InputDecl('decoded', InputScope.dayAndNext),
    InputDecl('metric_series', InputScope.range),
    InputDecl('device_coverage', InputScope.global),
  ],
  // Cross-day insights: the user's own logs against the derived series.
  'human.insights': [
    InputDecl('cycle_log', InputScope.range),
    InputDecl('cycle_symptom', InputScope.range),
    InputDecl('journal', InputScope.range),
    InputDecl('metric_series', InputScope.range),
  ],
  // Calc policies change timing only; declared so a change is stamped.
  'edge.assembly': [InputDecl('policy', InputScope.global)],
};

/// What [g] declares it reads: its own `inputs` plus [kGroupInputs].
List<InputDecl> declaredInputs(GroupDecl g) =>
    <InputDecl>[...g.inputs, ...?kGroupInputs[g.id]];
