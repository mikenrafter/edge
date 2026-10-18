// Round 8 (owner: SIMPLIFY, 2026-10-07). RED. Instead of attributing an app
// pattern's ending to the app by intervals, tails and stamp precision, the app
// AVOIDS the overlap:
//
//  quiet window   while snooze is on and an alarm is armed for T, non-alarm
//                 app haptics are HELD (never dropped) from T-10 s until the
//                 native stop is handled, or T + 30 s (native alarm duration)
//                 + 5 s when none arrives. The band queue's own hold is used.
//                 Gesture jobs and alarm jobs are not held. Snooze off: no
//                 window at all.
//  attribution    the first valid termination (not an error) stamped at or
//                 after the fire F (converted strap time; receipt time when
//                 the clock is unset) is the alarm's stop. One stamped before F
//                 never is.
//
// Real AppState, engine, haptics queue and stores on the rig.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

/// Fixed: nothing here reads the system clock.
final DateTime _start = DateTime(2026, 10, 7, 6, 0, 0);

void main() {
  snoozeSuiteSetup('openstrap_snooze_r8_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // T = F: the armed alarm's time, and when it fires

  tearDown(() async => rig.dispose());

  /// An alarm armed 30 s from now.
  Future<void> open({bool? snooze = true}) async {
    rig = await SnoozeBandRig.open(snooze: snooze, start: _start);
    t0 = rig.clock.now.add(kSec * 30);
    rig.engine.state.alarmEpoch = secOf(t0);
  }

  /// The app asks for a plain cue now (a held one waits in the band queue).
  Future<BuzzDelivery> requestCue() =>
      rig.app.gestureCues.slot(kGestureConfirmKey);

  Future<void> tick() async {
    await rig.app.debugKeepAliveTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  group('quiet window', () {
    test('(a)(e) a cue requested at T-5 s is held; the genuine stop '
        'releases it and it still plays (never dropped)', () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 8));
      await tick(); // the keep-alive opens the window (T-10 s)
      rig.clock.at(t0.subtract(kSec * 5));
      final cue = requestCue();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(hapticWrites(rig), 0,
          reason: 'the cue played over the arriving alarm: its band '
              'termination could be taken for the alarm\'s');
      expect(rig.app.haptics.pending, greaterThan(0),
          reason: 'it waits in the band queue');

      rig.clock.at(t0);
      await rig.fire(stamp: t0);
      expect(hapticWrites(rig), 0, reason: 'still held at the fire');
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired, quick: true);
      var heard = false;
      for (var i = 0; i < 100 && !heard; i++) {
        heard = await storedState() != null;
        if (!heard) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(heard, isTrue, reason: 'the stop was heard');

      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete,
          reason: 'the held cue was dropped, not played later');
      expect(hapticWrites(rig), greaterThan(0));
    });

    test('with no stop heard the window ends at T + 30 s + 5 s and releases '
        'the cue', () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 8));
      await tick();
      rig.clock.at(t0.subtract(kSec * 5));
      final cue = requestCue();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hapticWrites(rig), 0, reason: 'precondition: held');

      rig.clock.at(t0.add(kSec * 34));
      await tick();
      expect(hapticWrites(rig), 0, reason: 'still inside T + 35 s');

      rig.clock.at(t0.add(kSec * 36));
      await tick();
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
      expect(hapticWrites(rig), greaterThan(0));
    });

    test('well before T-10 s a cue plays at once (control)', () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 30));
      await tick();
      final cue = requestCue();
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
      expect(hapticWrites(rig), greaterThan(0));
    });

    test('a gesture job (a tap\'s own cue) is not held', () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 8));
      await tick();
      final cue = rig.app.haptics
          .asGesture('tap-in-window', () => requestCue());
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
      expect(hapticWrites(rig), greaterThan(0));
    });

    test('switching Snooze off inside the window releases what it held',
        () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 8));
      await tick();
      final cue = requestCue();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hapticWrites(rig), 0, reason: 'precondition: held');
      await switchSnoozeOff(rig);
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
    });

    test('(f) snooze OFF: no window, a cue at T-5 s plays at once', () async {
      await open(snooze: false);
      rig.clock.at(t0.subtract(kSec * 8));
      await tick();
      rig.clock.at(t0.subtract(kSec * 5));
      final cue = requestCue();
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
      expect(hapticWrites(rig), greaterThan(0));
    });

    test('no alarm armed: no window', () async {
      rig = await SnoozeBandRig.open(start: _start);
      rig.engine.state.alarmEpoch = null;
      await tick();
      final cue = requestCue();
      expect(await cue.timeout(const Duration(seconds: 20)),
          BuzzDelivery.complete);
    });
  });

  group('attribution: the first valid termination stamped at or after F', () {
    Future<void> openFired() async {
      rig = await SnoozeBandRig.open(start: _start);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
    }

    test('(b) a termination stamped before F never consumes the fire; the '
        'genuine one after it does', () async {
      await openFired();
      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.subtract(kSec * 2));
      expect(await storedState(), isNull,
          reason: 'something that ended before the alarm fired is not its '
              'stop');
      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 5));
      expect(await storedState(), isNotNull);
    });

    test('(b) ...a double-tap termination stamped 30 s before F starts '
        'nothing', () async {
      await openFired();
      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.userDoubleTap,
          stamp: t0.subtract(kSec * 30));
      expect(rig.app.snooze.consumesDoubleTaps, isFalse);
      expect(await storedWindow(), isNull);
      expect(await storedState(), isNull,
          reason: 'its window (4 s from a stop 30 s ago) was over at once and '
              'became a snooze');
    });

    test('(c) the first termination stamped at F (the same second) is the '
        'alarm\'s, and a second one changes nothing', () async {
      await openFired();
      await rig.terminate(HapticsTermination.expired, stamp: t0);
      final first = await storedState();
      expect(first, isNotNull);
      rig.clock.advance(kSec * 20);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 19));
      expect(await storedState(), first);
    });

    test('(c) the first one stamped after F (not an error) is the '
        'alarm\'s', () async {
      await openFired();
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.error, stamp: t0.add(kSec * 2));
      expect(await storedState(), isNull, reason: 'an error is no stop');
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 3));
      expect(await storedState(), isNotNull);
    });

    test('(d) unset strap clock on the fire: receipt time; an old stamp is '
        'not "before F"', () async {
      rig = await SnoozeBandRig.open(start: _start);
      t0 = rig.clock.now;
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.subtract(const Duration(days: 1)));
      expect(await storedState(), isNotNull);
    });

    test('(d) unset clock on the stop: receipt time', () async {
      await openFired();
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNotNull);
    });
  });
}
