// Round 3 of the snooze safety review (Sol, alarm-snooze-sol-review2-2026-10-07
// .md): the snooze's life cycle. RED. Real AppState, engine, haptics queue,
// wake store, snooze store; phone notifications read off the platform channel.
//
//  D  (new 3) persisted state ages out: a window or snooze whose native fire
//     is older than 3 h, or does not match the known alarm occurrence, is
//     dropped on resume (a log line, never a re-alarm)
//  E  (new 4) every end path (Cancel-all, unpair, the switch turned off) ends
//     the snooze silently, releases the prompt lease and cancels the backstop,
//     whatever the status was
//  K  (partial 7) a native fire with snooze ON takes the lease and arms the
//     backstop at once (fire + window + snooze), and both follow the state
//  G  (new 6) only the RE-ALARM is exempt from the command budget
//  H  (new 7) the Android backstop is EXACT when the OS allows it
//
// Contract used where the production API is new: the settings JSON field
// `enabled`; `AppState.disableAlarm()` / `unpair()` / `setSnoozeSettings` are
// the end paths.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r3_lifecycle_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)
  late NotificationSpy n;

  setUp(() => n = NotificationSpy()..install());
  tearDown(() async {
    n.uninstall();
    await rig.dispose();
  });

  Future<void> open({
    DateTime? start,
    AutoEnd autoEnd = AutoEnd.queueOnly,
    bool? snooze = true,
    Map<String, Object?> settings = const {},
  }) async {
    rig = await SnoozeBandRig.open(
        start: start, autoEnd: autoEnd, snooze: snooze, settings: settings);
    t0 = rig.clock.now;
  }

  Future<void> fireAndStop(int code,
      {Duration after = const Duration(seconds: 8)}) async {
    await rig.fire(stamp: t0);
    rig.clock.advance(after);
    await rig.terminate(code);
  }

  final backstopId = NotificationService.idSnoozeBackstop;

  // ── D ─────────────────────────────────────────────────────────────────────

  group('D persisted state ages out (never a phantom alarm days later)', () {
    test('a dismiss window from MONDAY, reopened on Wednesday with no '
        'confirmation: dropped, no re-alarm, a log line', () async {
      await open(start: DateTime(2026, 10, 7, 7, 0)); // Wednesday
      final monday = DateTime(2026, 10, 5, 6, 30);
      await const DbSnoozeStore().saveWindow(SnoozeWindow(
          stoppedAt: monday.add(kSec * 8), fireAt: monday, taps: const []));

      await rig.app.snooze.resume();
      await rig.settle();

      expect(rig.deliveries, isEmpty,
          reason: 'Monday\'s stop became a snooze that was already due: a '
              're-alarm on Wednesday');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(await storedWindow(), isNull);
      expect(await storedState(), isNull);
      expect(
          rig.app.logLines.any((l) =>
              l.contains('[snooze]') &&
              RegExp('drop|stale|too old|aged', caseSensitive: false)
                  .hasMatch(l)),
          isTrue,
          reason: 'dropped with a log line: ${rig.app.logLines.take(8)}');
    });

    test('a pending snooze whose fire is two days old: dropped, no re-alarm',
        () async {
      await open(start: DateTime(2026, 10, 7, 7, 0));
      final fire = DateTime(2026, 10, 5, 6, 30);
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 3, reAlarmAt: fire.add(kMin * 20), fireAt: fire));

      await rig.app.snooze.resume();
      await rig.settle();

      expect(rig.deliveries, isEmpty);
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(await storedState(), isNull);
    });

    test('a fire 3 h 1 min old is dropped; one 2 h 50 min old still '
        're-alarms (control)', () async {
      await open();
      final stale = t0.subtract(const Duration(hours: 3, minutes: 1));
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 1, reAlarmAt: stale.add(kMin * 5), fireAt: stale));
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.deliveries, isEmpty);
      expect(await storedState(), isNull);

      final fresh = t0.subtract(const Duration(hours: 2, minutes: 50));
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 1, reAlarmAt: fresh.add(kMin * 5), fireAt: fresh));
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1),
          reason: 'an overdue re-alarm of a recent alarm still plays: it is '
              'an alarm');
    });

    test('inside 3 h but NOT the occurrence the app knows: a native fire for '
        'a later wake was heard, so a window from the earlier fire is '
        'dropped', () async {
      await open();
      await rig.fire(stamp: t0); // the occurrence the app knows now
      final earlier = t0.subtract(const Duration(hours: 2));
      await const DbSnoozeStore().saveWindow(SnoozeWindow(
          stoppedAt: earlier.add(kSec * 8), fireAt: earlier));

      await rig.app.snooze.resume();
      await rig.settle();

      expect(rig.count(Played.reAlarm), 0,
          reason: 'a stale chain was resurrected over the current alarm');
      expect(await storedWindow(), isNull);
      expect(await storedState(), isNull);
    });

    test('control: the persisted state is the known occurrence\'s: it '
        'resumes and the overdue re-alarm plays', () async {
      await open();
      await rig.fire(stamp: t0);
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 1, reAlarmAt: t0.subtract(kSec * 5), fireAt: t0));
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1));
    });
  });

  // ── E ─────────────────────────────────────────────────────────────────────

  group('E every end path tears everything down', () {
    /// Snoozed, with a lease and a backstop in place.
    Future<DateTime> snoozed() async {
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final st = await storedState();
      expect(st, isNotNull, reason: 'precondition: a snooze is pending');
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty,
          reason: 'precondition: a lease');
      expect(n.idFor(st!.reAlarmAt), backstopId,
          reason: 'precondition: a backstop');
      return st.reAlarmAt;
    }

    Future<void> expectTornDown() async {
      await rig.settle();
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(await storedState(), isNull, reason: 'no snooze left stored');
      expect(await storedWindow(), isNull, reason: 'no window left stored');
      expect(rig.engine.prompts.last.enabled, isFalse,
          reason: 'the prompt lease is released');
      expect(n.endsCancelled(backstopId), isTrue,
          reason: 'the backstop notification is cancelled: ${n.order}');
      final before = rig.count(Played.reAlarm);
      rig.clock.advance(kMin * 10);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.count(Played.reAlarm), before, reason: 'nothing re-alarms');
    }

    test('Cancel-all during a pending snooze', () async {
      await open();
      await snoozed();
      rig.engine.allowUserDisable = true;
      await rig.app.disableAlarm();
      expect(rig.engine.userDisables, isNotEmpty, reason: 'the wearer\'s own');
      await expectTornDown();
    });

    test('Cancel-all during the dismiss window: no snooze follows it',
        () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition');
      rig.engine.allowUserDisable = true;
      await rig.app.disableAlarm();
      rig.clock.advance(kSec * 6);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isFalse);
      expect(rig.count(Played.snoozeConfirm), 0,
          reason: 'the wearer cancelled the alarm: the window must not turn '
              'into a snooze');
      await expectTornDown();
    });

    test('Cancel-all after the fire, BEFORE any stop: the lease and the '
        'backstop taken at the fire go too, though the status never left '
        'idle', () async {
      await open();
      await rig.fire(stamp: t0);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty,
          reason: 'precondition: the fire took the lease');
      expect(n.scheduled, isNotEmpty, reason: 'precondition: the backstop');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      rig.engine.allowUserDisable = true;
      await rig.app.disableAlarm();
      await expectTornDown();
    });

    test('unpairing the band during a pending snooze', () async {
      await open();
      await snoozed();
      await rig.app.unpair();
      await expectTornDown();
    });

    test('switching Snooze off during a pending snooze ends it silently',
        () async {
      await open();
      await snoozed();
      await rig.app.setSnoozeSettings(
          SnoozeSettings.fromJson({...rig.app.snoozeSettings.toJson(), 'enabled': false}));
      await expectTornDown();
      expect(rig.count(Played.dismissConfirm), 0, reason: 'silently');
      expect(rig.count(Played.cancelled), 0, reason: 'silently');
    });
  });

  group('dispose (a process going away) keeps what a dead process needs', () {
    test('timers cancelled and the lease released; the persisted snooze AND '
        'the OS backstop stay, and the next launch re-alarms', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final st = await storedState();
      expect(st, isNotNull, reason: 'precondition');
      expect(rig.engine.prompts.last.enabled, isTrue,
          reason: 'precondition: a lease');
      expect(n.idFor(st!.reAlarmAt), backstopId,
          reason: 'precondition: a backstop');
      final clock = rig.clock;
      final cancelsBefore = n.cancelled.length;

      await rig.dispose();

      expect(rig.app.snooze.consumesDoubleTaps, isFalse);
      expect(rig.engine.prompts.last.enabled, isFalse,
          reason: 'nothing here can renew the lease: it is released');
      expect(await storedState(), isNotNull,
          reason: 'kept for the next launch');
      expect(n.cancelled.length, cancelsBefore,
          reason: 'the backstop is for a process that is not running: it '
              'stays armed (${n.order})');
      expect(n.endsScheduled(backstopId), isTrue);

      clock.advance(kMin * 6);
      rig = await SnoozeBandRig.open(clock: clock);
      await rig.app.snooze.resume();
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1),
          reason: 'the next launch finds the snooze due and re-alarms');
    });
  });

  // ── K ─────────────────────────────────────────────────────────────────────

  group('K a native fire with snooze on takes the lease and arms the backstop '
      'at once', () {
    test('at the fire: a lease through fire + window + snooze, a backstop '
        'at fire + 4 s + 5 min', () async {
      await open();
      await rig.fire(stamp: t0);
      await rig.settle();
      final leases = rig.engine.prompts.where((c) => c.enabled).toList();
      expect(leases, isNotEmpty,
          reason: 'a suspension during the dismiss window would postpone '
              'the snooze to the next 900 s prompt');
      expect(leases.last.intervalSeconds, inInclusiveRange(61, 300));
      final due = t0.add(const Duration(seconds: 4) + kMin * 5);
      expect(leases.last.until!.isBefore(due), isFalse,
          reason: 'the lease covers the whole window + snooze');
      expect(n.idFor(due), backstopId,
          reason: 'a backstop notification: ${n.scheduled}');
    });

    test('an expired stop moves the backstop to stop + 5 min (the snooze\'s '
        'own due time); the lease stays', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final due = rig.clock.now.add(kMin * 5);
      expect(n.idFor(due), backstopId);
      expect(n.endsScheduled(backstopId), isTrue);
      expect(rig.engine.prompts.last.enabled, isTrue);
    });

    test('dismissed by taps in the window: lease released, backstop '
        'cancelled', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty,
          reason: 'precondition: the fire took the lease');
      expect(n.endsScheduled(backstopId), isTrue,
          reason: 'precondition: the fire armed the backstop');
      rig.clock.advance(kSec * 1);
      await rig.tap();
      await rig.settle();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1),
          reason: 'precondition');
      expect(rig.engine.prompts.last.enabled, isFalse);
      expect(n.endsCancelled(backstopId), isTrue, reason: '${n.order}');
    });

    test('a wake confirmed before any stop was heard releases both',
        () async {
      await open();
      await rig.fire(stamp: t0);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty,
          reason: 'precondition');
      await lastNightConfirmedAt(rig.clock.now.add(kMin * 1),
          upAt: rig.clock.now.subtract(const Duration(hours: 3)));
      rig.clock.advance(kMin * 2);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.engine.prompts.last.enabled, isFalse);
      expect(n.endsCancelled(backstopId), isTrue, reason: '${n.order}');
    });
  });

  // ── G ─────────────────────────────────────────────────────────────────────

  group('G only the re-alarm is exempt from the 30-in-2-minutes budget', () {
    Future<void> fullBudget() async {
      rig.app.haptics.ledger.record(60, DateTime.now());
      expect(rig.app.haptics.commandsLeft, 0, reason: 'precondition');
    }

    test('the dismiss confirm waits for room', () async {
      await open();
      await fullBudget();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap, quick: true);
      rig.clock.advance(kSec * 1);
      await rig.tap(quick: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle,
          reason: 'precondition: dismissed');
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'the wearer is awake: a plain cue, not budget-exempt');
    });

    test('the snooze-cancelled cue waits for room', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      await fullBudget();
      await lastNightConfirmedAt(rig.clock.now.add(kMin * 1),
          upAt: rig.clock.now.subtract(const Duration(hours: 3)));
      rig.clock.advance(kMin * 2);
      await rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle,
          reason: 'precondition: cancelled');
      expect(rig.count(Played.cancelled), 0);
    });
  });

  // ── H ─────────────────────────────────────────────────────────────────────

  group('H the Android backstop is exact when the OS allows it', () {
    Future<Scheduled> backstop({required bool? canExact}) async {
      n.canExact = canExact;
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final due = rig.clock.now.add(kMin * 5);
      final s = n.at(due);
      expect(s, isNotNull, reason: 'the backstop was scheduled: ${n.scheduled}');
      return s!;
    }

    test('exact alarms allowed: exactAllowWhileIdle', () async {
      final s = await backstop(canExact: true);
      expect(s.mode, 'exactAllowWhileIdle',
          reason: 'an inexact backstop can arrive after the snooze deadline '
              'with Dart suspended');
    });

    test('exact alarms NOT allowed: inexactAllowWhileIdle, still scheduled',
        () async {
      final s = await backstop(canExact: false);
      expect(s.mode, 'inexactAllowWhileIdle');
    });

    test('the OS does not answer: inexact (never an exact request that would '
        'throw)', () async {
      final s = await backstop(canExact: null);
      expect(s.mode, 'inexactAllowWhileIdle');
    });
  });
}
