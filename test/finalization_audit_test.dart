// The power-gated finalization audit (RED). Owner goal: "Large computations
// should only happen on occasion and when power is plentiful."
//
// The frequent derive passes are accumulator-based (cardio epoch-row cache,
// streaming night RR / hrvFreq / RSA, the day checkpoint) and designed to be
// bit-identical to the batch path. Once, when a day FINALIZES, and only when the
// Calculations power policy allows heavy work, the engine re-derives that day on
// the pure batch path (no DayCalculationState, no CardioRowCache, no checkpoint
// resume), compares it with the accumulator result about to be frozen, publishes
// the BATCH result as the finalized value (the reference), logs the verdict and
// keeps a persistent disagreement counter.
//
// ── PINNED API (nothing below exists yet; every symbol is new) ───────────────
//
//  lib/compute/finalization_audit.dart (pure Dart, isolate-safe, no I/O)
//    class AuditResult { const AuditResult({required this.diffKeys});
//                        final List<String> diffKeys; bool get ok => diffKeys.isEmpty;
//                        int get count => diffKeys.length; }
//    AuditResult auditFinalization(Map<String, dynamic> accumulator,
//                                  Map<String, dynamic> batch)
//      Deep, EXACT comparison of two day payloads (bit-identical doubles; NaN ==
//      NaN; int 1 vs double 1.0 is a difference). Keys are dotted paths
//      ('scalars.rhr', 'series.hrv_day.v[3].v'); a whole list of different
//      length is reported once, at the list path ('sleep.stages'); a key on one
//      side only is reported at its path. `diffKeys` is sorted, de-duplicated.
//      Ignored on both sides: 'computed_at' (a wall-clock stamp, never a metric).
//    String auditLogLine(String day, AuditResult r)
//      '[audit] <day> ok'  |  '[audit] <day> diff <n> keys: <k1>, <k2>, ...'
//      (n = r.count; at most the first 5 sorted keys are listed).
//    class FinalizationAuditState { int runs; int diffs; List<String> pending
//      (sorted day ids awaiting an audit); String? lastDiffDay;
//      List<String> lastDiffKeys; }
//
//  lib/compute/calc_power_policy.dart
//    bool CalcPowerPolicy.mayAuditFinalization(PowerState p)
//      eager: always true (it ignores the saver and the plug, like its sweep).
//      balanced: p.charging && !p.powerSaver (the same rule as
//        mayWarmWhilePlugged: heavy work needs external power and no saver).
//      maxBattery: never, plugged or not.
//
//  lib/data/db.dart
//    Future<FinalizationAuditState> LocalDb.finalizationAudit()
//    PERSISTENCE: ONE `last_result` row, key 'audit|state', JSON
//    {runs, diffs, pending[], last_diff_day, last_diff_keys[]}. Why there and not
//    a pref or a new table: it is a DB row, so the headless/background isolate
//    (where SharedPreferences is not guaranteed and the engine already runs) can
//    write it, a developer screen reads it with the same LocalDb handle, and no
//    schema bump is needed. The row is rewritten on every audit event so its
//    computed_at is fresh and the table's keep-newest-N trim never evicts it.
//    The log line is the other reader ("log export").
//
//  lib/compute/derivation_engine.dart  (DerivationEngine)
//    CalcPowerPolicy? auditPolicy;                    // null = feature off
//    Future<PowerState> Function()? auditPowerRead;   // null = feature off
//      The owner of the engine (AppState / DeriveCoordinator.policy + its
//      PowerSource, background_sync's headless source) assigns both; the engine
//      reads the power at the moment of finalization, never caches it. Either
//      one null => no audit AND no pending mark (existing behaviour untouched).
//    @visibleForTesting Map<String,dynamic> Function(String day,
//        Map<String,dynamic> bundle)? debugAccumulatorTamper;
//      Applied to the day's finished accumulator-path bundle (after the second
//      half, before the audit and before the write) and returned in its place.
//      This is how a test injects "the accumulator path disagreed".
//    Future<int> auditPendingFinalizations(Profile profile)
//      Audits every day in FinalizationAuditState.pending if
//      auditPolicy.mayAuditFinalization(await auditPowerRead()); returns how
//      many were audited. run() calls it once at the end of every pass (after
//      the days are written), so the "next eligible pass" needs no new trigger.
//
//  WHERE (hook points)
//   * finalization decision: derivation_engine.dart `_derivePreparedDay`, the
//     `finalized` computation (~5746-5752) and the write
//     `LocalDb.putDayResult(... finalized: effectiveFinalized ...)` (~5787).
//     The audit sits BETWEEN them: only when effectiveFinalized && reason ==
//     DayResultWrite.derive (a user force/override already is a from-scratch
//     run; an import is force-finalized with no raw). putDayResult
//     (db.dart ~9128-9200) refuses a derive overwrite of a frozen row, so the
//     batch result must be the payload of THE finalizing write itself.
//   * The batch run goes through the cancellable worker dispatcher
//     (`_runIsolateCancellable`, ~9890-9950) with a label starting
//     'audit-batch <day>' and runs the REGISTERED entry `auditBatchDay`
//     (lib/util/worker_entries.dart, Dispatcher.cancellable): never on the
//     UI/main isolate. It reports `WorkerAudit.entered('auditBatchDay')`.
//   * perf counters (DerivePerf, per pass, not the persisted counter):
//     'audit_batch_runs' (batch re-derives started).
//
// ── DECISIONS ─────────────────────────────────────────────────────────────────
//  * Ineligible power at finalization: finalize from the accumulator result as
//    today, no batch run, add the day to `pending`, log nothing at warn level.
//  * A pending audit is LATE: the row is frozen and downstream consumers
//    (baselines, notifications, exports) may already have read it. A late diff
//    therefore logs + bumps the counter and KEEPS the frozen row; it never
//    rewrites it (putDayResult's frozen rule stays the one place of truth; the
//    only allowed rewrite paths are a user override and a new kAlgoVersion).
//    The counter is the signal that the accumulator path has a bug to fix.
//    The late audit compares the STORED payload with a fresh batch derive.
//  * A pending day is audited only if the raw it was derived from is still whole:
//    the day's current `LocalDb.decodedDayFingerprints([day])` must equal the
//    fingerprint recorded when it was derived (`derivedFingerprints`). Raw
//    retention is 3 days and a day finalizes ~1 day before its raw ages out, so
//    a pending audit has a bounded window; a partly or wholly pruned day would
//    differ from its stored result for a reason that is not the accumulator's.
//    Such a day is dropped from `pending` with '[audit] <day> skipped' and no
//    counter change. Un-derived days are never audited and never pruned by this
//    feature.
//  * `runs` counts completed audits (timely or late); `diffs` counts audits that
//    found >= 1 differing key (one per audit, not per key).
//
// EXPECTED RED REASONS: compile errors on the missing symbols (everything above).
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/finalization_audit.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/power_source.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_power_source.dart';
import 'support/frozen_day_result_fixtures.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

