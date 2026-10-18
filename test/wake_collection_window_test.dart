// The data Natural Wake judges comes from the band's 1 Hz rows, which reach
// the phone through the band's high-frequency prompt window (the live
// 0x28/0x2B/0x33 streams are RAM-only and never reach the stager). So the
// window has to be requested for the WHOLE span the early wake can fire in,
// in every power mode, in the background, and released when it is over.
//
//   * the plan: a habitual or expected wake time earlier than the alarm used
//     to end the band's prompt before the Natural window did;
//   * the app: the window is requested when the span opens, re-requested after
//     a dropped link, kept alive by the keep-alive tick, and released once the
//     early wake fired or was acknowledged;
//   * Maximum battery, backgrounded, unplugged, power saver on: no difference.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/fake_power_source.dart';
import 'support/wake_fakes.dart';

Map<String, dynamic> _row(DateTime w) =>
    {'window_json': '{"value":{"offset_ms":${w.millisecondsSinceEpoch}}}'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the plan covers the whole Natural window', () {
    final alarm = DateTime(2026, 10, 6, 7, 30);
    final habitual = [
      _row(DateTime(2026, 10, 5, 6, 0)),
      _row(DateTime(2026, 10, 4, 6, 0)),
      _row(DateTime(2026, 10, 3, 6, 0)),
    ];

    test('a habitual wake time before the alarm no longer ends the prompt '
        'before the window does', () {
      // 05:30: the habitual window (04:00-06:00 here) is running AND so is the
      // alarm's (lead 150 min for a 120 min window: from 05:00).
      final now = DateTime(2026, 10, 6, 5, 30);
      final plan = HighFreqWakeWindow.planFromRows(habitual, now,
          scheduledWindowEnd: alarm, scheduledWindowMinutes: 120);
      expect(plan.shouldEnable, isTrue);
      expect(plan.targetWake, alarm);
      expect(plan.source, 'scheduled_alarm');
    });

    test('an expected sleep schedule ending before the alarm: same', () {
      const expected = ExpectedSleepSchedule(
          onsetMinute: 22 * 60 + 30, wakeMinute: 6 * 60);
      final now = DateTime(2026, 10, 6, 5, 30);
      final plan = HighFreqWakeWindow.planFromRows(const [], now,
          scheduledWindowEnd: alarm,
          scheduledWindowMinutes: 120,
          expectedSchedule: expected);
      expect(plan.shouldEnable, isTrue);
      expect(plan.targetWake, alarm);
    });

    test('a habitual window that already covers the alarm stays the source',
        () {
      final late = [
        _row(DateTime(2026, 10, 5, 8, 0)),
        _row(DateTime(2026, 10, 4, 8, 0)),
        _row(DateTime(2026, 10, 3, 8, 0)),
      ];
      final now = DateTime(2026, 10, 6, 6, 45);
      final plan = HighFreqWakeWindow.planFromRows(late, now,
          scheduledWindowEnd: alarm, scheduledWindowMinutes: 60);
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'habitual_wake');
      expect(plan.targetWake, DateTime(2026, 10, 6, 8, 0));
    });

    test('before the span opens and at/after the alarm: off', () {
      HighFreqWakePlan at(DateTime now) => HighFreqWakeWindow.planFromRows(
          habitual, now,
          scheduledWindowEnd: alarm, scheduledWindowMinutes: 60);
      expect(at(alarm.subtract(naturalCollectionLead(60) + const Duration(hours: 5)))
              .shouldEnable,
          isFalse);
      expect(at(alarm.add(const Duration(minutes: 1))).shouldEnable, isFalse);
    });
  });

  group('the app requests, keeps and releases the window', () {
    late FakeAlarmEngine band;
    late AppState app;
    late FakePowerSource power;
    late DateTime wakeAt;
    late List<AlarmScheduleEntry> week;

    // Each test gets its own wake minute: the wake run state (fired,
    // acknowledged) persists per wake epoch in the shared database, so two
    // tests in the same minute would otherwise inherit each other's fire.
    var testNo = 0;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_wake_collection_window_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    /// Inside the Natural window (alarm in 20 min, window 60), Maximum battery,
    /// backgrounded, unplugged, power saver on.
    setUp(() async {
      await (await SharedPreferences.getInstance()).clear();
      await LocalDb.clearAlarmSchedule();
      band = FakeAlarmEngine();
      band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
      power = FakePowerSource(charging: false, powerSaver: true);
      app.debugPowerSource = power;
      await app.setCalcPowerMode(CalcPowerMode.maxBattery);
      await app.debugAttachPower();
      app.debugBackground = true;

      final t = DateTime.now().add(Duration(minutes: 20 + testNo++));
      wakeAt = DateTime(t.year, t.month, t.day, t.hour, t.minute);
      week = [
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(
              weekday: w,
              hour: wakeAt.hour,
              minute: wakeAt.minute,
              enabled: true,
              smartWindowMinutes: 60,
              naturalWindowMinutes: 60),
      ];
      await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
      await app.debugLoadAlarmSchedule();
      await app.debugArmNextAlarmOccurrence();
      expect(app.wake.naturalEnabled, isTrue);
      expect(band.sets, hasLength(1));
    });

    tearDown(() async {
      app.dispose();
      await power.close();
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    bool requested() => band.offloadSnapshot['high_freq_requested'] == true;

    test('the span is open: the window is requested for the alarm', () async {
      expect(requested(), isFalse);
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);
      expect(band.highFreqReason, 'scheduled_alarm');
      expect(band.highFreqUntil!.millisecondsSinceEpoch ~/ 1000,
          wakeAt.millisecondsSinceEpoch ~/ 1000);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue,
          reason: 'Maximum battery was in force the whole time');
    });

    test('a dropped link is re-requested on the next link inside the span',
        () async {
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);
      await band.debugDropLink();
      expect(requested(), isFalse, reason: 'the prompt died with the link');
      // Reconnect: a new link, then the connect flow's refresh.
      band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
      band.state.connection = 'connected';
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);
      expect(band.highFreqReason, 'scheduled_alarm');
    });

    test('the keep-alive tick restores a prompt that is not running', () async {
      expect(requested(), isFalse);
      await app.debugKeepAliveTick();
      await until(requested);
      expect(requested(), isTrue);
    });

    test('the tick leaves a running window alone (no rewrite per tick)',
        () async {
      await app.debugRefreshHighFreqWakeWindow();
      final until0 = band.highFreqUntil;
      await app.debugKeepAliveTick();
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(band.highFreqUntil, until0);
    });

    test('outside the span the window is not requested', () async {
      // Alarm tomorrow: replace the schedule with a far-away occurrence.
      final far = DateTime.now().add(const Duration(hours: 10));
      week = [
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(
              weekday: w,
              hour: far.hour,
              minute: far.minute,
              enabled: true,
              smartWindowMinutes: 60,
              naturalWindowMinutes: 60),
      ];
      await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
      await app.debugLoadAlarmSchedule();
      await app.debugArmNextAlarmOccurrence();
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isFalse);
    });

    test('the early wake fires: the window is released, and the alarm at T '
        'stays armed', () async {
      // Awake in the window, with the data in place.
      app.sleepOperations.schedule = ExpectedSleepSchedule(
          onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
          wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
      (app.debugWakeObserver as ScriptedObserver).next = stageObs('wake');
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);

      await app.debugKeepAliveTick();
      await until(() => !requested());
      expect(requested(), isFalse, reason: 'released once the wake fired');
      expect(app.alarmEpoch, wakeAt.millisecondsSinceEpoch ~/ 1000,
          reason: 'the native alarm at T is untouched');
      // And it stays released: another refresh does not bring it back.
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isFalse);
    });

    group('the user in the app with the band moving (light sleep per the '
        'stager)', () {
      Future<void> seedAccel({required bool moving}) async {
        final db = await LocalDb.instance;
        await db.delete('decoded_onehz');
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final b = db.batch();
        for (var ts = now - 60; ts <= now; ts++) {
          b.insert('decoded_onehz', {
            'device_id': '',
            'ts_ms': ts * 1000,
            'rec_ts': ts,
            'counter': ts,
            'hr': 62,
            'ax': moving && ts.isEven ? 0.3 : 0.0,
            'ay': 0.0,
            'az': 1.0,
            'device_family': 'gen4',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await b.commit(noResult: true);
      }

      setUp(() {
        app.sleepOperations.schedule = ExpectedSleepSchedule(
            onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
            wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
        app.debugBackground = false; // the app is in the foreground
      });

      test('a touch plus movement wakes early and releases the window',
          () async {
        await seedAccel(moving: true);
        app.debugNoteInteraction(
            DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugRefreshHighFreqWakeWindow();
        expect(requested(), isTrue);
        await app.debugKeepAliveTick();
        await until(() => !requested());
        expect(requested(), isFalse);
        expect(app.alarmEpoch, wakeAt.millisecondsSinceEpoch ~/ 1000);
      });

      test('a touch with a still wrist does not', () async {
        await seedAccel(moving: false);
        app.debugNoteInteraction(
            DateTime.now().subtract(const Duration(seconds: 15)));
        await app.debugRefreshHighFreqWakeWindow();
        await app.debugKeepAliveTick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(requested(), isTrue);
      });

      test('movement with no touch (the stager says light sleep) does not',
          () async {
        await seedAccel(moving: true);
        await app.debugRefreshHighFreqWakeWindow();
        await app.debugKeepAliveTick();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(requested(), isTrue);
      });

      test('a backgrounded or locked app records no touch at all', () {
        app.debugBackground = true;
        app.noteForegroundActivity();
        expect(app.debugInteractions, isEmpty);
        app.debugBackground = false;
        app.noteForegroundActivity();
        app.noteForegroundActivity(); // thinned: one per 10 s
        expect(app.debugInteractions, hasLength(1));
      });
    });

    test('no data and no fire: the window keeps running to T', () async {
      app.sleepOperations.schedule = ExpectedSleepSchedule(
          onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
          wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
      (app.debugWakeObserver as ScriptedObserver).next = absentObs('noEvidence');
      await app.debugRefreshHighFreqWakeWindow();
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requested(), isTrue);
      expect(app.alarmEpoch, wakeAt.millisecondsSinceEpoch ~/ 1000);
    });
  });
}
