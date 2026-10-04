// End to end through `DerivationEngine.run`: a periodic awake pass over newly
// appended records must reuse the previous pass's state and store the same day
// a forced full derive stores. The pass-level tests elsewhere call the day
// pipeline directly; this is the path the scheduler takes.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/incremental_compare.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

int _counter = 1;

/// One 1 Hz record with moving accel, varying HR and an RR beat.
Future<void> _record(int ts) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'run$c',
      capturedAt: ts * 1000,
      recTs: ts,
    ),
    Sample(
      tsEpoch: ts,
      counter: c,
      hr: 70 + (c ~/ 60) % 50 + c % 3,
      rrIntervalsMs: [800 + (c % 7) * 9],
      ax: .2 * math.sin(c * .27),
      ay: .1 * math.cos(c * .17),
      az: 1 + .03 * math.sin(c * .09),
      spo2RedRaw: 1,
      spo2IrRaw: 1,
      skinTempRaw: 3000,
    ),
  );
}

/// The newest stored result for [day], without the fields that record when
/// it was written rather than what was derived.
Future<Map<String, dynamic>> _stored(String day) async {
  final row = (await LocalDb.dayResult(day))!;
  final payload = jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
  payload.remove('computed_at');
  return {
    'payload': payload,
    for (final k in ['rhr', 'rmssd', 'readiness', 'partial', 'finalized'])
      k: row[k],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'incremental_engine_run_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('awake run() passes reuse state and store the forced result', () async {
    // Yesterday from 08:00: a pending, never-finalized day for the light pass,
    // whatever time of day the test runs.
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day - 1);
    final day = dayLabelOf(midnight);
    final start = midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 1800; i++) {
      await _record(start + i);
    }

    final awake = DerivationEngine();
    Future<void> awakePass() => awake.run(
      _profile,
      calculationMode: ana.CalculationMode.periodicAwake,
    );
    await awakePass();
    final first = awake.debugCalculationState(day);
    expect(first, isNotNull, reason: 'the light pass derived $day');

    // Five more minutes arrive; the next periodic pass appends them.
    for (var i = 1800; i < 2100; i++) {
      await _record(start + i);
    }
    await awakePass();
    final second = awake.debugCalculationState(day)!;
    expect(second.hits, greaterThan(first!.hits),
        reason: 'the second awake pass reused cached results');
    expect(second.minutes - first.minutes, lessThanOrEqualTo(6),
        reason: 'only the appended minutes (and the open one) were priced');
    final reused = await _stored(day);
    final scalars = (reused['payload'] as Map)['scalars'] as Map;
    // Guard against comparing two empty days: the activity figures exist.
    for (final key in ['strain', 'calories', 'calories_total', 'active_min']) {
      expect(scalars[key], isNotNull, reason: key);
    }

    // Oracle: a fresh engine forced to recompute the same day from scratch.
    final full = DerivationEngine();
    await full.run(_profile, force: true);
    expect(full.debugCalculationState(day)!.hits, 0);
    final oracle = await _stored(day);

    expectSameJson(reused, oracle);
  });
}