// A day finalizes once its last record + 48 h is behind the data edge (the last
// drained record, 09-07 00:30): _d1 (last record 09-04 23:59) does, _d2 (09-05
// 08:00, +48 h = 09-07 08:00) does not. The 3-day raw prune (edge - 3 d =
// 09-04 00:30) leaves both days' raw whole. Run with TZ=UTC.
const _d1 = '2025-09-04';
const _d2 = '2025-09-05';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

late Database _db;

Future<void> _seedRaw() async {
  final b = _db.batch();
  var c = 0;
  void run(int from, int to, int Function(int) hr) {
    for (var ts = from; ts < to; ts++) {
      b.insert('decoded_onehz', {
        'device_id': '',
        'ts_ms': ts * 1000,
        'rec_ts': ts,
        'counter': c++,
        'hr': hr(ts),
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  int night(int ts) => 52 + (ts % 7);
  run(_sec(2025, 9, 4, 1, 0), _sec(2025, 9, 4, 8, 0), night);
  run(_sec(2025, 9, 4, 22, 0), _sec(2025, 9, 5, 8, 0), night);
  run(_sec(2025, 9, 7, 0, 30), _sec(2025, 9, 7, 0, 31), (_) => 70);
  await b.commit(noResult: true);
}

const _plugged = PowerState(charging: true);
const _unplugged = PowerState.unplugged;
const _pluggedSaver = PowerState(charging: true, powerSaver: true);

/// The accumulator bundle with a value the batch path cannot produce.
Map<String, dynamic> _tamper(String day, Map<String, dynamic> bundle) {
  if (day == _d1) {
    (bundle['scalars'] as Map)['rhr'] = 99.0;
  }
  return bundle;
}

DerivationEngine _engine(
  CalcPowerMode mode,
  PowerState power, {
  List<String>? log,
  bool tamper = false,
}) {
  final e = DerivationEngine(log: log?.add)
    ..auditPolicy = CalcPowerPolicy(mode)
    ..auditPowerRead = (() async => power);
  if (tamper) e.debugAccumulatorTamper = _tamper;
  return e;
}

Future<Map<String, Object?>> _rawRow(String day) async {
  final r = (await _db.query('day_result',
          where: 'day_id = ? AND algo_version = ?',
          whereArgs: [day, kAlgoVersion]))
      .single;
  return Map<String, Object?>.of(r);
}

Future<Map<String, dynamic>> _payload(String day) async {
  final p = jsonDecode((await _rawRow(day))['payload_json'] as String)
      as Map<String, dynamic>;
  return p..remove('computed_at');
}

int? _count(DerivationEngine e, String name) =>
    ((e.perf.summary()['counts'] as Map)[name] as num?)?.toInt();

List<String> _audit(List<String> log) =>
    [for (final l in log) if (l.startsWith('[audit] ')) l];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _db = await freshDb('finalization_audit_test.db');
    await _seedRaw();
  });
  tearDown(WorkerAudit.reset);
  tearDownAll(dropDb);

  // ── pure ───────────────────────────────────────────────────────────────────

  group('auditFinalization (pure)', () {
    Map<String, dynamic> base() => {
          'computed_at': 1,
          'scalars': <String, dynamic>{
            'rhr': 51.5,
            'rmssd': 44.0,
            'nan': double.nan,
          },
          'series': <String, dynamic>{
            'hrv_day': <String, dynamic>{
              'v': [
                {'t': 1, 'v': 40.0},
                {'t': 2, 'v': 41.0},
              ]
            }
          },
          'sleep': <String, dynamic>{'stages': ['a', 'b']},
        };

    test('identical payloads agree; computed_at and NaN are not differences',
        () {
      final b = base()..['computed_at'] = 2;
      final r = auditFinalization(base(), b);
      expect(r.ok, isTrue);
      expect(r.diffKeys, isEmpty);
      expect(r.count, 0);
    });

    test('differences are named by sorted dotted path, one per leaf', () {
      final b = base();
      (b['scalars'] as Map)['rhr'] = 51.5000001;
      ((b['series'] as Map)['hrv_day']['v'] as List)[1]['v'] = 41.5;
      (b['scalars'] as Map)['extra'] = 1.0;
      final r = auditFinalization(base(), b);
      expect(r.ok, isFalse);
      expect(r.diffKeys, [
        'scalars.extra',
        'scalars.rhr',
        'series.hrv_day.v[1].v',
      ]);
      expect(r.count, 3);
    });

    test('a list of another length is one difference at the list path; int '
        'vs double is a difference; the argument maps are not mutated', () {
      final a = base();
      final b = base();
      (b['sleep'] as Map)['stages'] = ['a'];
      (b['scalars'] as Map)['rmssd'] = 44;
      // base() holds a NaN, which jsonEncode refuses without a fallback.
      String snap(Object o) => jsonEncode(o, toEncodable: (x) => '$x');
      final before = snap(a);
      final r = auditFinalization(a, b);
      expect(r.diffKeys, ['scalars.rmssd', 'sleep.stages']);
      expect(snap(a), before);
    });

    test('log line format', () {
      expect(auditLogLine(_d1, const AuditResult(diffKeys: [])),
          '[audit] $_d1 ok');
      expect(
          auditLogLine(_d1, const AuditResult(diffKeys: ['a', 'b'])),
          '[audit] $_d1 diff 2 keys: a, b');
      expect(
          auditLogLine(_d1,
              const AuditResult(diffKeys: ['a', 'b', 'c', 'd', 'e', 'f', 'g'])),
          '[audit] $_d1 diff 7 keys: a, b, c, d, e');
    });
  });

  group('CalcPowerPolicy.mayAuditFinalization', () {
    test('eager always; balanced only on external power without the saver; '
        'maximum battery never', () {
      bool may(CalcPowerMode m, PowerState p) =>
          CalcPowerPolicy(m).mayAuditFinalization(p);
      for (final p in [_plugged, _unplugged, _pluggedSaver]) {
        expect(may(CalcPowerMode.eager, p), isTrue, reason: '$p');
        expect(may(CalcPowerMode.maxBattery, p), isFalse, reason: '$p');
      }
      expect(may(CalcPowerMode.balanced, _plugged), isTrue);
      expect(may(CalcPowerMode.balanced, _unplugged), isFalse);
      expect(may(CalcPowerMode.balanced, _pluggedSaver), isFalse);
      expect(
          may(CalcPowerMode.balanced,
              const PowerState(charging: false, powerSaver: true)),
          isFalse);
    });
  });

  // ── (1) eligible power, identical payloads ────────────────────────────────

  group('eligible power at finalization', () {
    test('audits once, publishes the batch result, logs ok, counter unchanged',
        () async {
      final log = <String>[];
      final e = _engine(CalcPowerMode.balanced, _plugged, log: log);
      await e.run(_profile, heavy: true);

      expect(_audit(log).where((l) => l.contains(_d1)), ['[audit] $_d1 ok']);
      expect(_audit(log).where((l) => l.contains(_d2)), isEmpty,
          reason: 'a day that is not finalized is not audited');
      expect(_count(e, 'audit_batch_runs'), 1);
      expect((await _rawRow(_d1))['finalized'], 1);
      expect((await _rawRow(_d2))['finalized'], 0);

      final st = await LocalDb.finalizationAudit();
      expect(st.diffs, 0, reason: 'identical payloads: the counter stays put');
      expect(st.runs, 1);
      expect(st.pending, isEmpty);

      // The published value IS the batch reference: a forced from-scratch
      // re-derive stores exactly the same payload.
      final published = await _payload(_d1);
      await DerivationEngine().run(_profile, force: true);
      expect(await _payload(_d1), published);
    });

    test('Eager audits even unplugged', () async {
      final log = <String>[];
      await _engine(CalcPowerMode.eager, _unplugged, log: log)
          .run(_profile, heavy: true);
      expect(_audit(log), contains('[audit] $_d1 ok'));
    });

    test('no policy/power wired: no audit, no pending mark (today\'s behaviour)',
        () async {
      final log = <String>[];
      final e = DerivationEngine(log: log.add);
      await e.run(_profile, heavy: true);
      expect(_audit(log), isEmpty);
      expect(_count(e, 'audit_batch_runs'), isNull);
      final st = await LocalDb.finalizationAudit();
      expect([st.runs, st.diffs, st.pending], [0, 0, <String>[]]);
      expect((await _rawRow(_d1))['finalized'], 1);
    });
  });

  // ── (2) forced difference ──────────────────────────────────────────────────

  group('a forced accumulator/batch difference', () {
    test('counter +1, diff logged with the key, batch value published',
        () async {
      final log = <String>[];
      final e =
          _engine(CalcPowerMode.balanced, _plugged, log: log, tamper: true);
      await e.run(_profile, heavy: true);

      final line = _audit(log).singleWhere((l) => l.contains(_d1));
      expect(line, startsWith('[audit] $_d1 diff '));
      expect(line, contains('scalars.rhr'));

      final st = await LocalDb.finalizationAudit();
      expect(st.diffs, 1);
      expect(st.runs, 1);
      expect(st.lastDiffDay, _d1);
      expect(st.lastDiffKeys, contains('scalars.rhr'));

      final row = await _rawRow(_d1);
      expect(row['finalized'], 1);
      expect(row['rhr'], isNot(99.0), reason: 'the indexed scalar is the batch\'s');
      expect(((await _payload(_d1))['scalars'] as Map)['rhr'], isNot(99.0));
      final published = await _payload(_d1);
      await DerivationEngine().run(_profile, force: true);
      expect(await _payload(_d1), published,
          reason: 'what was published equals the from-scratch reference');
    });

    test('the counter accumulates across audits (persistent, not per engine)',
        () async {
      await _engine(CalcPowerMode.balanced, _plugged, tamper: true)
          .run(_profile, heavy: true);
      await LocalDb.close(); // a cold start: same file, new handle
      expect((await LocalDb.finalizationAudit()).diffs, 1);
    });
  });

  // ── (3) power forbids heavy work ───────────────────────────────────────────

  group('power forbids heavy work', () {
    for (final c in <(String, CalcPowerMode, PowerState)>[
      ('maximum battery plugged in', CalcPowerMode.maxBattery, _plugged),
      ('maximum battery unplugged', CalcPowerMode.maxBattery, _unplugged),
      ('balanced unplugged', CalcPowerMode.balanced, _unplugged),
      ('balanced plugged under the saver', CalcPowerMode.balanced, _pluggedSaver),
    ]) {
      test('${c.$1}: no audit, the accumulator result is finalized, the day is '
          'marked pending', () async {
        final log = <String>[];
        final e = _engine(c.$2, c.$3, log: log, tamper: true);
        await e.run(_profile, heavy: true);

        expect(_audit(log), isEmpty);
        expect(_count(e, 'audit_batch_runs'), isNull);
        final row = await _rawRow(_d1);
        expect(row['finalized'], 1, reason: 'finalization is never blocked');
        expect(row['rhr'], 99.0, reason: 'finalized from the accumulator result');
        final st = await LocalDb.finalizationAudit();
        expect(st.pending, [_d1],
            reason: 'only the finalized day; never an un-derived or open one');
        expect([st.runs, st.diffs], [0, 0]);
      });
    }

    Future<Map<String, Object?>> finalizeUnaudited() async {
      await _engine(CalcPowerMode.maxBattery, _unplugged, tamper: true)
          .run(_profile, heavy: true);
      return _rawRow(_d1);
    }

    test('a later eligible pass runs the pending audit: a late diff logs and '
        'counts but keeps the frozen row', () async {
      final frozen = await finalizeUnaudited();
      final log = <String>[];
      final e = _engine(CalcPowerMode.balanced, _plugged, log: log);
      await e.run(_profile, heavy: true);

      expect(_audit(log).singleWhere((l) => l.contains(_d1)),
          allOf(startsWith('[audit] $_d1 diff '), contains('scalars.rhr')));
      expect(_count(e, 'audit_batch_runs'), 1);
      final st = await LocalDb.finalizationAudit();
      expect(st.pending, isEmpty);
      expect([st.runs, st.diffs], [1, 1]);
      expect(await _rawRow(_d1), frozen,
          reason: 'row, computed_at and all: a frozen row is never rewritten');
    });

    test('a late audit that agrees logs ok and clears the mark', () async {
      await _engine(CalcPowerMode.balanced, _unplugged)
          .run(_profile, heavy: true); // no tamper: stored == batch
      final frozen = await _rawRow(_d1);
      expect((await LocalDb.finalizationAudit()).pending, [_d1]);

      final log = <String>[];
      final n = await _engine(CalcPowerMode.balanced, _plugged, log: log)
          .auditPendingFinalizations(_profile);
      expect(n, 1);
      expect(_audit(log), ['[audit] $_d1 ok']);
      final st = await LocalDb.finalizationAudit();
      expect([st.runs, st.diffs, st.pending], [1, 0, <String>[]]);
      expect(await _rawRow(_d1), frozen);
    });

    test('an ineligible later pass leaves the mark in place', () async {
      await finalizeUnaudited();
      final log = <String>[];
      final n = await _engine(CalcPowerMode.balanced, _unplugged, log: log)
          .auditPendingFinalizations(_profile);
      expect(n, 0);
      expect(_audit(log), isEmpty);
      expect((await LocalDb.finalizationAudit()).pending, [_d1]);
    });

    test('a pending day whose raw is partly pruned is skipped and cleared, no '
        'count', () async {
      await finalizeUnaudited();
      await _db.delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [_sec(2025, 9, 4, 4, 0)]);
      final log = <String>[];
      await _engine(CalcPowerMode.eager, _plugged, log: log)
          .auditPendingFinalizations(_profile);
      expect(_audit(log), ['[audit] $_d1 skipped']);
      final st = await LocalDb.finalizationAudit();
      expect([st.runs, st.diffs, st.pending], [0, 0, <String>[]]);
      expect((await _rawRow(_d1))['finalized'], 1);
    });
  });

  // ── (4) the worker path ────────────────────────────────────────────────────

  group('the audit runs in a worker', () {
    test('the batch re-derive is a cancellable dispatch of the registered '
        'entry auditBatchDay, in another isolate', () async {
      final dispatches = <DispatchEvent>[];
      final entries = <EntryEvent>[];
      WorkerAudit.onDispatch = dispatches.add;
      WorkerAudit.onEntry = entries.add;
      await _engine(CalcPowerMode.balanced, _plugged).run(_profile, heavy: true);
      await pumpEventQueue(); // the workers' reports are in flight, not lost
      WorkerAudit.reset();

      final mine = dispatches
          .where((d) => d.label.startsWith('audit-batch $_d1'))
          .toList();
      expect(mine, hasLength(1));
      expect(mine.single.kind, Dispatcher.cancellable);
      final ran = entries.where((e) => e.dispatchId == mine.single.id);
      expect(ran.map((e) => e.entry), contains('auditBatchDay'));
      expect(ran.map((e) => e.isolateId),
          everyElement(isNot(WorkerAudit.currentIsolateId)));
      expect(
          kWorkerEntries.map((w) => w.symbol), contains(#auditBatchDay));
    });

    test('no worker is dispatched for the audit when power forbids it',
        () async {
      final dispatches = <DispatchEvent>[];
      WorkerAudit.onDispatch = dispatches.add;
      await _engine(CalcPowerMode.maxBattery, _plugged)
          .run(_profile, heavy: true);
      WorkerAudit.reset();
      expect(dispatches.where((d) => d.label.startsWith('audit-batch')),
          isEmpty);
    });
  });

  // ── headless engines (the factory every headless entry builds through) ─────

  group('headless engine factory', () {
    tearDown(() => debugHeadlessPowerSource = null);

    Future<(DerivationEngine, List<String>)> headless(CalcPowerMode? mode,
        PowerSource? power) async {
      SharedPreferences.setMockInitialValues(
          {if (mode != null) Prefs.calcPowerMode: mode.name});
      debugHeadlessPowerSource = power;
      final log = <String>[];
      return (await newHeadlessDerivationEngine(log.add), log);
    }

    test('Eager (saved mode) audits at finalization, even unplugged', () async {
      final (e, log) = await headless(CalcPowerMode.eager, FakePowerSource());
      await e.run(_profile, heavy: true);
      expect(_audit(log), contains('[audit] $_d1 ok'));
      expect((await LocalDb.finalizationAudit()).pending, isEmpty);
    });

    test('Maximum battery marks the finalized day pending, no audit', () async {
      final (e, log) = await headless(
          CalcPowerMode.maxBattery, FakePowerSource(charging: true));
      await e.run(_profile, heavy: true);
      expect(_audit(log), isEmpty);
      expect((await LocalDb.finalizationAudit()).pending, [_d1]);
    });

    test('power that cannot be read counts as not eligible: pending', () async {
      final (e, log) = await headless(CalcPowerMode.balanced, _UnreadablePower());
      await e.run(_profile, heavy: true);
      expect(_audit(log), isEmpty);
      expect((await LocalDb.finalizationAudit()).pending, [_d1]);
    });
  });
}

class _UnreadablePower implements PowerSource {
  @override
  Future<PowerState> read() async => throw StateError('no power channel');

  @override
  Stream<PowerState> get changes => const Stream.empty();
}
