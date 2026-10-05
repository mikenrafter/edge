// 8AG-perf P1-A: measure a derive pass.
//
// ASSUMED API (lib/compute/derive_perf.dart, new, pure Dart, no Flutter):
//
//   enum DerivePhase { prepare, compute, persist }
//
//   class DerivePerf {
//     DerivePerf({required int Function() nowMs});
//     void enqueued();                         // scheduler enqueued the job; the
//                                              // FIRST call before startPass wins
//     void noteHolds(Map<String, dynamic> schedulerSnapshot);
//                                              // reads DeriveScheduler.snapshot():
//                                              //   offload_active        -> 'offload'
//                                              //   manual_sync_hold      -> 'manual_sync_hold'
//                                              //   workout_active && !workout_hold_expired -> 'workout'
//                                              //   background            -> 'background'
//     void noteSettle();                       // the settle timer wait -> 'settle'
//     void startPass();                        // queue_wait = now - enqueued
//     void addPhase(String day, DerivePhase phase, int ms);   // accumulates per (day, phase)
//     void endPass();                          // pass_ms = now - startPass
//     Map<String, Object?> summary();
//     String logLine();                        // starts with '[perf] derive '
//     static String describe(Map<String, Object?>? summary);   // Settings > Developer row
//   }
//
//   summary() keys: queue_wait_ms (int?, null when never enqueued), holds
//   (List<String>, de-duplicated, first-seen order), days (int, distinct days
//   with a phase), prepare_ms / compute_ms / persist_ms (totals over days),
//   prepare_max_ms / compute_max_ms / persist_max_ms (largest single day),
//   pass_ms (int?, null until endPass).
//
//   class RenderLatency {                      // "first usable render" timer
//     RenderLatency({required int Function() nowMs});
//     void revisionBumped();                   // earliest UNCONSUMED bump wins
//     int? committed();                        // ms since that bump, then clears;
//                                              // null when nothing is pending
//   }
//
// Spec ambiguity resolved: "hold reasons seen while queued" are the snapshot-
// derived strings above, in first-seen order, de-duplicated.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derive_perf.dart';

class _Clock {
  int now = 1000;
  int call() => now;
}

