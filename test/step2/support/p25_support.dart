// Shared fixtures for the design 02 step 2 / P2.5 tests (remaining readers on
// the seam). Builds on p23_support.dart (and through it p22 / p21).
//
// What is named here that does not exist before the P2.5 green commit: nothing
// but `LocalRepository.getDayBlock` (a throwing stub), which the tests call.
// The generic JSON lane (`decodeJsonPayloadsHeavy`) is only ever observed from
// the outside: through the worker audit (which entry reported, from which
// isolate, for which dispatch) and through what a reader returns. The tests do
// not construct it, so its signature is green's to choose.
//
// Seeds use FIXED day labels wherever the reader does not depend on today; the
// two scenarios that do (the wake-only Home and the recovery note) use
// `p23Day(n)` and tokenise the labels in what they record, so nothing in a
// golden depends on the date the suite ran on. No test reads the wall clock
// for a value it asserts.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/publish_gate.dart';
import 'package:openstrap_edge/util/worker_audit.dart';

import 'p23_support.dart';

export 'p23_support.dart';

// -- worker audit ------------------------------------------------------------

/// Records which worker entries ran, from which isolate, for which dispatch.
/// `attach` before the call under test, `detach` in a tearDown.
class P25Audit {
  final List<EntryEvent> entries = [];
  final List<DispatchEvent> dispatches = [];

  void attach() {
    WorkerAudit.onEntry = entries.add;
    WorkerAudit.onDispatch = dispatches.add;
  }

  void detach() => WorkerAudit.reset();

  /// Every dispatch made so far has reported its entry (the report travels on
  /// a port, so it can trail the dispatch's own completion).
  Future<void> settle() => p22Until(
    () => entries.length >= dispatches.length,
    'every dispatched worker to report its entry',
  );

  Set<String> get names => {for (final e in entries) e.entry};

  /// Entries that ran on THIS isolate: a decode that never left the UI isolate
  /// is not dispatched at all, so a healthy reader has none of these.
  Iterable<EntryEvent> get onUiIsolate =>
      entries.where((e) => e.isolateId == WorkerAudit.currentIsolateId);
}

/// What a moved reader must show: at least one worker entry reported, none of
/// them from this isolate. A reader that still decodes inline reports nothing,
/// so `entries` is empty and this fails.
void p25ExpectDecodedInWorker(P25Audit audit, String what) {
  expect(audit.entries, isNotEmpty,
      reason: '$what: no worker entry reported: the decode ran inline on the '
          'UI isolate');
  expect(audit.onUiIsolate, isEmpty,
      reason: '$what: an entry reported from the UI isolate: ${audit.names}');
}

// -- gate effects ------------------------------------------------------------

class P25Effects implements PublishGateEffects {
  int bumps = 0;
  final List<String> logs = [];
  @override
  void publishBump() => bumps++;
  @override
  void publishLog(String line) => logs.add(line);
}

// -- rows --------------------------------------------------------------------

/// One `day_result` row with every column the readers look at.
Future<void> p25Row(
  Database db,
  String day, {
  String payload = '{}',
  String window = '{}',
  int computedAt = 1000,
  int skipped = 0,
  int finalized = 0,
  double? rhr,
  double? rmssd,
  double? readiness,
  int version = p21Version,
}) => db.insert('day_result', {
  'day_id': day,
  'algo_version': version,
  'payload_json': payload,
  'window_json': window,
  'computed_at': computedAt,
  'finalized': finalized,
  'skipped': skipped,
  'partial': 0,
  'rhr': rhr,
  'rmssd': rmssd,
  'readiness': readiness,
}, conflictAlgorithm: ConflictAlgorithm.replace);

