// Round 4 of the snooze safety review (Sol, alarm-snooze-sol-review3-2026-10-07
// .md): the OS backstop notification and the three-hour bound. RED. Phone
// notifications are read off the platform channel (snooze_notification_spy.dart);
// everything else is real (AppState, engine, queue, stores on the rig).
//
//  4  (P2) a persisted window or snooze that a fresh process finds already
//     confirmed, or too old, ends without cancelling the backstop the dead
//     process scheduled: the fresh AppState does not know it (its
//     `_snoozeBackstopFor` is null) and the notification fires minutes after
//     the alarm ended. The id is stable ([NotificationService.idSnoozeBackstop]),
//     so a new process can cancel it: it must.
//  5  (P2) [kSnoozeMaxAge] bounds everything: no backstop is scheduled at or
//     beyond fire + 3 h (a snooze whose due time would pass it ends the chain
//     instead), and a resume after 3 h cancels a backstop still scheduled.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/alarm_stop_policy.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_fakes.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r4_backstop_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)
  late NotificationSpy n;

  setUp(() => n = NotificationSpy()..install());
  tearDown(() async {
    n.uninstall();
    await rig.dispose();
  });

  final backstopId = NotificationService.idSnoozeBackstop;

  Future<void> open({
    Map<String, Object?> settings = const {},
    SnoozeBandRig? clockFrom,
  }) async {
    rig = await SnoozeBandRig.open(
        clock: clockFrom?.clock, settings: settings);
    t0 = rig.clock.now;
  }

  /// The process dies: the clock goes on, a fresh process starts and resumes
  /// what the dead one left, [after] later.
  Future<void> restart({required Duration after}) async {
    final clock = rig.clock;
    await rig.dispose(); // keeps the persisted state AND the OS notification
    clock.advance(after);
    rig = await SnoozeBandRig.open(clock: clock);
    await rig.app.snooze.resume();
    await rig.settle();
  }

  group('4 a fresh process that ends a restored chain cancels the backstop',
      () {
    test('a dismiss window the wearer\'s wake confirmation already answers',
        () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap);
      await rig.settle();
      expect(n.endsScheduled(backstopId), isTrue,
          reason: 'precondition: the dead process left a backstop');
      expect(await storedWindow(), isNotNull, reason: 'precondition');

      // The wearer is up (their phone confirmed it) while the app was dead.
      await lastNightConfirmedAt(rig.clock.now.add(kSec * 20),
          upAt: rig.clock.now.subtract(const Duration(hours: 3)));
      await restart(after: kMin * 2);

      expect(await storedWindow(), isNull, reason: 'precondition: resolved');
      expect(rig.deliveries.where((p) => p == Played.reAlarm), isEmpty);
      expect(n.endsCancelled(backstopId), isTrue,
          reason: 'the backstop of an alarm that is over stays armed and '
              'fires minutes later: ${n.order}');
    });

    test('a dismiss window that is older than 3 h (stale)', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap);
      await rig.settle();
      expect(n.endsScheduled(backstopId), isTrue, reason: 'precondition');

      await restart(after: const Duration(hours: 3, minutes: 10));

      expect(await storedWindow(), isNull, reason: 'dropped as stale');
      expect(rig.deliveries.where((p) => p == Played.reAlarm), isEmpty);
      expect(n.endsCancelled(backstopId), isTrue,
          reason: 'the stale-resume exit forgot the backstop: ${n.order}');
    });

    test('a snooze older than 3 h (stale): see also 5', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      expect(await storedState(), isNotNull, reason: 'precondition');
      expect(n.endsScheduled(backstopId), isTrue, reason: 'precondition');

      await restart(after: const Duration(hours: 3, minutes: 10));

      expect(await storedState(), isNull, reason: 'dropped as stale');
      expect(n.endsCancelled(backstopId), isTrue,
          reason: 'resume after 3 h dropped the snooze and left its backstop '
              'scheduled: ${n.order}');
    });

    test('control: a valid snooze, resumed before it is due, keeps (re-arms) '
        'its backstop', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      final due = (await storedState())!.reAlarmAt;

      await restart(after: kMin * 1);

      expect(await storedState(), isNotNull);
      expect(n.endsScheduled(backstopId), isTrue, reason: '${n.order}');
      expect(n.idFor(due), backstopId);
    });
  });

  group('5 the three-hour bound covers what is scheduled', () {
    test('a 30 min snooze that would be set at fire + 2 h 50 min (due after '
        'the bound) schedules no backstop at or past fire + 3 h and ends the '
        'chain', () async {
      await open(settings: {'minutes': 30});
      await rig.fire(stamp: t0);
      // The chain has been running: a re-alarm is due at fire + 2 h 49 min.
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 20, reAlarmAt: t0.add(const Duration(hours: 2, minutes: 49)),
          fireAt: t0));
      rig.clock.advance(const Duration(hours: 2, minutes: 50));
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1),
          reason: 'precondition: the re-alarm plays (inside the bound)');

      rig.clock.advance(kSec * 10); // unanswered
      await rig.app.debugKeepAliveTick();
      await rig.settle();

      final limit = t0.add(const Duration(hours: 3));
      expect(n.scheduled.where((s) => !s.at.isBefore(limit)), isEmpty,
          reason: 'a backstop at fire + 3 h 20 min: with the process '
              'suspended it fires past the bound: ${n.scheduled}');
      expect(await storedState(), isNull,
          reason: 'the next snooze would pass the bound: the chain ends');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(n.endsCancelled(backstopId), isTrue, reason: '${n.order}');
      expect(rig.count(Played.dismissConfirm), 0, reason: 'silently');
    });

    test('control: the same snooze with a due time inside the bound is set '
        'and its backstop scheduled', () async {
      await open(settings: {'minutes': 5});
      await rig.fire(stamp: t0);
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 20, reAlarmAt: t0.add(const Duration(hours: 2, minutes: 49)),
          fireAt: t0));
      rig.clock.advance(const Duration(hours: 2, minutes: 50));
      await rig.app.snooze.resume();
      await rig.settle();
      rig.clock.advance(kSec * 10);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      final st = await storedState();
      expect(st, isNotNull);
      expect(n.idFor(st!.reAlarmAt), backstopId);
    });

    test('controller: a snooze whose due time passes fire + 3 h is not set; '
        'the chain ends silently (no state, no timer, no cue)', () async {
      final fire = kT0;
      final r = SnoozeRig(
          settings: const SnoozeSettings(minutes: 30),
          stored: SnoozeState(
              count: 20,
              reAlarmAt: fire.add(const Duration(hours: 2, minutes: 49)),
              fireAt: fire));
      r.advance(const Duration(hours: 2, minutes: 50));
      await r.controller.resume();
      for (final t in r.scheduler.live.toList()) {
        if (t.after <= Duration.zero) t.fire();
      }
      await r.settle();
      expect(r.slots, contains(kSlotReAlarm), reason: 'precondition');

      r.advance(const Duration(seconds: 10));
      await r.controller.tick();
      await r.settle();

      expect(r.store.state, isNull,
          reason: 'a snooze due at fire + 3 h 20 min was persisted');
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty);
      expect(r.slots.where((s) => s == kSlotSnoozeConfirm), isEmpty);
      expect(r.slots.where((s) => s == kSlotDismissConfirm), isEmpty);
    });

    test('controller: a first snooze (5 min) of a chain that is recent is '
        'unaffected (control)', () async {
      final r = SnoozeRig();
      await r.controller.onAlarmStopped(AlarmStopCause.expired,
          at: r.clock.now, fire: r.clock.now);
      await r.settle();
      expect(r.store.state, isNotNull);
    });
  });
}
