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
  final attempts = <WakeTraceEntry>[];
  @override
  Future<bool> appendOnce(WakeTraceEntry entry) async {
    attempts.add(entry);
    if (failures > 0) {
      failures--;
      return false;
    }
    return super.appendOnce(entry);
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
      WakeHarnessRecorder(l, now: () => clock);
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
    await r.record(_epoch, rec(WakeHarnessConfig.defaults), untouched: true);
    expect(await rows(), isEmpty);
    await r.record(_epoch, rec(legacy), untouched: false);
    await r.record(_epoch, rec(legacy), untouched: false);
    await r.record(_epoch, rec(WakeHarnessConfig.defaults), untouched: true);
    final got = await rows();
    expect(got.map((e) => e.data['seq']), [0, 1]);
    expect(got.map((e) => e.data['rule']), ['legacy', 'natural']);
  });

  test('a failed append is not acknowledged and is retried as the same '
      'activation', () async {
    final l = _FlakyLedger(trace)..failures = 2;
    final r = recorder(l);
    await r.record(_epoch, rec(legacy), untouched: false);
    clock = clock.add(const Duration(seconds: 30));
    await r.record(_epoch, rec(legacy), untouched: false);
    expect(await rows(), isEmpty);
    clock = clock.add(const Duration(seconds: 30));
    await r.record(_epoch, rec(legacy), untouched: false);
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
    await recorder(l).record(_epoch, rec(legacy), untouched: false);
    expect(await rows(), isEmpty);
    // A new recorder over the same durable ledger: what a restart is.
    final again = recorder(l);
    const b = WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 8);
    await again.record(_epoch, rec(b), untouched: false);
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
    await r.record(_epoch, rec(legacy), untouched: false);
    await r.record(_epoch, rec(legacy, p: workout), untouched: false);
    await r.record(_epoch, rec(legacy), untouched: false);
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
    await r.record(_epoch, rec(hybrid), untouched: false);
    await r.record(_epoch, rec(hybrid, lead: 5), untouched: false);
    final got = await rows();
    expect(got, hasLength(2));
    expect((got[1].data['effective'] as Map)['windowLeadMinutes'], 5);
  });

  test('another occurrence starts its own sequence', () async {
    final r = recorder(MemoryWakeHarnessLedger(trace));
    await r.record(_epoch, rec(legacy), untouched: false);
    await r.record(_epoch + 86400, rec(legacy), untouched: false);
    expect(await rows(), hasLength(1));
    expect((await rows()).single.data['seq'], 0);
    expect(
      (await trace.forWake(_epoch + 86400)).single.data['seq'],
      0,
    );
  });
}
