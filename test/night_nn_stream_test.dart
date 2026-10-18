// RED tests: the night path of deriveDayBundle folds only the beats it has not
// seen into a per-night streaming RrCorrector instead of re-running correctRr
// over the whole sleep-window slice on every pass.
//
// CHOSEN SHAPE
// ------------
// The per-night corrector lives in DayCalculationState (lib/compute/
// day_calculation_state.dart), as a private RrCorrector plus a small record of
// what it folded (window-start beat, a fingerprint of / copy of the beats
// already folded). That is where every other incremental state already lives:
// deriveDayBundle receives it as `state:` and the engine's
// `_runDayBundleCancellable` returns the same object, which is deep-copied
// across the isolate boundary both ways (`_calculationStates[day]` holds it
// between passes). RrCorrector is plain Dart data, so it must survive that
// copy. The state is RAM-only like the rest of DayCalculationState; it is NOT
// added to DayResumeState / the day_checkpoint blob, because the checkpoint
// holds only sleep-window-independent folds and the night slice depends on the
// window. So there is no serialisation round trip to test, only the isolate hop.
//
// Public surface the tests pin (all on DayCalculationState):
//   ({List<double> nn, List<double> nnTimesMs, double cleanFraction,
//     int droppedCount, int correctedCount}) nightRr(List<double> rrMs, List<double> rrTsMs)
//     the corrected night for this slice, bit-identical to
//     correctRr(rrMs, rrTsMs: rrTsMs). Folds only the beats past what it has
//     already folded; starts over when the slice is not an extension of what
//     was folded (first beat / any earlier beat value or timestamp changed, or
//     the slice is shorter than what was folded).
//   int get processedNightBeats
//     cumulative beats this state has pushed through a corrector (a rebuild
//     counts the whole slice again), the work counter for "zero work".
//   int get nightRebuilds
//     times a corrector was started from scratch, the first build included.
//
// deriveDayBundle must call nightRr for 'sleep_rr' directly, not through memo(),
// so a forced/sleep/heavy pass (which bypasses the memo cache) still folds
// zero new beats when the slice is unchanged.
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart'
    show CalculationMode, correctRr;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/incremental_day_fixture.dart';

/// Strict structural equality: doubles must be the same bits (NaN == NaN).
void _expectIdentical(Object? actual, Object? expected, [String path = r'$']) {
  if (expected is double && actual is double) {
    final same = expected.isNaN
        ? actual.isNaN
        : (actual == expected && actual.isNegative == expected.isNegative);
    expect(same, isTrue, reason: '$path: $actual != $expected');
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual as Map;
    expect(a.keys.toSet(), expected.keys.toSet(), reason: '$path keys');
    for (final k in expected.keys) {
      _expectIdentical(a[k], expected[k], '$path.$k');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final a = actual as List;
    expect(a.length, expected.length, reason: '$path length');
    for (var i = 0; i < expected.length; i++) {
      _expectIdentical(a[i], expected[i], '$path[$i]');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

List<double> _dbls(Object? v) => [for (final x in v as List) (x as num).toDouble()];

/// [full] with the night's beats cut to the first [beats].
Map<String, dynamic> _upTo(Map<String, dynamic> full, int beats) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).take(beats).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).take(beats).toList();
  return d;
}

/// [full] with the first [skip] beats removed (window start moved later).
Map<String, dynamic> _from(Map<String, dynamic> full, int skip) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).skip(skip).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).skip(skip).toList();
  return d;
}

/// The bundle fields that come from the corrected night.
const _nightKeys = ['hrv_time', 'hrv_freq', 'prsa_dc', 'prsa_ac', 'hrv_timeline'];

void _expectBundleMatchesBatch(
  Map<String, dynamic> input,
  DayCalculationState state,
  CalculationMode mode, {
  String where = '',
}) {
  final oracle = deriveDayBundle(copyDay(input));
  final got = deriveDayBundle(input, state: state, mode: mode);
  for (final k in _nightKeys) {
    _expectIdentical(got[k], oracle[k], '$where.$k');
  }
  _expectIdentical(got, oracle, where);
}

({List<double> rr, List<double> ts}) _beats(Map<String, dynamic> d) =>
    (rr: _dbls(d['sleep_rr_ms']), ts: _dbls(d['sleep_rr_ts_ms']));

void _expectNightMatchesBatch(
  DayCalculationState state,
  List<double> rr,
  List<double> ts,
) {
  final got = state.nightRr(rr, ts);
  final want = correctRr(rr, rrTsMs: ts);
  _expectIdentical(got.nn, want.nn, 'nn');
  _expectIdentical(got.nnTimesMs, want.nnTimesMs, 'nnTimesMs');
  _expectIdentical(got.cleanFraction, want.cleanFraction, 'cleanFraction');
  expect(got.droppedCount, want.droppedCount, reason: 'droppedCount');
  expect(got.correctedCount, want.correctedCount, reason: 'correctedCount');
}

