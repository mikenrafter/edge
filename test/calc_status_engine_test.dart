// A derivation pass reports where it is, in plain words, and clears.
//
// API: lib/compute/calc_status.dart (see calc_status_test.dart). The
// engine reports on CalcStatus.instance, on the MAIN isolate, around its
// existing `_diag['stage']` transitions, with these EXACT labels:
//
//   stage            label
//   scope            "Reading recordings"
//   history          "Reading recordings"
//   per_day          "Day calculations"
//   (staging call)   "Sleep stages"       nested INSIDE "Day calculations",
//                                         around the sleep-staging isolate call
//   baselines        "Baselines"
//   cross_day        "Trends across days"
//   notifications    "Notifications"
//   prune            "Tidying up"
//   housekeeping     "Tidying up"
//   strain_rescale   "Strain rescale"
//   idle             (nothing open: CalcStatus.instance.value == null)
//
// Adjacent stages with the same label (scope+history, prune+housekeeping) may
// be one step or two; this test collapses repeats. A stage the pass does not
// reach (no day computed => no Baselines/Trends/Notifications) is not reported.
//
// Every exit clears: a pass that throws, or finds nothing to do, ends with
// CalcStatus.instance.value == null (AGENTS.md 4.3).

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/calc_status.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
  restingHrManual: 54,
);

const _db = 'calc_status_engine_test.db';
int _counter = 1;

Future<void> _record(int ts) async {
  final c = _counter++;
  await LocalDb.insertRecord(
    RawRecord(
      counter: c,
      packetType: 47,
      hex: 'status$c',
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

/// Labels in the order they became visible: nulls dropped, repeats collapsed.
List<String> _collapse(List<String?> raw) {
  final out = <String>[];
  for (final l in raw) {
    if (l == null) continue;
    if (out.isEmpty || out.last != l) out.add(l);
  }
  return out;
}

const _known = {
  'Reading recordings',
  'Day calculations',
  'Sleep stages',
  'Baselines',
  'Trends across days',
  'Notifications',
  'Tidying up',
  'Strain rescale',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String?> seen;
  late void Function() listener;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _db;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, _db));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, _db));
  });

  setUp(() {
    seen = [];
    listener = () => seen.add(CalcStatus.instance.value?.label);
    CalcStatus.instance.addListener(listener);
  });
  tearDown(() => CalcStatus.instance.removeListener(listener));

  test('a pass that finds nothing to do reports and returns to idle',
      () async {
    // Empty database: the pass ends early ("no decoded data").
    final engine = DerivationEngine();
    await engine.run(_profile, calculationMode: ana.CalculationMode.periodicAwake);
    expect(CalcStatus.instance.value, isNull);
    final labels = _collapse(seen);
    expect(labels, isNotEmpty, reason: 'it at least reported the read');
    expect(labels.first, 'Reading recordings');
    expect(labels.toSet().difference(_known), isEmpty,
        reason: 'only the plain labels');
  });

  test('a throwing pass clears the status', () async {
    final engine = DerivationEngine()
      ..debugScopeHook = () async => throw StateError('scope exploded');
    await engine.run(_profile, calculationMode: ana.CalculationMode.periodicAwake);
    expect(CalcStatus.instance.value, isNull);
    expect(_collapse(seen).first, 'Reading recordings');
  });

  test('a computing pass reports the stage sequence with the plain labels, '
      'sleep staging inside the day calculations, and ends idle', () async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day - 1);
    final start =
        midnight.add(const Duration(hours: 8)).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 1800; i++) {
      await _record(start + i);
    }
    seen.clear();

    final engine = DerivationEngine();
    final done = await engine.run(_profile,
        calculationMode: ana.CalculationMode.periodicAwake);
    expect(done, greaterThan(0),
        reason: 'the fixture day (${dayLabelOf(midnight)}) was computed');

    final labels = _collapse(seen);
    expect(labels.toSet().difference(_known), isEmpty,
        reason: 'only the plain labels: $labels');

    // The top-level stages, in order (Sleep stages is a nested step and is
    // checked on its own below).
    final top = [for (final l in labels) if (l != 'Sleep stages') l];
    int at(String l) => top.indexOf(l);
    const order = [
      'Reading recordings',
      'Day calculations',
      'Baselines',
      'Trends across days',
      'Notifications',
      'Tidying up',
      'Strain rescale',
    ];
    for (final l in order) {
      expect(at(l), isNonNegative, reason: '"$l" was reported: $labels');
    }
    for (var i = 1; i < order.length; i++) {
      expect(at(order[i]), greaterThan(at(order[i - 1])),
          reason: '"${order[i - 1]}" then "${order[i]}": $labels');
    }

    // Sleep staging is its own step, inside the day calculations.
    final stages = labels.indexOf('Sleep stages');
    expect(stages, isNonNegative, reason: 'staging reported: $labels');
    expect(labels.indexOf('Day calculations'), lessThan(stages));
    expect(stages, lessThan(labels.indexOf('Baselines')));

    expect(CalcStatus.instance.value, isNull, reason: 'idle after the pass');
    expect(seen.last, isNull, reason: 'and the last notification was the clear');
  });

  test('a second pass over the same, now unchanged, data still ends idle',
      () async {
    final engine = DerivationEngine();
    seen.clear();
    await engine.run(_profile, calculationMode: ana.CalculationMode.periodicAwake);
    expect(CalcStatus.instance.value, isNull);
    expect(_collapse(seen).toSet().difference(_known), isEmpty);
  });
}
