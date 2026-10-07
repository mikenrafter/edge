// Round 4 of the snooze safety review (Sol, alarm-snooze-sol-review3-2026-10-07
// .md): the re-alarm in the band queue. RED. Real AppState, engine, haptics
// queue and stores on the rig (snooze_band_rig.dart).
//
//  3  (P2) a re-alarm job that is already QUEUED (held by the open Device lab)
//     must never play once the chain has ended: the snooze switched off,
//     Cancel-all, or the band unpaired. Ending the chain bumps the
//     controller's generation but cancels nothing in the transport; the lab
//     closing releases the job and it buzzes.
//  6  (P2) the re-alarm's tap window starts when its PLAYBACK FINISHES, not at
//     the last write: the delivery future completes before the band has played
//     the last phrase, so with a 2 s window the wearer's taps during and just
//     after the final phrase are rejected.
//
// Contract used for 6: the playback of the delivered pattern is over when the
// band reports it ended (event 100), or its settle time runs out: the same
// point at which the band queue frees the band. The window runs from there.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'snooze_band_rig.dart';
import 'snooze_notification_spy.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

void main() {
  snoozeSuiteSetup('openstrap_snooze_r4_queue_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires (phone time)
  late NotificationSpy n;

  setUp(() => n = NotificationSpy()..install());
  tearDown(() async {
    n.uninstall();
    await rig.dispose();
  });

  Future<void> open({
    AutoEnd autoEnd = AutoEnd.queueOnly,
    Map<String, Object?> settings = const {},
  }) async {
    rig = await SnoozeBandRig.open(autoEnd: autoEnd, settings: settings);
    t0 = rig.clock.now;
  }

  group('3 a queued re-alarm never plays once the chain has ended', () {
    /// The keep-alive tick still waiting on the delivery (a Future returned
    /// from an async function would be awaited, so it is kept here).
    late Future<void> tick;

    /// Snoozed; the Device lab opens; the re-alarm falls due and queues behind
    /// the lab.
    Future<void> queuedReAlarm() async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      await rig.settle();
      expect(await storedState(), isNotNull, reason: 'precondition: snoozed');

      rig.app.haptics.beginLab();
      rig.clock.advance(kMin * 5);
      tick = rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rig.app.haptics.pending, greaterThan(0),
          reason: 'precondition: the re-alarm job waits in the band queue');
      expect(rig.count(Played.reAlarm), 0, reason: 'precondition: held');
    }

    Future<void> expectNeverPlays() async {
      final before = hapticWrites(rig);
      rig.app.haptics.endLab(); // the lab closes: the queue releases its jobs
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect(rig.count(Played.reAlarm), 0,
          reason: 'the chain ended while the re-alarm waited, and the band '
              'buzzed anyway');
      expect(hapticWrites(rig), before,
          reason: 'not one haptic command may reach the band');
    }

    test('the Snooze switch turned off', () async {
      await queuedReAlarm();
      await switchSnoozeOff(rig);
      await expectNeverPlays();
    });

    test('Cancel-all', () async {
      await queuedReAlarm();
      rig.engine.allowUserDisable = true;
      await rig.app.disableAlarm();
      await expectNeverPlays();
    });

    // Guard, green today (an unpaired app refuses the job on its own): kept so
    // the fix for the two above cannot loosen it.
    test('unpairing the band (and a band connected again before the lab '
        'closes: the queue must not hand the old chain\'s buzz to it)',
        () async {
      await queuedReAlarm();
      await rig.app.unpair();
      rig.engine.state.generation = 'gen5';
      rig.engine.state.connection = 'connected';
      await expectNeverPlays();
    });

    test('control: nothing ends the chain, the lab closes: the re-alarm '
        'plays', () async {
      await queuedReAlarm();
      rig.app.haptics.endLab();
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1));
    });
  });

  group('6 the re-alarm\'s tap window starts when its playback finishes', () {
    test('the band is still playing the last phrase 2.5 s after the last '
        'write; with a 2 s window, taps 1 s and 1.5 s after the playback '
        'ended dismiss', () async {
      await open(autoEnd: AutoEnd.none, settings: {'windowMs': 2000});
      await rig.fire(stamp: t0);
      // A snooze that is already due, as a restart would find it.
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 1, reAlarmAt: t0.add(kSec * 1), fireAt: t0));
      rig.clock.advance(kSec * 10);
      await rig.app.snooze.resume(); // due: the re-alarm is delivered now

      // The band takes the pattern's commands one by one; each one ends.
      final cmds = bandSequenceCommands(
          alarmSequenceFromNotes(const SnoozeSchedule().reAlarmCode(1),
              id: systemPatternId(kAlarmReAlarmKey)),
          HapticDeviceProfile.forGeneration('gen5'),
          maxRuntime: rig.app.haptics.maxRuntime);
      expect(cmds, greaterThanOrEqualTo(1), reason: 'precondition');
      for (var k = 1; k < cmds; k++) {
        expect(await until(() => hapticWrites(rig) >= k), isTrue,
            reason: 'command $k reached the band');
        rig.endPlayback();
      }
      expect(await until(() => hapticWrites(rig) >= cmds), isTrue,
          reason: 'the LAST command reached the band');
      // Let a delivery that completes at the last write say so.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: listening has opened');

      rig.clock.advance(kSec * 2 + const Duration(milliseconds: 500));
      rig.endPlayback(); // the band finishes the last phrase now
      await rig.settle();

      rig.clock.advance(kSec * 1);
      await rig.tap();
      rig.clock.advance(const Duration(milliseconds: 500));
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1),
          reason: 'the window ran out 0.5 s into the last phrase: the taps '
              'after the playback finished were rejected');
    });

    test('control: taps later than the window after the playback ended do '
        'not dismiss', () async {
      await open(autoEnd: AutoEnd.none, settings: {'windowMs': 2000});
      await rig.fire(stamp: t0);
      await const DbSnoozeStore().saveState(SnoozeState(
          count: 1, reAlarmAt: t0.add(kSec * 1), fireAt: t0));
      rig.clock.advance(kSec * 10);
      await rig.app.snooze.resume();
      final cmds = bandSequenceCommands(
          alarmSequenceFromNotes(const SnoozeSchedule().reAlarmCode(1),
              id: systemPatternId(kAlarmReAlarmKey)),
          HapticDeviceProfile.forGeneration('gen5'),
          maxRuntime: rig.app.haptics.maxRuntime);
      for (var k = 1; k < cmds; k++) {
        expect(await until(() => hapticWrites(rig) >= k), isTrue);
        rig.endPlayback();
      }
      expect(await until(() => hapticWrites(rig) >= cmds), isTrue);
      rig.endPlayback();
      await rig.settle();

      rig.clock.advance(kSec * 3); // past the 2 s window
      await rig.tap();
      rig.clock.advance(kSec * 1);
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), 0);
    });
  });
}
