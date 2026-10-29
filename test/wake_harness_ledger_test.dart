// The shared provenance seam (Sol code r1 #5, #6): a digest is acknowledged
// only after a confirmed append, a failed append is retried as the SAME
// activation (same seq and time, so a timeout that did land cannot duplicate),
// untouched occurrences write nothing, and every effective-policy transition
// (a journal workout, a learned lead) is a new activation, A -> B -> A included.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/wake_harness.dart';
import 'package:openstrap_edge/wake/wake_harness_ledger.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

const _epoch = 1791183600;

class _FlakyLedger extends MemoryWakeHarnessLedger {
  _FlakyLedger(super.trace);
  int failures = 0;
  int readFailures = 0;
  int saveFailures = 0;
  bool failAfterAppend = false;
  @override
  Future<void> saveState(Map<String, Object?> state) async {
    if (saveFailures > 0) {
      saveFailures--;
      throw StateError('ledger save failed');
    }
    await super.saveState(state);
  }

  @override
  Future<Map<String, Object?>?> loadState() async {
    if (readFailures > 0) {
      readFailures--;
      throw StateError('ledger read failed');
    }
    return super.loadState();
  }

  final attempts = <WakeTraceEntry>[];
  @override
  Future<bool> appendOnce(WakeTraceEntry entry) async {
    attempts.add(entry);
    if (failures > 0) {
      failures--;
      return false;
    }
    final ok = await super.appendOnce(entry);
    if (failAfterAppend) {
      failAfterAppend = false;
      // The row landed, but removing it from the durable queue will fail.
      saveFailures++;
    }
    return ok;
  }
}

