// Background memory: the incremental day state keeps compact running summaries,
// not copies of the day's samples, and every figure still equals a batch
// recompute bit for bit.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_activity_state.dart';
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/state_fingerprint.dart';
import 'package:openstrap_edge/compute/substrate.dart';

import 'support/incremental_activity_fixture.dart';

const _day = 86400;
const _profile = Profile(ageYears: 35, weightKg: 75, heightCm: 178, sex: 'male');

/// 2026-03-29 00:00 UTC: the day Europe changes its clocks, so a local day
/// there is 23 h. The summaries key on epoch minutes and never see a zone.
final _t0 = DateTime.utc(2026, 3, 29).millisecondsSinceEpoch ~/ 1000;

({List<int> ts, List<int> hr}) _hrDay({int seconds = _day, int skip = -1}) {
  final ts = <int>[], hr = <int>[];
  for (var i = 0; i < seconds; i++) {
    if (skip >= 0 && i >= skip && i < skip + 900) continue;
    ts.add(_t0 + i);
    hr.add(i % 97 == 96 ? 0 : [58, 64, 71, 96, 118, 152][(i ~/ 300) % 6] + i % 3);
  }
  return (ts: ts, hr: hr);
}

void _expectHrEqual(DayHrSummary a, DayHrSummary b) {
  expect(a.hrStats(), b.hrStats());
  expect(a.wakeHr, b.wakeHr);
  final x = a.wakeMinutes(), y = b.wakeMinutes();
  expect(x.keys, y.keys);
  expect(x.hr, y.hr);
}

DayHrSummary _batchHr(List<int> ts, List<int> hr,
    {int on = 0, int off = 0, int? age = 35}) {
  return DayHrSummary()
    ..sync(ts, hr, sleepOnsetSec: on, sleepOffsetSec: off, age: age);
}

