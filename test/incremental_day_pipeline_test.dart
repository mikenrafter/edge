import 'dart:convert';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart' show CalculationMode;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'support/incremental_day_fixture.dart';
import 'support/incremental_compare.dart';

void _sameBundle(Object? actual, Object? expected, [String path = r'$']) =>
    expectSameJson(actual, expected, path: path);

Map<String, dynamic> _compare(
  Map<String, dynamic> input,
  DayCalculationState state, {
  CalculationMode mode = CalculationMode.periodicAwake,
}) {
  final before = jsonEncode(input);
  final oracle = deriveDayBundle(copyDay(input));
  final result = deriveDayBundle(input, state: state, mode: mode);
  _sameBundle(result, oracle);
  expect(jsonEncode(input), before, reason: 'input is read-only');
  return result;
}

void main() {
  for (final seed in [1, 42, 914]) {
    for (final gap in [false, true]) {
      for (final chunk in [61, 257]) {
        test('awake day append parity seed=$seed gap=$gap chunk=$chunk', () {
          final full = incrementalDay(seed: seed, gaps: gap, daySeconds: 601);
          final state = DayCalculationState()..debugStats = {};
          var previousLength = 0;
          var first = true;
          var affectedMinuteBudget = 0;
          for (final n in <int>{
            1,
            59,
            60,
            61,
            299,
            300,
            301,
            for (var i = chunk; i < (full['day_hr'] as List).length; i += chunk)
              i,
            (full['day_hr'] as List).length,
          }.toList()..sort()) {
            final previousHits = state.hits;
            final input = prefixDay(full, n);
            affectedMinuteBudget += (full['day_ts'] as List)
                .sublist(previousLength, n)
                .map((v) => (v as int) ~/ 60)
                .toSet()
                .length;
            previousLength = n;
            _compare(input, state);
            expect(state.computations, greaterThan(0));
            if (!first) {
              expect(
                state.hits,
                greaterThanOrEqualTo(previousHits + 2),
                reason:
                    'multiple finished-night components are reused on awake append',
              );
            }
            first = false;
          }
          expect(
            state.debugStats!['hrv_time']!.misses,
            1,
            reason: 'finished unchanged night is reused during daytime append',
          );
          expect(state.hits, greaterThan(0));
          expect(
            state.processedMinutes,
            lessThanOrEqualTo(affectedMinuteBudget),
            reason: 'append revises only the trailing incomplete minute',
          );
        });
      }
    }
  }
  final mutations = <String, void Function(Map<String, dynamic>)>{
    'historical HR replacement': (d) => (d['day_hr'] as List)[17] = 149,
    'historical timestamp replacement': (d) => (d['day_ts'] as List)[17] += 73,
    'remove historic day sample': (d) {
      (d['day_ts'] as List).removeAt(17);
      (d['day_hr'] as List).removeAt(17);
    },
    'male to female profile': (d) => (d['profile'] as Map)['sex'] = 'female',
    'other sex interpolation': (d) => (d['profile'] as Map)['sex'] = 'other',
    'profile mass/height/age': (d) => (d['profile'] as Map).addAll(
      <String, dynamic>{'age': 47, 'weight_kg': 61.0, 'height_cm': 167.0},
    ),
    'resting HR anchor': (d) => (d['profile'] as Map)['resting_hr'] = 65,
    'observed ceiling': (d) => d['observed_hr_ceiling_bpm'] = 197.0,
    'missing profile': (d) => d['profile'] = <String, dynamic>{},
    'unknown device family': (d) => d['device_family'] = null,
    'cadence walking spans': (d) => (d['step_spans'] as List)[0][2] = 280,
    'remove cadence': (d) => (d['step_spans'] as List).clear(),
    'RR artifact replacement': (d) => (d['sleep_rr_ms'] as List)[89] = 2200.0,
    'RR gap replacement': (d) => (d['sleep_rr_ts_ms'] as List)[89] += 13000,
    'sleep HR replacement': (d) => (d['sleep_hr'] as List)[31] = 98,
    'stage replacement': (d) => (d['hypno_stages'] as List)[190] = 'wake',
    'sleep offset/bounds': (d) {
      d['sleep_offset_sec'] -= 60;
      (d['sleep_json'] as Map)['window']['offset_ms'] -= 60000;
    },
    'sleep accounting': (d) => (d['sleep_json'] as Map).addAll(
      <String, dynamic>{'tst_sec': 300, 'waso_sec': 61, 'efficiency_pct': 83.1},
    ),
    'skin temperature mutation': (d) =>
        (d['sleep_skin_temp'] as List)[37] += 200,
    'baseline histories': (d) {
      for (final k in [
        'rmssd_history',
        'rhr_history',
        'resp_history',
        'ln_rmssd_history',
        'skin_temp_adc_history',
      ]) {
        (d[k] as List)[0] += 3;
      }
    },
    'day flags/confidence': (d) {
      (d['day_flags'] as List).add('LOW_CONFIDENCE_RECOVERY');
      d['day_confidence'] = .3;
    },
  };
  for (final entry in mutations.entries) {
    test('awake cache invalidates ${entry.key}', () {
      final input = copyDay(incrementalDay());
      final state = DayCalculationState();
      _compare(input, state);
      entry.value(input);
      _compare(input, state);
      final hits = state.hits;
      _compare(input, state);
      expect(
        state.hits,
        greaterThan(hits),
        reason: 'new dependency snapshot must be reusable',
      );
      expect(state.computations, greaterThan(0));
    });
  }
  test('awake historical minute replacement prices one affected minute', () {
    final input = incrementalDay(daySeconds: 600);
    final state = DayCalculationState();
    _compare(input, state);
    expect(state.processedMinutes, 10);
    final work = state.processedMinutes;
    (input['day_hr'] as List)[17] = 149;
    _compare(input, state);
    expect(state.processedMinutes - work, 1);
    final hits = state.hits;
    _compare(input, state);
    expect(state.processedMinutes, work + 1);
    expect(state.hits, greaterThan(hits));
  });
  for (final mode in [
    CalculationMode.sleep,
    CalculationMode.heavy,
    CalculationMode.forced,
  ]) {
    test('$mode bypasses every reuse hit', () {
      final input = copyDay(incrementalDay());
      final state = DayCalculationState()..debugStats = {};
      _compare(input, state);
      final hits = state.hits, computations = state.computations;
      _compare(input, state, mode: mode);
      expect(state.hits, hits);
      expect(state.computations, greaterThan(computations));
      expect(state.debugStats!['hrv_time']!.misses, 2);
    });
  }
  test('default state mode remains forced', () {
    final input = copyDay(incrementalDay());
    final state = DayCalculationState();
    final oracle = deriveDayBundle(copyDay(input));
    _sameBundle(deriveDayBundle(input, state: state), oracle);
    final work = state.computations;
    _sameBundle(deriveDayBundle(input, state: state), oracle);
    expect(state.hits, 0);
    expect(state.computations, greaterThan(work));
  });
  test(
    'isolate returns copied calculation state with reusable finished-night cache',
    () async {
      final input = copyDay(incrementalDay());
      var state = DayCalculationState();
      _compare(input, state);
      final computations = state.computations;
      final original = state;
      final originalHits = state.hits;
      final result = await Isolate.run(() {
        final bundle = deriveDayBundle(
          input,
          state: state,
          mode: CalculationMode.periodicAwake,
        );
        return (bundle: bundle, state: state);
      });
      expect(
        original.hits,
        originalHits,
        reason: 'worker mutations cannot change main state',
      );
      _sameBundle(result.bundle, deriveDayBundle(copyDay(input)));
      state = result.state;
      expect(state.computations, computations);
      expect(state.hits, greaterThan(original.hits));
      final hits = state.hits;
      _compare(input, state);
      expect(state.hits, greaterThan(hits));
    },
  );
}
