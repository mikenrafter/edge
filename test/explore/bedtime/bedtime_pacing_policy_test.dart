// BedtimePacingPolicy: when a Bedtime breathing cues session ends, and what
// "sleep estimate" may say. Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333.
//
// The rules under test (docs: edge.research/ideas-sol-review-2026-10-07.md, "4.
// Fall-asleep pacing"):
//  * the duration cap always wins first;
//  * the optional sleep stop needs 4 consecutive non-wake epoch observations,
//    fresh and non-abstaining; stale or absent data never stops anything, never
//    claims awake, and breaks the run;
//  * 3 consecutive missed cues end the session; losing the link ends it.
//
// Sample order is OLDEST FIRST. Observations arrive about every 30 s; a sample
// is fresh while now - observedAt <= 90 s. The run's freshness is judged
// against the NEWEST sample (vs now) and against outages between consecutive
// observations (a gap over 90 s breaks the run), so four observations 30 s
// apart can all count.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';

final _t0 = DateTime.utc(2026, 10, 7, 23, 0, 0);

/// Epoch [i] starts at t0 + 30 i s and was observed 40 s into its life, so
/// consecutive observations are 30 s apart.
StageSample _s(String stage, int i, {Duration? observedAfter}) => StageSample(
      at: _t0.add(Duration(seconds: 30 * i)),
      stage: stage,
      observedAt: _t0.add(Duration(seconds: 30 * i)).add(
          observedAfter ?? const Duration(seconds: 40)),
    );

List<StageSample> _run(List<String> stages) =>
    [for (var i = 0; i < stages.length; i++) _s(stages[i], i)];

/// 10 s after the newest observation.
DateTime _nowFor(List<StageSample> s) => s.isEmpty
    ? _t0
    : s.last.observedAt.add(const Duration(seconds: 10));

BedtimePacingPolicy _policy({bool stopOnSleep = true, Duration? duration}) =>
    BedtimePacingPolicy(
        plan: BedtimePlan(
            stopOnSleep: stopOnSleep,
            duration: duration ?? const Duration(minutes: 15)));

BedtimeStopReason? _tick(
  BedtimePacingPolicy p,
  List<StageSample> stages, {
  Duration elapsed = const Duration(minutes: 5),
  DateTime? now,
  int missed = 0,
  bool connected = true,
}) =>
    p.onTick(
      elapsed: elapsed,
      now: now ?? _nowFor(stages),
      recentStages: stages,
      consecutiveMissedCues: missed,
      connected: connected,
    );

