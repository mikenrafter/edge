// Round 4 of the snooze safety review (Sol, alarm-snooze-sol-review3-2026-10-07
// .md): which taps and which terminations count. RED. Real AppState, engine,
// haptics queue, wake store and snooze store on the rig (snooze_band_rig.dart).
//
//  1  (P1) receipt-time mode (the alarm's strap clock was unset): a tap that
//     arrives as HISTORY (a plausible strap stamp, long past) never counts,
//     even though its identity is new. Only a live tap received inside the
//     window counts. Today `_snoozeTapTime` promotes every tap to live as soon
//     as the alarm's clock is unset.
//  2  (P1, round 2 #1 partial) a termination is attributed to the app's own
//     playback by its EVENT time: one whose (converted) stamp lies inside an
//     app playback interval (+ the 3 s tail) is that playback ending, even when
//     it is RECEIVED after the tail. In receipt-time mode the attribution is by
//     receipt, as before.
//
// Contract used: nothing new; the app's playback intervals are measured on the
// app's wake clock (the rig's TestClock).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r4_taps_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)

  Future<void> open({Map<String, Object?> settings = const {}}) async {
    rig = await SnoozeBandRig.open(settings: settings);
    t0 = rig.clock.now;
  }

  tearDown(() async => rig.dispose());

  group('1 a historical tap in receipt-time mode never counts', () {
    test('unset clock on the fire AND the stop: the window opens; a tap '
        'stamped YESTERDAY, new identity, received inside it is not tap #2',
        () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap, stamp: kUnsetStrap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: the dismiss window is open (receipt time)');

      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.subtract(const Duration(days: 1)));
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'a tap from yesterday replayed from the band\'s flash was '
              'counted as the wearer\'s second tap: a false dismissal, and '
              'nobody is woken');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window,
          reason: 'the window is still open, still waiting for a real tap');
    });

    test('...a live tap (stamp = now) received in the same window still '
        'dismisses (control: receipt time keeps working)', () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap, stamp: kUnsetStrap);
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.subtract(const Duration(days: 1)));
      rig.clock.advance(kSec * 1);
      await rig.tap(); // live: stamped now
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('...a tap with an unset stamp is receipt time and counts (control)',
        () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap, stamp: kUnsetStrap);
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: kUnsetStrap);
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('unset clock on the FIRE only: the same', () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.userDoubleTap); // believable
      expect(rig.app.snooze.consumesDoubleTaps, isTrue, reason: 'precondition');
      rig.clock.advance(kSec * 1);
      await rig.tap(stamp: rig.clock.now.subtract(const Duration(hours: 5)));
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'history counted because the fire\'s clock was unset');
    });

    test('the re-alarm of a receipt-time chain: two historical taps do not '
        'dismiss it', () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNotNull, reason: 'precondition: snoozed');
      rig.clock.advance(kMin * 5);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: the re-alarm plays and listens');

      for (var i = 0; i < 2; i++) {
        rig.clock.advance(kSec * 1);
        await rig.tap(
            stamp: rig.clock.now.subtract(Duration(hours: 20 + i)));
      }
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'two replayed taps silenced the re-alarm');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.reAlarming);
    });
  });

  group('2 a termination is attributed to our playback by its EVENT time', () {
    /// The app's own cue plays and ends. Returns when it ended (app clock).
    Future<DateTime> ownCueEnds() async {
      final before = rig.writes.length;
      await rig.app.gestureCues.slot(kGestureConfirmKey);
      await rig.settle();
      expect(rig.writes.length, greaterThan(before),
          reason: 'precondition: the cue reached the band');
      return rig.clock.now;
    }

    test('the review\'s case: a cue ends at F-2 s, the alarm fires at F, the '
        'cue\'s buffered expiry (stamped inside the cue + tail) arrives 5 s '
        'after F, past the tail: it does not use up the fire; the genuine '
        'native stop afterwards still snoozes', () async {
      await open();
      final ended = await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now; // F = ended + 2 s
      await rig.fire(stamp: t0);

      rig.clock.advance(kSec * 5); // received at F + 5 s: the tail is over
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 1)); // F - 1 s, inside cue + 3 s tail
      expect(await storedState(), isNull,
          reason: 'our own cue ending (stamped inside its playback) was taken '
              'as the alarm\'s stop: a phantom snooze');
      expect(rig.app.snooze.consumesDoubleTaps, isFalse);

      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired); // the genuine stop
      expect(await storedState(), isNotNull,
          reason: 'the fire was used up by the cue\'s expiry: the genuine '
              'stop is discarded as "already taken" and the wearer gets no '
              're-alarm');
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('the same with the strap 2 minutes AHEAD: the interval and the '
        'stamp are compared in PHONE time', () async {
      await open();
      const ahead = Duration(minutes: 2);
      rig.strapRunsAhead(ahead);
      final ended = await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0.add(ahead));

      rig.clock.advance(kSec * 5);
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 1).add(ahead));
      expect(await storedState(), isNull,
          reason: 'a stamp inside the playback interval once converted to '
              'phone time');

      rig.clock.advance(kSec * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: rig.clock.now.add(ahead));
      expect(await storedState(), isNotNull);
    });

    test('a termination stamped AFTER the cue + tail is the alarm\'s, even '
        'received late (control)', () async {
      await open();
      final ended = await ownCueEnds();
      rig.clock.advance(kSec * 2);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 9);
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 6)); // F + 4 s: outside cue + 3 s tail
      expect(await storedState(), isNotNull);
    });

    test('receipt-time mode (unset stamps) attributes by RECEIPT: a '
        'termination received inside the tail is our cue ending, one received '
        'after it is the stop (control)', () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      await ownCueEnds();
      rig.clock.advance(kSec * 1);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNull, reason: 'inside the tail');
      rig.clock.advance(kSec * 6);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNotNull);
    });
  });
}