void main() {
  late MemoryWakeTraceStore trace;
  late DateTime clock;
  setUp(() {
    trace = MemoryWakeTraceStore();
    clock = DateTime.utc(2026, 10, 26, 6);
  });
  WakeHarnessRecorder recorder(WakeHarnessLedger l) =>
      WakeHarnessRecorder(l);
  Future<List<WakeTraceEntry>> rows() async => [
    for (final e in await trace.forWake(_epoch))
      if (e.kind == 'harness') e,
  ];
  Map<String, Object?> rec(
    WakeHarnessConfig c, {
    ConfounderProfile p = const ConfounderProfile(),
    int lead = 0,
  }) => c.provenance(
    learnedOffsetSec: 0,
    composed: c.compose(p),
    windowLeadMinutes: lead,
    windowMinutes: 60,
  );
  const legacy = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 6);

  test('an untouched occurrence writes nothing; once experimental, a reset '
      'is recorded', () async {
    final r = recorder(MemoryWakeHarnessLedger(trace));
    await r.record(_epoch, rec(WakeHarnessConfig.defaults), untouched: true, atMs: clock.millisecondsSinceEpoch);
    expect(await rows(), isEmpty);
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch, rec(WakeHarnessConfig.defaults), untouched: true, atMs: clock.millisecondsSinceEpoch);
    final got = await rows();
    expect(got.map((e) => e.data['seq']), [0, 1]);
    expect(got.map((e) => e.data['rule']), ['legacy', 'natural']);
  });

  test('a failed append is not acknowledged and is retried as the same '
      'activation', () async {
    final l = _FlakyLedger(trace)..failures = 2;
    final r = recorder(l);
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    clock = clock.add(const Duration(seconds: 30));
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    expect(await rows(), isEmpty);
    clock = clock.add(const Duration(seconds: 30));
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    final got = await rows();
    expect(got, hasLength(1));
    expect(got.single.data['seq'], 0);
    expect(l.attempts.map((e) => e.atMs).toSet(), hasLength(1),
        reason: 'the pending activation keeps its time');
    expect(l.attempts.map((e) => e.data['seq']).toSet(), {0});
  });

  test('a pending activation survives a restart and is flushed before the '
      'next one', () async {
    final l = _FlakyLedger(trace)..failures = 1;
    await recorder(l).record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    expect(await rows(), isEmpty);
    // A new recorder over the same durable ledger: what a restart is.
    final again = recorder(l);
    const b = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 8);
    await again.record(_epoch, rec(b), untouched: false, atMs: clock.millisecondsSinceEpoch);
    final got = await rows();
    expect(got.map((e) => e.data['seq']), [0, 1]);
    expect(
      got.map((e) => (e.data['effective'] as Map)['hrRiseBpm']),
      [6, 8],
    );
  });

  test('a journal workout (protection, trend window) is a transition, and its '
      'reversal another: A -> B -> A', () async {
    final r = recorder(MemoryWakeHarnessLedger(trace));
    const workout = ConfounderProfile(
      protectionMinutes: 10,
      trendWindowMinutes: 5,
      workout: true,
    );
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch, rec(legacy, p: workout), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    final got = await rows();
    expect(got.map((e) => e.data['seq']), [0, 1, 2]);
    expect(got[0].data['digest'], got[2].data['digest']);
    expect(got[0].data['digest'], isNot(got[1].data['digest']));
    expect((got[1].data['effective'] as Map)['protectionMinutes'], 10);
    expect((got[1].data['effective'] as Map)['trendWindowMinutes'], 5);
  });

  test('a learned window-lead change is a transition', () async {
    final r = recorder(MemoryWakeHarnessLedger(trace));
    const hybrid = WakeHarnessConfig(rule: WakeRule.hybrid);
    await r.record(_epoch, rec(hybrid), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch, rec(hybrid, lead: 5), untouched: false, atMs: clock.millisecondsSinceEpoch);
    final got = await rows();
    expect(got, hasLength(2));
    expect((got[1].data['effective'] as Map)['windowLeadMinutes'], 5);
  });

  test('another occurrence starts its own sequence', () async {
    final r = recorder(MemoryWakeHarnessLedger(trace));
    await r.record(_epoch, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    await r.record(_epoch + 86400, rec(legacy), untouched: false, atMs: clock.millisecondsSinceEpoch);
    expect(await rows(), hasLength(1));
    expect((await rows()).single.data['seq'], 0);
    expect(
      (await trace.forWake(_epoch + 86400)).single.data['seq'],
      0,
    );
  });

  group('Sol code r2', () {
    const a = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 6);
    const b = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 9);
    Future<void> tick(WakeHarnessRecorder r, WakeHarnessConfig c,
        [int epoch = _epoch]) async {
      await r.record(epoch, rec(c), untouched: false,
          atMs: clock.millisecondsSinceEpoch);
      clock = clock.add(const Duration(seconds: 30));
    }

    List<Object?> hr(List<WakeTraceEntry> rows) =>
        [for (final e in rows) (e.data['effective'] as Map)['hrRiseBpm']];

    test(
      'an upgrade retains the old pending entry in its original occurrence',
      () async {
        final at = clock.millisecondsSinceEpoch;
        final snapshot = rec(a);
        final l = _FlakyLedger(trace)
          ..state = {
            'epoch': _epoch,
            'seq': 0,
            'pending': {
              'digest': snapshot['digest'],
              'atMs': at,
              'data': {...snapshot, 'seq': 0},
            },
          };
        clock = clock.add(const Duration(seconds: 30));
        await tick(recorder(l), b, _epoch + 86400);
        final old = await rows();
        expect(hr(old), [6]);
        expect(old.single.atMs, at);
        expect(old.single.data['seq'], 0);
        final next = await trace.forWake(_epoch + 86400);
        expect(hr(next), [9]);
        expect(next.single.data['seq'], 0);
      },
    );

    test(
      'a failed enqueue never retries older entries before the save',
      () async {
        final l = _FlakyLedger(trace)..failures = 1;
        await tick(recorder(l), a);
        l.saveFailures = 1;
        await tick(recorder(l), b);
        expect(l.attempts, hasLength(1));
        expect(await rows(), isEmpty);
        await tick(recorder(l), b);
        expect(hr(await rows()), [6, 9]);
        expect((await rows()).map((e) => e.data['seq']), [0, 1]);
      },
    );

    test(
      'an invalid queue is retained without appending or resetting state',
      () async {
        final state = <String, Object?>{'occ': {}, 'queue': 'broken'};
        final l = _FlakyLedger(trace)..state = state;
        await tick(recorder(l), a);
        expect(l.state, state);
        expect(l.attempts, isEmpty);
      },
    );

    test(
      'a failed queue acknowledgement retries the same row after restart',
      () async {
        final l = _FlakyLedger(trace)..failAfterAppend = true;
        final at = clock.millisecondsSinceEpoch;
        await tick(recorder(l), a);
        await tick(recorder(l), b);
        final got = await rows();
        expect(hr(got), [6, 9]);
        expect(got.map((e) => e.data['seq']), [0, 1]);
        expect(l.attempts.take(2).map((e) => e.atMs), [at, at]);
      },
    );

    test('A fails, then B (A still failing), then A: B is kept', () async {
      final l = _FlakyLedger(trace)..failures = 2;
      final r = recorder(l);
      await tick(r, a);
      await tick(r, b);
      await tick(r, a);
      final got = await rows();
      expect(got.map((e) => e.data['seq']), [0, 1, 2]);
      expect(hr(got), [6, 9, 6]);
    });

    test('a pending entry survives a change of occurrence', () async {
      final l = _FlakyLedger(trace)..failures = 1;
      final r = recorder(l);
      await tick(r, a);
      await tick(r, a, _epoch + 86400);
      expect(hr(await rows()), [6], reason: 'the first occurrence kept its A');
      expect(await trace.forWake(_epoch + 86400), hasLength(1));
    });

    test('a ledger read failure on the switch back to A retries, never '
        'resets the sequence', () async {
      final l = _FlakyLedger(trace);
      final r = recorder(l);
      await tick(r, a);
      await tick(r, b);
      l.readFailures = 1;
      await tick(r, a);
      await tick(r, a);
      final got = await rows();
      expect(got.map((e) => e.data['seq']), [0, 1, 2]);
      expect(hr(got), [6, 9, 6]);
    });

    test('missing bookkeeping (restore, fresh install) is recovered from the '
        "occurrence's durable rows", () async {
      await tick(recorder(MemoryWakeHarnessLedger(trace)), a);
      await tick(recorder(MemoryWakeHarnessLedger(trace)), b);
      // New, empty bookkeeping over the same durable rows each time.
      await tick(recorder(MemoryWakeHarnessLedger(trace)), b);
      expect((await rows()).map((e) => e.data['seq']), [0, 1],
          reason: 'B is already the last recorded snapshot');
      await tick(recorder(MemoryWakeHarnessLedger(trace)), a);
      final got = await rows();
      expect(got.map((e) => e.data['seq']), [0, 1, 2]);
      expect(hr(got), [6, 9, 6]);
    });
  });
}
