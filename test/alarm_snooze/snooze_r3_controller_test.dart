// Round 3 (Sol, alarm-snooze-sol-review2-2026-10-07.md, new defect 3): the
// controller's persisted state ages out. RED. Over the shared fakes (no BLE, no
// database): the age rules are the controller's alone.
//
//  * a persisted window or snooze whose native fire is older than 3 hours is
//    DROPPED on resume, with a log line, and never re-alarms
//  * the chain itself is bounded the same way: nothing answers it for 3 hours
//    after the native fire and it ends, silently (a phantom alarm hours later
//    is the second worst outcome after one that does not wake)
//
// The occurrence-match rule (a persisted fire that is not the alarm the app
// knows) needs the app's knowledge of fires and is pinned on the real AppState
// in snooze_r3_lifecycle_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';

import 'snooze_fakes.dart';

const _min = Duration(minutes: 1);
const _sec = Duration(seconds: 1);

bool _droppedLine(String l) =>
    l.contains('[snooze]') &&
    RegExp('drop|stale|too old|aged', caseSensitive: false).hasMatch(l);

void main() {
  group('a persisted window ages out', () {
    test('a window whose fire is two days old: resume drops it', () async {
      final r = SnoozeRig();
      final monday = kT0.subtract(const Duration(days: 2));
      r.store.window =
          SnoozeWindow(stoppedAt: monday.add(_sec * 8), fireAt: monday);
      await r.controller.resume();
      await r.settle();
      expect(r.plays, isEmpty,
          reason: 'Monday\'s stop became an overdue snooze and re-alarmed');
      expect(r.store.window, isNull);
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.controller.consumesDoubleTaps, isFalse);
      expect(r.logs.any(_droppedLine), isTrue, reason: '${r.logs}');
    });

    test('a window whose fire is 3 h 1 min old is dropped; 2 h 59 min is '
        'resumed (it is overdue: it snoozes from the original stop and '
        're-alarms)', () async {
      final old = SnoozeRig();
      final tooOld = kT0.subtract(const Duration(hours: 3, minutes: 1));
      old.store.window =
          SnoozeWindow(stoppedAt: tooOld.add(_sec * 8), fireAt: tooOld);
      await old.controller.resume();
      await old.settle();
      expect(old.plays, isEmpty);
      expect(old.store.window, isNull);

      final recent = SnoozeRig();
      final ok = kT0.subtract(const Duration(hours: 2, minutes: 59));
      recent.store.window =
          SnoozeWindow(stoppedAt: ok.add(_sec * 8), fireAt: ok);
      await recent.controller.resume();
      await recent.settle();
      expect(recent.slots, contains(kSlotReAlarm),
          reason: 'inside the bound an overdue snooze still plays: it is an '
              'alarm');
    });
  });

  group('a persisted snooze ages out', () {
    test('a snooze whose fire is two days old: dropped, no re-alarm, cleared',
        () async {
      final monday = kT0.subtract(const Duration(days: 2));
      final r = SnoozeRig(
          stored: SnoozeState(
              count: 4, reAlarmAt: monday.add(_min * 20), fireAt: monday));
      await r.controller.resume();
      await r.settle();
      expect(r.plays, isEmpty);
      expect(r.store.state, isNull, reason: 'cleared, not left to come back');
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.logs.any(_droppedLine), isTrue, reason: '${r.logs}');
      r.advance(_min * 10);
      await r.controller.tick();
      await r.settle();
      expect(r.plays, isEmpty);
    });

    test('3 h 1 min old: dropped. 2 h 59 min old: re-alarms (control)',
        () async {
      final tooOld = kT0.subtract(const Duration(hours: 3, minutes: 1));
      final a = SnoozeRig(
          stored: SnoozeState(
              count: 1, reAlarmAt: tooOld.add(_min * 5), fireAt: tooOld));
      await a.controller.resume();
      await a.settle();
      expect(a.plays, isEmpty);
      expect(a.store.state, isNull);

      final ok = kT0.subtract(const Duration(hours: 2, minutes: 59));
      final b = SnoozeRig(
          stored: SnoozeState(
              count: 1, reAlarmAt: ok.add(_min * 5), fireAt: ok));
      await b.controller.resume();
      // The overdue snooze's zero-length timer, as a real Timer would fire it.
      for (final t in b.scheduler.live.toList()) {
        if (t.after <= Duration.zero) t.fire();
      }
      await b.settle();
      expect(b.slots, contains(kSlotReAlarm));
    });
  });

  group('the chain is bounded', () {
    test('nobody answers: the re-alarms stop 3 hours after the native fire '
        'and the snooze is cleared, silently', () async {
      final r = SnoozeRig();
      final fire = r.clock.now;
      await r.controller
          .onAlarmStopped(AlarmStopCause.expired, at: r.clock.now, fire: fire);
      final end = fire.add(const Duration(hours: 3, minutes: 20));
      while (r.clock.now.isBefore(end)) {
        r.advance(_min * 5);
        await r.controller.tick(); // the snooze is due: the re-alarm plays
        await r.settle();
        r.advance(_sec * 10);
        await r.controller.tick(); // unanswered: snoozed again
        await r.settle();
      }
      final reAlarms = r.playsOf(kSlotReAlarm);
      expect(reAlarms.length, greaterThan(20),
          reason: 'precondition: the chain ran for hours');
      final limit = fire.add(const Duration(hours: 3));
      expect(reAlarms.where((p) => p.at.isAfter(limit)), isEmpty,
          reason: 'a re-alarm more than 3 h after the alarm fired: a '
              'phantom alarm');
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      final cues = r.slots.where((s) => s == kSlotDismissConfirm).length;
      expect(cues, 0, reason: 'ended silently: no "dismissed" cue');
    });
  });
}
