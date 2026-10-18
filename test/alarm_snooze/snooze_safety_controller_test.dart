// Safety round on the snooze controller (Sol's review, 2026-10-07, findings
// 1, 3, 8 and 9). RED: each test is a scenario from the review, run against the
// real controller over the shared fakes. An alarm that fails to wake the
// wearer is the worst outcome; when in doubt the controller re-alarms.
//
//  F1  the dismiss window is persisted when it opens: a restart finds it
//      (restored while open; expired while dead => snooze from the ORIGINAL
//      stop time; already due => re-alarm at once)
//  F3  a stop delivered late is computed from its own time, not from receipt
//  F8  another termination never resets or postpones a pending snooze
//  F9  re-alarm listening opens only once the band took the pattern, measures
//      its window from the delivery's end, never dismisses on taps heard while
//      undelivered, and an overdue window stops consuming gestures
//
// The play fake in the F9 tests takes the `onFirstWrite` hook the design adds:
// `void Function()? onFirstWrite`, called when the band has accepted the first
// command of the delivery. (A closure with an extra optional named parameter is
// assignable to today's SnoozeHapticPlay, so these compile against the branch.)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';

import 'snooze_fakes.dart';

const _min = Duration(minutes: 1);
const _sec = Duration(seconds: 1);
const _ms = Duration(milliseconds: 1);

/// What a real zero-length Timer does on the next turn of the event loop.
Future<void> _fireDueTimers(SnoozeRig r) async {
  for (final t in r.scheduler.live.toList()) {
    if (t.after <= Duration.zero) t.fire();
  }
  await r.settle();
}

