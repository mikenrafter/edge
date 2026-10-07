// The owner's rule for Natural Wake, from a real device log (Oct 5-6):
//
//   The window before Natural Wake must run the calculation AND collect more
//   frequent band data, whatever the power mode, in the background or locked.
//   A saved expected sleep schedule must never turn the wake-window collection
//   off. With no saved schedule, the night's DETECTED sleep onset decides main
//   sleep vs nap; with no onset either it stays unknown, never guessed.
//
// What the log showed. Every one of the 124 `smartWake=false
// (source=expected_sleep_schedule)` lines was outside both Natural windows, so
// that label alone was not the fault. Two holes behind it were real:
//   * saving a schedule REPLACED the history-derived habitual window instead of
//     adding to it;
//   * the Natural window was only planned while this process tracked an armed
//     epoch, and that epoch is cleared by a fire (whose event is routinely
//     missed), a replayed event or a restart, and is absent after a launch.
// And `sleepOnset` was never passed to the planner, so with no schedule the
// answer was always `unknown`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart' show dayLabelOf;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';
import 'package:openstrap_edge/wake/sleep_onset.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/wake_fakes.dart';

Map<String, dynamic> _row(DateTime w) =>
    {'window_json': '{"value":{"offset_ms":${w.millisecondsSinceEpoch}}}'};

