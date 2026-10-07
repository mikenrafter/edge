// Safety round on the snooze over a REAL AppState, engine, haptics queue, wake
// store and snooze store (Sol's review, 2026-10-07; findings 1 to 9). RED.
//
// Nothing is replaced: see snooze_band_rig.dart. Events are real frames on the
// engine's own path with the strap's own stamps; the band answers every haptic
// write with its own HAPTICS_TERMINATED `expired`, which is how our own
// playback ends on a real band.
//
//  controls  the rig is real: an expired stop snoozes, two taps dismiss (these
//            pass today and must keep passing)
//  F1  restart during the dismiss window (real wake_meta)
//  F2  taps: the event's own stamp, live only, one count per event
//  F3  a termination is correlated with the native fire by band stamps
//  F4  a native fire ends Natural's claim on the stop
//  F5  a confirmation counts only for THIS alarm's sleep (real stores)
//  F6  a capable band's unknown cause is an expiry
//  F7  a pending snooze holds a band-prompt lease and a phone backstop
//  F8  only the native alarm's stop counts, once
//  F9  budget-held re-alarm followed by taps and a dropped link
//
// Where a scenario needs a clock the band and the app share, both read the
// rig's TestClock; "received" is the engine's clock, "stamped" is the strap's.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_controller.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'snooze_band_rig.dart';

const _dbName = 'openstrap_snooze_safety_app_state_test.db';
const _min = Duration(minutes: 1);
const _sec = Duration(seconds: 1);

Future<void> _wipe() async {
  await LocalDb.close();
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, _dbName));
}

Future<SnoozeState?> _stored() => const DbSnoozeStore().loadState();

String _window(DateTime onset, DateTime? offset) => jsonEncode({
      'value': {
        'onset_ms': onset.millisecondsSinceEpoch,
        if (offset != null) 'offset_ms': offset.millisecondsSinceEpoch,
      },
    });

/// Last night's block (onset 23:00, up 07:15) and a confirmed wake at [at].
Future<void> _lastNightConfirmedAt(DateTime at, {DateTime? upAt}) async {
  final offset = upAt ?? DateTime(2026, 10, 7, 7, 15);
  final onset = upAt == null
      ? DateTime(2026, 10, 6, 23, 0)
      : upAt.subtract(const Duration(hours: 8, minutes: 15));
  await LocalDb.putDayResult(
    dayId: dayLabelOf(offset),
    algoVersion: 1,
    payloadJson: '{}',
    windowJson: _window(onset, offset),
  );
  await LocalDb.putWakeConfirmation(
    dayId: dayLabelOf(offset),
    atSec: secOf(at),
    basis: 'app_opened',
  );
}

/// The phone notifications the app scheduled and cancelled, read off the
/// platform channel (the plugin has no other seam). Android is the platform so
/// the plugin takes the zonedSchedule path.
class _Notifications {
  final scheduled = <({int id, DateTime at})>[];
  final cancelled = <int>[];
  final order = <String>[];

