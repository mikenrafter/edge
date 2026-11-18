// WHY: the coordinator owns staging. A legacy serialized flag must never
// start a second HMM classifier inside the day-bundle worker.
// Proves CLAIM(day-bundle-stage-owner).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test('legacy HMM flag is ignored and supplied stages remain authoritative', () {
    const start = 1780000000;
    const stages = ['deep', 'rem', 'unobserved', 'light', 'wake'];
    final input = DayBundleInput(
      date: '2026-06-01', dayTsSec: const [], dayHr: const [],
      sleepTsSec: [for (var i = 0; i < stages.length; i++) start + i],
      sleepHr: const [55, 55, 55, 55, 55],
      sleepRrTsMs: const [], sleepRrMs: const [], sleepSkinTemp: const [],
      sleepJson: const {}, hypnoStages: stages,
      sleepOnsetSec: start, sleepOffsetSec: start + stages.length,
      profile: const {},
    );
    final ordinary = deriveDayBundle(input.toJson());
    final legacy = deriveDayBundle({...input.toJson(), 'use_hmm_stages': true});
    expect(legacy, ordinary);
    final hypnogram = (legacy['series'] as Map)['hypnogram'] as List;
    expect([for (final segment in hypnogram) (segment as Map)['stage']], stages);
  });
}
