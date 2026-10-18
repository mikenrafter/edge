// Round 4 of the snooze safety review (Sol, alarm-snooze-sol-review3-2026-10-07
// .md): which taps and which terminations count. RED. Real AppState, engine,
// haptics queue, wake store and snooze store on the rig (snooze_band_rig.dart).
//
//  1  (P1) receipt-time mode (the alarm's strap clock was unset): a tap that
//     arrives as HISTORY (a plausible strap stamp, long past) never counts,
//     even though its identity is new. Only a live tap received inside the
//     window counts. Today `_snoozeTapTime` promotes every tap to live as soon
//     as the alarm's clock is unset.
//  (Attribution of a termination to the app's own playback was replaced in
//  round 8 by the quiet window and the "first termination at or after the fire"
//  rule: see snooze_r8_test.dart.)
//

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r4_taps_test.db');

  late SnoozeBandRig rig;

  Future<void> open({Map<String, Object?> settings = const {}}) async {
    rig = await SnoozeBandRig.open(settings: settings);
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
}
