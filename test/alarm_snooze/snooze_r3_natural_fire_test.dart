// Round 3 (Sol, alarm-snooze-sol-review2-2026-10-07.md, new defect 5): a native
// fire ends only ITS OWN Natural Wake repeat. RED.
//
// Over a real AppState with a running Natural repeat (the way
// test/wake_confirmation_wiring_test.dart drives one: an armed alarm, a
// scripted stager that reports "wake", the 30 s tick). The repeat belongs to
// the wake time T of the armed alarm. A native alarm fire (events 57/58)
// ends it only when the fire is THAT alarm's: stamped within [T - 1 min,
// T + 5 min]. A replayed fire from three minutes ago (an earlier wake's) must
// leave a newly configured wake's repeat alone: the requested Natural wake is
// otherwise lost.
//
// Real time: the orchestrator reads the wall clock, so this suite does too.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_alarm_engine.dart';
import '../support/wake_fakes.dart';

const _dbName = 'openstrap_snooze_r3_natural_fire_test.db';

int _sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wipe() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, _dbName));
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = _dbName;
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
  });
  setUp(() async {
    await wipe();
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    HeadlessSyncGate.resetForTest();
  });
  tearDownAll(wipe);

  late FakeAlarmEngine band;
  late AppState app;
  late DateTime now;
  late DateTime wakeAt; // T: the armed alarm, ~2 to 3 minutes away

  Future<void> saveWeek() async {
    await LocalDb.setAlarmScheduleRows([
      for (var w = 0; w < 7; w++)
        AlarmScheduleEntry(
                weekday: w,
                hour: wakeAt.hour,
                minute: wakeAt.minute,
                enabled: true,
                smartWindowMinutes: 60,
                naturalWindowMinutes: 60)
            .toRow(),
    ]);
    await app.debugLoadAlarmSchedule();
  }

  /// Natural Wake fires and its repeat runs.
  Future<void> startRepeat() async {
    (app.debugWakeObserver as ScriptedObserver).next = stageObs('wake');
    await app.debugRefreshHighFreqWakeWindow();
    await app.debugKeepAliveTick();
    expect(app.wake.naturalBuzzing.value, isTrue,
        reason: 'precondition: Natural fired and its repeat is running');
  }

  Future<void> feedFire(int id, DateTime stamp) async {
    app.debugHandleAlarmEvent(id, ts: _sec(stamp));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  Future<bool> repeatEndsWithin(Duration d) async {
    final end = DateTime.now().add(d);
    while (app.wake.naturalBuzzing.value && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return !app.wake.naturalBuzzing.value;
  }

  setUp(() async {
    now = DateTime.now();
    final w = now.add(const Duration(minutes: 3));
    wakeAt = DateTime(w.year, w.month, w.day, w.hour, w.minute);
    band = FakeAlarmEngine();
    band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
    band.state.generation = 'gen4'; // an alert transport: the buzz is delivered
    app = AppState.forTesting(engine: band);
    app.debugSetAlarmGraceMs(20);
    app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
    app.debugBackground = false;
    await saveWeek();
    await app.debugArmNextAlarmOccurrence();
    expect(app.alarmEpoch, _sec(wakeAt), reason: 'precondition: T is armed');
    app.sleepOperations.schedule = ExpectedSleepSchedule(
        onsetMinute: ((wakeAt.hour * 60 + wakeAt.minute) - 8 * 60) % 1440,
        wakeMinute: wakeAt.hour * 60 + wakeAt.minute);
  });
  tearDown(() => app.dispose());

  test('control: with no fire at all the repeat is still running 4 s later',
      () async {
    await startRepeat();
    expect(await repeatEndsWithin(const Duration(seconds: 4)), isFalse,
        reason: 'the harness itself must not end the repeat');
  });

  test('a replayed fire from three minutes ago (another wake\'s) does not '
      'end the repeat of the wake that is armed now', () async {
    await startRepeat();
    await feedFire(57, now.subtract(const Duration(minutes: 3)));
    expect(await repeatEndsWithin(const Duration(seconds: 4)), isFalse,
        reason: 'the fire was neither T-1 min..T+5 min of the armed wake: it '
            'ended the requested Natural wake');
  });

  test('...nor an hour-old one, nor one from tomorrow', () async {
    await startRepeat();
    await feedFire(58, now.subtract(const Duration(minutes: 40)));
    await feedFire(58, wakeAt.add(const Duration(hours: 24)));
    expect(await repeatEndsWithin(const Duration(seconds: 3)), isFalse);
  });

  test('control: the armed alarm\'s own fire (stamped T) ends its repeat',
      () async {
    await startRepeat();
    await feedFire(57, wakeAt);
    expect(await repeatEndsWithin(const Duration(seconds: 10)), isTrue,
        reason: 'the native alarm at T takes precedence over its own repeat');
  });

  test('control: a fire 30 s before T (inside the T-1 min bound) ends it',
      () async {
    await startRepeat();
    await feedFire(57, wakeAt.subtract(const Duration(seconds: 30)));
    expect(await repeatEndsWithin(const Duration(seconds: 10)), isTrue);
  });
}
