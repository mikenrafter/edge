// Natural Wake has no main-sleep / nap gate. It acts on an alarm the user
// scheduled, inside the window they chose, when the causal stager says REM or
// awake. The one sleep-length rule: a sleep known to have begun under 45 minutes
// ago holds the early wake. So a stored 3 h sleep that ended 5 minutes ago (a
// completed day_result window) does NOT hold it back: inside the window, with
// the stager out of light and deep sleep, it fires. (It used to be the
// opposite: onset-to-alarm was classified against a 4 h floor. Owner decision.)
//
// The alarm at T itself and the gradual wake never depended on it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart' show dayLabelOf;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/wake_fakes.dart';

String _window(DateTime onset, DateTime? offset) => jsonEncode({
      'value': {
        'onset_ms': onset.millisecondsSinceEpoch,
        if (offset != null) 'offset_ms': offset.millisecondsSinceEpoch,
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the app, no schedule saved, a stored completed sleep', () {
    late FakeAlarmEngine band;
    late AppState app;
    late DateTime wakeAt;
    var testNo = 0;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_wake_completed_sleep_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    setUp(() async {
      await (await SharedPreferences.getInstance()).clear();
      await LocalDb.clearAlarmSchedule();
      await (await LocalDb.instance).delete('day_result');
      band = FakeAlarmEngine();
      band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      // The user is awake in the window: the stager would let the early wake
      // fire if the sleep is eligible.
      app.debugWakeObserver = ScriptedObserver()..next = stageObs('wake');
      app.debugBackground = true;
      // The alarm is 115 min away with a 120 min Natural window: the window
      // opened 5 min ago. (A distinct minute per test: the wake run state
      // persists per wake epoch.)
      final t = DateTime.now().add(Duration(minutes: 115 + testNo++));
      wakeAt = DateTime(t.year, t.month, t.day, t.hour, t.minute);
      await LocalDb.setAlarmScheduleRows([
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(
                  weekday: w,
                  hour: wakeAt.hour,
                  minute: wakeAt.minute,
                  enabled: true,
                  smartWindowMinutes: 60,
                  naturalWindowMinutes: 120)
              .toRow(),
      ]);
      await app.debugLoadAlarmSchedule();
      await app.debugArmNextAlarmOccurrence();
      expect(app.sleepOperations.schedule, isNull);
    });

    tearDown(() => app.dispose());

    bool requested() => band.offloadSnapshot['high_freq_requested'] == true;

    Future<List<String>> naturalReasons() async => [
          for (final e in await const DbWakeTraceStore()
              .forWake(wakeAt.millisecondsSinceEpoch ~/ 1000))
            if (e.kind == 'natural') e.data['reason'] as String
        ];

    Future<void> seedNight(DateTime onset, DateTime offset) =>
        LocalDb.putDayResult(
          dayId: dayLabelOf(DateTime.now()),
          algoVersion: 1,
          payloadJson: '{}',
          windowJson: _window(onset, offset),
        );

    Future<List<String>> tickAndRead() async {
      await app.debugRefreshHighFreqWakeWindow();
      expect(requested(), isTrue);
      await app.debugKeepAliveTick();
      for (var i = 0; i < 100 && requested(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return naturalReasons();
    }

    test('control: a 4.5 h sleep that ended 3 min ago: the early wake fires '
        '(the harness works)', () async {
      final now = DateTime.now();
      await seedNight(now.subtract(const Duration(minutes: 270)),
          now.subtract(const Duration(minutes: 3)));
      expect(await tickAndRead(), contains('fire'));
    });

    test('a completed 3 h sleep that ended 5 min ago does not hold the early '
        'wake back: inside the window on an awake stage it fires', () async {
      final now = DateTime.now();
      // 3 h long, ended 5 min ago; onset to the alarm is 5 h.
      await seedNight(now.subtract(const Duration(minutes: 185)),
          now.subtract(const Duration(minutes: 5)));
      final reasons = await tickAndRead();
      expect(reasons, contains('fire'));
    });

    test('and with nothing stored at all it fires too', () async {
      expect(await tickAndRead(), contains('fire'));
    });

    test('a sleep that began 30 min ago holds it; one that began 50 min ago '
        'does not', () async {
      final now = DateTime.now();
      await seedNight(now.subtract(const Duration(minutes: 30)),
          now.subtract(const Duration(minutes: 3)));
      await app.debugRefreshHighFreqWakeWindow();
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await naturalReasons(), ['tooSoonAfterOnset']);
      expect(requested(), isTrue);

      await seedNight(now.subtract(const Duration(minutes: 50)),
          now.subtract(const Duration(minutes: 3)));
      await app.debugKeepAliveTick();
      for (var i = 0; i < 100 && requested(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await naturalReasons(), contains('fire'));
    });
  });
}
