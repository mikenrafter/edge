// WHY: when the opt-in HMM switch (#898) is off/omitted — or on without beats —
// the coordinator's supplied hypnoStages remain authoritative.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  test('supplied stages remain authoritative when HMM is off or has no beats', () {
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
    final hmmNoBeats = deriveDayBundle({...input.toJson(), 'use_hmm_stages': true});
    final hypnogram = (hmmNoBeats['series'] as Map)['hypnogram'] as List;
    expect([for (final segment in hypnogram) (segment as Map)['stage']], stages);
    final sleep = hmmNoBeats['sleep'] as Map;
    expect(sleep['accounting'], (ordinary['sleep'] as Map)['accounting']);
    expect(sleep['staging_effective_method'], 'cardio');
    expect(sleep['staging_fallback'], 'hmm_unavailable');
  });
}
