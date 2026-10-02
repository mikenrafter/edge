// blankNightInBundle: the night's blocks go, the rest of the day stays.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_blank.dart';

Map<String, dynamic> _prev() => {
      'date': '2025-09-05',
      'day_confidence': 0.6,
      'flags': ['SLEEP_MANUAL'],
      'sleep': {'window': {'value': {'onset_ms': 1.0}}},
      'sleep_source': 'manual',
      'wrist_orientation': {'dominant': 'supine'},
      'restlessness_map': [1],
      'clinical': {
        'resting_hr': {'value': 55},
        'readiness_composite': {'value': 71},
        'strain': {'value': 9.0},
      },
      'baselines': {'resting_hr': {'value': 55}},
      'series': {
        'hypnogram': [{'start': 1}],
        'hr_curve': {'v': [60]},
      },
      'coverage': {'hr_samples': 10, 'sleep_seconds': 25200},
      'sleep_periods': {
        'periods': [
          {'is_main': true, 'duration_min': 420},
          {'is_main': false, 'duration_min': 30},
        ],
        'total_asleep_min': 450,
      },
      'scalars': {
        'rhr': 55.0,
        'readiness': 71.0,
        'tst_min': 420.0,
        'strain': 9.0,
        'steps': 4000.0,
      },
    };

Map<String, dynamic> _absent() => {
      'day_confidence': 0.0,
      'flags': ['NO_SLEEP_DETECTED'],
      'sleep': {'window': {'value': '—'}},
      'clinical': {
        'resting_hr': {'value': '—'},
        'readiness_composite': {'value': '—'},
      },
      'baselines': {'resting_hr': {'value': null}},
      'series': {'hypnogram': []},
    };

void main() {
  test('the night goes, the day stays', () {
    final prev = _prev();
    final out = blankNightInBundle(prev, _absent(), source: 'rejected');
    expect(out['sleep'], {'window': {'value': '—'}});
    expect(out['sleep_source'], 'rejected');
    expect(out['flags'], ['SLEEP_REJECTED']);
    expect(out.containsKey('wrist_orientation'), isFalse);
    expect(out.containsKey('restlessness_map'), isFalse);
    expect((out['series'] as Map)['hypnogram'], isEmpty);
    expect((out['series'] as Map)['hr_curve'], {'v': [60]});
    expect((out['clinical'] as Map)['resting_hr'], {'value': '—'});
    expect((out['clinical'] as Map)['strain'], {'value': 9.0});
    expect((out['coverage'] as Map)['sleep_seconds'], 0);
    final periods = (out['sleep_periods'] as Map);
    expect((periods['periods'] as List).single['duration_min'], 30,
        reason: 'the nap is not the night');
    expect(periods['total_asleep_min'], isNull);
    final sc = out['scalars'] as Map;
    expect(sc['rhr'], isNull);
    expect(sc['readiness'], isNull);
    expect(sc['tst_min'], isNull);
    expect(sc['strain'], 9.0);
    expect(sc['steps'], 4000.0);
  });

  test('does not mutate its input, and is idempotent', () {
    final prev = _prev();
    final once = blankNightInBundle(prev, _absent(), source: 'manual');
    expect((prev['scalars'] as Map)['rhr'], 55.0);
    expect(once['flags'], ['NO_SLEEP_DETECTED']);
    final twice = blankNightInBundle(once, _absent(), source: 'manual');
    expect(twice, once);
  });

  test('every sleep scalar is named; daytime keys are not', () {
    for (final k in ['tst_min', 'rhr', 'readiness', 'odi_per_hour', 'spo2']) {
      expect(kSleepDerivedMetricKeys, contains(k));
    }
    for (final k in ['strain', 'steps', 'worn_min', 'nap_min', 'calories']) {
      expect(kSleepDerivedMetricKeys, isNot(contains(k)));
    }
  });
}
