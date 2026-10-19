// RED (phase 1): per-pass dependency identity and prefix checks cost O(new
// beats), not O(night beats).
//
// An audit found two O(night) costs that are not the computation itself:
//  (a) DayCalculationState.evaluate (the `memo()` seam in deriveDayBundle) calls
//      `dependencyFingerprint(dependencies)` (lib/compute/state_fingerprint.dart)
//      which walks every element of `nn`, `nnTimes`, `sleepRrMs`, `sleepRrTsMs`
//      for each memo that lists them, every pass.
//  (b) DayCalculationState.nightRr re-hashes the already-folded beats with
//      `nightBeatsFingerprint(rrMs, rrTsMs, held)` to prove the slice extends
//      the fold, and copies the result lists each pass.
//
// COUNTERS the implementation adds (names pinned; cumulative, per
// DayCalculationState; the engine should also forward the per-pass delta to
// `perf.addCount` under the same names):
//   int get memoFpBeatsHashed    night beats (one beat = one index of the
//       nn / sleep RR lists, however many lists or memos read it) newly digested
//       for memo dependency identity. A beat already covered by a running
//       digest that provably still matches costs 0.
//   int get nightRrBeatsHashed   beats hashed by nightRr to prove the slice
//       extends the fold (a rebuild/adopt may hash everything once).
//
// Budget on the 2nd and later warm passes over a growing night:
//   delta <= new beats + kSeam.
// Results stay bit-identical to a cold batch, and every fallback still fires
// when an earlier beat changes (guards, green today).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/incremental_day_fixture.dart';

const _seam = 200;

/// A counter that the implementation has not added yet reads as null (not a
/// compile error), so the red tests fail on the missing counter itself.
int? _counter(DayCalculationState s, String name) {
  final d = s as dynamic;
  try {
    return (name == 'memoFpBeatsHashed'
        ? d.memoFpBeatsHashed
        : d.nightRrBeatsHashed) as int?;
  } on NoSuchMethodError {
    return null;
  }
}

List<double> _dbls(Object? v) =>
    [for (final x in v as List) (x as num).toDouble()];

Map<String, dynamic> _upTo(Map<String, dynamic> full, int beats) {
  final d = copyDay(full);
  d['sleep_rr_ms'] = (d['sleep_rr_ms'] as List).take(beats).toList();
  d['sleep_rr_ts_ms'] = (d['sleep_rr_ts_ms'] as List).take(beats).toList();
  return d;
}

void _same(Object? a, Object? e, [String path = r'$']) {
  if (e is double && a is double) {
    expect(e.isNaN ? a.isNaN : (a == e && a.isNegative == e.isNegative), isTrue,
        reason: '$path: $a != $e');
  } else if (e is Map) {
    expect(a, isA<Map>(), reason: path);
    expect((a as Map).keys.toSet(), e.keys.toSet(), reason: '$path keys');
    for (final k in e.keys) {
      _same(a[k], e[k], '$path.$k');
    }
  } else if (e is List) {
    expect(a, isA<List>(), reason: path);
    expect((a as List).length, e.length, reason: '$path length');
    for (var i = 0; i < e.length; i++) {
      _same(a[i], e[i], '$path[$i]');
    }
  } else {
    expect(a, e, reason: path);
  }
}

Map<String, dynamic> _pass(Map<String, dynamic> input, DayCalculationState s,
    CalculationMode mode, String where) {
  final oracle = deriveDayBundle(copyDay(input));
  final got = deriveDayBundle(input, state: s, mode: mode);
  _same(got, oracle, where);
  return got;
}

