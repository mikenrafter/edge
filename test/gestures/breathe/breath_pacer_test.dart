// BreathPacer (RED): the screen-free driver behind the Breathing exercise
// gesture. Over a fake clock and a fake session host it must
//   * cue at EVERY phase boundary of the pattern (the first inhale at t=0),
//     none past the end, for resonance (5.45 s phases) and box (4 s phases);
//   * play the complete cue once at the target, AFTER the last phase cue,
//     then end the host's session once (that is the banking);
//   * end early, on a disconnect, or because someone else stopped the session,
//     with no complete cue and no cue afterwards, banking at most once;
//   * be torn down by dispose with no cue;
//   * never leave a latch behind: `pacedByBand` and the timer are cleared on
//     every way out, including a start the band refused or that threw.
//
// Decisions pinned here (the task left them open):
//   * the session ends at EXACTLY the target (no rounding to whole cycles:
//     a 1 min resonance session rounded down to 5 cycles would be 54.5 s and
//     never bank);
//   * start() THROWS StateError when the host did not become active, so the
//     gesture is reported as failed instead of "ran";
//   * onDisconnect() ends AND banks the session like stop(); dispose() cancels
//     only (it does not end the host's session, like the controller's dispose).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/breath_gesture.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import '../../support/breath_pacer_fakes.dart';

BreathPattern _p(String key) => kBreathPatternsByKey[key]!;

class _Rig {
  _Rig({bool connected = true}) {
    host = FakeBreathHost(time, connected: connected);
    pacer = BreathPacer(host, now: time.read, timer: time.timer);
  }
  final time = FakeTime();
  late final FakeBreathHost host;
  late final BreathPacer pacer;

  Future<void> start(String key, Duration d) =>
      pacer.start(pattern: _p(key), duration: d);
}

void expectCues(FakeBreathHost host, BreathPattern p, double totalSec) {
  final want = expectedCues(p, totalSec);
  expect(host.cues.map((c) => c.kind).toList(), want.map((c) => c.kind).toList(),
      reason: 'the phase cue sequence for ${p.key}');
  for (var i = 0; i < want.length && i < host.cues.length; i++) {
    expect(host.cues[i].at, closeTo(want[i].at, 0.05),
        reason: 'cue $i (${want[i].kind.name}) is at its boundary');
  }
}