String _window(DateTime onset, DateTime? offset) => jsonEncode({
      'value': {
        'onset_ms': onset.millisecondsSinceEpoch,
        if (offset != null) 'offset_ms': offset.millisecondsSinceEpoch,
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a saved schedule adds a collection window, it never removes one', () {
    final habit = [
      _row(DateTime(2026, 10, 5, 11, 0)),
      _row(DateTime(2026, 10, 4, 11, 0)),
      _row(DateTime(2026, 10, 3, 11, 0)),
    ];
    // Wakes at 14:00: its own window is 12:30-14:00.
    const schedule =
        ExpectedSleepSchedule(onsetMinute: 6 * 60, wakeMinute: 14 * 60);

    test('the measured habit window keeps collecting with a schedule saved',
        () {
      final now = DateTime(2026, 10, 6, 10, 0); // habit 09:30-11:00, schedule off
      final withSchedule = HighFreqWakeWindow.planFromRows(habit, now,
          expectedSchedule: schedule);
      final without = HighFreqWakeWindow.planFromRows(habit, now);
      expect(without.shouldEnable, isTrue);
      expect(withSchedule.shouldEnable, isTrue,
          reason: 'saving a schedule must not switch the habit window off');
      expect(withSchedule.source, 'habitual_wake');
      expect(withSchedule.targetWake, DateTime(2026, 10, 6, 11, 0));
    });

    test('the schedule window still collects when the habit window is not open',
        () {
      final now = DateTime(2026, 10, 6, 13, 0);
      final plan = HighFreqWakeWindow.planFromRows(habit, now,
          expectedSchedule: schedule);
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'expected_sleep_schedule');
      expect(plan.targetWake, DateTime(2026, 10, 6, 14, 0));
    });

    test('both open: the one ending later, so its lease covers more', () {
      const late =
          ExpectedSleepSchedule(onsetMinute: 6 * 60, wakeMinute: 11 * 60 + 30);
      final now = DateTime(2026, 10, 6, 10, 30); // habit to 11:00, schedule to 11:30
      final plan =
          HighFreqWakeWindow.planFromRows(habit, now, expectedSchedule: late);
      expect(plan.shouldEnable, isTrue);
      expect(plan.targetWake, DateTime(2026, 10, 6, 11, 30));
    });

    test('with neither open the schedule is the reported plan, as before', () {
      final plan = HighFreqWakeWindow.planFromRows(
          habit, DateTime(2026, 10, 6, 3, 0),
          expectedSchedule: schedule);
      expect(plan.shouldEnable, isFalse);
      expect(plan.source, 'expected_sleep_schedule');
    });
  });

  group('plannedCollectionWindow: the schedule, not the tracked epoch', () {
    final now = DateTime(2026, 10, 6, 12, 0); // a Tuesday
    List<AlarmScheduleEntry> week({int natural = 60, int smart = 0}) => [
          for (var w = 0; w < 7; w++)
            AlarmScheduleEntry(
                weekday: w,
                hour: 14,
                minute: 0,
                enabled: true,
                naturalWindowMinutes: natural,
                smartWindowMinutes: smart),
        ];

    test('no epoch tracked: the next occurrence supplies the window', () {
      final w = plannedCollectionWindow(
          epoch: null,
          schedule: week(),
          upgrade: WakeUpgradeState.none,
          now: now);
      expect(w, isNotNull);
      expect(w!.windowEnd, DateTime(2026, 10, 6, 14, 0));
      expect(w.minutes, 60);
    });

    test('a past epoch (the alarm fired, the event was missed) is not a window',
        () {
      final past = DateTime(2026, 10, 6, 11, 0).millisecondsSinceEpoch ~/ 1000;
      final w = plannedCollectionWindow(
          epoch: past,
          schedule: week(),
          upgrade: WakeUpgradeState.none,
          now: now);
      expect(w!.windowEnd, DateTime(2026, 10, 6, 14, 0));
    });

    test('a future epoch is what the band holds, and wins', () {
      final armed = DateTime(2026, 10, 6, 13, 0).millisecondsSinceEpoch ~/ 1000;
      final w = plannedCollectionWindow(
          epoch: armed,
          schedule: week(),
          upgrade: WakeUpgradeState.none,
          now: now);
      expect(w!.windowEnd, DateTime(2026, 10, 6, 13, 0));
    });

    test('an acknowledged occurrence is not planned again', () {
      final acked = DateTime(2026, 10, 6, 14, 0).millisecondsSinceEpoch ~/ 1000;
      final w = plannedCollectionWindow(
          epoch: null,
          schedule: week(),
          upgrade: WakeUpgradeState.none,
          now: now,
          ackedThroughEpochSec: acked);
      expect(w!.windowEnd, DateTime(2026, 10, 7, 14, 0));
    });

    test('no Natural window, or nothing enabled: no window (never invented)',
        () {
      expect(
          plannedCollectionWindow(
              epoch: null,
              schedule: week(natural: 0),
              upgrade: WakeUpgradeState.none,
              now: now),
          isNull);
      expect(
          plannedCollectionWindow(
              epoch: null,
              schedule: fillDefaultAlarmSchedule(const []),
              upgrade: WakeUpgradeState.none,
              now: now),
          isNull);
    });

    test('while the upgrade explanation is pending the legacy window drives it',
        () {
      final w = plannedCollectionWindow(
          epoch: null,
          schedule: week(natural: 60, smart: 30),
          upgrade: WakeUpgradeState.pending,
          now: now);
      expect(w!.minutes, 30);
    });
  });

  group('detectedSleepOnset reads the night candidate, never guesses', () {
    final wakeAt = DateTime(2026, 10, 6, 14, 0);
    final now = DateTime(2026, 10, 6, 13, 0);
    final onset = DateTime(2026, 10, 6, 5, 50);

    DateTime? detect(List<Object?> windows) =>
        detectedSleepOnset(windows: windows, wakeAt: wakeAt, now: now);

    test('an in-progress night (envelope, bare, or open-ended) is detected', () {
      final end = now.subtract(const Duration(minutes: 5));
      expect(detect([_window(onset, end)]), onset);
      expect(
          detect([
            jsonEncode({
              'onset_ms': onset.millisecondsSinceEpoch,
              'offset_ms': end.millisecondsSinceEpoch,
            })
          ]),
          onset);
      expect(detect([_window(onset, null)]), onset);
    });

    test('nothing usable stays null', () {
      expect(detect(const []), isNull);
      expect(detect([null, '', '{}', 'not json', jsonEncode({'value': '—'})]),
          isNull);
      // ends before it starts
      expect(
          detect([_window(onset, onset.subtract(const Duration(hours: 1)))]),
          isNull);
      // not yet started / starts at or after the wake time
      expect(detect([_window(now.add(const Duration(minutes: 1)), null)]),
          isNull);
    });

    test('yesterday\'s sleep, or a sleep that ended long ago, is not tonight\'s',
        () {
      expect(
          detect([
            _window(wakeAt.subtract(const Duration(hours: 20)), null),
          ]),
          isNull,
          reason: 'more than 16 h before the wake time');
      expect(
          detect([
            _window(onset, now.subtract(const Duration(hours: 3))),
          ]),
          isNull,
          reason: 'that sleep finished three hours ago');
    });

    test('an onset at or after the wake time is never tonight\'s sleep', () {
      final late = DateTime(2026, 10, 6, 14, 30);
      expect(
          detectedSleepOnset(
              windows: [_window(wakeAt, null), _window(late, null)],
              wakeAt: wakeAt,
              now: late.add(const Duration(minutes: 10))),
          isNull);
    });

    test('with several candidates the most recent sleep wins', () {
      final nap = DateTime(2026, 10, 6, 2, 0);
      final napEnd = DateTime(2026, 10, 6, 2, 30);
      final main = _window(onset, now.subtract(const Duration(minutes: 2)));
      expect(detect([_window(nap, napEnd), main]), onset);
    });
  });

  group('the app, backgrounded, with the alarm not tracked', () {
    late FakeAlarmEngine band;
    late AppState app;
    late DateTime wakeAt;
    var testNo = 0;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_wake_owner_rule_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    Future<void> saveWeek() async {
      final week = [
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
    }

    setUp(() async {
      await (await SharedPreferences.getInstance()).clear();
      await LocalDb.clearAlarmSchedule();
      await (await LocalDb.instance).delete('day_result');
      band = FakeAlarmEngine();
      band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      app.debugWakeObserver = ScriptedObserver()..next = stageObs('wake');
      app.debugBackground = true;
      // Inside the Natural window: the alarm is 20 min away, window 60.
      final t = DateTime.now().add(Duration(minutes: 20 + testNo++));
      wakeAt = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    });

    tearDown(() => app.dispose());

    bool requested() => band.offloadSnapshot['high_freq_requested'] == true;

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<List<String>> naturalReasons() async => [
          for (final e in await const DbWakeTraceStore()
              .forWake(wakeAt.millisecondsSinceEpoch ~/ 1000))
            if (e.kind == 'natural') e.data['reason'] as String
        ];

    Future<void> seedNight(DateTime onset, DateTime? offset) async {
      await LocalDb.putDayResult(
        dayId: dayLabelOf(DateTime.now()),
        algoVersion: 1,
        payloadJson: '{}',
        windowJson: _window(onset, offset),
      );
    }

    test('no epoch is tracked, a schedule is saved far away: the window still '
        'collects', () async {
      await saveWeek();
      // A saved expected schedule whose own window is hours from now.
      final far = DateTime.now().add(const Duration(hours: 9));
      app.sleepOperations.schedule = ExpectedSleepSchedule(
          onsetMinute: (far.hour * 60 + far.minute - 480) % 1440,
          wakeMinute: far.hour * 60 + far.minute);
      expect(app.alarmEpoch, isNull, reason: 'nothing armed or tracked');

      await app.debugRefreshHighFreqWakeWindow();

      expect(requested(), isTrue);
      expect(band.highFreqReason, 'scheduled_alarm');
      expect(band.highFreqUntil!.millisecondsSinceEpoch ~/ 1000,
          wakeAt.millisecondsSinceEpoch ~/ 1000);
    });

    test('with no schedule saved and a detected onset, Natural Wake is '
        'eligible and the early wake fires', () async {
      await saveWeek();
      await app.debugArmNextAlarmOccurrence();
      expect(app.sleepOperations.schedule, isNull);
      await seedNight(wakeAt.subtract(const Duration(hours: 8)),
          DateTime.now().subtract(const Duration(minutes: 3)));
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);

      await app.debugKeepAliveTick();
      await until(() => !requested());

      expect(requested(), isFalse, reason: 'fired, so the window is released');
      expect(await naturalReasons(), contains('fire'));
    });

    test('with no schedule and no detectable onset the early wake is not held '
        'back: it fires on an awake stage', () async {
      await saveWeek();
      await app.debugArmNextAlarmOccurrence();
      await app.debugRefreshHighFreqWakeWindow();

      await app.debugKeepAliveTick();
      await until(() => !requested());

      expect(requested(), isFalse);
      expect(await naturalReasons(), contains('fire'));
    });

    test('with no schedule and a detected sleep that began 30 min ago the '
        'early wake stays quiet', () async {
      await saveWeek();
      await app.debugArmNextAlarmOccurrence();
      await seedNight(DateTime.now().subtract(const Duration(minutes: 30)),
          DateTime.now().subtract(const Duration(minutes: 3)));
      await app.debugRefreshHighFreqWakeWindow();

      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(requested(), isTrue);
      expect(await naturalReasons(), ['tooSoonAfterOnset']);
    });

    test('a saved schedule is unchanged: it decides, onset or not', () async {
      await saveWeek();
      await app.debugArmNextAlarmOccurrence();
      app.sleepOperations.schedule = ExpectedSleepSchedule(
          onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
          wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
      await app.debugRefreshHighFreqWakeWindow();

      await app.debugKeepAliveTick();
      await until(() => !requested());

      expect(requested(), isFalse);
      expect(await naturalReasons(), contains('fire'));
    });

    test('wake decisions reach the log once per change, not once per tick',
        () async {
      await saveWeek();
      await app.debugArmNextAlarmOccurrence();
      app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
      await app.debugRefreshHighFreqWakeWindow();

      List<String> lines() =>
          app.logLines.where((l) => l.startsWith('[wake] tick:')).toList();
      Future<void> ticks(int n) async {
        for (var i = 0; i < n; i++) {
          await app.debugKeepAliveTick();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      }

      await ticks(3);
      expect(app.debugWakeTicksLogged, 3,
          reason: 'every tick reached the filter; none was coalesced away');
      expect(lines(), hasLength(1));
      expect(lines().single, contains('reason=noRemCandidate'));

      // The decision changes: a sleep that began 30 min ago is detected.
      await seedNight(DateTime.now().subtract(const Duration(minutes: 30)),
          DateTime.now().subtract(const Duration(minutes: 3)));
      await ticks(2);
      expect(app.debugWakeTicksLogged, 5);
      expect(lines(), hasLength(2), reason: 'one new line for the change');
      expect(lines().first, contains('reason=tooSoonAfterOnset'));
      expect(lines().first, isNot(contains('onset=-')));
    });

    test('the headless plan with no schedule saved collects the next window',
        () async {
      await saveWeek();
      final plan = await headlessWakeWindowPlan();
      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'scheduled_alarm');
      expect(plan.targetWake!.millisecondsSinceEpoch ~/ 1000,
          wakeAt.millisecondsSinceEpoch ~/ 1000);
    });

    test('the headless plan matches: schedule saved far away, nothing tracked',
        () async {
      await saveWeek();
      final far = DateTime.now().add(const Duration(hours: 9));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'expected_sleep_schedule_v1',
          jsonEncode(ExpectedSleepSchedule(
                  onsetMinute: (far.hour * 60 + far.minute - 480) % 1440,
                  wakeMinute: far.hour * 60 + far.minute)
              .toJson()));
      expect(prefs.getInt('alarm_epoch'), isNull);

      final plan = await headlessWakeWindowPlan();

      expect(plan.shouldEnable, isTrue);
      expect(plan.source, 'scheduled_alarm');
      expect(plan.targetWake!.millisecondsSinceEpoch ~/ 1000,
          wakeAt.millisecondsSinceEpoch ~/ 1000);
    });
  });
}