void main() {
  late _Clock clock;
  late DerivePerf perf;
  setUp(() {
    clock = _Clock();
    perf = DerivePerf(nowMs: clock.call);
  });

  test('queue wait is enqueue -> start, on the injected clock', () {
    perf.enqueued();
    clock.now += 12000;
    perf.startPass();
    clock.now += 500;
    perf.endPass();
    final s = perf.summary();
    expect(s['queue_wait_ms'], 12000);
    expect(s['pass_ms'], 500);
  });

  test('the first enqueue of a pass wins; a later one does not reset the wait',
      () {
    perf.enqueued();
    clock.now += 4000;
    perf.enqueued();
    clock.now += 4000;
    perf.startPass();
    expect(perf.summary()['queue_wait_ms'], 8000);
  });

  test('a pass that was never enqueued (manual / headless) has no queue wait',
      () {
    perf.startPass();
    clock.now += 10;
    perf.endPass();
    expect(perf.summary()['queue_wait_ms'], isNull,
        reason: 'never invent a wait that was not measured');
  });

  test('phases: totals, per-phase max, distinct day count', () {
    perf.startPass();
    perf.addPhase('2026-10-01', DerivePhase.prepare, 100);
    perf.addPhase('2026-10-01', DerivePhase.compute, 400);
    perf.addPhase('2026-10-01', DerivePhase.persist, 50);
    perf.addPhase('2026-10-02', DerivePhase.prepare, 300);
    perf.addPhase('2026-10-02', DerivePhase.compute, 200);
    perf.addPhase('2026-10-02', DerivePhase.persist, 70);
    perf.addPhase('2026-10-03', DerivePhase.compute, 1000);
    perf.endPass();
    final s = perf.summary();
    expect(s['days'], 3);
    expect(s['prepare_ms'], 400);
    expect(s['compute_ms'], 1600);
    expect(s['persist_ms'], 120);
    expect(s['prepare_max_ms'], 300);
    expect(s['compute_max_ms'], 1000);
    expect(s['persist_max_ms'], 70);
  });

  test('the same (day, phase) reported twice accumulates', () {
    perf.startPass();
    perf.addPhase('d', DerivePhase.compute, 100);
    perf.addPhase('d', DerivePhase.compute, 150);
    expect(perf.summary()['compute_ms'], 250);
    expect(perf.summary()['compute_max_ms'], 250);
    expect(perf.summary()['days'], 1);
  });

  test('hold reasons come from the scheduler snapshot, de-duplicated', () {
    perf.enqueued();
    perf.noteHolds({'offload_active': true, 'manual_sync_hold': false});
    perf.noteHolds({'offload_active': true, 'manual_sync_hold': true});
    perf.noteHolds({
      'workout_active': true,
      'workout_hold_expired': false,
      'background': true,
    });
    perf.noteSettle();
    perf.noteSettle();
    expect(perf.summary()['holds'],
        ['offload', 'manual_sync_hold', 'workout', 'background', 'settle']);
  });

  test('an expired workout hold is not a hold', () {
    perf.noteHolds({'workout_active': true, 'workout_hold_expired': true});
    expect(perf.summary()['holds'], isEmpty);
  });

  test('summary of an unused recorder claims nothing', () {
    final s = perf.summary();
    expect(s['days'], 0);
    expect(s['queue_wait_ms'], isNull);
    expect(s['pass_ms'], isNull);
    expect(s['holds'], isEmpty);
  });

  test('logLine is one [perf] derive line carrying the numbers', () {
    perf.enqueued();
    clock.now += 12000;
    perf.noteSettle();
    perf.startPass();
    perf.addPhase('d', DerivePhase.compute, 700);
    clock.now += 41000;
    perf.endPass();
    final line = perf.logLine();
    expect(line, startsWith('[perf] derive'));
    expect(line.contains('\n'), isFalse);
    expect(line, contains('12000'));
    expect(line, contains('41000'));
    expect(line, contains('settle'));
  });

  group('describe (the Settings > Developer "Last calculation" row)', () {
    test('the spec example', () {
      expect(
        DerivePerf.describe({
          'queue_wait_ms': 12000,
          'holds': ['settle'],
          'days': 3,
          'pass_ms': 41000,
        }),
        'Waited 12 s (settle), 3 days, 41 s total',
      );
    });

    test('no holds -> no parenthesis; one day is singular', () {
      expect(
        DerivePerf.describe({
          'queue_wait_ms': 2000,
          'holds': <String>[],
          'days': 1,
          'pass_ms': 9000,
        }),
        'Waited 2 s, 1 day, 9 s total',
      );
    });

    test('several holds are listed', () {
      final s = DerivePerf.describe({
        'queue_wait_ms': 60000,
        'holds': ['offload', 'settle'],
        'days': 2,
        'pass_ms': 5000,
      });
      expect(s, contains('(offload, settle)'));
    });

    test('sub-second values read in ms', () {
      expect(
        DerivePerf.describe({
          'queue_wait_ms': 850,
          'holds': <String>[],
          'days': 1,
          'pass_ms': 400,
        }),
        'Waited 850 ms, 1 day, 400 ms total',
      );
    });

    test('values only when measured: unmeasured pieces are left out', () {
      expect(
        DerivePerf.describe({
          'queue_wait_ms': null,
          'holds': <String>[],
          'days': 3,
          'pass_ms': 41000,
        }),
        '3 days, 41 s total',
      );
    });

    test('nothing measured is an em dash, never a zero', () {
      expect(DerivePerf.describe(null), '—');
      expect(DerivePerf.describe(const {}), '—');
      expect(
        DerivePerf.describe({
          'queue_wait_ms': null,
          'holds': <String>[],
          'days': 0,
          'pass_ms': null,
        }),
        '—',
      );
    });
  });

  group('RenderLatency (first usable render after a revision bump)', () {
    test('bump -> commit measures the gap, once', () {
      final c = _Clock();
      final r = RenderLatency(nowMs: c.call);
      r.revisionBumped();
      c.now += 300;
      expect(r.committed(), 300);
      expect(r.committed(), isNull, reason: 'a commit consumes the bump');
    });

    test('a commit with no bump pending measures nothing', () {
      final r = RenderLatency(nowMs: _Clock().call);
      expect(r.committed(), isNull);
    });

    test('the earliest unconsumed bump is the one timed', () {
      final c = _Clock();
      final r = RenderLatency(nowMs: c.call);
      r.revisionBumped();
      c.now += 100;
      r.revisionBumped();
      c.now += 200;
      expect(r.committed(), 300);
    });

    test('a later bump after a commit starts a new measurement', () {
      final c = _Clock();
      final r = RenderLatency(nowMs: c.call);
      r.revisionBumped();
      c.now += 50;
      r.committed();
      c.now += 1000;
      r.revisionBumped();
      c.now += 70;
      expect(r.committed(), 70);
    });
  });
}
