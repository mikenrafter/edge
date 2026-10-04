// The intraday calorie curve (`kcal_minutes|<day>`) next to the incremental
// minute metrics. An automatic light pass (`changedOnly` plus reuse) prices the
// day's calories through `IncrementalMinuteMetrics`; the curve is built from
// the batch minute series. Its active minutes must still add up to the stored
// daily active figure, and the whole result must match a forced derive.
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

Future<void> _record(int ts) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'kcal$c',
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

Future<Map<String, dynamic>> _scalars(String day) async {
  final row = (await LocalDb.dayResult(day))!;
  final body = jsonDecode(row['payload_json'] as String) as Map;
  return (body['scalars'] as Map).cast<String, dynamic>();
}

Future<Map<String, dynamic>> _curve(String day) async {
  final db = await LocalDb.instance;
  final rows = await db.rawQuery(
    'SELECT payload_json FROM last_result WHERE key = ?',
    ['kcal_minutes|$day'],
  );
  expect(rows, hasLength(1), reason: 'the derive stored the curve');
  return (jsonDecode(rows.single['payload_json'] as String) as Map)
      .cast<String, dynamic>();
}

double _sumActive(Map<String, dynamic> curve) => [
      for (final m in curve['minutes'] as List)
        ((m as Map)['active'] as num?)?.toDouble() ?? 0.0,
    ].fold(0.0, (a, b) => a + b);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'incremental_kcal_curve_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('after incremental changedOnly passes the curve still folds back to '
      'the stored active calories and matches a forced derive', () async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day - 1);
    final day = dayLabelOf(midnight);
    final start =
        midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 1800; i++) {
      await _record(start + i);
    }

    // The automatic light pass: narrowed to changed days, reuse allowed.
    final awake = DerivationEngine();
    Future<void> lightPass() => awake.run(
      _profile,
      changedOnly: true,
      calculationMode: ana.CalculationMode.periodicAwake,
    );
    await lightPass();
    for (var i = 1800; i < 2100; i++) {
      await _record(start + i);
    }
    await lightPass();
    final state = awake.debugCalculationState(day)!;
    expect(state.hits, greaterThan(0), reason: 'the second pass reused state');

    final reused = await _scalars(day);
    final curve = await _curve(day);
    expect(reused['calories'], isNotNull);
    expectRelClose(_sumActive(curve), reused['calories'] as num,
        reason: 'curve active minutes against the stored daily active');

    final full = DerivationEngine();
    await full.run(_profile, force: true);
    final oracle = await _scalars(day);
    expectRelClose(reused['calories'] as num, oracle['calories'] as num);
    expectRelClose(
        reused['calories_total'] as num, oracle['calories_total'] as num);
    expectSameJson(await _curve(day), curve);
  });
}