void main() {
  group('cues at every phase boundary of a 1 minute session', () {
    test('resonance: 12 cues, inhale first, alternating, none at 60 s',
        () async {
      final r = _Rig();
      await r.start('resonance', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      expect(r.host.cues, hasLength(12));
      expect(r.host.cues.first.kind, BreathPhaseKind.inhale);
      expectCues(r.host, _p('resonance'), 60);
    });

    test('box: 15 cues through inhale, hold, exhale, hold', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      expect(r.host.cues, hasLength(15));
      expect(r.host.cues.take(4).map((c) => c.kind), [
        BreathPhaseKind.inhale,
        BreathPhaseKind.holdIn,
        BreathPhaseKind.exhale,
        BreathPhaseKind.holdOut,
      ]);
      expectCues(r.host, _p('box'), 60);
    });

    test('the first cue is at t=0, not one phase late', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(Duration.zero);
      expect(r.host.cues.map((c) => c.kind), [BreathPhaseKind.inhale]);
      expect(r.host.cues.single.at, 0);
    });

    test('the cue stream does not depend on how time is advanced: one big '
        'step and many small ones give the same cues', () async {
      final a = _Rig();
      await a.start('box', const Duration(minutes: 1));
      await a.time.advance(const Duration(minutes: 1));
      final b = _Rig();
      await b.start('box', const Duration(minutes: 1));
      for (var i = 0; i < 600; i++) {
        await b.time.advance(const Duration(milliseconds: 100));
      }
      expect(b.host.cues.map((c) => c.kind).toList(),
          a.host.cues.map((c) => c.kind).toList());
    });
  });

  group('the start', () {
    test('hands the host the pattern and the target, sets pacedByBand, and '
        'completes while the session is still running', () async {
      final r = _Rig();
      await r.start('four_seven_eight', const Duration(minutes: 5));
      expect(r.host.events.first, 'start:four_seven_eight:300');
      expect(r.host.target, const Duration(minutes: 5));
      expect(r.pacer.running, isTrue);
      expect(r.host.pacedByBand, isTrue);
      expect(r.host.breathingActive, isTrue);
      expect(r.host.stops, 0);
    });

    test('a second start while running changes nothing', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.start('resonance', const Duration(minutes: 3));
      expect(r.host.starts, 1);
      await r.time.advance(const Duration(minutes: 1));
      expectCues(r.host, _p('box'), 60);
    });
  });

  group('the end', () {
    test('the complete cue comes once, at the target, after the last phase '
        'cue; then the session is ended (banked) once', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      expect(r.host.completes, 1);
      expect(r.host.completeAt, closeTo(60, 0.05));
      expect(r.host.events.takeLast(2), ['complete', 'stop']);
      expect(r.host.events.lastIndexWhere((e) => e.startsWith('phase:')),
          lessThan(r.host.events.indexOf('complete')));
      expect(r.host.stops, 1);
    });

    test('afterwards: not running, flag and timer cleared, and nothing more '
        'ever happens', () async {
      final r = _Rig();
      await r.start('resonance', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      final seen = List<String>.of(r.host.events);
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.events, seen);
    });

    test('stop, disconnect and dispose after the end are no-ops: banked '
        'exactly once', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      final seen = List<String>.of(r.host.events);
      await r.pacer.stop();
      await r.pacer.onDisconnect();
      r.pacer.dispose();
      expect(r.host.events, seen);
      expect(r.host.stops, 1);
    });

    test('a pacer can run a second session after the first ends', () async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      r.host.events.clear();
      r.host.cues.clear();
      final t0 = r.time.elapsedSec;
      await r.start('box', const Duration(minutes: 1));
      await r.time.advance(const Duration(minutes: 1));
      expect(r.host.cues, hasLength(15));
      expect(r.host.cues.first.at, closeTo(t0, 0.05));
      expect(r.host.completes, 1);
      expect(r.host.stops, 1);
    });
  });

  group('ending early', () {
    Future<_Rig> running() async {
      final r = _Rig();
      await r.start('box', const Duration(minutes: 3));
      await r.time.advance(const Duration(seconds: 22));
      return r;
    }

    test('stop(): no complete cue, no cue afterwards, flag and timer cleared, '
        'banked once', () async {
      final r = await running();
      final cuesBefore = r.host.cues.length;
      expect(cuesBefore, 6, reason: 'a cue at 0, 4, 8, 12, 16 and 20 s');
      await r.pacer.stop();
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      expect(r.host.stops, 1);
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.cues, hasLength(cuesBefore));
      expect(r.host.completes, 0);
    });

    test('stop() twice banks once; stop() when idle does nothing', () async {
      final r = await running();
      await r.pacer.stop();
      await r.pacer.stop();
      expect(r.host.stops, 1);
      final idle = _Rig();
      await idle.pacer.stop();
      expect(idle.host.events, isEmpty);
    });

    test('onDisconnect(): ends cue-less, banked once, flag cleared', () async {
      final r = await running();
      final cuesBefore = r.host.cues.length;
      await r.pacer.onDisconnect();
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      expect(r.host.stops, 1);
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.cues, hasLength(cuesBefore));
      expect(r.host.completes, 0);
    });

    test('dispose(): no cue afterwards, no complete cue, flag and timer '
        'cleared; the host session is left as it is', () async {
      final r = await running();
      final cuesBefore = r.host.cues.length;
      r.pacer.dispose();
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      expect(r.host.stops, 0);
      expect(r.host.breathingActive, isTrue);
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.cues, hasLength(cuesBefore));
      expect(r.host.completes, 0);
    });

    test('dispose() on an idle pacer is harmless', () {
      final r = _Rig();
      r.pacer.dispose();
      expect(r.host.events, isEmpty);
    });

    test('someone else ended the session (the screen, the Live Activity): '
        'the pacer notices, cues no more, does not bank it again', () async {
      final r = await running();
      final cuesBefore = r.host.cues.length;
      await r.host.stopBreathingSession(); // not through the pacer
      r.host.pacedByBand = true; // a host that left the flag behind
      await r.time.advance(const Duration(minutes: 5));
      expect(r.host.cues, hasLength(cuesBefore),
          reason: 'a cue is never played for a session that has ended');
      expect(r.host.completes, 0);
      expect(r.host.stops, 1, reason: 'only the outside stop');
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
    });
  });

  group('no sticky latch', () {
    test('the band refuses the session (not connected): start throws, nothing '
        'is armed, the flag is clear, and a later start works', () async {
      final r = _Rig(connected: false);
      await expectLater(
          r.start('box', const Duration(minutes: 1)), throwsStateError);
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      await r.time.advance(const Duration(minutes: 2));
      expect(r.host.cues, isEmpty);
      r.host.connected = true;
      await r.start('box', const Duration(minutes: 1));
      expect(r.pacer.running, isTrue);
      expect(r.host.pacedByBand, isTrue);
    });

    test('the host throws on start: the error reaches the caller, the flag '
        'is clear, nothing is armed', () async {
      final r = _Rig();
      r.host.startThrows = StateError('radio');
      await expectLater(
          r.start('box', const Duration(minutes: 1)), throwsStateError);
      expect(r.pacer.running, isFalse);
      expect(r.host.pacedByBand, isFalse);
      expect(r.time.pending, 0);
      r.host.startThrows = null;
      await r.start('box', const Duration(minutes: 1));
      expect(r.pacer.running, isTrue);
    });

    test('a phase cue that throws does not stop the pacing or leave the flag '
        'set', () async {
      final time = FakeTime();
      final host = _ThrowingCueHost(time);
      final pacer = BreathPacer(host, now: time.read, timer: time.timer);
      await pacer.start(pattern: _p('box'), duration: const Duration(minutes: 1));
      await time.advance(const Duration(minutes: 1));
      expect(host.attempts, 15, reason: 'every boundary still tried a cue');
      expect(pacer.running, isFalse);
      expect(host.pacedByBand, isFalse);
      expect(host.stops, 1);
    });
  });
}

class _ThrowingCueHost extends FakeBreathHost {
  _ThrowingCueHost(super.time);
  int attempts = 0;
  @override
  void buzzBreathPhase(BreathPhaseKind kind) {
    attempts++;
    throw StateError('band write failed');
  }
}

extension on List<String> {
  List<String> takeLast(int n) => sublist(length - n);
}
