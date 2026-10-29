// The wake harness through the orchestrator's production entry (tick): each
// stored coefficient flips a known fire/hold, rules route as specified, the
// fallback alarm is untouched (S1), defaults equal no harness (S2), and a
// non-default config leaves one provenance record per occurrence and config.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/natural_wake.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/wake_harness.dart';
import 'package:openstrap_edge/wake/wake_harness_ledger.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);
int get _tSec => _t.millisecondsSinceEpoch ~/ 1000;

/// The production legacy evaluator's place: a scripted answer, and what it
/// was asked with.
class _FakeLegacy implements LegacyWakeEvaluator {
  bool fire = true;
  ConfounderProfile journal = const ConfounderProfile();
  final asked = <ConfounderProfile?>[];
  @override
  Future<ConfounderProfile> journalProfile(
          DateTime end, ExpectedSleepSchedule? schedule) async =>
      journal;
  @override
  Future<bool> detected(DateTime now, DateTime end,
      ExpectedSleepSchedule? schedule,
      {ConfounderProfile? profile}) async {
    asked.add(profile);
    return fire;
  }
}

class _Rig {
  _Rig({MemoryWakeStateStore? state, MemoryWakeTraceStore? trace})
      : clock = TestClock(_t.subtract(const Duration(minutes: 40))),
        state = state ?? MemoryWakeStateStore(),
        trace = trace ?? MemoryWakeTraceStore() {
    env = FakeWakeEnv()..armedEpochSec = _tSec;
    observer = ScriptedObserver();
    ledger = MemoryWakeHarnessLedger(this.trace);
    orchestrator = _build();
  }
  final TestClock clock;
  final MemoryWakeStateStore state;
  final MemoryWakeTraceStore trace;
  final legacy = _FakeLegacy();
  late final MemoryWakeHarnessLedger ledger;
  late final FakeWakeEnv env;
  late final ScriptedObserver observer;
  late WakeOrchestrator orchestrator;
  WakeOrchestrator _build() => WakeOrchestrator(
      env: env,
      observer: observer,
      stateStore: state,
      traceStore: trace,
      legacy: legacy,
      harnessRecorder: WakeHarnessRecorder(ledger),
      now: clock.call);
  void restart() => orchestrator = _build();
  Future<WakeTickOutcome> tick(WakePlanInput p) => orchestrator.tick(p);
  Future<List<WakeTraceEntry>> entries([String? kind]) async {
    final all = await trace.forWake(_tSec);
    return kind == null ? all : all.where((e) => e.kind == kind).toList();
  }

  Future<String?> lastReason() async =>
      (await entries('natural')).lastOrNull?.data['reason'] as String?;
}

WakePlanInput _plan([WakeHarnessConfig? h]) {
  final p = planFor(_t, natural: 60);
  return h == null ? p : p.withHarness(h);
}

Future<(_Rig, bool, String?)> _run(
  NaturalObservation obs, [
  WakeHarnessConfig? h,
  bool legacyFires = true,
]) async {
  final r = _Rig();
  r.observer.next = obs;
  r.legacy.fire = legacyFires;
  final out = await r.tick(_plan(h));
  return (r, out.naturalFired, await r.lastReason());
}

