// AppState wiring of the main-alarm snooze, over the REAL AppState with a fake
// band that throws if anything arms or disables the native alarm. RED: the
// AppState snooze members are stubs that throw.
//
//  * HAPTICS_TERMINATED(100) user_double_tap opens the dismiss window, but only
//    right after the native alarm fired, and never while Natural Wake repeats;
//    expired snoozes; error is log only
//  * band double taps (event 14) are CONSUMED during the window and the
//    re-alarm, and reach the gestures otherwise (the Device lab row is the
//    witness: it is written only for a tap that was not consumed)
//  * the 30 s keep-alive tick drives the snooze (no second timer), with no
//    wake plan armed
//  * the native alarm is never armed, re-armed or disabled for a snooze
//  * source guards for the call sites a unit test cannot drive

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/wake/wake_confirmation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/dart_source_lexical.dart';
import '../support/fake_alarm_engine.dart';
import '../support/wake_fakes.dart' show TestClock;
import 'snooze_fakes.dart';

const _dbName = 'openstrap_snooze_app_state_test.db';
const _min = Duration(minutes: 1);
const _sec = Duration(seconds: 1);

/// A band that records, then refuses, every write that arms or disables the
/// native alarm.
class _NoArmEngine extends FakeAlarmEngine {
  final List<String> armCalls = [];

  @override
  Future<DateTime?> setAlarm(DateTime when,
      {int index = 0, List<int>? haptics}) async {
    armCalls.add('setAlarm');
    throw StateError('a snooze must never arm the native alarm');
  }

  @override
  Future<void> disableAlarm({int? id}) async {
    armCalls.add('disableAlarm');
    throw StateError('a snooze must never disable the native alarm');
  }

  @override
  Future<AlarmSlotWrite> setAlarmSlot(DateTime when, {required int slot}) async {
    armCalls.add('setAlarmSlot');
    throw StateError('a snooze must never arm an alarm slot');
  }

  @override
  Future<bool> clearAlarmSlot({required int slot}) async {
    armCalls.add('clearAlarmSlot');
    throw StateError('a snooze must never clear an alarm slot');
  }
}

Future<void> _wipe() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, _dbName));
}

