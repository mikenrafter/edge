// RED: each distinct night list is hashed at most once per pass.
//
// nightRr / memo get plain lists with no change signal, so an edited earlier
// beat can only be caught by hashing. What is avoidable is hashing the SAME
// list again for every memo (~10 memos list nn / nnTimes / sleepRrMs /
// sleepRrTsMs, each re-walked by dependencyFingerprint, plus nightRr's own
// prefix proof). The fix is a per-pass identity-keyed digest cache.
//
// COUNTER (name pinned): `int get nightListHashes` on DayCalculationState,
// cumulative, counting full-list digests computed (one per distinct list per
// pass, plus one for nightRr's folded-prefix proof when it hashes a prefix).
//   deriveDayBundle pass:  delta <= 5   (nn, nnTimes, sleepRrMs, sleepRrTsMs,
//                                        nightRr prefix proof)
//   direct nightRr call:   delta <= 1
// Results stay bit-identical to a cold batch; every fallback still fires
// (guards below, green before and after).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

import 'support/incremental_day_fixture.dart';

const _maxListHashes = 5;

/// A counter that the implementation has not added yet reads as null (not a
/// compile error), so the red tests fail on the missing counter itself.
int? _hashes(DayCalculationState s) {
  try {
    return (s as dynamic).nightListHashes as int?;
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

  group('work counters: each night list hashed once per pass (RED)', () {
    for (final mode in [CalculationMode.periodicAwake, CalculationMode.forced]) {
      test('deriveDayBundle passes, $mode', () {
        final s = DayCalculationState();
        for (final n in cuts) {
          final before = _hashes(s);
          _pass(_upTo(full, n), s, mode, 'beats=$n');
          final after = _hashes(s);
          expect(after, isNotNull, reason: 'nightListHashes is exposed');
          expect(after! - (before ?? 0), lessThanOrEqualTo(_maxListHashes),
              reason: 'beats=$n: a list is hashed once however many memos read it');
        }
      });
    }

    test('nightRr alone: direct many-pass chain', () {
      final s = DayCalculationState();
      final rr = _dbls(full['sleep_rr_ms']), ts = _dbls(full['sleep_rr_ts_ms']);
      for (final n in cuts) {
        final before = _hashes(s);
        s.nightRr(rr.sublist(0, n), ts.sublist(0, n));
        final after = _hashes(s);
        expect(after, isNotNull, reason: 'nightListHashes is exposed');
        expect(after! - (before ?? 0), lessThanOrEqualTo(1),
            reason: 'one prefix proof per call: n=$n');
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
