// Round 6 of the snooze safety review (Sol, alarm-snooze-sol-review6-2026-10-07
// .md). RED. A genuine stop that is delivered PROMPTLY must not be swallowed by
// the receipt-time guard: when the termination has a usable converted stamp it
// is attributed to the app's own playback by EVENT time only (the intervals,
// tails clipped at the fire). The receipt-time guard belongs to receipt-time
// mode (an unset clock), and there too the tail is clipped at the fire's
// receipt time.
//
// Real AppState, engine, haptics queue and stores on the rig.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r6_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // F

  tearDown(() async => rig.dispose());

  Future<void> open() async {
    rig = await SnoozeBandRig.open();
    t0 = rig.clock.now;
  }

  /// The app's own cue plays and ends now. Returns when it ended.
  Future<DateTime> ownCueEnds() async {
    final before = rig.writes.length;
    await rig.app.gestureCues.slot(kGestureConfirmKey);
    await rig.settle();
    expect(rig.writes.length, greaterThan(before),
        reason: 'precondition: the cue reached the band');
    return rig.clock.now;
  }

  const lag = Duration(milliseconds: 1200);

  group('a prompt genuine stop right after an old cue is the alarm\'s', () {
    test('cue ends at F-1 s, fire at F, expiry stamped F+1 s received at '
        'F+1.2 s (inside the old receipt tail): the snooze starts', () async {
      await open();
      await ownCueEnds();
      rig.clock.advance(kSec * 1);
      t0 = rig.clock.now; // F
      await rig.fire(stamp: t0);
      rig.clock.advance(lag);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 1));
      expect(await storedState(), isNotNull,
          reason: 'the receipt-time guard took the wearer\'s prompt stop for '
              'the old cue ending: no re-alarm');
    });

    test('...a double-tap stop opens the dismiss window', () async {
      await open();
      await ownCueEnds();
      rig.clock.advance(kSec * 1);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(lag);
      await rig.terminate(HapticsTermination.userDoubleTap,
          stamp: t0.add(kSec * 1));
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'no dismiss window: the stop was discarded');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window);
    });

    test('receipt-time mode (unset clocks): the same timing, the tail is '
        'clipped at the fire\'s receipt time: the snooze starts', () async {
      await open();
      await ownCueEnds();
      rig.clock.advance(kSec * 1);
      t0 = rig.clock.now;
      await rig.fire(stamp: kUnsetStrap);
      rig.clock.advance(lag);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNotNull,
          reason: 'the old cue\'s receipt tail covered a stop heard after '
              'the fire');
    });

    test('control: the old cue\'s own expiry, stamped F-1 s, received at '
        'F+1.2 s: still our pattern ending', () async {
      await open();
      final ended = await ownCueEnds();
      rig.clock.advance(kSec * 1);
      t0 = rig.clock.now;
      await rig.fire(stamp: t0);
      rig.clock.advance(lag);
      await rig.terminate(HapticsTermination.expired,
          stamp: ended.add(kSec * 0)); // F - 1 s
      expect(await storedState(), isNull);
    });

    test('control: a stop received WHILE a pattern started after the fire '
        'is playing is ignored (receipt-time mode)', () async {
      await open();
      await rig.fire(stamp: kUnsetStrap);
      await ownCueEnds(); // starts and ends after the fire
      rig.clock.advance(kSec * 1);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNull, reason: 'inside the tail');
      rig.clock.advance(kSec * 6);
      await rig.terminate(HapticsTermination.expired, stamp: kUnsetStrap);
      expect(await storedState(), isNotNull);
    });
  });
}
