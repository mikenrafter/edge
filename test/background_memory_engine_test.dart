// Background memory at the engine: which day states stay between passes.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';
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
  final newStart =
      DateTime.parse('${label}T08:00:00').millisecondsSinceEpoch ~/ 1000;
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
        {int? dataNowSec,
        ana.CalculationMode mode = ana.CalculationMode.periodicAwake}) =>
    engine.debugDerivePreparedDay(day, _profile, dataNowSec ?? day.endSec,
        calculationMode: mode);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'background_memory_engine_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });
  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a finalized day keeps no state, and drops the one it had', () async {
    final engine = DerivationEngine();
    final day = _day('2026-05-01');
    await _derive(engine, day);
    expect(engine.debugCalculationStateDays, ['2026-05-01']);
    // The data edge is 49 h past the day: it finalizes.
    await _derive(engine, day, dataNowSec: day.endSec + 49 * 3600);
    expect((await LocalDb.dayResult(day.date))!['finalized'], 1);
    expect(engine.debugCalculationStateDays, isEmpty);
  });

  test('a backgrounded engine keeps only the newest day state', () async {
    var background = false;
    final engine = DerivationEngine(isBackgrounded: () => background);
    for (final label in ['2026-05-12', '2026-05-11', '2026-05-10']) {
      await _derive(engine, _day(label, seconds: 61));
    }
    expect(engine.debugCalculationStateDays,
        ['2026-05-10', '2026-05-11', '2026-05-12'],
        reason: 'the foreground keeps three, as before');
    background = true;
    await _derive(engine, _day('2026-05-12', seconds: 121));
    expect(engine.debugCalculationStateDays, ['2026-05-12']);
    expect(engine.debugCalculationState('2026-05-12')!.minutes, greaterThan(0));
  });

  test('trimForBackground drops older days and leaves nothing sample-sized',
      () async {
    final engine = DerivationEngine();
    for (final label in ['2026-05-22', '2026-05-21', '2026-05-20']) {
      await _derive(engine, _day(label, seconds: 301));
    }
    engine.trimForBackground();
    expect(engine.debugCalculationStateDays, ['2026-05-22']);
    expect(engine.debugRetainedSamples, lessThan(100));
  });

  test('the foreground after a trim derives the same day result', () async {
    Future<String> run({required bool trim}) async {
      final engine = DerivationEngine();
      await _derive(engine, _day('2026-06-10'));
      if (trim) engine.trimForBackground();
      await _derive(engine, _day('2026-06-10', seconds: 661));
      final row = (await LocalDb.dayResult('2026-06-10'))!;
      return row['payload_json'] as String;
    }

    final plain = await run(trim: false);
    final trimmed = await run(trim: true);
    expect(trimmed, plain);
  });

  test('the memory log line carries rss and what the engine holds', () {
    expect(
        DerivePerf.memLine(
            rssBytes: 150 * 1024 * 1024,
            states: 1,
            retainedSamples: 12,
            cacheComputations: 30,
            cacheHits: 29),
        'rss=150.0MB dayStates=1 retainedSamples=12 cacheComputed=30 cacheHits=29');
  });
}
