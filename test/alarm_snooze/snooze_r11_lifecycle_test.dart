// Round 11 (Sol r10; owner: close the CLASS, not the instance). RED.
//
// The quiet machinery holds four kinds of state: an OPEN window (plain jobs
// held), an EXPECTATION (the queue knows a window will open: plain jobs that
// could still be playing then are DEFERRED), the jobs held by either, and the
// timer. This table walks every state x every way out and asserts the same
// thing after each: no hold, no expectation, nothing pending, and the held job
// RAN (never dropped) - or, where the exit is a clock change, only once the
// MONOTONIC bound has passed. D pins the late-establishment rule.
//
// Every date is fixed; time comes from the rig's TestClock and an injected
// monotonic reading. (Waits are event-loop turns for the rig's database and
// queue, not clock readings.)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

final DateTime kStart = DateTime(2026, 10, 7, 6, 0, 0);

enum Held { window, expecting }

typedef Exit = ({
  String name,

  /// Does the way out. [rig] is the live rig; [t] the alarm time.
  Future<void> Function(Ctx c) act,

  /// The hold must be gone straight after [act] (else: only after the
  /// monotonic bound, which the table then advances).
  bool immediate,

  /// The job must have RUN (false: only has to be settled; e.g. dispose).
  bool mustRun,

  /// The way out leaves ANOTHER alarm armed: its (new) expectation stands.
  bool newAlarm,
});

class Ctx {
  Ctx(this.rig, this.t);
  final SnoozeBandRig rig;
  final DateTime t;
  Duration mono = Duration.zero;

