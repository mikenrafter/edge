// BedtimeSessionController: one Bedtime breathing cues session, driven by a
// fake clock and scripted fakes (no real timers). Evidence: Tsai et al. 2015,
// doi:10.1111/psyp.12333.
//
// Invariants under test: one cue per phase boundary; the stager is asked at
// most every 30 s and never twice at once; an observe failure is just an absent
// sample; every way of ending releases the live streams exactly once (AGENTS
// 4.3: flags and holds clear on every path); stop is idempotent; dispose
// releases.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_session_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import 'package:openstrap_edge/wake/natural_wake.dart' show NaturalObservation;

import '../../support/bedtime_rig.dart';

NaturalObservation? _sleepy(int call) => bedtimeObs('nrem', call);

BedtimePlan _stopOnSleep({Duration? duration}) => BedtimePlan(
    stopOnSleep: true, duration: duration ?? const Duration(minutes: 15));

void main() {
  group('start', () {
    test('acquires the streams once and runs; no cue until the first tick',
        () async {
      final r = BedtimeRig();
      expect(r.controller.state, BedtimeState.idle);
      await r.start();
      expect(r.controller.state, BedtimeState.running);
      expect(r.acquires, 1);
      expect(r.releases, 0);
      expect(r.cues, isEmpty);
      expect(r.controller.stopReason, isNull);
      expect(r.controller.sleepEstimate, 'unavailable');
      expect(r.controller.cuesSent, 0);
      expect(r.controller.cuesMissed, 0);
    });

    test('a second start does nothing', () async {
      final r = BedtimeRig();
      await r.start();
      await r.start();
      expect(r.acquires, 1);
    });

    test('start cannot revive an ended session', () async {
      final r = BedtimeRig();
      await r.start();
      await r.controller.stop();
      await r.start();
      expect(r.controller.state, BedtimeState.ended);
      expect(r.acquires, 1);
      expect(r.releases, 1);
    });

    test('not connected: the session ends as disconnected, nothing acquired',
        () async {
      final r = BedtimeRig()..connected = false;
      await r.start();
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, BedtimeStopReason.disconnected);
      expect(r.acquires, 0);
      expect(r.releases, 0, reason: 'never acquired, so nothing to release');
      expect(r.cues, isEmpty);
    });

    test('acquire throws: ends as disconnected and still releases once', () async {
      final r = BedtimeRig()..acquireThrows = StateError('no streams');
      await r.start();
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, BedtimeStopReason.disconnected);
      expect(r.releases, 1);
      await r.at(0);
      expect(r.cues, isEmpty);
    });

    test('tick and stop before start are no-ops', () async {
      final r = BedtimeRig();
      await r.at(0);
      await r.controller.stop();
      expect(r.controller.state, BedtimeState.idle);
      expect(r.cues, isEmpty);
      expect(r.observeCalls, 0);
      expect(r.acquires, 0);
      expect(r.releases, 0);
    });

    test('setPlan changes the plan while idle and is ignored once running',
        () async {
      final r = BedtimeRig();
      final taper = BedtimePlan(startBpm: 6, endBpm: 5);
      r.controller.setPlan(taper);
      expect(r.controller.plan, same(taper));
      await r.start();
      r.controller.setPlan(BedtimePlan(startBpm: 7));
      expect(r.controller.plan, same(taper));
    });
  });

  group('cues', () {
    test('one cue per phase boundary at a fixed 6 bpm (5 s inhale, 5 s exhale)',
        () async {
      final r = BedtimeRig();
      await r.start();
      for (final s in [0, 1, 2, 4.9]) {
        await r.at(s);
      }
      expect(r.kinds, [BreathPhaseKind.inhale], reason: 'many ticks, one phase');
      await r.at(5);
      await r.at(7);
      expect(r.kinds, [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
      await r.at(10);
      await r.at(15);
      expect(r.kinds, [
        BreathPhaseKind.inhale,
        BreathPhaseKind.exhale,
        BreathPhaseKind.inhale,
        BreathPhaseKind.exhale,
      ]);
      expect(r.controller.cuesSent, 4);
      expect(r.controller.cuesMissed, 0);
    });

    // RED-FIX EDIT (review P2, skipped phases): this test used the tick at 27 s
    // (four skipped phases) and did not look at the counts, which is how the
    // defect passed. A late tick still plays only the CURRENT phase, but every
    // skipped boundary is a missed cue. Two skipped phases (tick at 17 s: phases
    // 1 and 2 skipped, phase 3 played) stay under the 3-in-a-row stop.
    test('a late tick plays the CURRENT phase once; it does not replay missed ones, '
        'and each one it skipped counts as missed', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      await r.at(17); // 17 s is 7 s into the second cycle: exhale (phase 3)
      expect(r.kinds, [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
      expect(r.controller.cuesMissed, 2, reason: 'phases 1 and 2 were skipped');
      expect(r.controller.cuesSent, 2);
      expect(r.controller.state, BedtimeState.running);
    });

    test('a taper keeps counting phases as the pace slows', () async {
      final r = BedtimeRig(plan: BedtimePlan(startBpm: 6, endBpm: 5));
      await r.start();
      for (var s = 0; s < 900; s++) {
        await r.at(s);
      }
      // 6 -> 5 bpm over 15 min is 82.5 breaths, so about 165 phase changes.
      expect(r.cues.length, inInclusiveRange(160, 170));
      for (var i = 0; i < r.kinds.length; i++) {
        expect(r.kinds[i],
            i.isEven ? BreathPhaseKind.inhale : BreathPhaseKind.exhale,
            reason: 'cue $i');
      }
    });

    test('a cue the band did not receive counts as missed, not sent', () async {
      final r = BedtimeRig()..deliverResult = false;
      await r.start();
      await r.at(0);
      expect(r.controller.cuesSent, 0);
      expect(r.controller.cuesMissed, 1);
    });

    test('a delivery that throws is a missed cue, and the next boundary still plays',
        () async {
      final r = BedtimeRig()..deliverThrows = StateError('queue gone');
      await r.start();
      await r.at(0);
      expect(r.controller.cuesMissed, 1);
      expect(r.controller.state, BedtimeState.running);
      r.deliverThrows = null;
      await r.at(5);
      expect(r.cues.length, 2, reason: 'the in-flight latch cleared in finally');
      expect(r.controller.cuesSent, 1);
    });

    test('a delivered cue clears the missed streak', () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverResult = false;
      await r.at(0);
      await r.at(5);
      r.deliverResult = true;
      await r.at(10);
      r.deliverResult = false;
      await r.at(15);
      await r.at(20);
      await r.at(20.5);
      expect(r.controller.state, BedtimeState.running,
          reason: '2 misses, a hit, then 2 misses: never 3 in a row');
      expect(r.controller.cuesMissed, 4);
      expect(r.controller.cuesSent, 1);
    });

    test('a tick while a cue is still being delivered does not deliver another',
        () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverHold = Completer<bool>();
      r.clock.at(kBedtimeT0);
      final first = r.controller.tick();
      r.clock.at(kBedtimeT0.add(const Duration(seconds: 5)));
      final second = r.controller.tick(); // a boundary, but the first is open
      await pumpEventQueue();
      expect(r.cues.length, 1);
      r.deliverHold!.complete(true);
      await Future.wait([first, second]);
      expect(r.cues.length, 1);
      expect(r.controller.cuesSent, 1);
      r.deliverHold = null;
      await r.at(5.5);
      expect(r.cues.length, 2, reason: 'the guard is released afterwards');
    });
  });

  group('observe', () {
    test('asked at most every 30 s, the first time on the first tick', () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      await r.at(0);
      await r.at(10);
      await r.at(29);
      expect(r.observeCalls, 1);
      await r.at(30);
      await r.at(59);
      expect(r.observeCalls, 2);
      await r.at(60);
      expect(r.observeCalls, 3);
      expect(r.observeAt, [
        Duration.zero,
        const Duration(seconds: 30),
        const Duration(seconds: 60),
      ]);
    });

    test('never concurrent, and a slow stager never delays the cues', () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      r.observeHold = Completer();
      await r.at(0);
      await r.at(5);
      await r.at(30);
      await r.at(35);
      await r.at(60);
      expect(r.observeCalls, 1, reason: 'one in flight, the rest wait');
      expect(r.maxInFlight, 1);
      expect(r.cues.length, 5, reason: 'inhale/exhale at 0 5 30 35 60 still played');
      r.observeHold!.complete(null);
      await pumpEventQueue();
      r.observeHold = null;
      await r.at(95);
      expect(r.observeCalls, 2);
      expect(r.maxInFlight, 1);
    });

    test('stopOnSleep false never asks the stager at all', () async {
      final r = BedtimeRig(plan: BedtimePlan(), script: _sleepy);
      await r.start();
      for (var s = 0; s < 200; s += 5) {
        await r.at(s);
      }
      expect(r.observeCalls, 0);
      expect(r.controller.sleepEstimate, 'unavailable');
      expect(r.controller.state, BedtimeState.running);
    });

    test('an observe that throws is an absent sample, not a crash', () async {
      final r = BedtimeRig(plan: _stopOnSleep())
        ..observeThrows = StateError('isolate died');
      await r.start();
      await r.at(0);
      await r.at(30);
      expect(r.controller.state, BedtimeState.running);
      expect(r.controller.sleepEstimate, 'unavailable',
          reason: 'never "awake" from a failure');
      r.observeThrows = null;
      r.script = _sleepy;
      await r.at(60);
      expect(r.controller.sleepEstimate, 'not yet sustained');
    });

    test('null, an absent stage and evidence that is too old are all unavailable',
        () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      r.script = (_) => null;
      await r.at(0);
      expect(r.controller.sleepEstimate, 'unavailable');
      r.script = (c) => bedtimeObs('absent', c);
      await r.at(30);
      expect(r.controller.sleepEstimate, 'unavailable');
      r.script = (c) => bedtimeObs('nrem', c, evidenceAgeMs: 200000);
      await r.at(60);
      expect(r.controller.sleepEstimate, 'unavailable',
          reason: 'stale evidence is not an observation of now');
    });

    test('the estimate follows what the stager says', () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      r.script = (c) => bedtimeObs('nrem', c);
      await r.at(0);
      expect(r.controller.sleepEstimate, 'not yet sustained');
      r.script = (c) => bedtimeObs('wake', c);
      await r.at(30);
      expect(r.controller.sleepEstimate, 'awake');
      r.script = (c) => bedtimeObs('absent', c);
      await r.at(60);
      expect(r.controller.sleepEstimate, 'unavailable');
    });

    test('with no new observation the estimate goes stale and says unavailable',
        () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      r.script = (c) => bedtimeObs('wake', c);
      await r.at(0);
      expect(r.controller.sleepEstimate, 'awake');
      r.observeHold = Completer(); // the stager stops answering
      await r.at(30);
      await r.at(125); // the awake sample is now 125 s old
      expect(r.controller.sleepEstimate, 'unavailable',
          reason: 'stale data never claims awake');
    });

    test('listeners hear every change', () async {
      final r = BedtimeRig(plan: _stopOnSleep(), script: _sleepy);
      var heard = 0;
      r.controller.addListener(() => heard++);
      await r.start();
      final afterStart = heard;
      expect(afterStart, greaterThan(0));
      await r.at(0);
      expect(heard, greaterThan(afterStart));
      final before = heard;
      await r.controller.stop();
      expect(heard, greaterThan(before));
    });
  });

  // Review P2 (skipped phases): a delayed tick or a slow delivery skips phase
  // boundaries. Each skipped boundary is a missed cue and breaks the run of
  // successes; only the current phase's cue is ever sent. At 6 bpm a phase is 5 s.
  group('skipped phases are missed cues (review P2)', () {
    test('ticks at 0 then 27 s skip four phases: they are missed and, being '
        'over three in a row, end the session as delivery failing', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      await r.at(27);
      expect(r.controller.cuesMissed, 4);
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, BedtimeStopReason.deliveryFailing);
      expect(r.cues.length, 1, reason: 'no cue is sent once it has failed');
      expect(r.releases, 1);
    });

    test('one skipped phase is one missed cue; the current cue is still played',
        () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      await r.at(10); // phase 1 skipped, phase 2 (inhale) played
      expect(r.kinds, [BreathPhaseKind.inhale, BreathPhaseKind.inhale]);
      expect(r.controller.cuesMissed, 1);
      expect(r.controller.cuesSent, 2);
      await r.at(20); // phase 3 skipped, phase 4 played
      expect(r.controller.cuesMissed, 2);
      expect(r.controller.cuesSent, 3);
      expect(r.controller.state, BedtimeState.running,
          reason: 'a delivered cue between them: never 3 in a row');
    });

    test('a slow delivery that hides boundaries: they are counted when it lands',
        () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverHold = Completer<bool>();
      r.clock.at(kBedtimeT0);
      final first = r.controller.tick(); // phase 0, still being delivered
      for (final s in [5, 10, 15]) {
        r.clock.at(kBedtimeT0.add(Duration(seconds: s)));
        await r.controller.tick(); // phases 1, 2 come and go while it is open
      }
      r.deliverHold!.complete(true);
      await first;
      r.deliverHold = null;
      await r.at(17); // phase 3
      expect(r.kinds, [BreathPhaseKind.inhale, BreathPhaseKind.exhale]);
      expect(r.controller.cuesMissed, 2, reason: 'phases 1 and 2');
      expect(r.controller.cuesSent, 2);
    });

    test('a delivery slow enough to skip more than three phases reaches the '
        'failure stop instead of carrying on', () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverHold = Completer<bool>();
      r.clock.at(kBedtimeT0);
      final first = r.controller.tick();
      for (final s in [5, 10, 15, 20, 25]) {
        r.clock.at(kBedtimeT0.add(Duration(seconds: s)));
        await r.controller.tick();
      }
      r.deliverHold!.complete(true);
      await first;
      r.deliverHold = null;
      await r.at(27); // phases 1..4 were skipped
      expect(r.controller.cuesMissed, 4);
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, BedtimeStopReason.deliveryFailing);
    });
  });

  // Review P2 (freshness and sustained sleep by evidence epochs, not request
  // times). Ticks every 5 s, so phase skipping never interferes. The stager is
  // asked at 0, 30, 60, 90 s.
  group('stage evidence is judged by its own epochs and age (review P2)', () {
    Future<void> walk(BedtimeRig r, int fromSec, int toSec) async {
      for (var s = fromSec; s <= toSec; s += 5) {
        await r.at(s);
      }
    }

    NaturalObservation epochEvery(int call, int epochGapSec) =>
        NaturalObservation(
          stage: 'nrem',
          confidence: 0.5,
          evidenceAgeMs: 30000,
          abstention: null,
          runSec: 600,
          epochStartMs: kBedtimeT0.millisecondsSinceEpoch +
              1000.0 * epochGapSec * call,
          note: null,
        );

    test('four sleep answers whose epochs are 60 s apart (an epoch missing '
        'between each) never stop the session', () async {
      final r = BedtimeRig(
          plan: _stopOnSleep(), script: (c) => epochEvery(c, 60));
      await r.start();
      await walk(r, 0, 120);
      expect(r.controller.state, BedtimeState.running,
          reason: 'stopped by ${r.controller.stopReason}');
      expect(r.observeCalls, 5);
      expect(r.controller.sleepEstimate, 'not yet sustained');
    });

    test('four ADJACENT 30 s epochs still stop it (guard: the fix keeps this)',
        () async {
      final r = BedtimeRig(
          plan: _stopOnSleep(), script: (c) => epochEvery(c, 30));
      await r.start();
      await walk(r, 0, 100);
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, BedtimeStopReason.sleepEstimated);
    });

    test('evidence that was 80 s old when asked ages after it is admitted: '
        '20 s later it is stale and the estimate is unavailable', () async {
      final r = BedtimeRig(
          plan: _stopOnSleep(),
          script: (c) => bedtimeObs('nrem', c, evidenceAgeMs: 80000));
      await r.start();
      await r.at(0);
      expect(r.controller.sleepEstimate, 'not yet sustained',
          reason: '80 s old when asked: still fresh');
      await walk(r, 5, 25); // no new ask before 30 s
      expect(r.observeCalls, 1);
      expect(r.controller.sleepEstimate, 'unavailable',
          reason: '100 s old by now (80 + 20): stale, never "not yet sustained"');
    });

    test('four adjacent sleep epochs that were each 90 s old when asked are '
        'stale by the next tick and never stop the session', () async {
      final r = BedtimeRig(
          plan: _stopOnSleep(),
          script: (c) => bedtimeObs('nrem', c, evidenceAgeMs: 90000));
      await r.start();
      await walk(r, 0, 115); // the fourth lands at 90 s; ticks follow at 95...
      expect(r.controller.state, BedtimeState.running,
          reason: 'the newest evidence is over 90 s old at every later tick');
      expect(r.controller.sleepEstimate, 'unavailable');
    });
  });

  group('every way to end releases the streams exactly once', () {
    void expectEndedOnce(BedtimeRig r, BedtimeStopReason why) {
      expect(r.controller.state, BedtimeState.ended);
      expect(r.controller.stopReason, why);
      expect(r.acquires, 1);
      expect(r.releases, 1);
    }

    test('the duration cap (and a cue is not sent after it)', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      await r.at(899);
      expect(r.controller.state, BedtimeState.running);
      final cuesBefore = r.cues.length;
      await r.at(900);
      expectEndedOnce(r, BedtimeStopReason.durationCap);
      expect(r.cues.length, cuesBefore, reason: 'the cap tick sends no cue');
      await r.at(905);
      await r.controller.stop();
      expectEndedOnce(r, BedtimeStopReason.durationCap);
    });

    test('a shorter plan caps at its own duration', () async {
      final r = BedtimeRig(plan: BedtimePlan(duration: const Duration(minutes: 2)));
      await r.start();
      await r.at(119);
      expect(r.controller.state, BedtimeState.running);
      await r.at(120);
      expectEndedOnce(r, BedtimeStopReason.durationCap);
    });

    test('the user stops it', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      await r.controller.stop();
      expectEndedOnce(r, BedtimeStopReason.userStopped);
      await r.at(5);
      expect(r.cues.length, 1, reason: 'no cue after stop');
    });

    test('a sustained sleep estimate (four epochs), after the stop is asked for',
        () async {
      final r = BedtimeRig(plan: _stopOnSleep(), script: _sleepy);
      await r.start();
      await r.at(0);
      await r.at(30);
      await r.at(60);
      expect(r.controller.state, BedtimeState.running);
      await r.at(90); // the fourth observation lands
      await r.at(91);
      expectEndedOnce(r, BedtimeStopReason.sleepEstimated);
      expect(r.controller.sleepEstimate, 'sustained');
      final cues = r.cues.length;
      await r.at(95);
      expect(r.cues.length, cues);
    });

    test('a wake in the middle resets the run; five clean epochs then stop',
        () async {
      final r = BedtimeRig(
        plan: _stopOnSleep(),
        script: (c) => bedtimeObs(c == 2 ? 'wake' : 'nrem', c),
      );
      await r.start();
      for (final s in [0, 30, 60, 90, 120, 150]) {
        await r.at(s);
        expect(r.controller.state, BedtimeState.running, reason: 'at $s');
      }
      await r.at(180); // epochs 3,4,5,6 are non-wake
      await r.at(181);
      expectEndedOnce(r, BedtimeStopReason.sleepEstimated);
    });

    test(
        'a whole 15 minutes of warm-up (no stage named) ends at the cap, never as sleep',
        () async {
      final r = BedtimeRig(
          plan: _stopOnSleep(), script: (c) => bedtimeObs('absent', c));
      await r.start();
      for (var s = 0; s <= 900; s += 5) {
        await r.at(s);
        expect(r.controller.sleepEstimate, 'unavailable', reason: 'at $s');
      }
      expectEndedOnce(r, BedtimeStopReason.durationCap);
    });

    test('the link drops', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      r.connected = false;
      await r.at(5);
      expectEndedOnce(r, BedtimeStopReason.disconnected);
      expect(r.cues.length, 1);
    });

    test('three cues in a row that did not reach the band', () async {
      final r = BedtimeRig()..deliverResult = false;
      await r.start();
      await r.at(0);
      await r.at(5);
      await r.at(10);
      await r.at(10.5);
      expectEndedOnce(r, BedtimeStopReason.deliveryFailing);
      expect(r.cues.length, 3, reason: 'no fourth attempt');
      expect(r.controller.cuesMissed, 3);
    });

    test('stop is idempotent and keeps the first reason', () async {
      final r = BedtimeRig();
      await r.start();
      await r.controller.stop();
      await r.controller.stop();
      await Future.wait([r.controller.stop(), r.controller.stop()]);
      expectEndedOnce(r, BedtimeStopReason.userStopped);
    });

    test('a release that throws does not escape stop and is not retried', () async {
      final r = BedtimeRig()..releaseThrows = StateError('already gone');
      await r.start();
      await r.controller.stop();
      expect(r.controller.state, BedtimeState.ended);
      expect(r.releases, 1);
      await r.controller.stop();
      expect(r.releases, 1);
    });

    test('stopping while a cue is still being delivered releases once', () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverHold = Completer<bool>();
      final tick = r.controller.tick();
      await pumpEventQueue();
      await r.controller.stop();
      r.deliverHold!.complete(true);
      await tick;
      await pumpEventQueue();
      expectEndedOnce(r, BedtimeStopReason.userStopped);
    });
  });

  group('dispose', () {
    test('releases the streams of a running session', () async {
      final r = BedtimeRig();
      await r.start();
      await r.at(0);
      r.controller.dispose();
      expect(r.releases, 1);
    });

    test('stop, tick and a late stop after dispose do nothing more', () async {
      final r = BedtimeRig();
      await r.start();
      r.controller.dispose();
      await r.controller.stop();
      await r.at(5);
      expect(r.releases, 1);
      expect(r.cues, isEmpty);
    });

    test('an idle session has nothing to release', () {
      final r = BedtimeRig();
      r.controller.dispose();
      expect(r.acquires, 0);
      expect(r.releases, 0);
    });

    test('an ended session is not released again', () async {
      final r = BedtimeRig();
      await r.start();
      await r.controller.stop();
      r.controller.dispose();
      expect(r.releases, 1);
    });

    test('an observation that lands after dispose is ignored', () async {
      final r = BedtimeRig(plan: _stopOnSleep());
      await r.start();
      r.observeHold = Completer();
      await r.at(0);
      expect(r.observeCalls, 1);
      r.controller.dispose();
      r.observeHold!.complete(bedtimeObs('nrem', 0));
      await pumpEventQueue();
      expect(r.releases, 1);
    });

    test('a cue delivery that lands after dispose is ignored', () async {
      final r = BedtimeRig();
      await r.start();
      r.deliverHold = Completer<bool>();
      final tick = r.controller.tick();
      await pumpEventQueue();
      r.controller.dispose();
      r.deliverHold!.complete(true);
      await tick;
      await pumpEventQueue();
      expect(r.releases, 1);
    });
  });
}