  void install() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));
    NotificationService.instance.debugProbePermission = () async => true;
    NotificationService.instance.debugRequestPermission = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            (call) async {
      final a = call.arguments;
      if (call.method == 'zonedSchedule' && a is Map) {
        final at = DateTime.parse(a['scheduledDateTimeISO8601'] as String);
        scheduled.add((id: a['id'] as int, at: at));
        order.add('schedule:${a['id']}');
      } else if (call.method == 'cancel' && a is Map) {
        cancelled.add(a['id'] as int);
        order.add('cancel:${a['id']}');
      }
      return null;
    });
  }

  void uninstall() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService.instance.debugProbePermission = null;
    NotificationService.instance.debugRequestPermission = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            null);
  }

  /// The id scheduled for within 2 s of [due], or null.
  int? idFor(DateTime due) {
    for (final s in scheduled.reversed) {
      if (s.at.difference(due).abs() <= _sec * 2) return s.id;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
    await _wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    await SnoozeBandRig.measure();
  });
  setUp(() async {
    await _wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    HeadlessSyncGate.resetForTest();
  });
  tearDownAll(_wipe);

  late SnoozeBandRig rig;
  late DateTime t0; // when the native alarm fires

  Future<void> open({
    DateTime? start,
    String generation = 'gen5',
    int autoEndLimit = 60,
    AutoEnd autoEnd = AutoEnd.queueOnly,
  }) async {
    rig = await SnoozeBandRig.open(
        start: start,
        generation: generation,
        autoEnd: autoEnd,
        autoEndLimit: autoEndLimit);
    t0 = rig.clock.now;
  }

  tearDown(() async => rig.dispose());

  /// The native alarm fires at [t0] and the wearer stops it [after] later.
  Future<void> fireAndStop(int code, {Duration after = const Duration(seconds: 8)}) async {
    await rig.fire(stamp: t0);
    rig.clock.advance(after);
    await rig.terminate(code);
  }

  group('controls: the rig is the real thing', () {
    test('an expired stop snoozes: the snooze confirm reaches the band and '
        'the snooze is stored', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
      final st = await _stored();
      expect(st, isNotNull);
      expect(rig.app.snooze.status.value.phase, SnoozePhase.snoozed);
      expect(rig.engine.armCalls, isEmpty);
    });

    test('a double-tap stop plus one more live tap dismisses', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue);
      rig.clock.advance(_sec * 1);
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });
  });

  group('F1 restart during the native dismiss window (real wake_meta)', () {
    test('inside the window: the restarted app restores it, and one more tap '
        'dismisses', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue);
      final clock = rig.clock;
      await rig.dispose(); // the process dies; the native alarm is stopped

      clock.advance(_sec * 1);
      rig = await SnoozeBandRig.open(clock: clock);
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'the window was lost: no re-alarm will ever follow');
      clock.advance(_sec * 1);
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('after the window: fewer than n taps snoozes from the original stop; '
        'already due, the re-alarm plays at once', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      final stopAt = rig.clock.now;
      final clock = rig.clock;
      await rig.dispose();

      clock.advance(_min * 6);
      rig = await SnoozeBandRig.open(clock: clock);
      await rig.app.snooze.resume();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1),
          reason: 'the snooze (stop + 5 min) came due while the app was dead');
      expect((await _stored())?.reAlarmAt, stopAt.add(_min * 5));
    });
  });

  group('F2 taps: the event\'s own stamp, live only, one count per event', () {
    test('a replayed historical tap one second after the stop is not the '
        'second tap', () async {
      await open();
      await fireAndStop(HapticsTermination.userDoubleTap);
      rig.clock.advance(_sec * 1);
      await rig.tap(stamp: t0.subtract(const Duration(hours: 1)));
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'an hour-old tap replayed from flash dismissed the alarm');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window);

      rig.clock.advance(_sec * 1);
      await rig.tap(); // the wearer's own, live
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });

    test('a live tap stamped before the stop never counts', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(_sec * 10);
      await rig.terminate(HapticsTermination.userDoubleTap);
      final stopAt = rig.clock.now;
      rig.clock.advance(_sec * 1);
      await rig.tap(stamp: stopAt.subtract(_sec * 2)); // delivered late
      expect(rig.count(Played.dismissConfirm), 0,
          reason: 'it happened before the alarm stopped');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.window);
    });

    test('one tap delivered twice counts once during a re-alarm', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      rig.clock.advance(_min * 5);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.app.snooze.consumesDoubleTaps, isTrue,
          reason: 'precondition: the re-alarm is playing and listening');
      final before = rig.count(Played.dismissConfirm);

      rig.clock.advance(_sec * 1);
      await rig.tap();
      await rig.tap(resend: true); // the same event again
      expect(rig.count(Played.dismissConfirm), before,
          reason: 'default n is 2: one event is one tap');

      rig.clock.advance(_sec * 1);
      await rig.tap(); // a different tap
      expect(rig.count(Played.dismissConfirm), before + 1);
    });

    test('two different live taps do dismiss a re-alarm (control)', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      rig.clock.advance(_min * 5);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      rig.clock.advance(_sec * 1);
      await rig.tap();
      rig.clock.advance(_sec * 1);
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1));
    });
  });

  group('F3 a termination is correlated with the fire by band stamps', () {
    test('fire and stop reported minutes later (a disconnect over 5 min): the '
        'snooze starts from the stop\'s own time and, already due, re-alarms '
        'now', () async {
      await open();
      rig.clock.advance(_min * 6); // the link was down
      await rig.fire(stamp: t0);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(_sec * 30));
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1));
      expect((await _stored())?.reAlarmAt, t0.add(_sec * 30 + _min * 5));
    });

    test('a stop received 3 min late is due 5 min after the STOP, not after '
        'receipt', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(_min * 3);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.add(_sec * 20));
      expect((await _stored())?.reAlarmAt, t0.add(_sec * 20 + _min * 5));
    });

    test('a termination stamped 20 minutes after the fire is not that '
        'alarm\'s stop (control)', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(_min * 20);
      await rig.terminate(HapticsTermination.expired, stamp: rig.clock.now);
      expect(await _stored(), isNull);
      expect(rig.deliveries, isEmpty);
    });

    test('a termination stamped an hour BEFORE the fire (a replay burst after '
        'reconnect) is not its stop', () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(_sec * 1);
      await rig.terminate(HapticsTermination.expired,
          stamp: t0.subtract(const Duration(hours: 1)));
      expect(await _stored(), isNull,
          reason: 'receipt time said "just after the fire"; the strap said '
              'otherwise');
      expect(rig.deliveries, isEmpty);
    });
  });

  group('F4 a native fire beats a Natural repeat that is still running', () {
    test('the repeat flag still true past T: the expired stop snoozes',
        () async {
      await open();
      rig.app.debugNaturalRepeating = () => true; // a held delivery
      await fireAndStop(HapticsTermination.expired);
      expect(await _stored(), isNotNull);
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('...and a double-tap stop opens the dismiss window whose taps are '
        'the snooze\'s, not Natural\'s', () async {
      await open();
      rig.app.debugNaturalRepeating = () => true;
      await fireAndStop(HapticsTermination.userDoubleTap);
      expect(rig.app.snooze.consumesDoubleTaps, isTrue);
      rig.clock.advance(_sec * 1);
      await rig.tap();
      expect(rig.count(Played.dismissConfirm), greaterThanOrEqualTo(1),
          reason: 'the tap was swallowed as Natural\'s dismissal');
    });
  });

  group('F5 a confirmation counts only for THIS alarm\'s sleep (real stores)',
      () {
    test('last morning\'s confirmed wake does not cancel a later alarm\'s '
        'snooze', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      // Up at 07:10, back to bed, a new block not derived yet; this alarm
      // fires at 10:30.
      await _lastNightConfirmedAt(DateTime(2026, 10, 7, 7, 10));
      await fireAndStop(HapticsTermination.expired);
      expect(await _stored(), isNotNull,
          reason: 'a stale confirmation suppressed the snooze');
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('a confirmation 31 minutes before the fire is not this alarm\'s',
        () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await _lastNightConfirmedAt(t0.subtract(_min * 31));
      await fireAndStop(HapticsTermination.expired);
      expect(await _stored(), isNotNull);
    });

    // Round 3 (partial 5): the 30-minute lookback was a stand-in for "the same
    // sleep block". A confirmation counts only at or after the fire (60 s
    // slack for clock skew); anything earlier is another block's, and failing
    // toward waking is fine. Pinned in full by snooze_r3_stop_test.dart (J).
    test('a confirmation 29 minutes before the fire is not this alarm\'s '
        '(round 3: the lookback is 60 s)', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await _lastNightConfirmedAt(t0.subtract(_min * 29));
      await fireAndStop(HapticsTermination.expired);
      expect(await _stored(), isNotNull);
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('a wake confirmed right after the fire cancels the snooze '
        '(control)', () async {
      await open(start: DateTime(2026, 10, 7, 10, 30));
      await _lastNightConfirmedAt(t0.add(_sec * 5));
      await fireAndStop(HapticsTermination.expired);
      expect(await _stored(), isNull);
      expect(rig.deliveries, isEmpty);
    });
  });

  group('F6 a capable band\'s unknown cause is an expiry', () {
    test('an undecoded cause code on a gen5 band snoozes', () async {
      await open();
      await fireAndStop(9); // 'code_9'
      expect(await _stored(), isNotNull,
          reason: 'unknown mapped to error: no snooze, no re-alarm, silence');
      expect(rig.count(Played.snoozeConfirm), greaterThanOrEqualTo(1));
    });

    test('a termination with no cause bytes on a gen5 band snoozes',
        () async {
      await open();
      await rig.fire(stamp: t0);
      rig.clock.advance(_sec * 8);
      await rig.terminate(0, noBody: true);
      expect(await _stored(), isNotNull);
    });
  });

  group('F7 a pending snooze survives a suspended phone', () {
    test('a band-prompt lease starts with the snooze, no longer than its '
        'length between prompts', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final due = (await _stored())!.reAlarmAt;
      final leases = rig.engine.prompts.where((c) => c.enabled).toList();
      expect(leases, isNotEmpty,
          reason: 'nothing would wake a suspended iOS app before the next '
              '900 s prompt');
      final l = leases.last;
      expect(l.intervalSeconds, inInclusiveRange(61, 300),
          reason: 'gen5 refuses 60 s or less; the default snooze is 300 s');
      expect(l.until!.isBefore(due), isFalse, reason: 'it covers the snooze');
    });

    test('the lease is kept when the app is backgrounded and the prompt is '
        're-planned', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      rig.app.debugBackground = true;
      await rig.app.debugRefreshHighFreqWakeWindow();
      final last = rig.engine.prompts.last;
      expect(last.enabled, isTrue,
          reason: 'the re-plan switched the prompt off under a pending snooze');
      expect(last.intervalSeconds, lessThanOrEqualTo(300));
    });

    test('the lease is released when the snooze ends', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      expect(rig.engine.prompts.where((c) => c.enabled), isNotEmpty,
          reason: 'precondition: a lease was taken');
      await rig.app.snooze.imUp();
      await rig.settle();
      expect(rig.engine.prompts.last.enabled, isFalse);
    });

    group('the phone backstop at the due time', () {
      late _Notifications n;
      setUp(() {
        n = _Notifications()..install();
      });
      tearDown(() => n.uninstall());

      test('(control) the spy sees a scheduled notification and its cancel',
          () async {
        final at = DateTime.now().add(_min * 5);
        await NotificationService.instance.scheduleOnce(
            id: NotificationService.idStillness,
            category: NotifCategory.reminders,
            title: 't',
            body: 'b',
            at: at);
        await NotificationService.instance.cancel(NotificationService.idStillness);
        expect(n.idFor(at), NotificationService.idStillness);
        expect(n.cancelled, [NotificationService.idStillness]);
      });

      test('is scheduled for the due time', () async {
        await open();
        await fireAndStop(HapticsTermination.expired);
        await rig.settle();
        final due = (await _stored())!.reAlarmAt;
        expect(n.idFor(due), isNotNull,
            reason: 'scheduled: ${n.scheduled}. A suspended app cannot run '
                'a Dart timer; the OS can post a notification');
      });

      test('is cancelled when the wearer dismisses', () async {
        await open();
        await fireAndStop(HapticsTermination.expired);
        await rig.settle();
        final id = n.idFor((await _stored())!.reAlarmAt);
        expect(id, isNotNull, reason: 'precondition: it was scheduled');
        await rig.app.snooze.imUp();
        await rig.settle();
        expect(n.cancelled, contains(id));
        expect(n.order.lastIndexOf('cancel:$id'),
            greaterThan(n.order.lastIndexOf('schedule:$id')));
      });

      test('is cancelled when a wake is confirmed during the snooze',
          () async {
        // On the real clock: the OS refuses to schedule a time in the past.
        await open();
        await fireAndStop(HapticsTermination.expired);
        await rig.settle();
        final id = n.idFor((await _stored())!.reAlarmAt);
        expect(id, isNotNull, reason: 'precondition: it was scheduled');
        // The app is opened and the band moves: a double confirmation of the
        // sleep this alarm woke (up at 3 h ago in the block just derived).
        await _lastNightConfirmedAt(rig.clock.now.add(_min * 1),
            upAt: rig.clock.now.subtract(const Duration(hours: 3)));
        rig.clock.advance(_min * 2);
        await rig.app.debugKeepAliveTick();
        await rig.settle();
        expect(rig.app.snooze.status.value.phase, SnoozePhase.idle,
            reason: 'precondition: the snooze was cancelled');
        expect(n.cancelled, contains(id));
      });
    });
  });

  group('F8 only the native alarm\'s stop counts, once', () {
    test('the snooze confirm\'s own end is not another stop: one confirm, '
        'one stable snooze', () async {
      await open(autoEnd: AutoEnd.real);
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      expect(rig.count(Played.snoozeConfirm), 1,
          reason: 'our own playback ended with a termination (expired) and '
              'was taken for the wearer stopping the alarm again');
      final st = await _stored();
      expect(st?.count, 1);
    });

    test('dismissing is not followed by a snooze: the dismiss confirm\'s own '
        'end is not a stop', () async {
      await open(autoEnd: AutoEnd.real);
      await fireAndStop(HapticsTermination.userDoubleTap);
      rig.clock.advance(_sec * 1);
      await rig.tap();
      await rig.settle();
      expect(rig.count(Played.dismissConfirm), 1);
      expect(rig.count(Played.snoozeConfirm), 0,
          reason: 'the wearer dismissed; a snooze started anyway');
      expect(await _stored(), isNull);
      expect(rig.app.snooze.status.value.phase, SnoozePhase.idle);
    });

    test('a second termination for the same fire does not move a pending '
        'snooze', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final first = await _stored();
      final confirms = rig.count(Played.snoozeConfirm);
      expect(first, isNotNull);

      rig.clock.advance(_sec * 40);
      await rig.terminate(HapticsTermination.expired); // same fire, again
      expect(await _stored(), first,
          reason: 'count and deadline are the first stop\'s');
      expect(rig.count(Played.snoozeConfirm), confirms);
    });

    test('the re-alarm\'s own end (snooze of 1 minute, inside the old 5 min '
        'gate) does not restart the snooze', () async {
      await open();
      await rig.app.setSnoozeSettings(
          SnoozeSettings.fromJson({'enabled': true, 'minutes': 1}));
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      final before = rig.deliveries.length;
      rig.clock.advance(_min * 1);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.deliveries.skip(before), contains(Played.reAlarm),
          reason: 'precondition');
      // The band reports the re-alarm finished (a real termination event).
      await rig.terminate(HapticsTermination.expired);
      final after = rig.deliveries.skip(before).toList();
      expect(after, isNot(contains(Played.snoozeConfirm)),
          reason: 'the re-alarm ended and was taken for a new stop');
      expect(rig.app.snooze.status.value.phase, SnoozePhase.reAlarming);
    });
  });

  group('the 30-in-2-minutes precaution holds the cues, never the re-alarm',
      () {
    // Round 3 (new 6): only the RE-ALARM is budget-exempt. The confirm,
    // dismiss and cancel cues use the normal queue (the wearer is awake or the
    // snooze is already set), so with the window exhausted they wait for room.
    test('with the command budget exhausted the snooze confirm waits, and the '
        'due re-alarm still plays at once', () async {
      await open();
      // The window is full of other haptics.
      rig.app.haptics.ledger.record(60, DateTime.now());
      expect(rig.app.haptics.commandsLeft, 0);
      await rig.fire(stamp: t0);
      rig.clock.advance(const Duration(seconds: 8));
      await rig.terminate(HapticsTermination.expired, quick: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await _stored())?.count, 1, reason: 'the snooze is set');
      expect(rig.count(Played.snoozeConfirm), 0,
          reason: 'a confirm is a plain job: it waits for room like any '
              'other cue');
      rig.clock.advance(_min * 5);
      await rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.count(Played.reAlarm), 1,
          reason: 'a due re-alarm waits for no budget');
      expect(rig.app.haptics.commandsLeft, 0);
    });
  });

  group('F9 a re-alarm held by the band queue, then taps, then a dropped '
      'link', () {
    test('taps heard while the delivery waits never dismiss; the failed '
        'delivery leaves the snooze pending and it is retried', () async {
      await open();
      await fireAndStop(HapticsTermination.expired);
      await rig.settle();
      expect((await _stored())?.count, 1);

      // The Device lab holds the band; the re-alarm queues behind it.
      final hold = Completer<void>();
      unawaited(rig.app.haptics.runExclusive(() => hold.future));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rig.clock.advance(_min * 5);
      final tick = rig.app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      rig.clock.advance(_sec * 1);
      await rig.tap(quick: true);
      rig.clock.advance(_sec * 1);
      await rig.tap(quick: true);
      expect(rig.count(Played.dismissConfirm), 0);
      expect(rig.app.snooze.status.value.phase, isNot(SnoozePhase.idle),
          reason: 'two taps on a buzz nobody felt dismissed the alarm');

      rig.failWrites = true; // the link drops under the queued job
      hold.complete();
      await tick.timeout(const Duration(seconds: 20), onTimeout: () {});
      await rig.settle();
      expect((await _stored())?.count, 1, reason: 'still pending');
      expect(rig.count(Played.dismissConfirm), 0);

      rig.failWrites = false; // reconnected
      rig.clock.advance(_sec * 30);
      await rig.app.debugKeepAliveTick();
      await rig.settle();
      expect(rig.count(Played.reAlarm), greaterThanOrEqualTo(1),
          reason: 'retried once the band took it');
    });
  });
}
