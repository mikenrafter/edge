// Round 5 of the snooze safety review (Sol, alarm-snooze-sol-review4-2026-10-07
// .md). RED. Real AppState, engine, haptics queue and stores on the rig
// (snooze_band_rig.dart); phone notifications read off the platform channel.
//
//  1  (P1) a PREVIOUS app playback's tail never swallows the native alarm's
//     stop: tails are clipped at the fire F. A cue that ended at F-2 s still
//     has its tail running at F+1 s; the wearer's genuine stop stamped F+1 s
//     (heard at F+8 s) is the alarm's stop. The cue's own buffered expiry
//     (stamped before F) and a playback that started at/after F are still
//     attributed to the app.
//  2  (P2) "I'm up" (the Home card calls the controller directly) ends the
//     chain for the band queue too: a re-alarm queued behind another pattern
//     never plays after it.
//  3  (P2) a re-alarm queued just inside fire + 3 h that would start after it
//     is dropped: the queue's wanted() also checks the chain's age.
//  4  (P2, round 3 #4 leftover) a persisted snooze whose reAlarmAt is at or
//     past fire + 3 h (a round-3 build could write one) ends the chain on
//     resume and cancels the backstop; nothing is re-armed.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_fakes.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r5_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)
  late NotificationSpy n;

  setUp(() => n = NotificationSpy()..install());
  tearDown(() async {
    n.uninstall();
    await rig.dispose();
  });

  final backstopId = NotificationService.idSnoozeBackstop;

  Future<void> open({Map<String, Object?> settings = const {}}) async {
    rig = await SnoozeBandRig.open(settings: settings);
    t0 = rig.clock.now;
  }

  /// The app's own cue plays and ends. Returns when it ended (app clock).
  Future<DateTime> ownCueEnds() async {
    final before = rig.writes.length;
    await rig.app.gestureCues.slot(kGestureConfirmKey);
    await rig.settle();
    expect(rig.writes.length, greaterThan(before),
        reason: 'precondition: the cue reached the band');
    return rig.clock.now;
  }

  group('1 a previous playback\'s tail is clipped at the fire', () {
    test('the review\'s case: a cue ends at F-2 s, the alarm fires at F, '
        'the genuine stop stamped F+1 s (inside the old cue\'s tail) is '
        'heard at F+8 s: it is the alarm\'s stop', () async {
      await open();
      await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now; // F
      await rig.fire(stamp: t0);

      rig.clock.advance(kSec * 8); // heard at F + 8 s: no app pattern playing
      await rig.terminate(HapticsTermination.userDoubleTap,
          stamp: t0.add(kSec * 1));
      // Heard 7 s after it happened, its 4 s dismiss window is already over
      // (measured from the stop): with no second tap it becomes the snooze.
      expect(await storedState(), isNotNull,
          reason: 'the old cue\'s tail swallowed the wearer\'s stop: no '
              'dismiss window, and no band snooze follows');
    });

    test('...an expiry stop in the same place starts the snooze', () async {
      await open();
      await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 1));
      expect(await storedState(), isNotNull,
          reason: 'the alarm\'s stop was discarded as the old cue ending');
    });

    test('control (round 4): the old cue\'s OWN buffered expiry, stamped '
        'F-1 s, still does not consume the fire; the genuine stop does',
        () async {
      await open();
      final ended = await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 5);
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 1)); // F - 1 s
      expect(await storedState(), isNull);
      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 6));
      expect(await storedState(), isNotNull);
    });

    test('control: a playback that STARTED after F is attributed by its '
        'own interval + tail: its late expiry does not consume the fire',
        () async {
      await open();
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2);
      final ended = await ownCueEnds(); // plays and ends at F + 2 s
      rig.clock.advance(kSec * 6); // heard at F + 8 s, past the tail
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 1)); // F + 3 s, inside cue + tail
      expect(await storedState(), isNull,
          reason: 'our own cue ending (started after the fire)');
      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 12));
      expect(await storedState(), isNotNull);
    });
  });

  group('2 "I\'m up" ends the chain for the band queue', () {
    test('a re-alarm queued behind another pattern never plays once the '
        'wearer says "I\'m up"', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      expect(await storedState(), isNotNull, reason: 'precondition: snoozed');

      // Another pattern holds the band when the snooze falls due.
      final hold = Completer<void>();
      final job = rig.app.haptics.runJob(1, (token) async {
        await token.write(() async => true);
        await hold.future;
        return BuzzDelivery.complete;
      }, timeout: const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      rig.clock.advance(kMin * 5);
      final tick = rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rig.app.haptics.pending, greaterThan(1),
          reason: 'precondition: the re-alarm waits behind the pattern');
      expect(rig.count(Played.reAlarm), 0, reason: 'precondition');

      await rig.app.snooze.imUp(); // the Home card's button
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle,
          reason: 'precondition: dismissed');

      hold.complete();
      await job;
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect(rig.count(Played.reAlarm), 0,
          reason: 'the dismissed alarm buzzed anyway when the pattern ahead '
              'of it finished');
    });

    test('a wake confirmation that arrives while the re-alarm waits behind '
        'another pattern drops it too (the next tick notices)', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      expect(await storedState(), isNotNull, reason: 'precondition: snoozed');

      final hold = Completer<void>();
      final job = rig.app.haptics.runJob(1, (token) async {
        await token.write(() async => true);
        await hold.future;
        return BuzzDelivery.complete;
      }, timeout: const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      rig.clock.advance(kMin * 5);
      final tick = rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rig.app.haptics.pending, greaterThan(1),
          reason: 'precondition: the re-alarm waits behind the pattern');

      // The wearer is up: their phone confirmed it after the fire.
      await lastNightConfirmedAt(rig.clock.now.add(kSec * 10),
          upAt: rig.clock.now.subtract(const Duration(hours: 3)));
      rig.clock.advance(kSec * 30);
      await rig.app.debugKeepAliveTick(); // the next keep-alive tick
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle,
          reason: 'the confirmation never reached a snooze whose re-alarm '
              'was already on its way');
      expect(await storedState(), isNull);

      hold.complete();
      await job;
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect(rig.count(Played.reAlarm), 0,
          reason: 'the wearer was up and the re-alarm buzzed anyway');
    });

    test('control: nobody dismisses: the queued re-alarm plays after the '
        'pattern ahead of it', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      final hold = Completer<void>();
      final job = rig.app.haptics.runJob(1, (token) async {
        await token.write(() async => true);
        await hold.future;
        return BuzzDelivery.complete;
      }, timeout: const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      rig.clock.advance(kMin * 5);
      final tick = rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      hold.complete();
      await job;
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1));
    });
  });

  group('3 a queued re-alarm that would start after fire + 3 h is dropped',
      () {
    /// A snooze due just inside the bound is resumed while another pattern
    /// holds the band; the pattern ends [wait] later.
    Future<void> queuedNearTheBound({required Duration wait}) async {
      await open();
      await rig.fire(stamp: t0);
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 5,
          reAlarmAt: t0.add(const Duration(hours: 2, minutes: 59, seconds: 50)),
          fireAt: t0));
      final hold = Completer<void>();
      final job = rig.app.haptics.runJob(1, (token) async {
        await token.write(() async => true);
        await hold.future;
        return BuzzDelivery.complete;
      }, timeout: const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      rig.clock.advance(const Duration(hours: 2, minutes: 59, seconds: 58));
      await rig.app.snooze.resume(); // due: the re-alarm queues behind
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rig.count(Played.reAlarm), 0, reason: 'precondition: queued');
      expect(rig.app.haptics.pending, greaterThan(1),
          reason: 'precondition: waiting behind the pattern');

      rig.clock.advance(wait); // the pattern ends this much later
      hold.complete();
      await job;
      await rig.settle();
    }

    test('the pattern ends at F+3 h 3 s: the re-alarm never plays',
        () async {
      await queuedNearTheBound(wait: kSec * 5);
      expect(rig.count(Played.reAlarm), 0,
          reason: 'a phantom re-alarm more than 3 h after the alarm fired');
    });

    test('control: the pattern ends at F+2 h 59 min 59 s: it plays',
        () async {
      await queuedNearTheBound(wait: kSec * 1);
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1));
    });
  });

  group('4 a persisted snooze due at or past fire + 3 h ends on resume', () {
    Future<void> reopenAt(Duration afterFire, Duration dueAfterFire) async {
      await open();
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 4, reAlarmAt: t0.add(dueAfterFire), fireAt: t0));
      rig.clock.advance(afterFire);
      await rig.app.snooze.resume();
      await rig.settle();
    }

    test('the review\'s case: due F+3 h 20 min, reopened at F+2 h 55 min: '
        'the chain ends, the backstop is cancelled and none is armed past '
        'the bound', () async {
      await reopenAt(const Duration(hours: 2, minutes: 55),
          const Duration(hours: 3, minutes: 20));
      final limit = t0.add(const Duration(hours: 3));
      expect(n.scheduled.where((s) => !s.at.isBefore(limit)), isEmpty,
          reason: 'the OS notification was re-armed beyond the bound: '
              '${n.scheduled}');
      expect(await storedState(), isNull);
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(n.endsCancelled(backstopId), isTrue,
          reason: 'what the older build scheduled is cancelled: ${n.order}');
      rig.clock.advance(kMin * 30);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.count(Played.reAlarm), 0);
    });

    test('exactly F+3 h is past the bound too', () async {
      await reopenAt(const Duration(hours: 2, minutes: 50),
          const Duration(hours: 3));
      expect(await storedState(), isNull);
      expect(n.endsCancelled(backstopId), isTrue, reason: '${n.order}');
    });

    test('control: due F+2 h 58 min, reopened at F+2 h 55 min: it resumes '
        'and its backstop is armed', () async {
      final due = const Duration(hours: 2, minutes: 58);
      await reopenAt(const Duration(hours: 2, minutes: 55), due);
      expect(await storedState(), isNotNull);
      expect(n.idFor(t0.add(due)), backstopId);
    });

    test('controller: the same state is dropped, no timer is set',
        () async {
      final fire = kT0;
      final r = SnoozeRig(
          stored: SnoozeState(
              count: 4,
              reAlarmAt: fire.add(const Duration(hours: 3, minutes: 20)),
              fireAt: fire));
      r.advance(const Duration(hours: 2, minutes: 55));
      await r.controller.resume();
      await r.settle();
      expect(r.store.state, isNull);
      expect(r.controller.status.value, SnoozeStatus.idle);
      expect(r.scheduler.live, isEmpty);
      expect(r.plays, isEmpty);
    });
  });
}
