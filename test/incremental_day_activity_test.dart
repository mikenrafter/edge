import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'support/incremental_activity_fixture.dart';
import 'support/incremental_compare.dart';

const _male = Profile(ageYears: 35, weightKg: 75, heightCm: 178, sex: 'male');
const _profiles = <Profile>[
  _male,
  Profile(ageYears: 41, weightKg: 61, heightCm: 167, sex: 'female'),
  Profile(ageYears: 29, weightKg: 70, heightCm: 172, sex: 'other'),
];

void _same(Object? actual, Object? expected, [String path = r'$']) =>
    expectSameJson(actual, expected, path: path);

/// Samples folded into the per-second summaries; repeating an unchanged day
/// on a periodic awake pass must add none.
int _work(DayCalculationState s) =>
    s.processedHrSamples +
    s.processedOrientationSamples +
    s.processedMotionPoints;

typedef _Output = ({
  Map<String, dynamic> bundle,
  Map<String, dynamic> scalars,
  Map<String, dynamic> wake,
});
_Output _run(
  Substrate s, {
  DayCalculationState? state,
  ana.CalculationMode mode = ana.CalculationMode.forced,
  Profile profile = _male,
  double? restingHr = 54,
  int? onset,
  int? offset,
  int calendarSeconds = 86400,
  bool cadence = true,
  List<Map<String, dynamic>> sessions = const [],
}) {
  final start = s.tsSec.first;
  final bundle = <String, dynamic>{
    'untouched': {
      'nested': [3, null],
    },
  };
  final scalars = <String, dynamic>{
    'readiness': 51.7,
    'strain': 17.5,
    'calories': 900.0,
    'calories_total': 999.0,
    'steps': 123,
  };
  final wake = DerivationEngine.applyDayActivity(
    bundle: bundle,
    scalars: scalars,
    daySub: s,
    profile: profile,
    sleepOnsetSec: onset ?? 0,
    sleepOffsetSec: offset ?? 0,
    dayStartSec: start,
    dayCalendarEndSec: start + calendarSeconds,
    dataNowSec: s.tsSec.last + 1,
    restingHr: restingHr,
    dynFloorG: .03,
    dynHistoryDays: 14,
    liveStepsReal: cadence ? 480 : 0,
    liveStepsFromStrap: 0,
    stepSpans: cadence
        ? [
            [start, start + 240, 480],
          ]
        : [],
    sessions: sessions,
    state: state,
    mode: mode,
  );
  return (bundle: bundle, scalars: scalars, wake: wake);
}

void _compare(
  Substrate s,
  DayCalculationState state, {
  ana.CalculationMode mode = ana.CalculationMode.periodicAwake,
  Profile profile = _male,
  double? restingHr = 54,
  int? onset,
  int? offset,
  int calendarSeconds = 86400,
  bool cadence = true,
  List<Map<String, dynamic>> sessions = const [],
}) {
  final oracle = _run(
    s,
    profile: profile,
    restingHr: restingHr,
    onset: onset,
    offset: offset,
    calendarSeconds: calendarSeconds,
    cadence: cadence,
    sessions: sessions,
  );
  final actual = _run(
    s,
    state: state,
    mode: mode,
    profile: profile,
    restingHr: restingHr,
    onset: onset,
    offset: offset,
    calendarSeconds: calendarSeconds,
    cadence: cadence,
    sessions: sessions,
  );
  _same(actual.wake, oracle.wake, 'wake');
  _same(actual.bundle, oracle.bundle, 'bundle');
  _same(actual.scalars, oracle.scalars, 'scalars');
  expect(() => jsonEncode(actual.bundle), returnsNormally);
}