  Future<void> tick() async {
    await rig.app.debugKeepAliveTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  snoozeSuiteSetup('openstrap_snooze_r11_lifecycle_test.db');

  late SnoozeBandRig rig;

  tearDown(() async => rig.dispose());

  final exits = <Exit>[
    (
      name: 'the native stop is handled',
      act: (c) async {
        c.rig.clock.at(c.t);
        await c.rig.fire(stamp: c.t);
        c.rig.clock.advance(kSec * 8);
        await c.rig.terminate(HapticsTermination.expired);
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'T+35 s passes (wall clock forward)',
      act: (c) async {
        c.rig.clock.at(c.t.add(kSec * 36));
        c.mono += kSec * 40;
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the wall clock stands still, monotonic time runs on',
      act: (c) async {
        c.mono += const Duration(minutes: 5);
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the wall clock is set back an hour',
      act: (c) async {
        c.rig.clock.at(c.t.subtract(const Duration(hours: 1)));
        await c.tick();
      },
      immediate: false,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'snooze switched off',
      act: (c) => switchSnoozeOff(c.rig),
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the band cannot drive a snooze (capability lost)',
      act: (c) async {
        c.rig.engine.state.generation = 'gen4';
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'Cancel-all',
      act: (c) async {
        c.rig.engine.allowUserDisable = true;
        await c.rig.app.disableAlarm();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'unpair while connected',
      act: (c) => c.rig.app.unpair(),
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'unpair while already disconnected',
      act: (c) async {
        c.rig.engine.state.connection = 'disconnected';
        await c.rig.app.unpair();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the alarm is disarmed (event 59)',
      act: (c) async {
        c.rig.app.debugHandleAlarmEvent(59, ts: secOf(c.rig.clock.now));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the alarm is changed to another time',
      act: (c) async {
        final other = c.t.add(const Duration(hours: 1));
        await c.rig.app.debugOnArmed(other, secOf(other));
        c.rig.engine.state.alarmEpoch = secOf(other);
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: true,
    ),
    (
      name: 'the same alarm is armed again',
      act: (c) async {
        await c.rig.app.debugOnArmed(c.t, secOf(c.t));
        await c.tick();
        // nothing changes: it ends like any other, at T+35 s
        c.rig.clock.at(c.t.add(kSec * 36));
        c.mono += kSec * 40;
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the link drops, then T+35 s passes',
      act: (c) async {
        c.rig.engine.state.connection = 'disconnected';
        c.rig.clock.at(c.t.add(kSec * 36));
        c.mono += kSec * 40;
        await c.tick();
      },
      immediate: true,
      mustRun: true,
      newAlarm: false,
    ),
    (
      name: 'the app is disposed',
      act: (c) => c.rig.dispose(),
      immediate: true,
      mustRun: false,
      newAlarm: false,
    ),
  ];

  for (final state in Held.values) {
    group('state: ${state.name}', () {
      for (final e in exits) {
        test('exit: ${e.name}', () async {
          rig = await SnoozeBandRig.open(start: kStart);
          final t = kStart.add(const Duration(minutes: 1));
          final c = Ctx(rig, t);
          rig.app.debugMonotonic = () => c.mono;
          rig.engine.state.alarmEpoch = secOf(t);
          final h = rig.app.haptics;

          // Get into the state, with one plain job held by it.
          var ran = false;
          var settled = false;
          late Future<BuzzDelivery> job;
          if (state == Held.window) {
            rig.clock.at(t.subtract(kSec * 8));
            await c.tick();
            expect(h.quietOpen, isTrue, reason: 'precondition: open');
            job = h.runJob(1, (token) async {
              ran = true;
              await token.write(() async => true);
              return BuzzDelivery.complete;
            }, timeout: const Duration(seconds: 2), settle: Duration.zero);
          } else {
            rig.clock.at(t.subtract(kSec * 30));
            await c.tick();
            expect(h.quietExpected, isTrue, reason: 'precondition: expected');
            job = h.runJob(1, (token) async {
              ran = true;
              await token.write(() async => true);
              return BuzzDelivery.complete;
            }, timeout: const Duration(seconds: 40), settle: Duration.zero);
          }
          unawaited(job.then((_) => settled = true, onError: (_) {
            settled = true;
          }));
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(ran, isFalse, reason: 'precondition: held');

          await e.act(c);
          if (!e.immediate) {
            // Only the monotonic bound may end it: the wall clock lies.
            await Future<void>.delayed(const Duration(milliseconds: 200));
            c.mono += const Duration(minutes: 5);
            await c.tick();
          }

          expect(
              await until(
                  () =>
                      !h.quietOpen &&
                      (e.newAlarm || !h.quietExpected) &&
                      h.pending == 0 &&
                      settled,
                  turns: 300),
              isTrue,
              reason: 'open=${h.quietOpen} expected=${h.quietExpected} '
                  'pending=${h.pending} settled=$settled: something '
                  'survived its bound');
          if (e.mustRun) {
            expect(ran, isTrue, reason: 'the held job was dropped');
            expect(await job, BuzzDelivery.complete);
          }
        });
      }
    });
  }

  group('D an alarm too close to T when snooze is turned on or armed gets no '
      'window; the next one does', () {
    late DateTime t;

    Future<void> openOff() async {
      rig = await SnoozeBandRig.open(start: kStart, snooze: false);
      t = kStart.add(const Duration(minutes: 1));
      rig.engine.state.alarmEpoch = secOf(t);
    }

    Future<void> tick() async {
      await rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    Future<void> expectNoWindowThenNext() async {
      rig.clock.at(t.subtract(kSec * 8));
      await tick();
      expect(rig.app.haptics.quietOpen, isFalse,
          reason: 'a window for an alarm that was set up too late: a plain '
              'pattern may already be playing across it');
      expect(rig.app.haptics.quietExpected, isFalse);

      // The next alarm, far enough ahead, gets its window.
      final next = t.add(const Duration(hours: 1));
      await rig.app.debugOnArmed(next, secOf(next));
      rig.engine.state.alarmEpoch = secOf(next);
      rig.clock.at(next.subtract(kSec * 8));
      await tick();
      expect(rig.app.haptics.quietOpen, isTrue);
    }

    test('snooze switched on 20 s before T', () async {
      await openOff();
      rig.clock.at(t.subtract(kSec * 20));
      await rig.app.setSnoozeSettings(snoozeOn());
      await expectNoWindowThenNext();
    });

    test('the alarm armed 20 s before T (snooze already on)', () async {
      rig = await SnoozeBandRig.open(start: kStart);
      t = kStart.add(const Duration(minutes: 1));
      rig.clock.at(t.subtract(kSec * 20));
      await rig.app.debugOnArmed(t, secOf(t));
      rig.engine.state.alarmEpoch = secOf(t);
      await expectNoWindowThenNext();
    });

    test('control: snooze switched on 90 s before T: the window opens',
        () async {
      await openOff();
      rig.clock.at(t.subtract(kSec * 90));
      await rig.app.setSnoozeSettings(snoozeOn());
      rig.clock.at(t.subtract(kSec * 8));
      await tick();
      expect(rig.app.haptics.quietOpen, isTrue);
    });
  });
}
