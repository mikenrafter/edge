import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/incremental_activity_fixture.dart';

const _profile = Profile(ageYears: 35, weightKg: 75, heightCm: 178,
    sex: 'male', restingHrManual: 54);

PreparedDerivationDay _day(String label, {int seconds = 601}) {
  final source = incrementalActivity(seconds: seconds, moving: false);
  final oldStart = source.tsSec.first;
  final newStart = DateTime.parse('${label}T08:00:00').millisecondsSinceEpoch ~/ 1000;
  // Use the public constructor to make the clock shift explicit, keeping RR
  // endpoints aligned to the same wall clock as the 1 Hz series.
  final s = Substrate(
    tsSec: [for (final t in source.tsSec) t + newStart - oldStart],
    hr: source.hr, rrMs: source.rrMs,
    rrTsMs: [for (final t in source.rrTsMs) t + (newStart - oldStart) * 1000],
    ax: source.ax, ay: source.ay, az: source.az,
    spo2Red: source.spo2Red, spo2Ir: source.spo2Ir,
    skinTemp: source.skinTemp, skinContact: source.skinContact,
    deviceFamily: 'gen4',
  );
  return PreparedDerivationDay(date: label, endSec: s.tsSec.last + 1,
    confidence: .8, flags: const [], sleepJson: const {},
    hypnoStages: const [], sleepOnsetSec: 0, sleepOffsetSec: 0,
    daySub: s, sleepSub: Substrate.empty);
}

Future<void> _derive(DerivationEngine engine, PreparedDerivationDay day,
    {ana.CalculationMode mode = ana.CalculationMode.periodicAwake}) =>
    engine.debugDerivePreparedDay(day, _profile, day.endSec,
        calculationMode: mode);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'incremental_engine_state_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('both worker copies publish after complete day and wake writes', () async {
    final engine = DerivationEngine();
    final day = _day('2026-06-01');
    engine.debugAfterDayBlocks = (_) async {
      expect(engine.debugCalculationState(day.date), isNull);
      expect(await LocalDb.dayResult(day.date), isNull);
    };
    await _derive(engine, day);
    final first = engine.debugCalculationState(day.date)!;
    expect(first.computations, greaterThan(0));
    expect(first.minutes, 11, reason: 'two workers share identical minute bills');
    expect((await LocalDb.dayResult(day.date))!['partial'], 0);
    expect(await LocalDb.wakeDayFeatures(day.date), isNotNull);
    final payload = jsonDecode((await LocalDb.dayResult(day.date))!['payload_json'] as String) as Map;
    expect(payload.containsKey('calculation_state'), isFalse);
    engine.debugAfterDayBlocks = (_) async {
      expect(engine.debugCalculationState(day.date), first,
          reason: 'main-isolate state survives worker mutations until persistence');
    };
    await _derive(engine, day);
    final second = engine.debugCalculationState(day.date)!;
    expect(second.hits, greaterThan(first.hits));
    expect(second.minutes, first.minutes);
    expect(second.computations, first.computations);
  });

  test('second-half failure leaves no candidate, then retry publishes', () async {
    final engine = DerivationEngine();
    final day = _day('2026-06-02');
    engine.debugAfterDayBlocks = (_) async => throw TimeoutException('second half');
    await _derive(engine, day);
    expect(engine.debugCalculationState(day.date), isNull);
    expect((await LocalDb.dayResult(day.date))!['partial'], 1);
    engine.debugAfterDayBlocks = null;
    await _derive(engine, day);
    expect(engine.debugCalculationState(day.date), isNotNull);
    expect((await LocalDb.dayResult(day.date))!['partial'], 0);
    final first = engine.debugCalculationState(day.date);
    engine.debugAfterDayBlocks = (_) async => throw StateError('retry failed');
    await _derive(engine, _day(day.date, seconds: 661));
    expect(engine.debugCalculationState(day.date), first,
        reason: 'carry-forward detail cannot publish the failed candidate');
    engine.debugAfterDayBlocks = null;
    await _derive(engine, _day(day.date, seconds: 661));
    expect(engine.debugCalculationState(day.date)!.minutes, first!.minutes + 1);
  });

  test('required wake-feature write failure retains the old worker checkpoint', () async {
    final engine = DerivationEngine();
    final day = _day('2026-06-03');
    await _derive(engine, day);
    final before = engine.debugCalculationState(day.date);
    final db = await LocalDb.instance;
    await db.execute("CREATE TRIGGER reject_wake BEFORE INSERT ON wake_day_features BEGIN SELECT RAISE(ABORT, 'write failed'); END");
    try {
      await _derive(engine, _day(day.date, seconds: 661));
      expect(engine.debugCalculationState(day.date), before);
    } finally {
      await db.execute('DROP TRIGGER reject_wake');
    }
    await _derive(engine, _day(day.date, seconds: 661));
    expect(engine.debugCalculationState(day.date)!.minutes, before!.minutes + 1);
  });

  test('day-result write failure discards candidate and retry reuses prior state', () async {
    final engine = DerivationEngine();
    final day = _day('2026-06-04');
    await _derive(engine, day);
    final before = engine.debugCalculationState(day.date);
    final rowBefore = await LocalDb.dayResult(day.date);
    final db = await LocalDb.instance;
    await db.execute("CREATE TRIGGER reject_day BEFORE INSERT ON day_result BEGIN SELECT RAISE(ABORT, 'write failed'); END");
    try {
      await expectLater(_derive(engine, _day(day.date, seconds: 661)), throwsA(anything));
      expect(engine.debugCalculationState(day.date), before);
      expect(await LocalDb.dayResult(day.date), rowBefore);
    } finally {
      await db.execute('DROP TRIGGER reject_day');
    }
    await _derive(engine, _day(day.date, seconds: 661));
    expect(engine.debugCalculationState(day.date)!.minutes, before!.minutes + 1);
  });

  for (final mode in [ana.CalculationMode.sleep, ana.CalculationMode.heavy,
      ana.CalculationMode.forced]) {
    test('$mode traverses both workers with every cache bypassed', () async {
      final engine = DerivationEngine();
      final day = _day('2026-07-01');
      await _derive(engine, day);
      final first = engine.debugCalculationState(day.date)!;
      await _derive(engine, day, mode: mode);
      final second = engine.debugCalculationState(day.date)!;
      expect(second.hits, first.hits);
      expect(second.computations, greaterThan(first.computations));
      expect(second.minutes, first.minutes + 22);
    });
  }

  test('only three newest day states survive a historical pass', () async {
    final engine = DerivationEngine();
    for (final label in ['2026-08-04', '2026-08-03', '2026-08-02', '2026-08-01']) {
      await _derive(engine, _day(label, seconds: 61));
    }
    expect(engine.debugCalculationStateDays,
        ['2026-08-02', '2026-08-03', '2026-08-04']);
  });
}