int _sec_(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
  });
  tearDownAll(_wipe);

  late _NoArmEngine band;
  late AppState app;
  late TestClock clock;
  late MemorySnoozeStore store;
  late List<Play> plays;
  late List<(WakeEvidenceKind, DateTime)> evidence;
  var confirmed = false;

  setUp(() async {
    await _wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    HeadlessSyncGate.resetForTest();
    // Whole seconds: the strap stamps events in whole seconds, and a tap is
    // timed by its own stamp, so a stop stamped mid-second would put the tap
    // that follows it before the stop.
    clock = TestClock(DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000));
    store = MemorySnoozeStore();
    plays = [];
    evidence = [];
    confirmed = false;
    band = _NoArmEngine();
    app = AppState.forTesting(engine: band);
    app.debugBackground = false;
    app.debugWakeClock = clock.call;
    app.debugSnoozeStore = store;
    app.debugSnoozeConfirmedWake = () async => confirmed;
    app.debugSnoozeEvidence = (k, at) async => evidence.add((k, at));
    app.debugSnoozePlay = (slot, {notes, void Function()? onFirstWrite}) async {
      plays.add(Play(slot, notes, clock.now));
      return true;
    };
    // Snooze is OPT-IN (round 3, design A): these tests are about a snooze
    // that is on. The off state is pinned in snooze_r3_stop_test.dart.
    await app.setSnoozeSettings(SnoozeSettings.fromJson({'enabled': true}));
  });
  tearDown(() async => app.dispose());

  List<String> slots() => [for (final x in plays) x.slot];

  /// The native alarm fires and the strap stamps it now.
  Future<void> alarmFires() async {
    app.debugHandleAlarmEvent(57, ts: _sec_(clock.now));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Future<void> terminated(String cause) async {
    await app.debugOnHapticsTerminated(cause, at: clock.now);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  StrapEvent tap() => StrapEvent(
      eventId: 14,
      tsEpoch: _sec_(clock.now),
      receivedAt: clock.now,
      hex: '',
      deviceId: 'd');

  /// Feed a double tap and report whether it reached the gestures (the lab
  /// writes a row for a tap that was not consumed).
  Future<bool> tapReachedGestures() async {
    final before = app.deviceLab.entries.length;
    app.debugOnLiveEvent(tap());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return app.deviceLab.entries.length == before + 1;
  }

  group('the stop', () {
    test('user_double_tap right after the native alarm fired opens the window',
        () async {
      await alarmFires();
      await terminated('user_double_tap');
      expect(app.snooze.consumesDoubleTaps, isTrue);
      expect(plays, isEmpty);
    });

    test('expired snoozes: the snooze confirm plays, state is stored',
        () async {
      await alarmFires();
      await terminated('expired');
      expect(slots(), [kSlotSnoozeConfirm]);
      expect(store.state!.reAlarmAt, clock.now.add(_min * 5));
    });

    test('error is log only', () async {
      await alarmFires();
      await terminated('error');
      expect(plays, isEmpty);
      expect(store.state, isNull);
      expect(app.snooze.consumesDoubleTaps, isFalse);
    });

    test('a termination with no native alarm having fired is not an alarm stop',
        () async {
      await terminated('user_double_tap');
      await terminated('expired');
      expect(plays, isEmpty);
      expect(app.snooze.consumesDoubleTaps, isFalse);
    });

    test('a fired event from long ago (a replayed history event) does not '
        'make a later termination an alarm stop', () async {
      app.debugHandleAlarmEvent(57,
          ts: _sec_(clock.now.subtract(const Duration(hours: 1))));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await terminated('user_double_tap');
      expect(app.snooze.consumesDoubleTaps, isFalse);
      expect(plays, isEmpty);
    });

    test('a native fire takes precedence over a Natural repeat that is still '
        'flagged running: its stop is snoozed (safety round)', () async {
      // The repeat only notices T between awaited deliveries, so its flag can
      // outlive T. Once the NATIVE alarm has fired for this wake, its stop is
      // the snooze's business (it used to be swallowed).
      app.debugNaturalRepeating = () => true;
      await alarmFires();
      await terminated('expired');
      expect(slots(), [kSlotSnoozeConfirm]);
      expect(store.state, isNotNull);
    });

    test('a confirmed wake at the stop: no snooze, no window', () async {
      confirmed = true;
      await alarmFires();
      await terminated('expired');
      await terminated('user_double_tap');
      expect(plays, isEmpty);
      expect(app.snooze.consumesDoubleTaps, isFalse);
    });
  });

  group('double taps', () {
    test('outside a window or re-alarm they reach the gestures (guard)',
        () async {
      expect(await tapReachedGestures(), isTrue);
      await alarmFires();
      await terminated('expired'); // snoozed, not listening
      expect(await tapReachedGestures(), isTrue);
    });

    test('in the dismiss window they are consumed; the n-th dismisses; the '
        'next one is a normal gesture again', () async {
      await alarmFires();
      await terminated('user_double_tap');
      clock.advance(_sec * 1);
      expect(await tapReachedGestures(), isFalse, reason: 'consumed');
      expect(slots(), [kSlotDismissConfirm]);
      expect(evidence.map((e) => e.$1), [WakeEvidenceKind.alarmAcknowledged]);
      expect(app.snooze.consumesDoubleTaps, isFalse);
      clock.advance(_sec * 1);
      expect(await tapReachedGestures(), isTrue, reason: 'normal again');
    });

    test('during the re-alarm they are consumed too, and n of them dismiss',
        () async {
      await alarmFires();
      await terminated('expired');
      clock.advance(_min * 5);
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotSnoozeConfirm, kSlotReAlarm]);
      expect(app.snooze.consumesDoubleTaps, isTrue);
      clock.advance(_sec * 1);
      expect(await tapReachedGestures(), isFalse);
      clock.advance(_sec * 1);
      expect(await tapReachedGestures(), isFalse);
      expect(slots().last, kSlotDismissConfirm);
      expect(store.state, isNull);
      clock.advance(_sec * 1);
      expect(await tapReachedGestures(), isTrue);
    });

    test('while Natural Wake repeats, a double tap BEFORE any native fire is '
        'Natural\'s, never the snooze\'s', () async {
      app.debugNaturalRepeating = () => true;
      expect(await tapReachedGestures(), isFalse,
          reason: 'consumed as Natural\'s dismissal');
      expect(plays, isEmpty, reason: 'and counted as no snooze tap');
      expect(evidence, isEmpty);
    });
  });

  group('the keep-alive tick drives the snooze', () {
    test('re-alarm at +5 min with no wake plan armed, via the haptic play, and '
        'the native alarm is never touched', () async {
      await alarmFires();
      await terminated('expired');
      clock.advance(_min * 5 - _sec * 1);
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotSnoozeConfirm]);
      clock.advance(_sec * 1);
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotSnoozeConfirm, kSlotReAlarm]);
      expect(plays.last.notes, const SnoozeSchedule().reAlarmNotes(1));
      expect(band.armCalls, isEmpty,
          reason: 'no arm, re-arm, slot write or disable for a snooze');
      expect(band.sets, isEmpty);
      expect(band.disables, 0);
    });

    test('a whole chain (stop, window, snooze, re-alarm, snooze, dismiss) '
        'never reaches the native alarm', () async {
      await alarmFires();
      await terminated('user_double_tap');
      clock.advance(_sec * 4);
      await app.debugKeepAliveTick(); // window over: snooze 1
      clock.advance(_min * 5);
      await app.debugKeepAliveTick(); // re-alarm 1
      clock.advance(_sec * 4);
      await app.debugKeepAliveTick(); // fewer: snooze 2
      clock.advance(_min * 5);
      await app.debugKeepAliveTick(); // re-alarm 2
      await app.snooze.imUp();
      expect(slots(), [
        kSlotSnoozeConfirm,
        kSlotReAlarm,
        kSlotSnoozeConfirm,
        kSlotReAlarm,
        kSlotDismissConfirm,
      ]);
      expect(band.armCalls, isEmpty);
    });

    test('a wake confirmed during the snooze cancels it at the next tick',
        () async {
      await alarmFires();
      await terminated('expired');
      clock.advance(_min * 2);
      confirmed = true;
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotSnoozeConfirm, kSlotCancelled]);
      clock.advance(_min * 10);
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotSnoozeConfirm, kSlotCancelled]);
      expect(store.state, isNull);
    });

    test('the pending snooze is there for a new AppState (a restart resumes it)',
        () async {
      await alarmFires();
      await terminated('expired');
      expect(store.state, isNotNull);
      app.dispose();

      app = AppState.forTesting(engine: band);
      app.debugBackground = false;
      app.debugWakeClock = clock.call;
      app.debugSnoozeStore = store;
      app.debugSnoozeConfirmedWake = () async => false;
      app.debugSnoozeEvidence = (k, at) async => evidence.add((k, at));
      app.debugSnoozePlay = (slot, {notes, void Function()? onFirstWrite}) async {
        plays.add(Play(slot, notes, clock.now));
        return true;
      };
      await app.setSnoozeSettings(SnoozeSettings.fromJson({'enabled': true}));
      plays.clear();
      clock.advance(_min * 40); // far past due: still plays
      await app.snooze.resume();
      await app.debugKeepAliveTick();
      expect(slots(), [kSlotReAlarm]);
    });
  });

  group('settings', () {
    test('defaults, then a change is clamped, stored and used', () async {
      expect(app.snoozeSettings, SnoozeSettings.fromJson({'enabled': true}));
      await app.setSnoozeSettings(app.snoozeSettings
          .copyWith(requiredTaps: 9, minutes: 12, windowMs: 6000, cap: 3));
      expect(app.snoozeSettings.requiredTaps, 5);
      expect(store.settings.requiredTaps, 5);
      expect(store.settings.minutes, 12);
      await alarmFires();
      await terminated('expired');
      expect(store.state!.reAlarmAt, clock.now.add(_min * 12));
    });
  });

  group('source guards', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final code = codeOnly(src);

    test('the engine\'s termination hook is wired to the snooze', () {
      expect(code, contains('.onHapticsTerminated ='));
    });

    test('_onLiveEvent consumes a double tap for the snooze BEFORE Natural '
        'Wake\'s own repeat check (a native fire takes precedence)', () {
      final body = codeOnly(bodyOf(src, 'void _onLiveEvent('));
      final natural = body.indexOf('_naturalRepeating()');
      final snooze = body.indexOf('consumesDoubleTaps');
      expect(natural, isNonNegative);
      expect(snooze, isNonNegative);
      expect(snooze, lessThan(natural));
      final helper = codeOnly(bodyOf(src, 'bool _naturalRepeating('));
      expect(helper, contains('debugNaturalRepeating'),
          reason: 'the Natural check reads the same seam the tests use');
      expect(helper, contains('isNaturalRepeating'));
    });

    test('the keep-alive ticks the snooze before anything that can return '
        'early', () {
      final body = codeOnly(bodyOf(src, 'Future<void> _checkSmartWake('));
      final tick = body.indexOf('snooze');
      final firstReturn = body.indexOf('return');
      expect(tick, isNonNegative, reason: 'the snooze is ticked here');
      expect(tick, lessThan(firstReturn));
    });

    test('the snooze\'s haptics go through the shared band queue and never '
        'touch the native alarm', () {
      final body = codeOnly(bodyOf(src, 'Future<bool> _playSnoozeHaptic('));
      expect(body, isNotEmpty, reason: '_playSnoozeHaptic exists');
      expect(body, contains('_dispatchBandAlert'));
      for (final bad in ['setAlarm', 'disableAlarm', 'setAlarmSlot', 'runAlarm']) {
        expect(body, isNot(contains(bad)), reason: bad);
      }
    });

    test('dispose disposes the snooze controller', () {
      final body = codeOnly(bodyOf(src, 'void dispose('));
      expect(body, contains('snooze'));
    });
  });
}