void main() {
  final full = incrementalDay(seed: 7, nightSeconds: 7200);
  final total = (full['sleep_rr_ms'] as List).length;
  const cuts = [5000, 5300, 5700, 6100];

  test('fixture: a long night, new beats a small part of it', () {
    expect(total, greaterThan(6500));
  });

  group('work counters: O(new beats) per warm pass (RED)', () {
    for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
      for (final name in ['memoFpBeatsHashed', 'nightRrBeatsHashed']) {
        test('$name, $mode', () {
          final s = DayCalculationState();
          var prev = 0;
          var pass = 0;
          for (final n in cuts) {
            final before = _counter(s, name);
            _pass(_upTo(full, n), s, mode, 'beats=$n');
            pass++;
            final after = _counter(s, name);
            expect(after, isNotNull, reason: '$name counter is exposed');
            if (pass >= 2) {
              final fresh = n - prev;
              expect(after! - (before ?? 0), lessThanOrEqualTo(fresh + _seam),
                  reason: '$name pass $pass: +$fresh new of $n beats');
            }
            prev = n;
          }
        });
      }
    }

    test('nightRr alone: direct many-pass chain', () {
      final s = DayCalculationState();
      final rr = _dbls(full['sleep_rr_ms']), ts = _dbls(full['sleep_rr_ts_ms']);
      var prev = 0;
      var pass = 0;
      for (final n in cuts) {
        final before = _counter(s, 'nightRrBeatsHashed');
        s.nightRr(rr.sublist(0, n), ts.sublist(0, n));
        pass++;
        final after = _counter(s, 'nightRrBeatsHashed');
        expect(after, isNotNull, reason: 'nightRrBeatsHashed is exposed');
        if (pass >= 2) {
          expect(after! - (before ?? 0), lessThanOrEqualTo(n - prev + _seam),
              reason: 'extension proof is O(new): pass $pass');
        }
        prev = n;
      }
    });
  });

  group('earlier changes still force the fallback, stored night == batch', () {
    final changes = <String, void Function(Map<String, dynamic>)>{
      'a beat replaced earlier in the night': (d) =>
          (d['sleep_rr_ms'] as List)[1200] =
              (d['sleep_rr_ms'] as List)[1200] + 37.0,
      'a sub-ms edit of an early timestamp': (d) =>
          (d['sleep_rr_ts_ms'] as List)[300] =
              (d['sleep_rr_ts_ms'] as List)[300] + 0.001,
      'beats evicted from the middle': (d) {
        (d['sleep_rr_ms'] as List).removeRange(800, 900);
        (d['sleep_rr_ts_ms'] as List).removeRange(800, 900);
      },
      'onset moved (first beats dropped)': (d) {
        (d['sleep_rr_ms'] as List).removeRange(0, 120);
        (d['sleep_rr_ts_ms'] as List).removeRange(0, 120);
      },
    };
    for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
      for (final c in changes.entries) {
        test('${c.key}, $mode', () {
          final s = DayCalculationState();
          _pass(_upTo(full, 5000), s, mode, 'warm-up');
          _pass(_upTo(full, 5300), s, mode, 'extend');
          final rebuilds = s.nightRebuilds;
          final changed = _upTo(full, 5700);
          c.value(changed);
          _pass(changed, s, mode, c.key);
          expect(s.nightRebuilds, rebuilds + 1,
              reason: '${c.key}: the fold restarted');
          // And streaming resumes after the fallback.
          final next = copyDay(changed);
          final src = _upTo(full, 6100);
          final drop = (src['sleep_rr_ms'] as List).length -
              (changed['sleep_rr_ms'] as List).length;
          expect(drop, greaterThanOrEqualTo(0));
          final rr = (changed['sleep_rr_ms'] as List);
          final ts = (changed['sleep_rr_ts_ms'] as List);
          final fullRr = full['sleep_rr_ms'] as List;
          final fullTs = full['sleep_rr_ts_ms'] as List;
          for (var i = 5700; i < 6100; i++) {
            rr.add(fullRr[i]);
            ts.add(fullTs[i]);
          }
          next['sleep_rr_ms'] = rr;
          next['sleep_rr_ts_ms'] = ts;
          _pass(next, s, mode, '${c.key}: after fallback');
          expect(s.nightRebuilds, rebuilds + 1, reason: 'extends again');
        });
      }
    }
  });

  group('memoized periodicAwake results (guard)', () {
    test('unchanged inputs reuse the memo, no recompute', () {
      final s = DayCalculationState();
      final input = _upTo(full, 5000);
      _pass(input, s, CalculationMode.periodicAwake, 'first');
      final computed = s.computations;
      final hits = s.hits;
      _pass(copyDay(input), s, CalculationMode.periodicAwake, 'second');
      expect(s.computations, computed, reason: 'nothing recomputed');
      expect(s.hits, greaterThan(hits), reason: 'served from the memo');
    });

    test('one new beat recomputes and matches the batch', () {
      final s = DayCalculationState();
      _pass(_upTo(full, 5000), s, CalculationMode.periodicAwake, 'first');
      final computed = s.computations;
      _pass(_upTo(full, 5001), s, CalculationMode.periodicAwake, 'one beat');
      expect(s.computations, greaterThan(computed),
          reason: 'a new beat is a changed dependency');
    });
  });
}
