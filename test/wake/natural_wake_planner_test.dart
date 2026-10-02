// The pure Natural Wake decision: when an estimated-REM observation may fire an
// early haptic, and every reason it must abstain instead.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/wake/natural_wake.dart';

import 'support/wake_fakes.dart';

final _t = DateTime(2026, 10, 5, 7, 0);

NaturalDecision _decide({
  DateTime? now,
  int window = 60,
  SleepEligibility eligibility = SleepEligibility.mainSleep,
  NaturalObservation? obs,
  bool connected = true,
  bool fired = false,
  bool acked = false,
  Duration lateness = Duration.zero,
}) =>
    NaturalWakePlanner.decide(NaturalDecisionInput(
      now: now ?? _t.subtract(const Duration(minutes: 30)),
      wakeAt: _t,
      windowMinutes: window,
      eligibility: eligibility,
      observation: obs ?? remObs(),
      connected: connected,
      alreadyFired: fired,
      acknowledged: acked,
      lateness: lateness,
    ));

void main() {
  test('the REM trigger is runSec >= 120, a named constant', () {
    expect(kNaturalRemTriggerRunSec, 120);
    expect(_decide(obs: remObs(runSec: 119)).reason, NaturalReason.remNotStable);
    expect(_decide(obs: remObs(runSec: 120)).fire, isTrue);
  });

  group('every Natural window from 15 to 120 minutes', () {
    for (var n = 15; n <= 120; n += 15) {
      test('window $n: closed before T-N, open on [T-N, T), closed at T', () {
        final start = _t.subtract(Duration(minutes: n));
        expect(NaturalWakePlanner.windowStart(_t, n), start);
        expect(
            _decide(window: n, now: start.subtract(const Duration(seconds: 1)))
                .reason,
            NaturalReason.beforeWindow);
        expect(_decide(window: n, now: start).fire, isTrue,
            reason: 'T-N itself is inside the window');
        expect(
            _decide(window: n, now: _t.subtract(const Duration(seconds: 1)))
                .fire,
            isTrue);
        expect(_decide(window: n, now: _t).reason, NaturalReason.windowClosed);
        expect(
            _decide(window: n, now: _t.add(const Duration(minutes: 1))).reason,
            NaturalReason.windowClosed);
      });
    }

    test('a zero window is off', () {
      expect(_decide(window: 0).reason, NaturalReason.off);
    });
  });

  group('abstentions are named and never fire', () {
    test('no REM candidate: wake and nrem', () {
      expect(_decide(obs: stageObs('nrem')).reason, NaturalReason.noRemCandidate);
      expect(_decide(obs: stageObs('wake')).reason, NaturalReason.noRemCandidate);
    });

    test('low confidence', () {
      expect(
          _decide(obs: remObs(confidence: kNaturalMinConfidence - 0.01)).reason,
          NaturalReason.lowConfidence);
      expect(_decide(obs: remObs(confidence: kNaturalMinConfidence)).fire,
          isTrue);
    });

    test('every analytics abstention reason maps to its own reason', () {
      const expected = {
        'missingHr': NaturalReason.missingHr,
        'missingAccel': NaturalReason.missingAccel,
        'offWrist': NaturalReason.offWrist,
        'lowCoverage': NaturalReason.lowCoverage,
        'warmup': NaturalReason.warmup,
        'noEvidence': NaturalReason.noEvidence,
        'clockRegressed': NaturalReason.clockRegressed,
        'staleEvidence': NaturalReason.samplesStale,
      };
      expected.forEach((raw, reason) {
        final d = _decide(obs: absentObs(raw));
        expect(d.fire, isFalse, reason: raw);
        expect(d.reason, reason, reason: raw);
      });
    });

    test('an unrecognised abstention still abstains', () {
      final d = _decide(obs: absentObs('somethingNew'));
      expect(d.fire, isFalse);
      expect(d.reason, NaturalReason.abstained);
    });

    test('stale samples: REM from evidence older than the bound is refused',
        () {
      final d = _decide(
          obs: remObs(evidenceAgeMs: kNaturalMaxEvidenceAgeMs + 1));
      expect(d.fire, isFalse);
      expect(d.reason, NaturalReason.samplesStale);
      expect(d.samplesCurrent, isFalse);
      expect(
          _decide(obs: remObs(evidenceAgeMs: kNaturalMaxEvidenceAgeMs.toDouble()))
              .samplesCurrent,
          isTrue);
    });

    test('no observation at all (observer failed)', () {
      final d = NaturalWakePlanner.decide(NaturalDecisionInput(
        now: _t.subtract(const Duration(minutes: 30)),
        wakeAt: _t,
        windowMinutes: 60,
        eligibility: SleepEligibility.mainSleep,
        observation: null,
        connected: true,
        alreadyFired: false,
        acknowledged: false,
        lateness: Duration.zero,
      ));
      expect(d.reason, NaturalReason.observerFailed);
      expect(d.fire, isFalse);
    });

    test('disconnect: a live-only haptic is not attempted', () {
      expect(_decide(connected: false).reason, NaturalReason.disconnected);
    });

    test('late background execution: a tick the OS ran minutes late', () {
      expect(
          _decide(lateness: kNaturalMaxTickLateness + const Duration(seconds: 1))
              .reason,
          NaturalReason.lateExecution);
      expect(_decide(lateness: kNaturalMaxTickLateness).fire, isTrue);
    });

    test('once only, and never after an acknowledgement', () {
      expect(_decide(fired: true).reason, NaturalReason.alreadyFired);
      expect(_decide(acked: true).reason, NaturalReason.acknowledged);
    });
  });

  group('main sleep versus nap', () {
    test('a nap and an unknown sleep are ineligible', () {
      expect(_decide(eligibility: SleepEligibility.nap).reason,
          NaturalReason.ineligibleNap);
      expect(_decide(eligibility: SleepEligibility.unknown).reason,
          NaturalReason.ineligibleUnknown);
    });

    const expected = ExpectedSleepSchedule(onsetMinute: 23 * 60, wakeMinute: 7 * 60);

    test('the configured overnight sleep is the main sleep', () {
      expect(
          NaturalWakePlanner.classify(
              wakeAt: DateTime(2026, 10, 5, 7, 0), expected: expected),
          SleepEligibility.mainSleep);
      expect(
          NaturalWakePlanner.classify(
              wakeAt: DateTime(2026, 10, 5, 6, 30), expected: expected),
          SleepEligibility.mainSleep);
    });

    test('an afternoon alarm is a nap', () {
      expect(
          NaturalWakePlanner.classify(
              wakeAt: DateTime(2026, 10, 5, 15, 0), expected: expected),
          SleepEligibility.nap);
    });

    test('a short sleep ending at the usual wake time is still a nap', () {
      expect(
          NaturalWakePlanner.classify(
              wakeAt: DateTime(2026, 10, 5, 7, 0),
              expected: expected,
              sleepOnset: DateTime(2026, 10, 5, 4, 30)),
          SleepEligibility.nap);
    });

    test('with nothing known the answer is unknown, never a guess', () {
      expect(NaturalWakePlanner.classify(wakeAt: _t), SleepEligibility.unknown);
    });
  });

  group('time: absolute instants, local schedule', () {
    test('the same absolute instant decides the same in UTC or local form',
        () {
      for (final form in [_t, _t.toUtc()]) {
        final d = NaturalWakePlanner.decide(NaturalDecisionInput(
          now: _t.subtract(const Duration(minutes: 20)).toUtc(),
          wakeAt: form,
          windowMinutes: 60,
          eligibility: SleepEligibility.mainSleep,
          observation: remObs(),
          connected: true,
          alreadyFired: false,
          acknowledged: false,
          lateness: Duration.zero,
        ));
        expect(d.fire, isTrue);
      }
    });

    test('DST: the window is N elapsed minutes, so a window that spans the '
        'transition opens at the right instant', () {
      for (final t in [DateTime(2026, 3, 8, 3, 30), DateTime(2026, 11, 1, 2, 30)]) {
        final start = NaturalWakePlanner.windowStart(t, 120);
        expect(t.difference(start).inMinutes, 120);
        bool fires(DateTime now) => NaturalWakePlanner.decide(NaturalDecisionInput(
              now: now,
              wakeAt: t,
              windowMinutes: 120,
              eligibility: SleepEligibility.mainSleep,
              observation: remObs(),
              connected: true,
              alreadyFired: false,
              acknowledged: false,
              lateness: Duration.zero,
            )).fire;
        expect(fires(start.subtract(const Duration(seconds: 1))), isFalse);
        expect(fires(start), isTrue);
        expect(fires(t), isFalse);
      }
      if (Platform.environment['TZ'] == 'America/Denver') {
        final t = DateTime(2026, 3, 8, 3, 30);
        expect(NaturalWakePlanner.windowStart(t, 120).hour, 0);
      }
    });

    test('travel: classification follows the wall clock of the zone the '
        'alarm is armed in, while the decision follows absolute time', () {
      // 07:00 local in whatever zone this process is in is the main sleep;
      // the identical absolute instant read as a nap-time alarm (the schedule
      // saying 07:00 but the alarm now falling at 15:00 after a flight) is
      // not, and nothing else about the decision changes.
      const expected = ExpectedSleepSchedule(onsetMinute: 23 * 60, wakeMinute: 7 * 60);
      final home = DateTime(2026, 10, 5, 7, 0);
      final afterFlight = home.add(const Duration(hours: 8));
      expect(NaturalWakePlanner.classify(wakeAt: home, expected: expected),
          SleepEligibility.mainSleep);
      expect(NaturalWakePlanner.classify(wakeAt: afterFlight, expected: expected),
          SleepEligibility.nap);
    });
  });
}
