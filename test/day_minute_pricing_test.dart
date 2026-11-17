import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';

const _profile = ana.WorkoutUserProfile(
  weightKg: 75, heightCm: 178, age: 35, sex: 'male',
);

void main() {
  // WHY: E18 must reuse prices after an edit while folding cached bills in
  // input order. Exact JSON catches subtract/add drift; the counter catches
  // replaying unchanged prices. Proves CLAIM(minute-bill-order).
  // catches: forcing a replay, retaining removed bills, or summing in map order.
  test('edits, removals and reordered keys reuse bills with exact fresh parity', () {
    final keys = List.generate(1440, (i) => 30000000 + i);
    final hr = List.generate(1440, (i) => 60.0 + (i * 17 % 100));
    final cadence = List<double?>.generate(1440, (i) => i % 3 == 0 ? 110.0 : null);
    final state = DayCalculationState();
    ana.MinuteMetrics run(DayCalculationState st, {double restingHr = 54}) =>
        st.minutesHeavy(keys, hr, cadence: cadence, restingHr: restingHr,
          maxHr: 190, sex: ana.Sex.male, profile: _profile,
          mode: ana.CalculationMode.periodicAwake);
    void check(int expectedWork) {
      final before = state.processedMinutes;
      final actual = run(state);
      final fresh = run(DayCalculationState());
      expect(jsonEncode(actual.trimp.toJson()), jsonEncode(fresh.trimp.toJson()));
      expect(jsonEncode(actual.strain.toJson()), jsonEncode(fresh.strain.toJson()));
      expect(actual.energy, fresh.energy);
      // Batch oracles also catch a forwarding bug shared by both Edge states.
      expect(jsonEncode(actual.trimp.toJson()), jsonEncode(ana.banisterTrimp(
        hr, restingHr: 54, maxHr: 190, sex: ana.Sex.male,
      ).toJson()));
      expect(actual.energy, ana.Calories.dailyEnergy(
        hr, profile: _profile, hrmax: 190, restingHr: 54,
        cadenceSpmPerMin: cadence,
      ));
      expect(actual.minutes, isNull);
      expect(state.processedMinutes - before, expectedWork);
    }
    check(1440);
    hr[720] = 81;
    check(1);
    cadence[721] = 120;
    check(1);
    keys.removeAt(13); hr.removeAt(13); cadence.removeAt(13);
    check(0);
    final key = keys.removeAt(100), value = hr.removeAt(100), steps = cadence.removeAt(100);
    keys.insert(900, key); hr.insert(900, value); cadence.insert(900, steps);
    check(0);
    keys.insert(400, 29999999); hr.insert(400, 112); cadence.insert(400, null);
    check(1);
    check(0);
    final before = state.processedMinutes;
    final changed = run(state, restingHr: 55);
    final fresh = run(DayCalculationState(), restingHr: 55);
    expect(changed.energy, fresh.energy);
    expect(changed.trimp.value, fresh.trimp.value);
    expect(state.processedMinutes - before, keys.length);
  });

  // WHY: Edge's binary checkpoint restores row bills without native columns.
  // It must rebuild once, preserve exact output, then reuse the rebuilt cache.
  test('row checkpoint rebuilds once then prices only a changed minute', () {
    final keys = List.generate(1440, (i) => 30000000 + i);
    final hr = List.generate(1440, (i) => 60.0 + (i * 17 % 100));
    ana.MinuteMetrics run(DayCalculationState state) => state.minutesHeavy(
      keys, hr, restingHr: 54, maxHr: 190, sex: ana.Sex.male,
      profile: _profile, mode: ana.CalculationMode.periodicAwake,
    );
    final original = DayCalculationState();
    run(original);
    final bills = original.minuteBills(beforeMinute: keys.last + 1);
    expect(bills!.bills.length, 1440);
    final checkpoint = encodeDayResumeState(DayResumeState(bills: bills));
    final resume = decodeDayResumeState(checkpoint);
    expect(resume, isNotNull);
    final restored = DayCalculationState()..seedFrom(resume!);
    final rebuilt = run(restored), fresh = run(DayCalculationState());
    expect(jsonEncode(rebuilt.trimp.toJson()), jsonEncode(fresh.trimp.toJson()));
    expect(rebuilt.energy, fresh.energy);
    expect(restored.processedMinutes, 1440);
    run(restored);
    expect(restored.processedMinutes, 1440);
    hr[720] = 81;
    final edited = run(restored), expected = run(DayCalculationState());
    expect(jsonEncode(edited.trimp.toJson()), jsonEncode(expected.trimp.toJson()));
    expect(edited.energy, expected.energy);
    expect(restored.processedMinutes, 1441);
  });
}