void main() {
  // ~1500 s night: a few hundred beats, past the 91-beat window many times.
  final fixtures = {
    'smooth': incrementalDay(seed: 7, nightSeconds: 1500),
    'gaps+artifacts': incrementalDay(seed: 42, gaps: true, nightSeconds: 1500),
  };

  group('growing night matches the batch path', () {
    for (final f in fixtures.entries) {
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        test('${f.key} bundle, $mode', () {
          final full = f.value;
          final total = (full['sleep_rr_ms'] as List).length;
          expect(total, greaterThan(1000), reason: 'fixture sanity');
          final state = DayCalculationState();
          // Uneven steps, including a step of 1 beat and one under the window.
          final cuts = <int>{
            1, 2, 40, 90, 91, 92, 183, 300, 301, 640, total - 1, total,
          }.toList()
            ..sort();
          for (final n in cuts) {
            _expectBundleMatchesBatch(
              _upTo(full, n),
              state,
              mode,
              where: 'beats=$n',
            );
          }
          expect(state.nightRebuilds, 1, reason: 'pure growth never rebuilds');
          expect(state.processedNightBeats, total,
              reason: 'each beat folded exactly once');
        });
      }
    }

    test('direct nightRr over many passes is bit-identical', () {
      final b = _beats(fixtures['gaps+artifacts']!);
      final state = DayCalculationState();
      final rnd = math.Random(3);
      var n = 0;
      while (n < b.rr.length) {
        n = math.min(b.rr.length, n + 1 + rnd.nextInt(60));
        _expectNightMatchesBatch(
          state,
          b.rr.sublist(0, n),
          b.ts.sublist(0, n),
        );
      }
      expect(state.nightRebuilds, 1);
      expect(state.processedNightBeats, b.rr.length);
    });

    test('empty night matches batch and costs nothing', () {
      final state = DayCalculationState();
      _expectNightMatchesBatch(state, const [], const []);
      expect(state.processedNightBeats, 0);
    });
  });

  group('a pass with no new beats does no correction work', () {
    test('direct nightRr, repeated and from fresh list copies', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectNightMatchesBatch(state, b.rr, b.ts);
      final work = state.processedNightBeats;
      expect(work, b.rr.length);
      for (var i = 0; i < 3; i++) {
        _expectNightMatchesBatch(state, [...b.rr], [...b.ts]);
      }
      expect(state.processedNightBeats, work);
      expect(state.nightRebuilds, 1);
    });

    test('bundle pass in a cache-bypassing mode folds nothing new', () {
      final full = fixtures['smooth']!;
      final state = DayCalculationState();
      final input = _upTo(full, 500);
      _expectBundleMatchesBatch(input, state, CalculationMode.forced);
      final work = state.processedNightBeats;
      expect(work, 500);
      // Other inputs change (day HR grows) so the whole bundle is recomputed,
      // but the night slice is the same.
      final again = copyDay(input);
      (again['profile'] as Map)['resting_hr'] = 61;
      _expectBundleMatchesBatch(again, state, CalculationMode.heavy);
      _expectBundleMatchesBatch(again, state, CalculationMode.sleep);
      expect(state.processedNightBeats, work);
      expect(state.nightRebuilds, 1);
    });

    test('growth folds only the delta', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectNightMatchesBatch(state, b.rr.sublist(0, 400), b.ts.sublist(0, 400));
      _expectNightMatchesBatch(state, b.rr.sublist(0, 437), b.ts.sublist(0, 437));
      expect(state.processedNightBeats, 437);
    });
  });

  group('a slice that is not an extension rebuilds and still matches batch', () {
    // Each case: build over [0, 600), then give the changed slice.
    final cases = <String,
        ({List<double> rr, List<double> ts}) Function(
            List<double> rr, List<double> ts)>{
      'window start moved later': (rr, ts) =>
          (rr: rr.sublist(25, 650), ts: ts.sublist(25, 650)),
      'earlier beat value edited': (rr, ts) {
        final r = [...rr.sublist(0, 650)];
        r[17] += 333;
        return (rr: r, ts: ts.sublist(0, 650));
      },
      'earlier beat timestamp edited': (rr, ts) {
        final t = [...ts.sublist(0, 650)];
        t[250] += 5000;
        return (rr: rr.sublist(0, 650), ts: t);
      },
      'last folded beat edited': (rr, ts) {
        final r = [...rr.sublist(0, 650)];
        r[599] += 41;
        return (rr: r, ts: ts.sublist(0, 650));
      },
      'slice shrank': (rr, ts) =>
          (rr: rr.sublist(0, 380), ts: ts.sublist(0, 380)),
      'slice emptied': (rr, ts) => (rr: <double>[], ts: <double>[]),
    };
    for (final c in cases.entries) {
      test('direct: ${c.key}', () {
        final b = _beats(fixtures['gaps+artifacts']!);
        final first = (rr: b.rr.sublist(0, 600), ts: b.ts.sublist(0, 600));
        final state = DayCalculationState();
        _expectNightMatchesBatch(state, first.rr, first.ts);
        expect(state.nightRebuilds, 1);

        final next = c.value(b.rr, b.ts);
        final before = state.processedNightBeats;
        _expectNightMatchesBatch(state, next.rr, next.ts);
        expect(state.nightRebuilds, 2, reason: 'not an extension: rebuild');
        expect(state.processedNightBeats, before + next.rr.length,
            reason: 'a rebuild folds the whole new slice, once');

        // And it is incremental again afterwards.
        if (next.rr.length + 10 <= b.rr.length && next.rr.isNotEmpty) {
          final start = c.key == 'window start moved later' ? 25 : 0;
          final grown = next.rr.length + 10;
          if (start + grown <= b.rr.length) {
            final w = state.processedNightBeats;
            final rr2 = [...next.rr, ...b.rr.sublist(start + next.rr.length, start + grown)];
            final ts2 = [...next.ts, ...b.ts.sublist(start + next.ts.length, start + grown)];
            _expectNightMatchesBatch(state, rr2, ts2);
            expect(state.nightRebuilds, 2);
            expect(state.processedNightBeats, w + 10);
          }
        }
      });
    }

    test('direct: unchanged slice is not a rebuild (control)', () {
      final b = _beats(fixtures['smooth']!);
      final state = DayCalculationState();
      _expectNightMatchesBatch(state, b.rr.sublist(0, 600), b.ts.sublist(0, 600));
      _expectNightMatchesBatch(state, b.rr.sublist(0, 600), b.ts.sublist(0, 600));
      expect(state.nightRebuilds, 1);
    });

    test('bundle: moved window start, edited beat, shrink', () {
      final full = fixtures['gaps+artifacts']!;
      for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
        final state = DayCalculationState();
        _expectBundleMatchesBatch(_upTo(full, 600), state, mode, where: 'grow');
        expect(state.nightRebuilds, 1);

        _expectBundleMatchesBatch(_from(_upTo(full, 650), 30), state, mode,
            where: 'start moved');
        expect(state.nightRebuilds, 2);

        final edited = _upTo(full, 650);
        (edited['sleep_rr_ms'] as List)[40] =
            ((edited['sleep_rr_ms'] as List)[40] as num) + 250.0;
        _expectBundleMatchesBatch(edited, state, mode, where: 'edited');
        expect(state.nightRebuilds, 3);

        _expectBundleMatchesBatch(_upTo(full, 300), state, mode, where: 'shrunk');
        expect(state.nightRebuilds, 4);

        // Growing again after the rebuild stays incremental.
        final work = state.processedNightBeats;
        _expectBundleMatchesBatch(_upTo(full, 320), state, mode, where: 'regrow');
        expect(state.nightRebuilds, 4);
        expect(state.processedNightBeats, work + 20);
      }
    });
  });

  group('isolate hop', () {
    test('state returned from a worker keeps its corrector and extends it',
        () async {
      final full = fixtures['gaps+artifacts']!;
      var state = DayCalculationState();
      final first = _upTo(full, 500);
      _expectBundleMatchesBatch(first, state, CalculationMode.periodicAwake);
      expect(state.processedNightBeats, 500);

      // Same shape as the engine's _runDayBundleCancellable: the state is
      // captured, copied into the worker, mutated there and returned as a copy.
      final grown = _upTo(full, 560);
      final captured = state;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(
          grown,
          state: captured,
          mode: CalculationMode.periodicAwake,
        );
        return (
          bundle: bundle,
          state: captured,
          worked: captured.processedNightBeats,
          rebuilds: captured.nightRebuilds,
        );
      });
      expect(state.processedNightBeats, 500,
          reason: 'worker mutations do not leak into the main-isolate state');
      expect(result.worked, 560, reason: 'worker folded only the 60 new beats');
      expect(result.rebuilds, 1);
      _expectIdentical(result.bundle, deriveDayBundle(copyDay(grown)));

      state = result.state;
      expect(state.processedNightBeats, 560);
      final total = (full['sleep_rr_ms'] as List).length;
      _expectBundleMatchesBatch(
          _upTo(full, total), state, CalculationMode.periodicAwake);
      expect(state.processedNightBeats, total);
      expect(state.nightRebuilds, 1);
    });
  });
}
