// The engine folds a resumed day's beat tail through the registered entry
// `foldDayTailHeavy` (design 02, phase 1 RED), engine layer: a real database,
// a fresh engine per pass (a headless wake), and a forced full pass as the
// oracle for what is persisted.
//
// Today the resumed pass hands `_foldTail`'s inline closure to
// `_runIsolateCancellable`: the persisted output is right (the existing
// day_stream_checkpoint_engine_test pins that and stays green), but no
// registered entry runs in the worker, so the dispatcher audit sees none. What
// this file pins, with the audit hook the background-dispatch test uses:
//
//  * the resumed pass's "day-stream" dispatch runs `foldDayTailHeavy` INSIDE a
//    worker isolate (not the dispatching one);
//  * what is persisted after the resumed pass - the whole `day_result` payload
//    (so `clinical.irregular_24h` with its PRV `diagnostics`, `hrv_day`,
//    `resp_day`, `daytime_hrv`), the `metric_series` rows and the checkpoint
//    bytes - equals what a forced full pass over the same rows persists;
//  * a first pass (no checkpoint) dispatches no day-stream fold at all.
//
// The data is a fixed past day (no wall clock in it): finalization is anchored
// on the data edge, not the clock.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/util/worker_audit.dart';
import 'package:openstrap_edge/util/worker_entries.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/day_stream_fixture.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 08:00 UTC on a fixed day: a closed-bucket boundary.
  final start = DateTime.utc(2026, 1, 10, 8).millisecondsSinceEpoch ~/ 1000;
  final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000));
  // Three hours first, then twenty minutes more: the tail is a small part.
  const first = 3 * 3600;
  const second = first + 1200;

  final beats = synthBeats(SynthBeats(
    seed: 17,
    startSec: start,
    seconds: 4 * 3600,
    irregularBurst: (4000, 7000),
  ));
  final accel = synthAccel(23, start, start + 4 * 3600 + 60);

  final entries = <EntryEvent>[];
  final dispatches = <DispatchEvent>[];

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'day_tail_fold_engine_test.db';
  });

  setUp(() async {
    await wipe();
    entries.clear();
    dispatches.clear();
  });

  tearDown(WorkerAudit.reset);
  tearDownAll(wipe);

  Future<void> rows(int from, int to) =>
      writeSeconds(beats, accel, start + from, start + to);

  Future<Map<String, dynamic>> stored() async {
    final row = (await LocalDb.dayResult(day))!;
    final payload =
        jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
    payload.remove('computed_at');
    final db = await LocalDb.instance;
    final series = await db.query('metric_series',
        where: 'date = ?', whereArgs: [day], orderBy: 'key');
    return {
      'payload': payload,
      for (final k in ['rhr', 'rmssd', 'readiness', 'partial', 'finalized'])
        k: row[k],
      'series': {for (final r in series) r['key'] as String: r['value']},
    };
  }

  /// One fresh engine's pass with the audit hook installed; its checkpoint line.
  Future<String> auditedPass() async {
    WorkerAudit.onDispatch = dispatches.add;
    WorkerAudit.onEntry = entries.add;
    final log = <String>[];
    await DerivationEngine(log: log.add).run(_profile);
    await pumpEventQueue(); // the workers' reports are in flight, not lost
    WorkerAudit.reset();
    return log.singleWhere((l) => l.contains('[perf] checkpoint $day')).trim();
  }

  Iterable<DispatchEvent> dayStreamDispatches() =>
      dispatches.where((d) => d.label.startsWith('day-stream'));

  test('a first pass (no checkpoint) folds no day-stream tail', () async {
    await rows(0, first);
    expect(await auditedPass(), contains('full none'));
    expect(dayStreamDispatches(), isEmpty);
    expect(entries.map((e) => e.entry), isNot(contains('foldDayTailHeavy')));
  });

  test('a resumed pass folds its tail in the registered entry, in a worker, '
      'and stores what a forced full pass stores', () async {
    await rows(0, first);
    await auditedPass();
    expect((await LocalDb.dayCheckpoint(day, kAlgoVersion)), isNotNull);

    await rows(first, second);
    entries.clear();
    dispatches.clear();
    final line = await auditedPass();
    expect(line, matches(RegExp(r'resume folded=\d+')),
        reason: 'fixture: the second pass resumes from the checkpoint');

    expect(dayStreamDispatches(), hasLength(1),
        reason: 'the resumed pass dispatches its tail fold once');
    expect(dayStreamDispatches().single.kind, Dispatcher.cancellable);
    final fold = entries.where((e) => e.entry == 'foldDayTailHeavy').toList();
    expect(fold, hasLength(1),
        reason: 'the day-stream dispatch ran the registered entry (today it '
            'runs an inline closure, which reports no entry)');
    expect(fold.single.isolateId, isNot(WorkerAudit.currentIsolateId),
        reason: 'inside a worker isolate, not the dispatching one');

    final resumed = await stored();
    final screen = ((resumed['payload'] as Map)['clinical'] as Map)['irregular_24h']
        as Map;
    expect(screen['diagnostics'], isA<Map>(),
        reason: 'the PRV diagnostics are persisted with the screen');
    final cp = (await LocalDb.dayCheckpoint(day, kAlgoVersion))!;

    await DerivationEngine().run(_profile, force: true); // the oracle
    expect(await stored(), equals(resumed),
        reason: 'resuming changes no stored figure, diagnostics included');
    expect((await LocalDb.dayCheckpoint(day, kAlgoVersion))!.state, cp.state,
        reason: 'resumed-then-advanced is byte-identical to folded at once');
  });
}
