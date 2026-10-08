// Round 3 of the snooze safety review (Sol, alarm-snooze-sol-review2-2026-10-07
// .md): the native stop. RED. Real AppState, engine, haptics queue, wake store
// and snooze store on the rig (snooze_band_rig.dart); events are real frames
// with the strap's own stamps.
//
//  A  snooze is OPT-IN: a wearer who never touches the settings sees the
//     native alarm path exactly as before this branch
//  B  (new 1) a fire is consumed only by a VALID native stop; an `error` or a
//     termination during the app's own playback never consumes it
//  C  (new 2, partial 3) one clock domain: strap stamps become phone time
//     through the engine's ClockRef; an unset strap clock means receipt time
//     for ALL of that alarm's events
//  I  (partial 2) tap identities are persisted with the window
//  J  (partial 5) a confirmation counts only at or after the fire (60 s slack)
//
// Contract used where the production API is new: the settings JSON field
// `enabled` (default false). (Round 8 removed the app-playback attribution
// tests of group B: the quiet window, snooze_r8_test.dart, replaces them.)

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r3_stop_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)

  Future<void> open({
    DateTime? start,
    String generation = 'gen5',
    AutoEnd autoEnd = AutoEnd.queueOnly,
    bool? snooze = true,
    Map<String, Object?> settings = const {},
  }) async {
    rig = await SnoozeBandRig.open(
        start: start,
        generation: generation,
        autoEnd: autoEnd,
        snooze: snooze,
        settings: settings);
    t0 = rig.clock.now;
  }

  tearDown(() async => rig.dispose());

  /// The native alarm fires at [t0] and the wearer stops it [after] later.
  Future<void> fireAndStop(int code,
      {Duration after = const Duration(seconds: 8)}) async {
    await rig.fire(stamp: t0);
    rig.clock.advance(after);
    await rig.terminate(code);
  }

  group('A snooze is opt-in: a wearer who never opens the settings', () {
    late NotificationSpy n;
    setUp(() => n = NotificationSpy()..install());
    tearDown(() => n.uninstall());

    test('the default is OFF', () async {
      await open(snooze: null);
      expect(enabledOf(rig.app.snoozeSettings), isFalse,
          reason: 'the snooze settings carry an `enabled` field, false until '
              'the wearer switches it on');
    });

    test('a double-tap stop opens no window and consumes no tap: the taps '
        'that follow are the wearer\'s normal gestures', () async {
      await open(snooze: null);
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isFalse,
          reason: 'with snooze off a termination opens no window');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
      expect(await storedWindow(), isNull);
      expect(await storedState(), isNull);

      for (var i = 0; i < 2; i++) {
        rig.clock.advance(kSec * 1);
        final before = rig.app.deviceLab.entries.length;
        await rig.tap();
        expect(rig.app.deviceLab.entries.length, before + 1,
            reason: 'tap ${i + 1} reached the gestures (consumed: false)');
      }
      expect(rig.count(Played.dismissConfirm), 0);
      expect(rig.count(Played.snoozeConfirm), 0);
    });

    test('an expired stop starts no snooze, no confirm cue, nothing stored',
        () async {
      await open(snooze: null);
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNull);
      expect(await storedWindow(), isNull);
      expect(rig.deliveries, isEmpty);
      rig.clock.advance(kMin * 6);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.count(Played.reAlarm), 0);
    });

    test('no band-prompt lease and no phone backstop, at the fire or at the '
        'stop', () async {
      await open(snooze: null);
      await rig.fire(stamp: t0);
      await rig.settle();
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isEmpty,
          reason: 'no lease: the band is prompted as it was before this '
              'branch');
      expect(n.scheduled, isEmpty, reason: 'no backstop notification');
    });

    test('control: switched on, the same stop does snooze', () async {
      await open(snooze: true);
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });
  });

  group('B a fire is consumed only by a VALID native stop', () {
    test('an `error` termination heard after the fire (stamped 10 s BEFORE '
        'it) does not use up the fire: the real expiry still snoozes',
        () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2);
      await rig.terminate(HapticsTermination.error,
          stamp: t0.subtract(kSec * 10));
      expect(await storedState(), isNull, reason: 'an error is no stop');

      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      expect(await storedState(), isNotNull,
          reason: 'the genuine native expiry was discarded as "already '
              'taken": the wearer gets no re-alarm');
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('an `error` right after the fire, then the wearer\'s double tap '
        'stop, opens the window', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 1);
      await rig.terminate(HapticsTermination.error);
      rig.clock.advance(kSec * 5);
      await rig.terminate(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue);
    });

    test('control: an `unknown` cause on a capable band is a valid stop '
        '(failing toward waking)', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.app.debugOnHapticsTerminated('unknown', at: rig.clock.now);
      await rig.settle();
      expect(await storedState(), isNotNull);
    });

    test('control: a second termination for the same fire changes nothing',
        () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      final first = await storedState();
      rig.clock.advance(kSec * 40);
      await rig.terminate(HapticsTermination.expired);
      expect(await storedState(), first);
    });
  });

  group('C one clock domain: strap stamps become phone time by the engine\'s '
      'ClockRef', () {
    test('a strap 2 minutes AHEAD: its genuine stop 10 s after the fire is '
        'that fire\'s stop, and the snooze is due 5 min after the stop in '
        'PHONE time', () async {
      await open();
      const ahead = Duration(minutes: 2);
      rig.strapRunsAhead(ahead);
      await rig.fire(stamp: t0.add(ahead)); // the strap's stamp of "now"
      rig.clock.advance(kSec * 10);
      await rig.terminate(HapticsTermination.expired,
          stamp: rig.clock.now.add(ahead));
      final st = await storedState();
      expect(st, isNotNull,
          reason: 'a future termination was clamped to receipt time while '
              'the fire stayed in strap time: -110 s, "not its stop"');
      expect(st!.reAlarmAt.difference(rig.clock.now).inSeconds.abs(),
          closeTo(300, 2),
          reason: 'due in phone time');
    });

    test('a strap 5 s BEHIND: the double-tap stop keeps the full 4 s dismiss '
        'window (phone time) and a tap 1 s later dismisses', () async {
      await open();
      const behind = Duration(seconds: -5);
      rig.strapRunsAhead(behind);
      await rig.fire(stamp: t0.add(behind));
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap,
          stamp: rig.clock.now.add(behind));
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'the strap-stamped stop made the window end 1 s ago');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window);

      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.add(behind));
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1),
          reason: 'the tap\'s strap stamp preceded the window and was '
              'rejected');
    });

    test('a strap 2 minutes AHEAD: the double-tap stop, the window and a tap '
        'all agree', () async {
      await open();
      const ahead = Duration(minutes: 2);
      rig.strapRunsAhead(ahead);
      await rig.fire(stamp: t0.add(ahead));
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap,
          stamp: rig.clock.now.add(ahead));
      expect(rig.app.snooze.consumesDoubleTaps, isTrue);
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.add(ahead));
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('a strap 10 s BEHIND: during the re-alarm a live tap is still live '
        '(age is measured in phone time) and two dismiss', () async {
      await open();
      const behind = Duration(seconds: -10);
      rig.strapRunsAhead(behind);
      await rig.fire(stamp: t0.add(behind));
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired,
          stamp: rig.clock.now.add(behind));
      rig.clock.advance(kMin * 5);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: the re-alarm plays and listens');

      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.add(behind));
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.add(behind));
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1),
          reason: 'taps 10 s old by the strap\'s clock were called replayed');
    });

    test('an UNSET strap clock (epoch zero) on the fire AND the stop: receipt '
        'time for both, the stop is that fire\'s', () async {
      await open();
      final unset = DateTime.fromMillisecondsSinceEpoch(0);
      await rig.fire(stamp: unset);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired, stamp: unset);
      final st = await storedState();
      expect(st, isNotNull,
          reason: 'the stop got no stamp, the fire kept 1970: they could '
              'never correlate');
      expect(st!.reAlarmAt.difference(rig.clock.now).inSeconds.abs(),
          closeTo(300, 2));
    });

    test('an unset clock on the FIRE only: receipt time for both', () async {
      await open();
      await rig.fire(stamp: DateTime.fromMillisecondsSinceEpoch(0));
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired); // a believable stamp
      expect(await storedState(), isNotNull);
    });

    test('an unset clock on the STOP only: receipt time for both', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired,
          stamp: DateTime.fromMillisecondsSinceEpoch(0));
      expect(await storedState(), isNotNull);
    });

    test('an unset clock on the TAPS: receipt time, they count', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: DateTime.fromMillisecondsSinceEpoch(0));
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('control: both clocks agree (no ClockRef): unchanged', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });
  });

  group('I a replayed tap after a restart cannot count twice', () {
    test('3 taps required: stop (#1), tap A (#2), restart, the SAME tap A '
        'delivered again is not #3; a new tap is', () async {
      await open(settings: {'requiredTaps': 3});
      await fireAndStop(HapticsTermination.userDoubleTap);
      rig.clock.advance(kSec * 1);
      final tapA = rig.clock.now;
      await rig.tap(sub: 4242);
      expect(rig.count(Played.dismissConfirm), 0, reason: 'only 2 of 3');
      final clock = rig.clock;
      await rig.dispose(); // the process dies inside the window

      rig = await SnoozeBandRig.open(
          clock: clock, settings: {'requiredTaps': 3});
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: the window was restored');

      clock.advance(kSec * 1);
      await rig.tap(stamp: tapA, sub: 4242); // the same event, still live
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'the identity was only in memory: the replay counted again '
              'and falsely dismissed');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window);

      clock.advance(kSec * 1);
      await rig.tap(); // a genuinely new tap
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });
  });

  group('J a confirmed wake counts only at or after the fire', () {
    // Start at 10:30: the fire is t0. Up 07:10, back to bed, alarm at t0.
    test('the review\'s case: confirmed 07:00 (up 07:15), alarm 07:20: that '
        'confirmation is the previous block\'s and never suppresses',
        () async {
      await open(start: DateTime(2026, 10, 7, 7, 20));
      await lastNightConfirmedAt(DateTime(2026, 10, 7, 7, 0));
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('61 s before the fire: not this alarm\'s', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await lastNightConfirmedAt(t0.subtract(kSec * 61));
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });

    test('20 minutes before the fire: not this alarm\'s', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await lastNightConfirmedAt(t0.subtract(kMin * 20));
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });

    test('59 s before the fire is inside the 60 s clock-skew slack (control)',
        () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await lastNightConfirmedAt(t0.subtract(kSec * 59));
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNull);
      expect(rig.deliveries, isEmpty);
    });

    test('after the fire it counts (control)', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await lastNightConfirmedAt(t0.add(kSec * 5));
      await fireAndStop(HapticsTermination.expired);
      expect(await storedState(), isNull);
      expect(rig.deliveries, isEmpty);
    });
  });
}
