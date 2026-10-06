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
  bool userActive = false,
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
      userActive: userActive,
    ));

void main() {
  test('the REM trigger is runSec >= 120, a named constant', () {
    expect(kNaturalRemTriggerRunSec, 120);
    expect(_decide(obs: remObs(runSec: 119)).reason, NaturalReason.remNotStable);
    expect(_decide(obs: remObs(runSec: 120)).fire, isTrue);
  });

  group('the rule is "not light and not deep sleep"', () {
    test('REM fires', () => expect(_decide(obs: stageObs('rem')).fire, isTrue));

    test('awake fires', () {
      final d = _decide(obs: stageObs('wake'));
      expect(d.fire, isTrue);
      expect(d.viaUserActivity, isFalse);
    });

    test('light or deep (nrem) does not', () {
      expect(_decide(obs: stageObs('nrem')).fire, isFalse);
    });

    test('unknown or absent never counts, whatever the abstention, and an '
        'unrecognised stage name is not eligible', () {
      for (final raw in ['staleEvidence', 'noEvidence', 'warmup', 'offWrist',
          'missingHr', 'missingAccel', 'lowCoverage', 'clockRegressed', 'x']) {
        expect(_decide(obs: absentObs(raw)).fire, isFalse, reason: raw);
      }
      expect(_decide(obs: stageObs('unknown')).fire, isFalse);
      expect(_decide(obs: stageObs('light')).fire, isFalse);
      expect(_decide(obs: stageObs('deep')).fire, isFalse);
      expect(kNaturalEligibleStages, {'rem', 'wake'});
    });

    test('awake is held to the same stability and confidence bar as REM', () {
      expect(_decide(obs: stageObs('wake', runSec: 119)).reason,
          NaturalReason.remNotStable);
      expect(
          _decide(obs: stageObs('wake', confidence: kNaturalMinConfidence - 0.01))
              .reason,
          NaturalReason.lowConfidence);
    });

    test('awake outside the window, once fired, after an acknowledgement, '
        'disconnected: nothing', () {
      expect(
          _decide(
                  obs: stageObs('wake'),
                  now: _t.subtract(const Duration(minutes: 61)))
              .reason,
          NaturalReason.beforeWindow);
      expect(_decide(obs: stageObs('wake'), now: _t).reason,
          NaturalReason.windowClosed);
      expect(_decide(obs: stageObs('wake'), fired: true).reason,
          NaturalReason.alreadyFired);
      expect(_decide(obs: stageObs('wake'), acked: true).reason,
          NaturalReason.acknowledged);
      expect(_decide(obs: stageObs('wake'), connected: false).reason,
          NaturalReason.disconnected);
    });
  });

  group('the user is in the app and the band moves with it', () {
    test('counts as awake even when the stager says light sleep', () {
      final d = _decide(obs: stageObs('nrem'), userActive: true);
      expect(d.fire, isTrue);
      expect(d.viaUserActivity, isTrue);
    });

    test('still counts when the stager abstained or failed', () {
      expect(_decide(obs: absentObs('warmup'), userActive: true).fire, isTrue);
      expect(
          NaturalWakePlanner.decide(NaturalDecisionInput(
            now: _t.subtract(const Duration(minutes: 30)),
            wakeAt: _t,
            windowMinutes: 60,
            eligibility: SleepEligibility.mainSleep,
            observation: null,
            connected: true,
            alreadyFired: false,
            acknowledged: false,
            lateness: Duration.zero,
            userActive: true,
          )).fire,
          isTrue);
    });

    test('never outside the window, for a nap, once fired, acknowledged, '
        'disconnected or late', () {
      expect(
          _decide(
                  userActive: true,
                  now: _t.subtract(const Duration(minutes: 61)))
              .fire,
          isFalse);
      expect(_decide(userActive: true, now: _t).fire, isFalse);
      expect(
          _decide(userActive: true, eligibility: SleepEligibility.nap).fire,
          isFalse);
      expect(
          _decide(userActive: true, eligibility: SleepEligibility.unknown).fire,
          isFalse);
      expect(_decide(userActive: true, fired: true).fire, isFalse);
      expect(_decide(userActive: true, acked: true).fire, isFalse);
      expect(_decide(userActive: true, connected: false).fire, isFalse);
      expect(
          _decide(userActive: true, lateness: const Duration(minutes: 4)).fire,
          isFalse);
    });

    group('the correlation', () {
      final now = DateTime(2026, 10, 5, 6, 30);
      final touch = now.subtract(const Duration(seconds: 20));
      final t0 = touch.millisecondsSinceEpoch.toDouble();

      /// 1 Hz rows from -30 s to +20 s around the touch; [moveEvery] > 0 makes
      /// the wrist swing every n-th second.
      List<List<double>> rows({int moveEvery = 0, double step = 0.2}) => [
            for (var k = -30; k <= 20; k++)
              [
                t0 + k * 1000,
                moveEvery > 0 && k % moveEvery == 0 ? step : 0.0,
                0.0,
                1.0,
              ],
          ];

      bool awake(List<List<double>> accel,
              {Iterable<DateTime>? touches, DateTime? at}) =>
          NaturalWakePlanner.userAwakeFromInteraction(
            now: at ?? now,
            interactions: touches ?? [touch],
            accel: accel,
          );

      test('a touch with a moving wrist is awake', () {
        expect(awake(rows(moveEvery: 2)), isTrue);
      });

      test('a touch with a still wrist (phone on the nightstand) is not', () {
        expect(awake(rows()), isFalse);
        expect(awake(rows(moveEvery: 2, step: 0.005)), isFalse);
      });

      test('a moving wrist with no touch is not this function\'s business', () {
        expect(awake(rows(moveEvery: 2), touches: const []), isFalse);
      });

      test('no movement data is never an inference', () {
        expect(awake(const []), isFalse);
        expect(awake([rows()[0]]), isFalse);
      });

      test('the motion has to be near the touch in time', () {
        // Moving, but only a long time before the touch.
        final far = [
          for (var k = -300; k <= -200; k++)
            [t0 + k * 1000, k.isEven ? 0.3 : 0.0, 0.0, 1.0],
          ...rows(),
        ];
        expect(awake(far), isFalse);
      });

      test('a stale touch says nothing about now', () {
        expect(awake(rows(moveEvery: 2),
                at: touch.add(kUserInteractionFreshness +
                    const Duration(seconds: 1))),
            isFalse);
        expect(awake(rows(moveEvery: 2),
                at: touch.add(kUserInteractionFreshness)),
            isTrue);
      });

      test('a gap in the rows is not a step', () {
        final gappy = [
          for (var k = -30; k <= 20; k += 5)
            [t0 + k * 1000, (k ~/ 5).isEven ? 0.4 : 0.0, 0.0, 1.0],
        ];
        expect(awake(gappy), isFalse);
      });
    });
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
    test('light or deep sleep (the stager\'s nrem) never fires', () {
      expect(_decide(obs: stageObs('nrem')).reason, NaturalReason.noRemCandidate);
      expect(_decide(obs: stageObs('nrem', runSec: 3600)).fire, isFalse);
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