void main() {
  group('DayHrSummary', () {
    test('a full day folds in and keeps no sample copy', () {
      final d = _hrDay();
      final s = DayHrSummary()
        ..sync(d.ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      expect(s.processedSamples, _day);
      expect(s.retainedSamples, lessThan(100),
          reason: 'only the smoothing window may stay');
    });

    test('tail-only passes fold in only the new samples and equal the batch', () {
      final d = _hrDay();
      final s = DayHrSummary();
      for (var n = 3600; n <= _day; n += 1800) {
        s.sync(d.ts.sublist(0, n), d.hr.sublist(0, n),
            sleepOnsetSec: _t0 + 6 * 3600,
            sleepOffsetSec: _t0 + 7 * 3600,
            age: 35);
        _expectHrEqual(
            s,
            _batchHr(d.ts.sublist(0, n), d.hr.sublist(0, n),
                on: _t0 + 6 * 3600, off: _t0 + 7 * 3600));
      }
      expect(s.processedSamples, _day,
          reason: 'every sample folded in exactly once');
    });

    test('a replaced earlier sample rebuilds to the batch value', () {
      final d = _hrDay();
      final s = DayHrSummary()
        ..sync(d.ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      final changed = List<int>.of(d.hr)..[1000] = 199;
      s.sync(d.ts, changed, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      _expectHrEqual(s, _batchHr(d.ts, changed));
      expect(s.processedSamples, 2 * _day, reason: 'rebuilt from the start');
    });

    test('a counter reset (timestamps step back) rebuilds to the batch value', () {
      final d = _hrDay();
      final s = DayHrSummary()
        ..sync(d.ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      // The band restarted its clock: everything from 40 000 s on is re-stamped
      // earlier, as INSERT-OR-REPLACE on rec_ts leaves it.
      final ts = List<int>.of(d.ts);
      for (var i = 40000; i < ts.length; i++) {
        ts[i] -= 5000;
      }
      s.sync(ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      _expectHrEqual(s, _batchHr(ts, d.hr));
    });

    test('a gap, a changed sleep window and a changed age rebuild', () {
      final d = _hrDay(skip: 30000);
      final s = DayHrSummary()
        ..sync(d.ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      s.sync(d.ts, d.hr,
          sleepOnsetSec: _t0 - 3600, sleepOffsetSec: _t0 + 7 * 3600, age: 35);
      _expectHrEqual(
          s, _batchHr(d.ts, d.hr, on: _t0 - 3600, off: _t0 + 7 * 3600));
      s.sync(d.ts, d.hr,
          sleepOnsetSec: _t0 - 3600, sleepOffsetSec: _t0 + 7 * 3600, age: 80);
      _expectHrEqual(
          s, _batchHr(d.ts, d.hr, on: _t0 - 3600, off: _t0 + 7 * 3600, age: 80));
    });

    test('a shorter day (rows removed) rebuilds', () {
      final d = _hrDay();
      final s = DayHrSummary()
        ..sync(d.ts, d.hr, sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      s.sync(d.ts.sublist(0, 5000), d.hr.sublist(0, 5000),
          sleepOnsetSec: 0, sleepOffsetSec: 0, age: 35);
      _expectHrEqual(s, _batchHr(d.ts.sublist(0, 5000), d.hr.sublist(0, 5000)));
    });
  });

  group('DayMotionSummary', () {
    ({List<int> ts, List<double> x, List<double> y, List<double> z}) motion(
        {int seconds = _day}) {
      final ts = <int>[], x = <double>[], y = <double>[], z = <double>[];
      for (var i = 0; i < seconds; i++) {
        ts.add(_t0 + i + (i > 50000 ? 400 : 0));
        x.add(.16 * (i % 61 < 30 ? 1 : -1) * (i % 7) / 7);
        y.add(.09 * (i % 13) / 13);
        z.add(i % 211 == 0 ? double.nan : 1.0 - .03 * (i % 5) / 5);
      }
      return (ts: ts, x: x, y: y, z: z);
    }

    DayMotionSummary batch(
            ({List<int> ts, List<double> x, List<double> y, List<double> z}) m,
            {int on = 0,
            int off = 0}) =>
        DayMotionSummary()
          ..sync(m.ts, m.x, m.y, m.z, sleepOnsetSec: on, sleepOffsetSec: off);

    void expectEqual(DayMotionSummary a, DayMotionSummary b) {
      expect(a.activeMinutes(), b.activeMinutes());
      expect(jsonEncode(a.activityCurve()), jsonEncode(b.activityCurve()));
      expect(a.wearRuns(), b.wearRuns());
    }

    test('a full day folds in and keeps no sample copy', () {
      final m = motion();
      final s = batch(m);
      expect(s.processedSamples, _day);
      expect(s.length, _day);
      expect(s.retainedSamples, lessThan(100));
    });

    test('tail passes, a replaced sample and a counter reset equal the batch', () {
      final m = motion();
      final s = DayMotionSummary();
      for (final n in [3600, 10800, 50000, 82800, _day]) {
        s.sync(m.ts.sublist(0, n), m.x.sublist(0, n), m.y.sublist(0, n),
            m.z.sublist(0, n),
            sleepOnsetSec: _t0, sleepOffsetSec: _t0 + 6 * 3600);
      }
      expect(s.processedSamples, _day);
      expectEqual(s, batch(m, on: _t0, off: _t0 + 6 * 3600));

      final x = List<double>.of(m.x)..[2000] = 3.5;
      s.sync(m.ts, x, m.y, m.z,
          sleepOnsetSec: _t0, sleepOffsetSec: _t0 + 6 * 3600);
      expectEqual(
          s,
          batch((ts: m.ts, x: x, y: m.y, z: m.z),
              on: _t0, off: _t0 + 6 * 3600));

      final ts = List<int>.of(m.ts);
      for (var i = 60000; i < ts.length; i++) {
        ts[i] -= 9000;
      }
      s.sync(ts, x, m.y, m.z,
          sleepOnsetSec: _t0, sleepOffsetSec: _t0 + 6 * 3600);
      expectEqual(
          s,
          batch((ts: ts, x: x, y: m.y, z: m.z), on: _t0, off: _t0 + 6 * 3600));
    });
  });

  group('dependency fingerprints', () {
    test('equal dependencies match, any difference does not', () {
      final a = [
        1.5,
        [1, 2, 3],
        {'k': 2.0, 'j': 'x'},
        null,
        true,
        double.nan,
      ];
      final same = [
        1.5,
        [1, 2, 3],
        {'j': 'x', 'k': 2.0},
        null,
        true,
        double.nan,
      ];
      expect(dependencyFingerprint(a), dependencyFingerprint(same));
      expect(dependencyFingerprint([0.0]), dependencyFingerprint([-0.0]));
      for (final other in [
        [1.5000001, [1, 2, 3], {'k': 2.0, 'j': 'x'}, null, true, double.nan],
        [1.5, [1, 2, 4], {'k': 2.0, 'j': 'x'}, null, true, double.nan],
        [1.5, [1, 3, 2], {'k': 2.0, 'j': 'x'}, null, true, double.nan],
        [1.5, [1, 2], {'k': 2.0, 'j': 'x'}, null, true, double.nan],
        [1.5, [1, 2, 3], {'k': 2.0, 'j': 'y'}, null, true, double.nan],
        [1.5, [1, 2, 3], {'k': 2.0, 'j': 'x'}, null, false, double.nan],
        [1.5, [[1], 2, 3], {'k': 2.0, 'j': 'x'}, null, true, double.nan],
      ]) {
        expect(dependencyFingerprint(a), isNot(dependencyFingerprint(other)));
      }
    });

    test('a long array changes its fingerprint on a one-element edit', () {
      final base = [for (var i = 0; i < 20000; i++) i * .5];
      final edited = List<double>.of(base)..[12345] += 1e-12;
      expect(dependencyFingerprint(base), isNot(dependencyFingerprint(edited)));
      expect(dependencyFingerprint(base), dependencyFingerprint(List.of(base)));
    });

    test('the cache reuses on equal dependencies and keeps no copy of them', () {
      final state = DayCalculationState();
      var calls = 0;
      final deps = [for (var i = 0; i < 1000; i++) i * 1.0];
      int run(Object? d) => state.evaluate('k', d, () => ++calls,
          ana.CalculationMode.periodicAwake);
      expect(run(deps), 1);
      expect(run(List.of(deps)), 1, reason: 'a hit returns the first result');
      expect(state.hits, 1);
      deps[999] = -1;
      expect(run(deps), 2, reason: 'a changed element recomputes');
    });
  });

  group('DayCalculationState.compact', () {
    ({Map<String, dynamic> bundle, Map<String, dynamic> wake}) pass(
        Substrate s, DayCalculationState? state, ana.CalculationMode mode) {
      final start = s.tsSec.first;
      final bundle = <String, dynamic>{};
      final wake = DerivationEngine.applyDayActivity(
        bundle: bundle,
        scalars: <String, dynamic>{},
        daySub: s,
        profile: _profile,
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        dayStartSec: start,
        dayCalendarEndSec: start + _day,
        dataNowSec: s.tsSec.last + 1,
        restingHr: 54,
        dynFloorG: .03,
        dynHistoryDays: 14,
        liveStepsReal: 0,
        liveStepsFromStrap: 0,
        state: state,
        mode: mode,
      );
      return (bundle: bundle, wake: wake);
    }

    test('a compacted state holds no samples and the next pass still matches', () {
      final plain = DayCalculationState(), compacted = DayCalculationState();
      const first = 3 * 3600;
      pass(incrementalActivity(seconds: first), plain, ana.CalculationMode.sleep);
      pass(incrementalActivity(seconds: first), compacted,
          ana.CalculationMode.sleep);
      for (var n = first + 1800; n <= 6 * 3600; n += 1800) {
        final s = incrementalActivity(seconds: n);
        compacted.compact();
        expect(compacted.retainedSamples, lessThan(100));
        final a = pass(s, plain, ana.CalculationMode.periodicAwake);
        final b = pass(s, compacted, ana.CalculationMode.periodicAwake);
        final batch = pass(s, null, ana.CalculationMode.forced);
        expect(jsonEncode(b.wake), jsonEncode(a.wake), reason: 'n=$n wake');
        expect(jsonEncode(b.bundle), jsonEncode(a.bundle), reason: 'n=$n bundle');
        expect(jsonDecode(jsonEncode(b.wake)).keys.toSet(),
            jsonDecode(jsonEncode(batch.wake)).keys.toSet());
      }
    });

    test('a full day leaves only the motion series held until compact', () {
      final state = DayCalculationState();
      final s = incrementalActivity(seconds: _day);
      final samples = [
        for (var i = 0; i < s.length; i++)
          ana.AccelSample(s.tsSec[i] * 1000.0, s.ax[i], s.ay[i], s.az[i]),
      ];
      pass(s, state, ana.CalculationMode.sleep);
      state.motionMinutes(samples, ana.CalculationMode.sleep);
      expect(state.processedHrSamples, greaterThan(0));
      expect(state.retainedSamples, greaterThan(_day ~/ 2),
          reason: 'the analytics motion series keeps its valid samples');
      state.compact();
      expect(state.retainedSamples, lessThan(100));
    });
  });
}