void main() {
  setUp(HeadlessSyncGate.resetForTest);

  test('withHarness carries the config', () {
    const h = WakeHarnessConfig(rule: WakeRule.hybrid);
    expect(_plan(h).harness.rule, WakeRule.hybrid);
    expect(_plan(h).withSleepOnset(_t).harness.rule, WakeRule.hybrid);
  });

  group('S2: the default config is today', () {
    for (final (name, obs) in [
      ('rem', remObs()),
      ('nrem', stageObs('nrem')),
      ('stale', absentObs('staleEvidence')),
      ('low confidence', remObs(confidence: 0.1)),
    ]) {
      test('identical decision and trace: $name', () async {
        final (a, fa, ra) = await _run(obs);
        final (b, fb, rb) = await _run(obs, WakeHarnessConfig.defaults);
        expect(fb, fa);
        expect(rb, ra);
        expect(
          [for (final e in await b.entries()) (e.kind, jsonEncode(e.data))],
          [for (final e in await a.entries()) (e.kind, jsonEncode(e.data))],
        );
        expect(await b.entries('harness'), isEmpty);
      });
    }
  });

  group('natural coefficients flip fire/hold', () {
    test('trigger run', () async {
      final obs = remObs(runSec: 150);
      expect((await _run(obs)).$2, isTrue);
      final (_, fired, reason) =
          await _run(obs, const WakeHarnessConfig(triggerRunSec: 180));
      expect(fired, isFalse);
      expect(reason, 'remNotStable');
      final (_, low, _) = await _run(
          remObs(runSec: 40), const WakeHarnessConfig(triggerRunSec: 30));
      expect(low, isTrue);
    });

    test('min confidence', () async {
      final obs = remObs(confidence: 0.5);
      expect((await _run(obs)).$2, isTrue);
      final (_, fired, reason) =
          await _run(obs, const WakeHarnessConfig(minConfidence: 0.55));
      expect(fired, isFalse);
      expect(reason, 'lowConfidence');
    });

    test('eligible stages: REM only holds on wake', () async {
      final obs = stageObs('wake');
      expect((await _run(obs)).$2, isTrue);
      final (_, fired, reason) =
          await _run(obs, const WakeHarnessConfig(remOnly: true));
      expect(fired, isFalse);
      expect(reason, 'noRemCandidate');
    });

    test('evidence-age planner cap', () async {
      final obs = remObs(evidenceAgeMs: 100000);
      expect((await _run(obs)).$2, isTrue);
      final (_, fired, reason) =
          await _run(obs, const WakeHarnessConfig(evidenceAgeCapSec: 60));
      expect(fired, isFalse);
      expect(reason, 'samplesStale');
    });
  });

  group('legacy rule', () {
    test('Natural stands down: no stager, no early haptic from this path',
        () async {
      final (r, fired, _) =
          await _run(remObs(), const WakeHarnessConfig(rule: WakeRule.legacy));
      expect(fired, isFalse);
      expect(r.env.haptics, isEmpty);
      expect(r.observer.requests, isEmpty);
      expect(r.legacy.asked, isEmpty,
          reason: 'the legacy route (AppState) evaluates and records it');
      expect(await r.lastReason(), isNull);
    });
  });

  group('hybrid rule: production legacy AND NOT a current NREM', () {
    const hybrid = WakeHarnessConfig(rule: WakeRule.hybrid);

    test('a current NREM at or above the veto confidence holds', () async {
      final (_, fired, reason) =
          await _run(stageObs('nrem', confidence: 0.5), hybrid);
      expect(fired, isFalse);
      expect(reason, 'noRemCandidate');
    });

    test('NREM below the veto confidence: the legacy decision fires',
        () async {
      final (_, natural, _) = await _run(stageObs('nrem', confidence: 0.4));
      expect(natural, isFalse, reason: 'control: Natural holds on NREM');
      final (_, fired, _) = await _run(stageObs('nrem', confidence: 0.4),
          const WakeHarnessConfig(rule: WakeRule.hybrid, vetoMinConfidence: 0.45));
      expect(fired, isTrue);
    });

    test('the legacy evaluator holding holds, whatever the stage', () async {
      final (_, fired, reason) = await _run(remObs(), hybrid, false);
      expect(fired, isFalse);
      expect(reason, 'legacyHold');
    });

    test('no current stager evidence: legacy stands', () async {
      final (_, fired, _) = await _run(absentObs('staleEvidence'), hybrid);
      expect(fired, isTrue);
    });

    test('an observer error is no stage evidence: legacy stands', () async {
      final r = _Rig()..observer.failWith = StateError('stager down');
      final out = await r.tick(_plan(hybrid));
      expect(out.naturalFired, isTrue);
      final strict = _Rig()..observer.failWith = StateError('stager down');
      final held = await strict.tick(_plan(const WakeHarnessConfig(
          rule: WakeRule.hybrid, requireRemOrWake: true)));
      expect(held.naturalFired, isFalse);
    });

    test('require REM or wake: no evidence holds, REM fires', () async {
      const strict = WakeHarnessConfig(
          rule: WakeRule.hybrid, requireRemOrWake: true);
      expect((await _run(absentObs('staleEvidence'), strict)).$2, isFalse);
      expect((await _run(remObs(runSec: 10), strict)).$2, isTrue,
          reason: 'hybrid has no run-length gate');
    });

    test('the evaluator gets the composed profile, and the record carries it',
        () async {
      final r = _Rig()
        ..observer.next = remObs()
        ..legacy.journal = const ConfounderProfile(
            protectionMinutes: 10, trendWindowMinutes: 5, workout: true);
      await r.tick(_plan(
          const WakeHarnessConfig(rule: WakeRule.hybrid, hrRiseBpm: 9)));
      expect(r.legacy.asked, hasLength(1));
      final used = r.legacy.asked.single!;
      expect(used.hrArousalBpm, 9);
      expect(used.protectionMinutes, 10);
      final eff = (await r.entries('harness')).single.data['effective'] as Map;
      expect(eff['hrRiseBpm'], 9);
      expect(eff['protectionMinutes'], 10);
      expect(eff['trendWindowMinutes'], 5);
    });
  });

  test('S1: the fallback alarm is armed and never cancelled under every rule',
      () async {
    for (final h in [
      const WakeHarnessConfig(rule: WakeRule.legacy, hrRiseBpm: 15),
      const WakeHarnessConfig(
          rule: WakeRule.hybrid,
          vetoMinConfidence: 0,
          requireRemOrWake: true,
          motionCeilingG: 0.02),
      const WakeHarnessConfig(
          triggerRunSec: 300, minConfidence: 0.9, evidenceAgeCapSec: 60),
    ]) {
      final r = _Rig();
      r.env.armedEpochSec = null;
      await r.tick(_plan(h));
      expect(r.env.armCalls, [_tSec], reason: h.rule.name);
      expect(r.env.cancelCalls, isEmpty);
      expect(await r.entries('harness'),
          hasLength(h.rule == WakeRule.legacy ? 0 : 1),
          reason: '${h.rule.name}: legacy records on its own route');
    }
  });

  group('provenance (G3)', () {
    test('one record per occurrence and config, kept across a restart',
        () async {
      const h = WakeHarnessConfig(rule: WakeRule.hybrid, hrRiseBpm: 9);
      final r = _Rig();
      r.observer.next = stageObs('nrem', confidence: 0.6);
      await r.tick(_plan(h));
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(_plan(h));
      r.restart();
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(_plan(h));
      final recs = await r.entries('harness');
      expect(recs, hasLength(1));
      expect(recs.single.data['rule'], 'hybrid');
      expect((recs.single.data['effective'] as Map)['hrRiseBpm'], 9);
    });

    test('once experimental, a reset to defaults is recorded; A-B-A keeps '
        'both activations of A', () async {
      const a = WakeHarnessConfig(rule: WakeRule.hybrid);
      const b = WakeHarnessConfig(rule: WakeRule.hybrid, hrRiseBpm: 5);
      final r = _Rig();
      r.observer.next = stageObs('nrem', confidence: 0.6);
      for (final h in [a, b, a, WakeHarnessConfig.defaults]) {
        await r.tick(_plan(h));
        r.clock.advance(const Duration(seconds: 30));
      }
      final recs = await r.entries('harness');
      expect(recs.map((e) => e.data['seq']), [0, 1, 2, 3]);
      expect(recs.map((e) => e.data['rule']),
          ['hybrid', 'hybrid', 'hybrid', 'natural']);
      expect(recs[0].data['digest'], recs[2].data['digest']);
      expect(recs[0].data['digest'], isNot(recs[1].data['digest']));
    });

    test('a mid-window change writes a new record', () async {
      final r = _Rig();
      r.observer.next = stageObs('nrem', confidence: 0.6);
      await r.tick(_plan(const WakeHarnessConfig(rule: WakeRule.hybrid)));
      r.clock.advance(const Duration(seconds: 30));
      await r.tick(_plan(const WakeHarnessConfig(
          rule: WakeRule.hybrid, vetoMinConfidence: 0.7)));
      final recs = await r.entries('harness');
      expect(recs, hasLength(2));
      expect((recs.last.data['effective'] as Map)['vetoMinConfidence'], 0.7);
    });
  });
}
