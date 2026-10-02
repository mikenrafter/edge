// Phase 7 audit — absent and malformed inputs to the sleep-blanking patch.
// It runs over stored rows (some written by older builds), so a missing or odd
// section must blank cleanly, never throw and never invent a value.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/sleep_blank.dart';

void main() {
  test('an empty stored result and an empty absent envelope blank to the '
      'minimum: only the source and the flag are written', () {
    final out = blankNightInBundle(const {}, const {}, source: 'rejected');
    expect(out['sleep_source'], 'rejected');
    expect(out['flags'], ['SLEEP_REJECTED']);
    expect(out.keys.toSet(), {'sleep_source', 'flags'});
  });

  test('a user window with no samples is flagged as no sleep detected, not '
      'rejected', () {
    final out = blankNightInBundle(const {}, const {}, source: 'user_window');
    expect(out['flags'], ['NO_SLEEP_DETECTED']);
  });

  test('odd section types are tolerated and never turned into numbers', () {
    final out = blankNightInBundle(
      {
        'scalars': 'not a map',
        'clinical': [],
        'series': 7,
        'coverage': {'sleep_seconds': 'x'},
        'sleep_periods': {'periods': 'oops', 'total_asleep_min': 400},
      },
      {
        'clinical': {'hrv_time': null},
      },
      source: 'rejected',
    );
    expect((out['sleep_periods'] as Map)['periods'], isEmpty);
    expect((out['sleep_periods'] as Map)['total_asleep_min'], isNull);
    expect((out['coverage'] as Map)['sleep_seconds'], 0);
  });

  test('blanking twice is the same as blanking once, whatever the input', () {
    final prev = {
      'scalars': {'rmssd': 55.0, 'strain': 12.0, 'tst_min': 410.0},
      'sleep_periods': {
        'periods': [
          {'is_main': true, 'start': 1},
          {'is_main': false, 'start': 2},
        ],
        'total_asleep_min': 410,
      },
      'series': {'hypnogram': [1, 2, 3]},
    };
    final once = blankNightInBundle(prev, const {}, source: 'rejected');
    final twice = blankNightInBundle(once, const {}, source: 'rejected');
    expect(twice, once);
    // The day stays; the night goes; the nap survives.
    expect((once['scalars'] as Map)['strain'], 12.0);
    expect((once['scalars'] as Map)['rmssd'], isNull);
    expect(((once['sleep_periods'] as Map)['periods'] as List).single['start'], 2);
  });

  test('the input map is never mutated', () {
    final prev = {
      'scalars': {'rmssd': 55.0},
    };
    blankNightInBundle(prev, const {}, source: 'rejected');
    expect((prev['scalars'] as Map)['rmssd'], 55.0);
  });
}
