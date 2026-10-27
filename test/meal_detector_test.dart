import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/meal_candidates.dart';

// Minute samples, one hour of observed awake baseline before the rise.
// 60 -> 70 bpm is +16.7%, within the research envelope and above +8 bpm.
List<MealSample> meal({int at = 12 * 60, int duration = 25,
  double rise = 70, double? motion = 0.005}) => [
  for (var m = at - 60; m < at + duration; m++)
    MealSample(ts: m * 60, hr: m < at ? 60 : rise,
        motion: motion, minuteOfDay: m % 1440),
];

void main() {
  test('sustained low-motion awake rise proposes once, at the rise', () {
    final rows = detectMealCandidates(meal());
    expect(rows, hasLength(1));
    expect(rows.single['start_ts'], 12 * 3600);
    expect(rows.single['end_ts'], (12 * 60 + 25) * 60);
  });

  test('empty, short, absent HR and absent motion do not invent meals', () {
    expect(detectMealCandidates([]), isEmpty);
    expect(detectMealCandidates(meal(duration: 19)), isEmpty);
    expect(detectMealCandidates(meal(motion: null)), isEmpty);
    expect(detectMealCandidates([
      for (final s in meal()) MealSample(ts: s.ts, hr: null,
          motion: s.motion, minuteOfDay: s.minuteOfDay),
    ]), isEmpty);
    expect(detectMealCandidates(meal(rise: 62)), isEmpty);
    expect(detectMealCandidates(meal(motion: 0.2)), isEmpty);
  });

  test('sleep, workouts and recording gaps cannot form a candidate', () {
    final span = MealExclusion(12 * 3600, 13 * 3600);
    expect(detectMealCandidates(meal(), sleep: [span]), isEmpty);
    expect(detectMealCandidates(meal(), workouts: [span]), isEmpty);
    // Ten minutes on either side of a ten-minute gap is not sustained 20 min.
    final gapped = meal(duration: 30).where((s) =>
        s.ts < (12 * 60 + 10) * 60 || s.ts >= (12 * 60 + 20) * 60).toList();
    expect(detectMealCandidates(gapped), isEmpty);
  });

  test('nighttime candidates abstain and meal-time prior cannot create a rise', () {
    expect(detectMealCandidates(meal(at: 2 * 60)), isEmpty);
    expect(detectMealCandidates(meal(rise: 60),
        typicalMealMinutes: [12 * 60]), isEmpty);
  });

  test('meal-time prior ranks supported candidates under daily cap', () {
    final samples = [...meal(at: 10 * 60), ...meal(at: 14 * 60)];
    final rows = detectMealCandidates(samples,
        typicalMealMinutes: [14 * 60], maxPerDay: 1);
    expect(rows, hasLength(1));
    expect(rows.single['start_ts'], 14 * 3600);
    expect(detectMealCandidates(samples, maxPerDay: 0), isEmpty);
  });

  test('shipped default caps at ten per day and never duplicates a bout', () {
    // Separate local daytime dates, each with 11 independent supported rises.
    final samples = <MealSample>[];
    for (var d = 0; d < 2; d++) {
      for (var h = 6; h < 17; h++) {
        for (var m = 0; m < 60; m++) {
          samples.add(MealSample(ts: (d * 1440 + h * 60 + m) * 60,
              hr: m < 35 ? 60 : 70, motion: 0.005,
              minuteOfDay: h * 60 + m));
        }
      }
    }
    final rows = detectMealCandidates(samples);
    expect(rows, hasLength(20));
    expect(rows.map((r) => r['start_ts']).toSet(), hasLength(20));
  });
}
