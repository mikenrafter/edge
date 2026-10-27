import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/wake/natural_wake_tuning.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'support/wake_fakes.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';
import 'package:openstrap_edge/wake/wake_night_context.dart';
import 'package:openstrap_edge/state/control_operations.dart';

import 'wake_journal/fixtures.dart';

class ContextStore extends MemoryWakeStateStore
    implements NaturalWakeContextStore, NaturalWakeParameterStore {
  int? selectedTrack;
  @override
  Future<WakeNightValue> nightContext(
    DateTime wakeAt,
    ExpectedSleepSchedule? schedule,
  ) async => const WakeNightValue(
    ConfounderProfile(alcohol: true, stress: true),
    'context_ready',
  );
  @override
  Future<List<Map<String, Object?>>> baselineNights() async => [];
  @override
  Future<NaturalWakeParameters> naturalParameters({int track = 0}) async {
    selectedTrack = track;
    return const NaturalWakeParameters(
      triggerRunOffsetSec: -60,
      windowLeadMinutes: 10,
    );
  }
}

void main() {
  test('collection starts at least 135 minutes before the alarm', () {
    expect(naturalCollectionLead(30).inMinutes, 135);
    expect(naturalCollectionLead(130).inMinutes, 160);
  });
  test('seven alcohol nights learn a separate bounded track', () {
    final d = NaturalWakeTuning.evaluate([
      for (var i = 0; i < 7; i++) outcome(i, substance: WakeSubstance.alcohol),
    ], tonightSubstance: WakeSubstance.alcohol);
    expect(d.eligibleNights, 7);
    expect(d.applied, isTrue);
    expect(d.parameters.triggerRunOffsetSec, -15);
    expect(d.parameters.windowLeadMinutes, 1);
    expect(d.expectEarlyRem, isFalse);
  });
  test(
    'production loads active-set parameters and keeps Gradual and native alarm',
    () async {
      final at = DateTime(2026, 10, 6, 7);
      final env = FakeWakeEnv();
      final store = ContextStore();
      final orchestrator = WakeOrchestrator(
        env: env,
        stateStore: store,
        traceStore: MemoryWakeTraceStore(),
        observer: ScriptedObserver(),
        now: () => at.subtract(const Duration(minutes: 9)),
      );
      addTearDown(orchestrator.dispose);
      final r = await orchestrator.tick(planFor(at, natural: 60, gradual: 15));
      expect(store.selectedTrack, 9);
      expect(r.naturalFired, isFalse);
      expect(env.haptics.map((h) => h.kind), [WakeHapticKind.gradual]);
      expect(env.armedEpochSec, at.millisecondsSinceEpoch ~/ 1000);
      expect(env.cancelCalls, isEmpty);
    },
  );
  test(
    'production causal REM candidate with no physiology stays quiet',
    () async {
      final at = DateTime(2026, 10, 6, 7);
      final env = FakeWakeEnv();
      final orchestrator = WakeOrchestrator(
        env: env,
        stateStore: MemoryWakeStateStore(),
        traceStore: MemoryWakeTraceStore(),
        observer: ScriptedObserver()..evidence = null,
        now: () => at.subtract(const Duration(minutes: 20)),
      );
      addTearDown(orchestrator.dispose);
      final result = await orchestrator.tick(planFor(at, natural: 60));
      expect(result.naturalFired, isFalse);
      expect(env.haptics, isEmpty);
      expect(env.cancelCalls, isEmpty);
    },
  );
}
