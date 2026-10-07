// SnoozeController over fakes (fake clock, fake timers, fake haptic play, fake
// store). RED: the controller is a stub that throws.
//
// The controller has no handle on the band's native alarm at all (it is built
// from a clock, a haptic play, a probe, an evidence sink, a store and a
// scheduler), so "never arms" is pinned where an engine exists: see
// snooze_app_state_test.dart.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/wake/wake_confirmation.dart';

import 'snooze_fakes.dart';

const _min = Duration(minutes: 1);
const _sec = Duration(seconds: 1);
const _ms = Duration(milliseconds: 1);

void main() {
  group('the native alarm stops', () {
    test('error: log only, nothing else', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.error);
      await r.settle();
      expect(r.plays, isEmpty);
      expect(r.store.stateWrites, isEmpty);
      expect(r.scheduler.timers, isEmpty);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.controller.consumesDoubleTaps, isFalse);
      expect(r.logs, isNotEmpty, reason: 'logged');
    });

    test('expired: snoozes at once with the snooze confirm', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      expect(r.slots, [kSlotSnoozeConfirm]);
      expect(r.store.state,
          SnoozeState(count: 1, reAlarmAt: kT0.add(const Duration(minutes: 5))));
      final s = r.controller.status.value;
      expect(s.phase, SnoozePhase.snoozed);
      expect(s.until, kT0.add(_min * 5));
      expect(s.snoozeCount, 1);
      expect(r.controller.consumesDoubleTaps, isFalse,
          reason: 'a pending snooze leaves the gestures alone');
    });

    test('user_double_tap opens the dismiss window (its own length) and '
        'consumes taps', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.plays, isEmpty, reason: 'nothing is decided yet');
      expect(r.controller.status.value.phase, SnoozePhase.window);
      expect(r.controller.consumesDoubleTaps, isTrue);
      expect(r.scheduler.live.map((t) => t.after),
          [const Duration(milliseconds: 4000)]);
      expect(r.store.state, isNull, reason: 'a window is not persisted');
    });

    test('the window length is the setting, not a gesture timing', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(windowMs: 6500));
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.scheduler.live.single.after, const Duration(milliseconds: 6500));
    });

    test('the n-th tap dismisses EARLY: evidence, dismiss confirm, no snooze',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_ms * 1500);
      expect(r.controller.consumesDoubleTaps, isFalse, reason: 'decided now');
      expect(r.slots, [kSlotDismissConfirm]);
      expect(r.evidence, [
        (WakeEvidenceKind.alarmAcknowledged, kT0.add(_ms * 1500)),
      ]);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty, reason: 'the window timer is cancelled');
      // Waiting out the old window changes nothing.
      r.advance(_sec * 10);
      await r.controller.tick();
      expect(r.slots, [kSlotDismissConfirm]);
    });

    test('n=1: the stopping tap alone dismisses; no window opens', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(requiredTaps: 1));
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.slots, [kSlotDismissConfirm]);
      expect(r.evidence.map((e) => e.$1), [WakeEvidenceKind.alarmAcknowledged]);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.controller.consumesDoubleTaps, isFalse);
      expect(r.scheduler.timers, isEmpty);
    });

    test('n=1 does not make an expiry a dismissal', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(requiredTaps: 1));
      await r.stop(AlarmStopCause.expired);
      expect(r.slots, [kSlotSnoozeConfirm]);
      expect(r.evidence, isEmpty);
    });

    test('n=3: stop + one tap is not enough; the second tap dismisses',
        () async {
      final r = SnoozeRig(settings: const SnoozeSettings(requiredTaps: 3));
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_sec * 1);
      expect(r.plays, isEmpty);
      expect(r.controller.consumesDoubleTaps, isTrue);
      await r.tapAfter(_sec * 1);
      expect(r.slots, [kSlotDismissConfirm]);
      expect(r.evidence.single.$2, kT0.add(_sec * 2));
    });

    test('fewer taps by the window end: snooze (via the keep-alive tick)',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      r.advance(_ms * 3999);
      await r.controller.tick();
      expect(r.plays, isEmpty, reason: 'window not over yet');
      r.advance(_ms * 1);
      await r.controller.tick();
      expect(r.slots, [kSlotSnoozeConfirm]);
      expect(r.store.state,
          SnoozeState(count: 1, reAlarmAt: kT0.add(_sec * 4 + _min * 5)));
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);
      expect(r.controller.consumesDoubleTaps, isFalse);
    });

    test('fewer taps by the window end: snooze (via the window timer)',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_ms * 0); // the same instant as the stop: echo, ignored
      r.advance(_sec * 4);
      r.scheduler.timers.first.fire();
      await r.settle();
      expect(r.slots, [kSlotSnoozeConfirm]);
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);
    });

    test('a gesture echo of the stopping tap (inside 750 ms) is not tap 2',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_ms * 300);
      expect(r.plays, isEmpty, reason: 'still waiting for a real second tap');
      expect(r.controller.consumesDoubleTaps, isTrue);
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.slots, [kSlotSnoozeConfirm], reason: 'it snoozed');
      expect(r.evidence, isEmpty);
    });

    test('a real second double tap just past the echo guard counts', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(kStopTapDedupe + _ms * 1);
      expect(r.slots, [kSlotDismissConfirm]);
    });

    test('snooze minutes come from the setting', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(minutes: 12));
      await r.stop(AlarmStopCause.expired);
      expect(r.store.state!.reAlarmAt, kT0.add(_min * 12));
      expect(r.scheduler.live.single.after, _min * 12);
    });

    test('settings are read live at each use', () async {
      final r = SnoozeRig();
      r.settings = const SnoozeSettings(requiredTaps: 3);
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_sec * 1);
      expect(r.plays, isEmpty, reason: 'n is now 3');
    });
  });

  group('a confirmed wake', () {
    test('at the stop (expired): nothing is snoozed or played', () async {
      final r = SnoozeRig()..confirmed = true;
      await r.stop(AlarmStopCause.expired);
      await r.settle();
      expect(r.plays, isEmpty);
      expect(r.store.stateWrites, isEmpty);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty);
    });

    test('at the stop (user_double_tap): no window opens', () async {
      final r = SnoozeRig()..confirmed = true;
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.controller.consumesDoubleTaps, isFalse);
      expect(r.plays, isEmpty);
    });

    test('during the window, found at its end: no snooze', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      r.confirmed = true;
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.slots, isNot(contains(kSlotSnoozeConfirm)));
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
    });

    test('a probe that throws reads "not confirmed": the wearer is woken, a '
        'wake is never assumed', () async {
      final r = SnoozeRig()..probeThrows = StateError('db closed');
      await r.stop(AlarmStopCause.expired);
      expect(r.slots, [kSlotSnoozeConfirm]);
    });

    test('a failed probe does not wedge the next stop', () async {
      final r = SnoozeRig()..probeThrows = StateError('db closed');
      await r.stop(AlarmStopCause.userDoubleTap);
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);
      await r.controller.imUp();
      r.probeThrows = null;
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.controller.status.value.phase, SnoozePhase.window);
    });
  });

  group('the snooze and its re-alarm', () {
    test('re-alarm at +5 min through the haptic play; not a second early',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.plays.clear();
      r.advance(_min * 5 - _sec * 1);
      await r.controller.tick();
      expect(r.plays, isEmpty);
      r.advance(_sec * 1);
      await r.controller.tick();
      final play = r.playsOf(kSlotReAlarm).single;
      expect(play.at, kT0.add(_min * 5));
      expect(play.notes, const SnoozeSchedule().reAlarmNotes(1));
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming);
      expect(r.controller.consumesDoubleTaps, isTrue);
    });

    test('the snooze timer fires the re-alarm on time (a tick is only the '
        'backstop)', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      expect(r.scheduler.live.single.after, _min * 5);
      r.advance(_min * 5);
      r.scheduler.live.single.fire();
      await r.settle();
      expect(r.playsOf(kSlotReAlarm), hasLength(1));
    });

    test('the tick and the timer together play it once', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      final timer = r.scheduler.live.single;
      await r.controller.tick();
      timer.fire();
      await r.controller.tick();
      await r.settle();
      expect(r.playsOf(kSlotReAlarm), hasLength(1));
    });

    test('a wake confirmed during the snooze cancels the re-alarm and plays '
        'the cancelled slot', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 2);
      await r.controller.tick();
      expect(r.slots, [kSlotSnoozeConfirm], reason: 'nothing yet');
      r.confirmed = true;
      r.advance(_sec * 30);
      await r.controller.tick();
      expect(r.slots, [kSlotSnoozeConfirm, kSlotCancelled]);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty, reason: 'the re-alarm timer is gone');
      r.advance(_min * 10);
      await r.controller.tick();
      expect(r.slots, [kSlotSnoozeConfirm, kSlotCancelled],
          reason: 'no re-alarm later');
    });

    test('confirmed is checked at the re-alarm due time too (never buzz an '
        'awake wearer)', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.confirmed = true;
      r.advance(_min * 5);
      await r.controller.tick();
      expect(r.playsOf(kSlotReAlarm), isEmpty);
      expect(r.playsOf(kSlotCancelled), hasLength(1));
    });

    test('n taps during a re-alarm dismiss: dismiss slot + alarmAcknowledged',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      r.plays.clear();
      await r.tapAfter(_ms * 500);
      expect(r.plays, isEmpty, reason: 'one of two');
      expect(r.controller.consumesDoubleTaps, isTrue);
      await r.tapAfter(_ms * 700);
      expect(r.slots, [kSlotDismissConfirm]);
      expect(r.evidence, [
        (WakeEvidenceKind.alarmAcknowledged, kT0.add(_min * 5 + _ms * 1200)),
      ]);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.controller.consumesDoubleTaps, isFalse);
      expect(r.scheduler.live, isEmpty);
    });

    test('during a re-alarm the first tap is a real tap, not an implicit one',
        () async {
      final r = SnoozeRig(settings: const SnoozeSettings(requiredTaps: 1));
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming,
          reason: 'n=1 does not dismiss a re-alarm by itself');
      await r.tapAfter(_ms * 300);
      expect(r.playsOf(kSlotDismissConfirm), hasLength(1));
    });

    test('fewer taps than n: the next snooze, with a harsher pattern',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      await r.tapAfter(_ms * 500); // 1 of 2
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.slots, [
        kSlotSnoozeConfirm,
        kSlotReAlarm,
        kSlotSnoozeConfirm,
      ]);
      final due = kT0.add(_min * 5 + _ms * 4500 + _min * 5);
      expect(r.store.state, SnoozeState(count: 2, reAlarmAt: due));
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);
      expect(r.controller.status.value.snoozeCount, 2);
      r.clock.at(due);
      await r.controller.tick();
      final second = r.playsOf(kSlotReAlarm).last;
      expect(second.notes, const SnoozeSchedule().reAlarmNotes(2));
      expect(second.notes, isNot(r.playsOf(kSlotReAlarm).first.notes));
    });

    test('no taps at all: the same next snooze', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.store.state!.count, 2);
    });

    test('a wake confirmed while the re-alarm listens ends it: cancelled',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      r.confirmed = true;
      r.advance(_sec * 4);
      await r.controller.tick();
      expect(r.playsOf(kSlotCancelled), hasLength(1));
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
    });

    test('escalation per snooze index, the cap, and it never gives up',
        () async {
      final r = SnoozeRig(settings: const SnoozeSettings(cap: 6));
      await r.stop(AlarmStopCause.expired);
      for (var i = 1; i <= 9; i++) {
        r.clock.at(r.store.state!.reAlarmAt);
        await r.controller.tick();
        r.advance(_sec * 4);
        await r.controller.tick();
      }
      final sent = r.playsOf(kSlotReAlarm);
      expect(sent, hasLength(9));
      const sched = SnoozeSchedule(cap: 6);
      for (var i = 1; i <= 9; i++) {
        expect(sent[i - 1].notes, sched.reAlarmNotes(i), reason: 'index $i');
      }
      expect(sent[8].notes, sent[5].notes, reason: 'past the cap: unescalated');
      expect(r.controller.status.value.phase, SnoozePhase.snoozed,
          reason: 'still re-alarming every interval until dismissed');
      expect(r.store.state!.count, 10);
    });

    test('a smaller cap from the settings stops escalation sooner', () async {
      final r = SnoozeRig(settings: const SnoozeSettings(cap: 2));
      await r.stop(AlarmStopCause.expired);
      for (var i = 1; i <= 4; i++) {
        r.clock.at(r.store.state!.reAlarmAt);
        await r.controller.tick();
        r.advance(_sec * 4);
        await r.controller.tick();
      }
      final sent = r.playsOf(kSlotReAlarm);
      expect(sent[2].notes, sent[1].notes);
      expect(sent[3].notes, sent[1].notes);
      expect(sent[1].notes, isNot(sent[0].notes));
    });

    test('a refused delivery is not a played re-alarm: it stays due and is '
        'retried, nothing is counted', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.playOk = false;
      r.advance(_min * 5);
      await r.controller.tick();
      expect(r.playsOf(kSlotReAlarm), hasLength(1), reason: 'tried');
      expect(r.controller.status.value.phase, SnoozePhase.snoozed);
      expect(r.controller.consumesDoubleTaps, isFalse, reason: 'no window');
      expect(r.store.state!.count, 1);
      r.playOk = true;
      r.advance(_sec * 30);
      await r.controller.tick();
      final tries = r.playsOf(kSlotReAlarm);
      expect(tries, hasLength(2));
      expect(tries.last.notes, tries.first.notes, reason: 'still index 1');
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming);
    });

    test('a delivery that throws is a refused one; the controller carries on',
        () async {
      final r = SnoozeRig();
      final c = SnoozeController(
        now: r.clock.call,
        play: (slot, {notes}) async => throw StateError('band gone'),
        confirmedWake: () async => false,
        recordEvidence: (k, at) async {},
        store: r.store,
        settings: () => r.settings,
        scheduler: r.scheduler.call,
      );
      await c.onAlarmStopped(AlarmStopCause.expired, at: r.clock.now);
      // The snooze itself is still set (the state is what survives).
      expect(r.store.state?.count, 1);
      expect(c.status.value.phase, SnoozePhase.snoozed);
      c.dispose();
    });
  });

  group('I\'m up', () {
    test('dismisses a snooze', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 1);
      await r.controller.imUp();
      expect(r.slots, [kSlotSnoozeConfirm, kSlotDismissConfirm]);
      expect(r.evidence.map((e) => e.$1), [WakeEvidenceKind.alarmAcknowledged]);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty);
    });

    test('dismisses a window and a re-alarm', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.controller.imUp();
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.controller.consumesDoubleTaps, isFalse);
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      expect(r.controller.status.value.phase, SnoozePhase.reAlarming);
      await r.controller.imUp();
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.store.state, isNull);
    });

    test('with nothing to dismiss it does nothing (no evidence invented)',
        () async {
      final r = SnoozeRig();
      await r.controller.imUp();
      expect(r.plays, isEmpty);
      expect(r.evidence, isEmpty);
    });
  });

  group('double taps outside a window / re-alarm', () {
    test('are not consumed and change nothing', () async {
      final r = SnoozeRig();
      expect(r.controller.consumesDoubleTaps, isFalse);
      await r.controller.onBandDoubleTap(r.clock.now);
      expect(r.plays, isEmpty);
      expect(r.evidence, isEmpty);
      await r.stop(AlarmStopCause.expired);
      expect(r.controller.consumesDoubleTaps, isFalse, reason: 'snoozed');
      await r.controller.onBandDoubleTap(r.clock.now);
      expect(r.slots, [kSlotSnoozeConfirm]);
    });
  });

  group('persistence and restart', () {
    test('a restart resumes the pending re-alarm', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.controller.dispose();
      expect(r.store.state, isNotNull, reason: 'dispose keeps the snooze');

      r.advance(_min * 1);
      final again = r.build();
      await again.resume();
      expect(again.status.value.phase, SnoozePhase.snoozed);
      expect(again.status.value.until, kT0.add(_min * 5));
      expect(again.status.value.snoozeCount, 1);
      expect(r.scheduler.live.single.after, _min * 4,
          reason: 'a timer for what is left');

      r.plays.clear();
      r.clock.at(kT0.add(_min * 5));
      await again.tick();
      expect(r.playsOf(kSlotReAlarm).single.notes,
          const SnoozeSchedule().reAlarmNotes(1));
      again.dispose();
    });

    test('a re-alarm more than 10 minutes late after a restart STILL plays',
        () async {
      final r = SnoozeRig(
          stored: SnoozeState(
              count: 2, reAlarmAt: kT0.subtract(const Duration(minutes: 35))));
      await r.controller.resume();
      await r.controller.tick();
      await r.settle();
      final sent = r.playsOf(kSlotReAlarm);
      expect(sent, hasLength(1), reason: 'once, not skipped and not doubled');
      expect(sent.single.notes, const SnoozeSchedule().reAlarmNotes(2));
      r.controller.dispose();
    });

    test('a wake confirmed while the app was dead: resume cancels, no buzz',
        () async {
      final r = SnoozeRig(
          stored: SnoozeState(
              count: 1, reAlarmAt: kT0.add(const Duration(minutes: 2))))
        ..confirmed = true;
      await r.controller.resume();
      await r.controller.tick();
      expect(r.playsOf(kSlotReAlarm), isEmpty);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
    });

    test('nothing stored: resume is idle and quiet', () async {
      final r = SnoozeRig();
      await r.controller.resume();
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.plays, isEmpty);
      expect(r.scheduler.timers, isEmpty);
    });

    test('every state change is persisted: set, advance, clear', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.advance(_min * 5);
      await r.controller.tick();
      r.advance(_sec * 4);
      await r.controller.tick(); // second snooze
      await r.controller.imUp();
      final counts = <int>[];
      for (final s in r.store.stateWrites) {
        if (s != null && (counts.isEmpty || counts.last != s.count)) {
          counts.add(s.count);
        }
      }
      expect(counts, [1, 2]);
      expect(r.store.stateWrites.last, isNull, reason: 'cleared on dismissal');
    });
  });

  group('dispose', () {
    test('cancels the window timer; nothing runs afterwards', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      final timer = r.scheduler.live.single;
      r.controller.dispose();
      expect(timer.cancelled, isTrue);
      r.advance(_sec * 10);
      await r.controller.tick();
      await r.controller.onBandDoubleTap(r.clock.now);
      await r.stop(AlarmStopCause.expired);
      await r.settle();
      expect(r.plays, isEmpty);
      expect(r.store.stateWrites, isEmpty);
    });

    test('cancels the snooze timer but keeps the persisted snooze for the '
        'next launch', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      final timer = r.scheduler.live.single;
      r.controller.dispose();
      expect(timer.cancelled, isTrue);
      expect(r.store.state?.count, 1);
      r.advance(_min * 6);
      await r.controller.tick();
      expect(r.playsOf(kSlotReAlarm), isEmpty, reason: 'a dead controller is quiet');
    });

    test('a confirmed-wake probe that finishes after dispose changes nothing',
        () async {
      final r = SnoozeRig()..probeGate = Completer<bool>();
      final stop = r.stop(AlarmStopCause.expired);
      await r.settle();
      r.controller.dispose();
      r.probeGate!.complete(false);
      await stop;
      await r.settle();
      expect(r.plays, isEmpty);
      expect(r.store.stateWrites, isEmpty);
      expect(r.scheduler.live, isEmpty);
    });

    test('a re-alarm delivery that finishes after dispose opens no window and '
        'leaves no timer', () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      r.playGate = Completer<void>();
      r.advance(_min * 5);
      final tick = r.controller.tick();
      await r.settle();
      expect(r.playsOf(kSlotReAlarm), hasLength(1), reason: 'delivery in flight');
      r.controller.dispose();
      r.playGate!.complete();
      await tick;
      await r.settle();
      expect(r.scheduler.live, isEmpty);
      expect(r.controller.consumesDoubleTaps, isFalse);
    });

    test('dispose twice is harmless', () async {
      final r = SnoozeRig();
      r.controller.dispose();
      r.controller.dispose();
    });
  });

  group('no sticky latches', () {
    test('a delivery that never returns does not block a dismissal',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.expired);
      final gate = Completer<void>(); // the band does not answer yet
      r.playGate = gate;
      r.advance(_min * 5);
      final stuck = r.controller.tick();
      await r.settle();
      r.playGate = null;
      await r.controller.imUp();
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.store.state, isNull);
      gate.complete();
      await stuck;
    });

    test('after a full dismiss, the next morning\'s stop starts clean',
        () async {
      final r = SnoozeRig();
      await r.stop(AlarmStopCause.userDoubleTap);
      await r.tapAfter(_sec * 1); // dismissed
      r.advance(_min * (24 * 60));
      r.plays.clear();
      await r.stop(AlarmStopCause.userDoubleTap);
      expect(r.controller.status.value.phase, SnoozePhase.window);
      expect(r.controller.status.value.snoozeCount, 0,
          reason: 'the snooze count restarts for a new alarm');
    });
  });
}
