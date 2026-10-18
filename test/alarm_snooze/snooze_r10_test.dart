// Round 10 (Sol, /tmp/snooze-sol-r9.out). RED. The quiet window around the
// native alarm, on a real AppState / engine / haptics queue (the rig). Every
// date here is fixed and every clock is the rig's TestClock or an injected
// monotonic reading; nothing reads the system clock. (Waits are event-loop
// turns for the rig's database and queue, not clock readings.)
//
//  2  a restart inside the window: the saved alarm loads AFTER the snooze
//     settings, and the window is checked again then
//  3  AppState tells the queue when the next window opens, so a plain job that
//     could still be playing then is held
//  4  the window is bounded by MONOTONIC time and by the wall clock staying in
//     [T-10 s, T+35 s]: moving the phone clock back never keeps a hold

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'snooze_band_rig.dart';
import 'snooze_fakes.dart';
import 'snooze_r3_support.dart';
import 'snooze_r4_support.dart';

/// The day of the scenario; nothing reads the system clock.
final DateTime kStart = DateTime(2026, 10, 7, 6, 0, 0);

void main() {
  snoozeSuiteSetup('openstrap_snooze_r10_test.db');

  late SnoozeBandRig rig;
  late DateTime t0; // T = F

  tearDown(() async => rig.dispose());

  Future<void> open() async {
    rig = await SnoozeBandRig.open(start: kStart);
    t0 = kStart.add(kSec * 30);
    rig.engine.state.alarmEpoch = secOf(t0);
  }

  Future<void> tick() async {
    await rig.app.debugKeepAliveTick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<BuzzDelivery> requestCue() =>
      rig.app.gestureCues.slot(kGestureConfirmKey);

  group('2 a restart inside the window', () {
    test('settings load first, the saved alarm after: the window is open '
        'once both are in', () async {
      final t = kStart.add(kSec * 5); // T = 6:00:05; the app starts at T-5 s
      SharedPreferences.setMockInitialValues({'alarm_epoch': secOf(t)});
      rig = await SnoozeBandRig.open(start: kStart, snooze: null);
      rig.app.debugSnoozeStore = MemorySnoozeStore(settings: snoozeOn());
      await rig.app.debugInit();
      await until(() => rig.app.snoozeSettings.enabled);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.app.snoozeSettings.enabled, isTrue,
          reason: 'precondition: the settings are loaded');
      expect(rig.app.haptics.quietOpen, isTrue,
          reason: 'the window was checked before the saved alarm was known '
              'and not again: plain patterns play across the native alarm');
    });
  });

  group('3 AppState tells the queue when the next window opens', () {
    Future<bool> startsWithin(Duration timeout) async {
      var started = false;
      unawaited_(rig.app.haptics.runJob(1, (token) async {
        started = true;
        await token.write(() async => true);
        return BuzzDelivery.complete;
      }, timeout: timeout));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return started;
    }

    test('a long plain rhythm (60 s) requested 30 s before T is held until '
        'the native stop is handled; a short one is not', () async {
      await open();
      rig.clock.at(t0.subtract(kSec * 30));
      await tick(); // the window is 20 s away: the queue is told
      expect(await startsWithin(const Duration(seconds: 2)), isTrue,
          reason: 'control: a short job is done long before the window');
      await Future<void>.delayed(const Duration(milliseconds: 1800));

      expect(await startsWithin(const Duration(seconds: 60)), isFalse,
          reason: 'a 60 s rhythm started now would be playing at the fire: '
              'its termination could be taken for the alarm\'s');

      rig.clock.at(t0);
      await rig.fire(stamp: t0);
      rig.clock.advance(kSec * 8);
      await rig.terminate(HapticsTermination.expired);
      expect(await until(() => rig.app.haptics.pending == 0), isTrue,
          reason: 'released after the stop, and played');
    });
  });

  group('4 the window is bounded by monotonic time and by the wall clock',
      () {
    late Duration mono;

    /// Opens the window at T-8 s with a cue held in it.
    Future<Future<BuzzDelivery>> heldCue() async {
      await open();
      mono = Duration.zero;
      rig.app.debugMonotonic = () => mono;
      rig.clock.at(t0.subtract(kSec * 8));
      await tick();
      expect(rig.app.haptics.quietOpen, isTrue, reason: 'precondition');
      final cue = requestCue();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hapticWrites(rig), 0, reason: 'precondition: held');
      return cue;
    }

    Future<void> expectReleased(Future<BuzzDelivery> cue) async {
      expect(
          await until(
              () => !rig.app.haptics.quietOpen && hapticWrites(rig) > 0,
              turns: 150),
          isTrue,
          reason: 'the hold outlived its bounds');
      expect(await cue, BuzzDelivery.complete);
    }

    test('the phone clock is set back an hour: the hold ends', () async {
      final cue = await heldCue();
      rig.clock.at(t0.subtract(const Duration(hours: 1)));
      mono += kSec * 5;
      await tick();
      await expectReleased(cue);
    });

    test('the wall clock stands still inside the window while monotonic '
        'time runs past its planned length: the hold ends', () async {
      final cue = await heldCue();
      rig.clock.at(t0.add(kSec * 10)); // inside [T-10 s, T+35 s]
      mono += const Duration(minutes: 3);
      await tick();
      await expectReleased(cue);
    });

    test('control: wall and monotonic time agree and stay inside: still '
        'held', () async {
      final cue = await heldCue();
      rig.clock.at(t0.add(kSec * 10));
      mono += kSec * 18; // 8 s before T to 10 s after
      await tick();
      expect(rig.app.haptics.quietOpen, isTrue);
      expect(hapticWrites(rig), 0);
      rig.clock.at(t0.add(kSec * 36));
      mono += kSec * 26;
      await tick();
      await expectReleased(cue);
    });
  });
}

void unawaited_(Future<void> f) {}