void main() {
  group('F1 restart during the native dismiss window', () {
    test('the open window survives a restart: resume() restores it, and the '
        'taps heard before the restart still count', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(requiredTaps: 3));
      await r.stop(AlarmStopCause.userDoubleTap); // the stopping tap is #1
      await r.tapAfter(_sec * 1); // #2
      expect(r.controller.status.value.phase, SnoozePhase.window);
      r.controller.dispose(); // the process dies

      r.advance(_ms * 500);
      final again = r.build();
      await again.resume();
      await r.settle();
      expect(again.status.value.phase, SnoozePhase.window,
          reason: 'the native alarm is already stopped: nothing else will '
              'ever re-alarm if the window is forgotten');
      expect(again.consumesDoubleTaps, isTrue);

      r.plays.clear();
      r.advance(_ms * 500);
      await again.onBandDoubleTap(r.clock.now); // #3
      await r.settle();
      expect(r.slots, [kSlotDismissConfirm],
          reason: 'stop + the tap before the restart + this one');
      expect(r.store.state, isNull);

      final next = r.build(); // and a dismissed window is not resurrected
      await next.resume();
      await r.settle();
      expect(next.status.value, SnoozeStatus.idle);
      expect(next.consumesDoubleTaps, isFalse);
      expect(r.plays.where((p) => p.slot == kSlotReAlarm), isEmpty);
      next.dispose();
      again.dispose();
    });

    test('a window that expired while the process was dead, with fewer than n '
        'taps, snoozes from the ORIGINAL stop time', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap); // stopped at kT0
      r.controller.dispose();

      r.advance(_min * 1); // dead for a minute; the 4 s window is long over
      final again = r.build();
      await again.resume();
      await r.settle();
      expect(again.status.value.phase, SnoozePhase.snoozed);
      expect(again.status.value.until, kT0.add(_min * 5),
          reason: 'from the stop, not from the restart');
      expect(r.store.state,
          SnoozeState(count: 1, reAlarmAt: kT0.add(_min * 5)));
      expect(again.consumesDoubleTaps, isFalse);
      again.dispose();
    });

    test('...and when that snooze is already due, the re-alarm plays at once',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      r.controller.dispose();

      r.advance(_min * 6); // the snooze (stop + 5 min) came due while dead
      r.plays.clear();
      final again = r.build();
      await again.resume();
      await r.settle();
      await _fireDueTimers(r);
      expect(r.playsOf(kSlotReAlarm), hasLength(1),
          reason: 'no tick needed: a wearer asleep for a minute too long is '
              'woken now');
      again.dispose();
    });
  });

  group('F3 a stop delivered late is computed from its own time', () {
    test('already due when it arrives: the re-alarm plays now', () async {
      final r = SnoozeRig();
      final stoppedAt = kT0.add(_sec * 30);
      r.advance(_min * 6); // the link was down; the band reports minutes later
      await r.controller.onAlarmStopped(AlarmStopCause.expired, at: stoppedAt);
      await r.settle();
      await _fireDueTimers(r);
      expect(r.playsOf(kSlotReAlarm), hasLength(1));
      expect(r.store.state?.reAlarmAt, stoppedAt.add(_min * 5),
          reason: 'due from the stop, 5:30 after the alarm, not from receipt');
    });

    test('not yet due: the snooze ends at stop + length, not receipt + '
        'length', () async {
      final r = SnoozeRig();
      final stoppedAt = kT0.add(_sec * 30);
      r.advance(_min * 3);
      await r.controller.onAlarmStopped(AlarmStopCause.expired, at: stoppedAt);
      await r.settle();
      expect(r.store.state?.reAlarmAt, stoppedAt.add(_min * 5));
      expect(r.controller.status.value.until, stoppedAt.add(_min * 5));
      expect(r.playsOf(kSlotReAlarm), isEmpty);
    });

    test('a double-tap stop heard late measures its window from the stop: '
        'the window is over, so it snoozes from the stop', () async {
      final r = SnoozeRig();
      r.advance(_sec * 10); // delivered 10 s after the stop; window is 4 s
      await r.controller.onAlarmStopped(AlarmStopCause.userDoubleTap, at: kT0);
      await r.settle();
      expect(r.controller.consumesDoubleTaps, isFalse,
          reason: 'its window ended 6 s ago');
      expect(r.store.state?.reAlarmAt, kT0.add(_min * 5));
    });
  });

  group('F8 another termination never resets a pending snooze', () {
    test('a termination during a snooze changes neither its count nor its '
        'deadline', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick(); // re-alarm 1
      r.advance(_sec * 4);
      await r.controller.tick(); // fewer taps: snooze 2
      final pending = r.store.state;
      expect(pending?.count, 2);
      r.plays.clear();

      r.advance(_min * 1);
      await r.stop(AlarmStopCause.expired); // e.g. the confirm's own end
      await r.settle();
      expect(r.store.state, pending, reason: 'count 2 and the same deadline');
      expect(r.controller.status.value.snoozeCount, 2);
      expect(r.controller.status.value.until, pending!.reAlarmAt);
      expect(r.plays, isEmpty, reason: 'no second snooze confirm');
    });

    test('a termination while the re-alarm listens does not wipe the chain',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick(); // re-alarm 1, listening
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming);
      final pending = r.store.state;
      r.plays.clear();

      await r.stop(AlarmStopCause.expired); // the re-alarm's own end
      await r.settle();
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming);
      expect(r.store.state, pending);
      expect(r.plays, isEmpty);
    });
  });

  group('F9 re-alarm listening', () {
    /// A controller whose play takes `onFirstWrite`: the re-alarm is "accepted"
    /// when [accept] completes and "finished" when [finish] does.
    ({
      SnoozeController c,
      Completer<void> accept,
      Completer<void> finish,
      List<String> slots,
      SnoozeRig r,
    }) rig({SnoozeSettings settings = const SnoozeSettings()}) {
      final r = SnoozeRig(settings: settings);
      final accept = Completer<void>(), finish = Completer<void>();
      final slots = <String>[];
      final c = SnoozeController(
        now: r.clock.call,
        play: (slot, {notes, void Function()? onFirstWrite}) async {
          slots.add(slot);
          if (slot == kSlotReAlarm) {
            await accept.future;
            onFirstWrite?.call();
            await finish.future;
          }
          return true;
        },
        confirmedWake: () async => false,
        recordEvidence: (k, at) async => r.evidence.add((k, at)),
        store: r.store,
        settings: () => r.settings,
        scheduler: r.scheduler.call,
        log: r.logs.add,
      );
      return (c: c, accept: accept, finish: finish, slots: slots, r: r);
    }

    test('nothing is consumed and no tap counts until the band took the '
        'pattern; taps heard while undelivered never dismiss', () async {
      final x = rig();
      await x.c.onAlarmStopped(AlarmStopCause.expired, at: x.r.clock.now);
      x.r.advance(_min * 5);
      final due = x.c.tick(); // the re-alarm is queued behind the budget
      await x.r.settle();

      expect(x.c.consumesDoubleTaps, isFalse,
          reason: 'the wearer has felt nothing yet: gestures stay theirs');
      // Not awaited: a controller that wrongly dismisses waits on a play that
      // is itself waiting, and the test should fail, not hang.
      x.r.advance(_ms * 300);
      final t1 = x.c.onBandDoubleTap(x.r.clock.now);
      x.r.advance(_ms * 300);
      final t2 = x.c.onBandDoubleTap(x.r.clock.now);
      await x.r.settle();
      expect(x.slots.where((s) => s == kSlotDismissConfirm), isEmpty,
          reason: 'two taps on a buzz nobody felt dismissed the alarm');
      expect(x.r.evidence, isEmpty);
      expect(x.r.store.state, isNotNull);

      x.accept.complete();
      x.finish.complete();
      await Future.wait([due, t1, t2]);
      x.c.dispose();
    });

    test('a delivery that fails after taps were heard keeps the snooze '
        'pending and is retried; the old taps do not carry over', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      final gate = Completer<void>();
      r.playGate = gate;
      r.playOk = false; // the band drops while the job waits
      final due = r.controller.tick();
      await r.settle();
      // Not awaited: see the test above.
      final t1 = r.tapAfter(_ms * 300);
      final t2 = r.tapAfter(_ms * 300);
      await r.settle();
      gate.complete();
      await Future.wait([due, t1, t2]);
      await r.settle();

      expect(r.playsOf(kSlotDismissConfirm), isEmpty);
      expect(r.store.state?.count, 1, reason: 'still pending, not dismissed');
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);

      r.playGate = null;
      r.playOk = true;
      r.advance(_sec * 30);
      await r.controller.tick();
      expect(r.playsOf(kSlotReAlarm), hasLength(2), reason: 'retried');
      await r.tapAfter(_ms * 300);
      expect(r.playsOf(kSlotDismissConfirm), isEmpty,
          reason: 'one fresh tap of two; the taps heard before do not count');
    });

    test('listening opens at the first accepted write and the window runs from '
        'the delivery\'s END: taps during a long delivery count', () async {
      final x = rig();
      await x.c.onAlarmStopped(AlarmStopCause.expired, at: x.r.clock.now);
      x.r.advance(_min * 5);
      final due = x.c.tick();
      x.accept.complete(); // the band took the first command
      await x.r.settle();
      expect(x.c.consumesDoubleTaps, isTrue);
      expect(x.c.status.value.phase, SnoozePhase.reAlarming);

      // The pattern plays for 10 s: a tap at 1 s and one at 9 s, both before it
      // ends and the second beyond the 4 s window counted from its start.
      x.r.advance(_sec * 1);
      await x.c.onBandDoubleTap(x.r.clock.now);
      x.r.advance(_sec * 8);
      await x.c.onBandDoubleTap(x.r.clock.now);
      await x.r.settle();
      expect(x.slots.where((s) => s == kSlotDismissConfirm), hasLength(1));
      x.finish.complete();
      await due;
      x.c.dispose();
    });

    test('an overdue re-alarm window stops consuming gestures even before '
        'the timer or the tick runs', () async {
      final x = rig();
      await x.c.onAlarmStopped(AlarmStopCause.expired, at: x.r.clock.now);
      x.r.advance(_min * 5);
      x.accept.complete();
      x.finish.complete();
      await x.c.tick(); // delivered; window 4 s from now
      expect(x.c.consumesDoubleTaps, isTrue);
      x.r.advance(_sec * 5); // overdue; no timer fired, no tick
      expect(x.c.consumesDoubleTaps, isFalse);
      await x.c.onBandDoubleTap(x.r.clock.now);
      expect(x.slots.where((s) => s == kSlotDismissConfirm), isEmpty,
          reason: 'a tap after the deadline is nobody\'s dismissal');
      x.c.dispose();
    });
  });

  group('F9 the native-window tap path checks its deadline', () {
    test('an overdue native window stops consuming gestures while its probe '
        'is still pending', () async {
      final r = SnoozeRig();
      r.probeGate = Completer<bool>(); // the confirmation probe is slow
      final stopping = r.stop(AlarmStopCause.userDoubleTap);
      await r.settle();
      expect(r.controller.consumesDoubleTaps, isTrue, reason: 'inside 4 s');

      r.advance(_sec * 5);
      expect(r.controller.consumesDoubleTaps, isFalse,
          reason: 'the window ended; a stuck probe must not keep stealing '
              'the wearer\'s gestures');
      await r.controller.onBandDoubleTap(r.clock.now);
      expect(r.playsOf(kSlotDismissConfirm), isEmpty);

      r.probeGate!.complete(false);
      await stopping;
      await r.settle();
      expect(r.store.state?.reAlarmAt, kT0.add(_min * 5),
          reason: 'fewer taps in the window: snoozed from the stop');
    });
  });
}