void main() {
  for (final seed in [1, 42]) {
    for (final profile in _profiles) {
      for (final gaps in [false, true]) {
        test(
          'canonical awake append seed=$seed sex=${profile.sex} gaps=$gaps',
          () {
            final full = incrementalActivity(seed: seed, gaps: gaps);
            final state = DayCalculationState();
            var previousLength = 0, affectedBudget = 0;
            for (final n in [1, 59, 60, 61, 119, 180, 301, full.length]) {
              if (n > full.length) continue;
              final s = full.sliceIdx(0, n);
              affectedBudget += full.tsSec
                  .sublist(previousLength, n)
                  .map((t) => t ~/ 60)
                  .toSet()
                  .length;
              previousLength = n;
              _compare(s, state, profile: profile);
              expect(_work(state), greaterThan(0));
            }
            expect(state.processedMinutes, greaterThan(0));
            expect(state.processedMinutes, lessThanOrEqualTo(affectedBudget));
            final work = state.processedMinutes, samples = _work(state);
            _compare(full, state, profile: profile);
            expect(state.processedMinutes, work);
            expect(_work(state), samples);
          },
        );
      }
    }
  }
  for (final family in <String?>['gen4', 'gen5', null, 'unknown']) {
    for (final cadence in [false, true]) {
      test('canonical family=$family cadence=$cadence envelope parity', () {
        final s = incrementalActivity(family: family, gaps: true);
        final state = DayCalculationState();
        _compare(s, state, cadence: cadence);
        final samples = _work(state);
        _compare(s, state, cadence: cadence);
        expect(_work(state), samples);
      });
    }
  }
  for (final profile in <Profile>[
    const Profile(),
    const Profile(ageYears: 35, sex: 'm'),
    const Profile(ageYears: 35, weightKg: 75, sex: 'm'),
    const Profile(ageYears: 35, weightKg: 75, heightCm: 178),
  ]) {
    test('canonical missing profile anchors ${profile.toMap()}', () {
      final s = incrementalActivity();
      final state = DayCalculationState();
      _compare(s, state, profile: profile, restingHr: null);
      final samples = _work(state);
      _compare(s, state, profile: profile, restingHr: null);
      expect(_work(state), samples);
    });
  }
  test('canonical historical HR edits price only the changed minute', () {
    final s = incrementalActivity(seconds: 600);
    final state = DayCalculationState();
    _compare(s, state);
    final work = state.processedMinutes;
    expect(work, 10);
    s.hr[17] = 149;
    _compare(s, state);
    expect(state.processedMinutes, work + 1);
    final samples = _work(state);
    _compare(s, state);
    expect(state.processedMinutes, work + 1);
    expect(_work(state), samples);
  });
  test('canonical wake bounds, profile, duration and cadence invalidation', () {
    final s = incrementalActivity();
    final state = DayCalculationState();
    for (final profile in _profiles) {
      for (final duration in [23 * 3600, 24 * 3600, 25 * 3600]) {
        for (final cadence in [false, true]) {
          _compare(
            s,
            state,
            profile: profile,
            onset: s.tsSec.first + 60,
            offset: s.tsSec.first + 180,
            calendarSeconds: duration,
            cadence: cadence,
            restingHr: profile.sex == 'female' ? 65 : 54,
          );
        }
      }
    }
    final samples = _work(state);
    _compare(
      s,
      state,
      profile: _profiles.last,
      onset: s.tsSec.first + 60,
      offset: s.tsSec.first + 180,
      calendarSeconds: 25 * 3600,
    );
    expect(_work(state), samples);
  });
  test('canonical motion replacement and absent accel keep honest outputs', () {
    final state = DayCalculationState();
    final s = incrementalActivity();
    _compare(s, state);
    s.ax[17] += .2;
    _compare(s, state);
    final absent = incrementalActivity(missingAccel: true);
    _compare(absent, state);
    final samples = _work(state);
    _compare(absent, state);
    expect(_work(state), samples);
  });
  test(
    'canonical session gap credit updates without changing covered-minute prices',
    () {
      final s = incrementalActivity();
      final state = DayCalculationState();
      _compare(s, state);
      final session = <String, dynamic>{
        'start_ts': s.tsSec.last + 60,
        'end_ts': s.tsSec.last + 360,
        'calories': 250.0,
        'status': 'done',
      };
      _compare(s, state, sessions: [session]);
      session['calories'] = 350.0;
      _compare(s, state, sessions: [session]);
      final samples = _work(state);
      _compare(s, state, sessions: [session]);
      expect(_work(state), samples);
    },
  );
  for (final mode in [
    ana.CalculationMode.sleep,
    ana.CalculationMode.heavy,
    ana.CalculationMode.forced,
  ]) {
    test('canonical $mode always recomputes and leaves hits unchanged', () {
      final s = incrementalActivity();
      final state = DayCalculationState();
      _compare(s, state);
      final work = _work(state), hits = state.hits;
      _compare(s, state, mode: mode);
      expect(state.hits, hits);
      expect(_work(state), greaterThan(work));
    });
  }
  // The engine no longer recomputes the batch curve over the incremental one
  // (`_computeDayBlocks` used to overwrite it). The curve the summary hands out
  // is therefore the persisted value, so it must be the batch value for every
  // mode, on gappy and absent-accel days too.
  for (final mode in ana.CalculationMode.values) {
    for (final fixture in <String>['canonical', 'gaps', 'absent']) {
      test('activity_curve from state equals the stateless one mode=$mode '
          '$fixture', () {
        final s = switch (fixture) {
          'gaps' => incrementalActivity(seed: 7, seconds: 900, gaps: true),
          'absent' => incrementalActivity(missingAccel: true),
          _ => incrementalActivity(),
        };
        final oracle = _run(s);
        final state = DayCalculationState();
        // Seed an awake state first so periodic modes take their reuse path.
        _run(s.sliceIdx(0, s.length ~/ 2),
            state: state, mode: ana.CalculationMode.periodicAwake);
        final actual = _run(s, state: state, mode: mode);
        _same(actual.bundle['activity_curve'], oracle.bundle['activity_curve']);
        expect(jsonEncode(actual.bundle['activity_curve']),
            jsonEncode(oracle.bundle['activity_curve']));
      });
    }
  }
  test('canonical omitted mode retains forced behavior', () {
    final s = incrementalActivity();
    final state = DayCalculationState();
    final expected = _run(s);
    final actual = _run(s, state: state);
    _same(actual.bundle, expected.bundle);
    final work = _work(state);
    _run(s, state: state);
    expect(_work(state), greaterThan(work));
    expect(state.hits, 0);
  });

  // Stress inputs for the per-second summaries: each pass is compared with the
  // batch readers by `_compare`, on prefixes, edits and a shrink.
  Substrate stressed({required int seed}) {
    final s = incrementalActivity(seed: seed, seconds: 900, gaps: true);
    for (var i = 0; i < s.length; i++) {
      // Plausibility rejects at both ends, dropouts, and a 200 s record gap.
      if (i % 53 == 7) s.hr[i] = 250;
      if (i % 67 == 11) s.hr[i] = 21;
      if (i % 29 == 3) s.hr[i] = 0;
      if (i % 41 == 5) s.ax[i] = double.nan;
      if (i % 37 == 9) {
        s.ax[i] = 0;
        s.ay[i] = 0;
        s.az[i] = 0;
      }
      if (i >= 500) s.tsSec[i] += 200;
    }
    return s;
  }

  for (final seed in [3, 77]) {
    for (final age in <int?>[null, 20, 70]) {
      for (final sleep in [false, true]) {
        test('summary stress seed=$seed age=$age sleep=$sleep', () {
          final full = stressed(seed: seed);
          final profile = Profile(
            ageYears: age,
            weightKg: 75,
            heightCm: 178,
            sex: 'male',
          );
          final onset = sleep ? full.tsSec.first + 120 : null;
          final offset = sleep ? full.tsSec.first + 330 : null;
          final state = DayCalculationState();
          var appended = 0;
          int summaries() =>
              state.processedHrSamples + state.processedOrientationSamples;
          for (final n in [
            1, 3, 4, 5, 6, 59, 61, 250, 499, 501, 700, full.length,
          ]) {
            final before = summaries();
            _compare(full.sliceIdx(0, n), state,
                profile: profile, onset: onset, offset: offset);
            if (appended > 0) {
              // The activity pass's HR and orientation summaries each fold in
              // only the appended seconds.
              expect(summaries() - before, 2 * (n - appended));
            }
            appended = n;
          }
          // A historical edit, a timestamp replacement and a shrink rebuild.
          full.hr[40] = 190;
          _compare(full, state, profile: profile, onset: onset, offset: offset);
          full.tsSec[10] -= 1;
          _compare(full, state, profile: profile, onset: onset, offset: offset);
          _compare(full.sliceIdx(0, 300), state,
              profile: profile, onset: onset, offset: offset);
        });
      }
    }
  }

  test('summary stress: almost no valid HR uses the plain extremes', () {
    final s = incrementalActivity(seconds: 300);
    for (var i = 0; i < s.length; i++) {
      s.hr[i] = i == 10 ? 140 : (i == 200 ? 90 : (i == 250 ? 240 : 0));
    }
    final state = DayCalculationState();
    for (final n in [11, 201, 251, 300]) {
      _compare(s.sliceIdx(0, n), state);
    }
  });
}
