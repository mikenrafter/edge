// P2.0a, desktop part (design 02 step 2 scope, section 5): the perf counters
// that measure what step 2 moves, built on `DerivePerf.addCount` / `addStage`.
// This file pins the pure parts; the wiring is pinned in
// perf_counters_read_seam_test.dart (screen reads, last_result) and
// perf_counters_derive_test.dart (pager, Substrate adoption, worker spawn).
//
// How perf is gated today: it is not. The derive engine's `perf` is always on
// and its counters are plain map increments. P2.0a adds ONE gate and uses it
// everywhere:
//
//   DerivePerf(nowMs:, enabled: true)   enabled=false: addCount / addStage /
//                                       addPhase / stage / addCountLazy record
//                                       nothing; summary() has empty counts and
//                                       stages. `stage` still runs its body.
//   DerivePerf.addCountLazy(name, f)    f runs ONLY when enabled, so a count that
//                                       is itself costly to measure (a node walk,
//                                       a byte sum) costs nothing when disabled.
//   ReadPerf.sink                       the DerivePerf of reads outside a derive
//                                       pass (the repository read seam,
//                                       LastResultCache). Null = disabled.
//   payloadNodeCount(decoded)           values in a decoded JSON graph (every map,
//                                       list and scalar once, keys not counted).
//   rowsByteEstimate(rows)              num = 8, String = utf8 length,
//                                       Uint8List = length, null/other = 0.
//
// Stubs added by the RED commit: `enabled` (stored, not honoured),
// `addCountLazy` (no-op), `ReadPerf` (a field), `payloadNodeCount` and
// `rowsByteEstimate` (return 0), and the `perf:` constructor parameter of
// `DerivationEngine`.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_perf.dart';

class _Clock {
  int now = 1000;
  int call() => now;
}

void main() {
  late _Clock clock;
  setUp(() => clock = _Clock());

  group('payloadNodeCount', () {
    test('counts every map, list and scalar once; keys do not count', () {
      expect(payloadNodeCount(<String, Object?>{'a': [1, 2], 'b': null}), 5);
    });

    test('a scalar root is one node; an empty map or list is one node', () {
      expect(payloadNodeCount(7), 1);
      expect(payloadNodeCount(null), 1);
      expect(payloadNodeCount(<String, Object?>{}), 1);
      expect(payloadNodeCount(<Object?>[]), 1);
    });

    test('nested graphs add up', () {
      final g = <String, Object?>{
        'skipped': false,
        'scalars': {'steps': 1234, 'strain': 9.5},
        'sleep': {
          'stages': [1, 2, 3],
        },
      };
      // root 1, skipped 1, scalars 1 + 2, sleep 1, stages 1 + 3.
      expect(payloadNodeCount(g), 10);
    });
  });

  group('rowsByteEstimate', () {
    test('numbers 8, strings their UTF-8 length, blobs their length, null 0', () {
      expect(
        rowsByteEstimate([
          {
            'a': 1,
            'b': 'héllo', // h, e-acute (2 bytes), l, l, o = 6
            'c': null,
            'd': 2.5,
            'e': Uint8List(3),
          },
        ]),
        8 + 6 + 0 + 8 + 3,
      );
    });

    test('sums over rows; no rows is 0', () {
      expect(rowsByteEstimate(const []), 0);
      expect(
        rowsByteEstimate([
          {'a': 1},
          {'a': 2, 'b': 'xy'},
        ]),
        8 + 8 + 2,
      );
    });
  });

  group('the enabled gate', () {
    test('enabled (the default) records counts, stages and lazy counts', () {
      final p = DerivePerf(nowMs: clock.call);
      p.startPass();
      p.addCount('rows', 5);
      p.addCount('rows', 2);
      p.addStage('load', 30);
      var evaluated = 0;
      p.addCountLazy('bytes', () {
        evaluated++;
        return 41;
      });
      p.addCountLazy('bytes', () => 1);
      final s = p.summary();
      expect((s['counts'] as Map)['rows'], 7);
      expect((s['counts'] as Map)['bytes'], 42,
          reason: 'a lazy count adds like addCount');
      expect((s['stages'] as Map)['load'], 30);
      expect(evaluated, 1);
    });

    test('disabled: nothing is recorded and a lazy value is never computed', () {
      final p = DerivePerf(nowMs: clock.call, enabled: false);
      p.startPass();
      var evaluated = 0;
      p.addCount('rows', 5);
      p.addStage('load', 30);
      p.addPhase('2025-09-02', DerivePhase.compute, 10);
      p.addCountLazy('bytes', () {
        evaluated++;
        return 41;
      });
      p.endPass();
      final s = p.summary();
      expect(s['counts'], isEmpty);
      expect(s['stages'], isEmpty);
      expect(s['days'], 0);
      expect(evaluated, 0,
          reason: 'the measuring work itself must not run when disabled');
    });

    test('disabled: stage still runs its body, returns its value, and rethrows',
        () async {
      final p = DerivePerf(nowMs: clock.call, enabled: false);
      expect(await p.stage('x', () async => 3), 3);
      await expectLater(
          p.stage('y', () async => throw StateError('boom')), throwsStateError);
      expect(p.summary()['stages'], isEmpty);
    });
  });

  test('ReadPerf is disabled (no sink) until something sets one', () {
    expect(ReadPerf.sink, isNull);
  });
}