/// A `wake_day_features` row at the served version with a payload of ours.
Future<void> p25Wake(Database db, String day, Object? payload, {int computedAt = 2000}) =>
    db.insert('wake_day_features', {
      'day_id': day,
      'algo_version': p21Version,
      'payload_json': payload is String ? payload : jsonEncode(payload),
      'computed_at': computedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

// -- recentDayDiagnostics (B6) ----------------------------------------------

const List<String> p25DiagDays = [
  '2025-04-01',
  '2025-04-02',
  '2025-04-03',
  '2025-04-04',
  '2025-04-05',
];

/// Five days: scalars only (columns null), columns that win over the scalars, a
/// skipped day with a reason, an undecodable payload, and a compact stored
/// bundle with curves. Raw rows for two of them.
Future<void> p25SeedDiagnostics(Database db) async {
  await p25Row(db, p25DiagDays[0],
      payload: jsonEncode({
        'scalars': {
          'rhr': 51.0,
          'rmssd': 44.0,
          'readiness': 66.0,
          'strain': 9.5,
          'tst_min': 430.0,
          'resp_rate': 14.2,
        },
      }),
      computedAt: 1001);
  await p25Row(db, p25DiagDays[1],
      payload: jsonEncode({
        'scalars': {'rhr': 99.0, 'rmssd': 99.0, 'readiness': 99.0, 'strain': 12.25},
      }),
      computedAt: 1002,
      rhr: 52.5,
      rmssd: 45.5,
      readiness: 71.0);
  await p25Row(db, p25DiagDays[2],
      payload: jsonEncode({'skipped': true, 'reason': 'day_prepare_budget_exceeded'}),
      computedAt: 1003,
      skipped: 1);
  await p25Row(db, p25DiagDays[3], payload: '{oops', computedAt: 1004);
  await p22Seed(db, p25DiagDays[4], p22DayBundle(p25DiagDays[4], i: 3), computedAt: 1005, finalized: true);
  await p23Raw(db, p25DiagDays[0]);
  await p23Raw(db, p25DiagDays[4]);
}

// -- sleepWindows (a) --------------------------------------------------------

/// 16 served days (so a 14-row limit cuts) in every `window_json` shape the
/// reader has met, and one skipped day the reader must not return.
const List<String> p25WindowDays = [
  '2025-05-01', '2025-05-02', '2025-05-03', '2025-05-04',
  '2025-05-05', '2025-05-06', '2025-05-07', '2025-05-08',
  '2025-05-09', '2025-05-10', '2025-05-11', '2025-05-12',
  '2025-05-13', '2025-05-14', '2025-05-15', '2025-05-16',
];

String _win(int i) =>
    jsonEncode({'onset_ms': 1746000000000 + i * 86400000, 'offset_ms': 1746028800500 + i * 86400000, 'spt_sec': 28800});

Future<void> p25SeedWindows(Database db) async {
  final shapes = <String>[
    jsonEncode({'value': {'onset_ms': 1746000000000, 'offset_ms': 1746028800500}, 'confidence': 0.8, 'tier': 'A'}),
    jsonEncode({'onset_ms': 1746086400000, 'offset_ms': 1746115200000, 'confidence': 0.5, 'tier': 'B'}),
    jsonEncode({'value': '—', 'confidence': 0.1}),
    '{not json',
    '[]',
    '{}',
    jsonEncode({'onset_ms': 1746518400000}),
    jsonEncode({'offset_ms': 1746547200000, 'confidence': 1}),
  ];
  for (var i = 0; i < p25WindowDays.length; i++) {
    await p25Row(db, p25WindowDays[i],
        window: i < shapes.length ? shapes[i] : _win(i), computedAt: 3000 + i);
  }
  await p25Row(db, '2025-05-17', window: _win(99), skipped: 1, computedAt: 3099);
}

// -- kcal curve and last_result (B9, B7) ------------------------------------

const String p25KcalFull = '2025-06-01';
const String p25KcalSparse = '2025-06-02';
const String p25KcalNoMinutes = '2025-06-03';
const String p25KcalList = '2025-06-04';
const String p25KcalMissing = '2025-06-09';

Future<void> p25SeedKcal() async {
  final full = {
    'minutes': [
      for (var i = 0; i < 1440; i++)
        {
          't': 1748736000 + i * 60,
          'total': i % 11 == 0 ? null : 1.0 + (i % 7) * 0.125,
          'active': i % 5 == 0 ? 0 : 0.25 * (i % 4),
          if (i % 13 != 0) 'basal': 1.0 + i % 3 * 0.0625,
          'extra_field_not_returned': i,
        },
    ],
    'basal_kcal_per_min': 1.0625,
    'covered_minutes': 1380,
    'ignored': 'x',
  };
  await LocalDb.putLastResult('kcal_minutes|$p25KcalFull', 4100, jsonEncode(full), 200);
  await LocalDb.putLastResult('kcal_minutes|$p25KcalSparse', 4101,
      jsonEncode({'minutes': [{'t': 1748822400}, {'t': 1748822460, 'total': 2}]}), 200);
  await LocalDb.putLastResult('kcal_minutes|$p25KcalNoMinutes', 4102,
      jsonEncode({'basal_kcal_per_min': 0.9}), 200);
  await LocalDb.putLastResult('kcal_minutes|$p25KcalList', 4103, '[1,2,3]', 200);
}

/// A map shaped like the night-beats artifact: thousands of numbers.
Map<String, dynamic> p25BigArtifact() => {
  'day': '2025-06-01',
  'nn': [for (var i = 0; i < 6000; i++) 800.0 + (i * 7919) % 400 / 4],
  'ts': [for (var i = 0; i < 6000; i++) 1748736000000 + i * 850],
  'flags': [null, true, false, 'x'],
  'nested': {'a': {'b': {'c': [1, 2.5, 3e10, -0.0]}}},
};

/// key -> (computedAt, stored text, sig)
Map<String, (int, String, String?)> p25LastResultRows() => {
  'workout|w1': (5100, jsonEncode({'hr': [60, 61.5, 62], 'name': 'run'}), null),
  'beats|2025-06-01': (5101, jsonEncode(p25BigArtifact()), 'sig-1'),
  'circadian': (5102, '[1,2,3]', null),
  'corrupt': (5103, '{oops', null),
  'scalar': (5104, '42', null),
  'sig': (5105, jsonEncode({'v': 1}), 'abc'),
};

Future<void> p25SeedLastResults() async {
  for (final e in p25LastResultRows().entries) {
    await LocalDb.putLastResult(e.key, e.value.$1, e.value.$2, 200, sig: e.value.$3);
  }
}

// -- tokens ------------------------------------------------------------------

/// Today's label and the 40 before it, replaced by `<D0>` .. `<D40>`.
String p25Tokens(String text) {
  var out = text;
  for (var i = 40; i >= 0; i--) {
    out = out.replaceAll(p23Day(i), '<D$i>');
  }
  return out;
}

/// A canonical text of any JSON-shaped value (the comparison form of goldens).
String p25Text(Object? v) => jsonEncode(v);
