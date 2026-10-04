// Cache benchmark: which calculation-cache entries are reused on periodic awake
// passes, and what each costs. Opt-in (slow): INCREMENTAL_BENCH=1.
//
// A 16 h awake day is appended in 5-minute steps after a full seed pass, as a
// periodic pass would see it. Every pass is also run without a state, so the
// printed totals compare reuse with the original full computation.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

import 'support/incremental_activity_fixture.dart';
import 'support/incremental_day_fixture.dart';

const _profile = Profile(
  ageYears: 35,
  weightKg: 75,
  heightCm: 178,
  sex: 'male',
);
const _awakeSeconds = 16 * 3600;
const _nightSeconds = 8 * 3600;
const _stepSeconds = 300;
const _passes = 6;

void _pass(
  Substrate s,
  Map<String, dynamic> input,
  DayCalculationState? state,
  ana.CalculationMode mode,
) {
  deriveDayBundle(copyDay(input), state: state, mode: mode);
  final start = s.tsSec.first;
  DerivationEngine.applyDayActivity(
    bundle: <String, dynamic>{},
    scalars: <String, dynamic>{},
    daySub: s,
    profile: _profile,
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    dayStartSec: start,
    dayCalendarEndSec: start + 86400,
    dataNowSec: s.tsSec.last + 1,
    restingHr: 54,
    dynFloorG: .03,
    dynHistoryDays: 14,
    liveStepsReal: 0,
    liveStepsFromStrap: 0,
    state: state,
    mode: mode,
  );
  DerivationEngine.dayHrvCurve(s, state: state, mode: mode);
  DerivationEngine.dayRespCurve(s, state: state, mode: mode);
}

void main() {
  test(
    'periodic awake cache benchmark',
    () {
      final state = DayCalculationState();
      final first = _awakeSeconds - _passes * _stepSeconds;
      Substrate sub(int n) => incrementalActivity(seconds: n);
      Map<String, dynamic> day(int n) =>
          incrementalDay(daySeconds: n, nightSeconds: _nightSeconds);

      _pass(sub(first), day(first), state, ana.CalculationMode.sleep);
      state.debugStats = {};
      var oracleMs = 0, awakeMs = 0;
      for (var p = 1; p <= _passes; p++) {
        final n = first + p * _stepSeconds;
        final s = sub(n), input = day(n);
        final w = Stopwatch()..start();
        _pass(s, input, null, ana.CalculationMode.forced);
        oracleMs += w.elapsedMilliseconds;
        w.reset();
        _pass(s, input, state, ana.CalculationMode.periodicAwake);
        awakeMs += w.elapsedMilliseconds;
      }
      final rows = state.debugStats!.entries.toList()
        ..sort((a, b) => b.value.micros.compareTo(a.value.micros));
      final out = StringBuffer()
        ..writeln('passes=$_passes oracle=${oracleMs}ms awake=${awakeMs}ms')
        ..writeln('key\thits\tmisses\tms');
      for (final r in rows) {
        out.writeln(
          '${r.key}\t${r.value.hits}\t${r.value.misses}\t'
          '${(r.value.micros / 1000).toStringAsFixed(1)}',
        );
      }
      // ignore: avoid_print
      print(out);
    },
    skip: Platform.environment['INCREMENTAL_BENCH'] != '1',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