void main() {
  group('duration cap', () {
    test('nothing ends a clean session before the cap', () {
      final p = _policy();
      expect(_tick(p, const [], elapsed: Duration.zero), isNull);
      expect(_tick(p, const [], elapsed: const Duration(minutes: 14, seconds: 59)),
          isNull);
    });

    test('the default cap is 15 minutes', () {
      expect(_tick(_policy(), const [], elapsed: const Duration(minutes: 15)),
          BedtimeStopReason.durationCap);
      expect(_tick(_policy(), const [], elapsed: const Duration(minutes: 16)),
          BedtimeStopReason.durationCap);
    });

    test('the cap is the plan duration (10 minutes, and the 20 minute maximum)', () {
      expect(
          _tick(_policy(duration: const Duration(minutes: 10)), const [],
              elapsed: const Duration(minutes: 10)),
          BedtimeStopReason.durationCap);
      expect(
          _tick(_policy(duration: const Duration(minutes: 20)), const [],
              elapsed: const Duration(minutes: 19, seconds: 59)),
          isNull);
      expect(
          _tick(_policy(duration: const Duration(minutes: 20)), const [],
              elapsed: const Duration(minutes: 20)),
          BedtimeStopReason.durationCap);
    });

    test('the cap wins over every other reason at once', () {
      final stages = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      expect(
          _tick(_policy(), stages,
              elapsed: const Duration(minutes: 15), missed: 9, connected: false),
          BedtimeStopReason.durationCap);
    });
  });

  group('sustained sleep stop', () {
    test('four consecutive nrem observations stop a stop-on-sleep session', () {
      final stages = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      expect(_tick(_policy(), stages), BedtimeStopReason.sleepEstimated);
    });

    test('rem counts as sleep, and nrem and rem mix', () {
      expect(_tick(_policy(), _run(['rem', 'rem', 'rem', 'rem'])),
          BedtimeStopReason.sleepEstimated);
      expect(_tick(_policy(), _run(['nrem', 'rem', 'nrem', 'rem'])),
          BedtimeStopReason.sleepEstimated);
    });

    test('three is not sustained', () {
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'nrem'])), isNull);
    });

    test('only the LAST four count; an older wake does not block the stop', () {
      expect(_tick(_policy(), _run(['wake', 'wake', 'nrem', 'nrem', 'nrem', 'nrem'])),
          BedtimeStopReason.sleepEstimated);
    });

    test('a wake inside the last four resets the run (flicker)', () {
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'nrem', 'wake', 'nrem'])),
          isNull);
      expect(_tick(_policy(), _run(['nrem', 'wake', 'nrem', 'nrem', 'nrem'])),
          isNull);
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'nrem', 'nrem', 'wake'])),
          isNull,
          reason: 'newest is wake: not asleep now');
    });

    test('after a flicker, four fresh non-wake in a row stop it again', () {
      expect(
          _tick(_policy(),
              _run(['nrem', 'nrem', 'nrem', 'wake', 'nrem', 'nrem', 'nrem', 'nrem'])),
          BedtimeStopReason.sleepEstimated);
    });

    test('an absent observation in the last four breaks the run', () {
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'absent', 'nrem', 'nrem'])),
          isNull);
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'nrem', 'nrem', 'absent'])),
          isNull);
      expect(_tick(_policy(), _run(['absent', 'absent', 'absent', 'absent'])),
          isNull);
    });

    test('an unknown stage string is not sleep', () {
      expect(_tick(_policy(), _run(['nrem', 'nrem', 'deep', 'nrem'])), isNull);
    });

    test('no samples at all never stops the session', () {
      expect(_tick(_policy(), const []), isNull);
    });

    test('a newest sample older than 90 s is stale: no stop', () {
      final stages = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      final fresh = stages.last.observedAt.add(const Duration(seconds: 90));
      final stale = stages.last.observedAt.add(const Duration(seconds: 91));
      expect(_tick(_policy(), stages, now: fresh),
          BedtimeStopReason.sleepEstimated,
          reason: '90 s is still fresh');
      expect(_tick(_policy(), stages, now: stale), isNull,
          reason: '91 s is stale');
    });

    // RED-FIX EDIT (review P2, freshness by evidence epochs): this test used to
    // break the run on a gap between OBSERVATION REQUEST times with the epochs
    // themselves adjacent (0, 30, 60, 90 s). That is the defect: adjacency is
    // the epochs' own times. The outage is now a missing epoch (epoch 2 never
    // observed), same expectation.
    test('a missing epoch (a gap in the epochs\' own times) breaks the run', () {
      final stages = [
        _s('nrem', 0),
        _s('nrem', 1),
        _s('nrem', 3), // epoch 2 (t0 + 60 s) was never observed
        _s('nrem', 4),
      ];
      expect(_tick(_policy(), stages), isNull);
    });

    test('the same epoch observed twice counts once', () {
      final stages = [
        _s('nrem', 0),
        _s('nrem', 1),
        _s('nrem', 1, observedAfter: const Duration(seconds: 55)),
        _s('nrem', 2),
      ];
      expect(_tick(_policy(), stages), isNull, reason: 'three distinct epochs');
      final four = [...stages, _s('nrem', 3)];
      expect(_tick(_policy(), four), BedtimeStopReason.sleepEstimated);
    });

    test('stopOnSleep false never stops for sleep, however clear', () {
      final stages = _run(['nrem', 'nrem', 'nrem', 'nrem', 'nrem', 'nrem']);
      expect(_tick(_policy(stopOnSleep: false), stages), isNull);
    });
  });

  // Review P2: "sustained" is four ADJACENT 30 s epochs by the observation's own
  // epoch time (StageSample.at), not four requests less than 90 s apart.
  group('sustained sleep needs adjacent epochs (review P2)', () {
    StageSample every(String stage, int i, int gapSec) => StageSample(
          at: _t0.add(Duration(seconds: gapSec * i)),
          stage: stage,
          observedAt: _t0.add(Duration(seconds: gapSec * i + 40)),
        );

    test('four sleep epochs 60 s apart (an epoch missing between each) are not '
        'sustained', () {
      final s = [for (var i = 0; i < 4; i++) every('nrem', i, 60)];
      expect(_policy().sleepEstimateStatus(s, _nowFor(s)), 'not yet sustained');
      expect(_tick(_policy(), s), isNull);
    });

    test('a single missing epoch inside the last four breaks the run; four '
        'adjacent ones after it stop', () {
      final gap = [_s('nrem', 0), _s('nrem', 1), _s('nrem', 2), _s('nrem', 4)];
      expect(_policy().sleepEstimateStatus(gap, _nowFor(gap)),
          'not yet sustained');
      expect(_tick(_policy(), gap), isNull);
      final after = [
        _s('nrem', 0),
        _s('nrem', 1),
        _s('nrem', 4),
        _s('nrem', 5),
        _s('nrem', 6),
        _s('nrem', 7),
      ];
      expect(_tick(_policy(), after), BedtimeStopReason.sleepEstimated);
    });
  });

  group('delivery and link', () {
    test('two missed cues carry on, three end the session', () {
      expect(_tick(_policy(), const [], missed: 2), isNull);
      expect(_tick(_policy(), const [], missed: 3),
          BedtimeStopReason.deliveryFailing);
      expect(_tick(_policy(), const [], missed: 12),
          BedtimeStopReason.deliveryFailing);
    });

    test('not connected ends the session cleanly, from the first tick', () {
      expect(_tick(_policy(), const [], elapsed: Duration.zero, connected: false),
          BedtimeStopReason.disconnected);
    });

    test('disconnected is named over deliveryFailing (the link is the cause)', () {
      expect(_tick(_policy(), const [], missed: 5, connected: false),
          BedtimeStopReason.disconnected);
    });

    test('a link and delivery problem outrank a sleep estimate', () {
      final stages = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      expect(_tick(_policy(), stages, missed: 3),
          BedtimeStopReason.deliveryFailing);
      expect(_tick(_policy(), stages, connected: false),
          BedtimeStopReason.disconnected);
    });
  });

  group('sleepEstimateStatus', () {
    String status(List<StageSample> s, {DateTime? now}) =>
        _policy().sleepEstimateStatus(s, now ?? _nowFor(s));

    test('no samples: unavailable', () {
      expect(_policy().sleepEstimateStatus(const [], _t0), 'unavailable');
    });

    test('only absent samples: unavailable (never awake)', () {
      expect(status(_run(['absent', 'absent'])), 'unavailable');
    });

    test('newest sample absent: unavailable, not a guess from older ones', () {
      expect(status(_run(['nrem', 'nrem', 'absent'])), 'unavailable');
    });

    test('a fresh wake observation is awake', () {
      expect(status(_run(['wake'])), 'awake');
      expect(status(_run(['nrem', 'nrem', 'nrem', 'nrem', 'wake'])), 'awake');
    });

    test('a STALE wake observation is unavailable, never awake', () {
      final s = _run(['wake']);
      final late = s.last.observedAt.add(const Duration(seconds: 91));
      expect(status(s, now: late), 'unavailable');
    });

    test('stale sleep is unavailable too', () {
      final s = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      final late = s.last.observedAt.add(const Duration(seconds: 120));
      expect(status(s, now: late), 'unavailable');
    });

    test('fewer than four non-wake epochs is not yet sustained', () {
      expect(status(_run(['nrem'])), 'not yet sustained');
      expect(status(_run(['nrem', 'rem', 'nrem'])), 'not yet sustained');
    });

    test('a run broken by an absent epoch is not yet sustained', () {
      expect(status(_run(['nrem', 'nrem', 'absent', 'nrem'])), 'not yet sustained');
    });

    test('four fresh non-wake epochs is sustained', () {
      expect(status(_run(['nrem', 'nrem', 'rem', 'nrem'])), 'sustained');
    });

    test('the status is independent of stopOnSleep (it only informs)', () {
      final s = _run(['nrem', 'nrem', 'nrem', 'nrem']);
      expect(
          _policy(stopOnSleep: false).sleepEstimateStatus(s, _nowFor(s)),
          'sustained');
    });

    test('every answer is one of the four honest strings', () {
      const allowed = {'unavailable', 'awake', 'not yet sustained', 'sustained'};
      for (final stages in [
        <String>[],
        ['absent'],
        ['wake'],
        ['nrem'],
        ['nrem', 'nrem', 'nrem', 'nrem'],
        ['rem', 'absent', 'wake', 'nrem'],
      ]) {
        final s = _run(stages);
        expect(allowed, contains(status(s)), reason: '$stages');
      }
    });
  });
}
