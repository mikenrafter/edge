// Round 7 of the snooze safety review (Sol, alarm-snooze-sol-review7-2026-10-07
// .md). RED. Termination stamps are WHOLE seconds (the strap's RTC) while the
// app's playback starts keep phone-clock fractions: a short cue started at
// F+2.100 s whose expiry the band stamps F+2 s falls BEFORE the recorded start,
// is not attributed to the cue, and consumes the fire. Attribution compares at
// the stamp's precision: the interval start is floored to the whole second
// (a stamp covers [s, s+1)), for open and completed intervals alike. Tail
// clipping at the fire is unchanged.
//
// Real AppState, engine, haptics queue and stores on the rig. The rig starts on
// a whole second; the fractions come from moving its TestClock by milliseconds.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_r3_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r7_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // F, a whole second

  tearDown(() async => rig.dispose());

  Future<void> open({AutoEnd autoEnd = AutoEnd.queueOnly}) async {
    rig = await SnoozeBandRig.open(autoEnd: autoEnd);
    t0 = rig.clock.now;
  }

  Future<void> cue() async {
    final before = rig.writes.length;
    await rig.app.gestureCues.slot(kGestureConfirmKey);
    await rig.settle();
    expect(rig.writes.length, greaterThan(before),
        reason: 'precondition: the cue reached the band');
  }

  const frac = Duration(milliseconds: 100);

  group('a whole-second stamp is compared with a fractional playback start',
      () {
    test('the band answers the cue (started F+2.1 s) with its own expiry '
        'stamped F+2 s, through the engine: our pattern ending, the fire '
        'stays open and the genuine stop snoozes', () async {
      await open(autoEnd: AutoEnd.real);
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2 + frac);
      await cue(); // the band's real expiry arrives stamped F + 2 s
      expect(await storedState(), isNull,
          reason: 'our own cue ending was taken for the alarm\'s stop: its '
              'whole-second stamp lies before the fractional start');

      rig.clock.advance(kSec * 10);
      await rig.terminate(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });

    test('a completed short cue (F+2.1 s .. F+2.6 s): its expiry stamped '
        'F+2 s, heard at F+2.6 s, is not the alarm\'s stop', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2 + frac);
      await cue(); // starts and ends at F + 2.1 s on the test clock
      rig.clock.advance(const Duration(milliseconds: 500));
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 2));
      expect(await storedState(), isNull,
          reason: 'a stamp floored to the second preceded the recorded start');

      rig.clock.advance(kSec * 10);
      await rig.terminate(HapticsTermination.expired);
      expect(await storedState(), isNotNull);
    });

    test('control: a stamp the second BEFORE the cue\'s second is not '
        'covered: it is the alarm\'s stop', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2 + frac);
      await cue();
      rig.clock.advance(const Duration(milliseconds: 500));
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 1)); // F + 1 s, before the cue's second
      expect(await storedState(), isNotNull);
    });

    test('control: a stamp past cue + tail is the alarm\'s stop', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 2 + frac);
      await cue();
      rig.clock.advance(kSec * 6);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(kSec * 6)); // F + 6 s: past F + 2.1 s + 3 s
      expect(await storedState(), isNotNull);
    });
  });
}
