// An iOS background keep-alive lease must not count as Natural Wake's data
// collection.
//
// `AppState._ensureWakeCollection` (the 30 s keep-alive tick) skips the refresh
// when the band already has a high-frequency lease that ends after the alarm
// ("covered"). It only looks at the lease's END, not at who asked or how often
// the band prompts. The iOS background lease (reason `ios_background`, 2 h)
// prompts every 900 s, while Natural Wake needs the 61 s cadence (reason
// `scheduled_alarm`) for the whole window. Backgrounded on iOS with a lease
// that happens to run past the alarm, the tick therefore never upgrades it and
// the stager is starved of the 1 Hz rows it reads.
//
// The reason string is the observable: it is what the engine keeps for the
// lease it last programmed (`highFreqReason`), and the policy picks the 61 s
// request only under `scheduled_alarm`.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_alarm_engine.dart';
import 'support/fake_power_source.dart';
import 'support/wake_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAlarmEngine band;
  late AppState app;
  late FakePowerSource power;
  late DateTime wakeAt;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_wake_collection_ios_lease_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  /// Inside the Natural window (alarm in 20 min, window 60), backgrounded.
  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
    await LocalDb.clearAlarmSchedule();
    band = FakeAlarmEngine();
    band.debugInstallFakeLink(onWrite: (_) async => true, listening: true);
    app = AppState.forTesting(engine: band);
    app.debugSetAlarmGraceMs(20);
    app.debugWakeObserver = ScriptedObserver()..next = stageObs('nrem');
    power = FakePowerSource(charging: false, powerSaver: false);
    app.debugPowerSource = power;
    await app.setCalcPowerMode(CalcPowerMode.balanced);
    await app.debugAttachPower();
    app.debugBackground = true;

    final t = DateTime.now().add(const Duration(minutes: 20));
    wakeAt = DateTime(t.year, t.month, t.day, t.hour, t.minute);
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
    await app.debugArmNextAlarmOccurrence();
    expect(app.wake.naturalEnabled, isTrue);
  });

  tearDown(() async {
    app.dispose();
    await power.close();
  });

  test('an ios_background lease that runs past the alarm is upgraded to the '
      'Natural window\'s 61 s request by the keep-alive tick', () async {
    final now = DateTime.now();
    await band.applyHighFreqWakeWindow(
      enabled: true,
      targetWake: now.add(kIosBackgroundPromptLease),
      duration: kIosBackgroundPromptLease,
      intervalSeconds: kIosBackgroundPromptIntervalSeconds,
      reason: kIosBackgroundPromptReason,
    );
    expect(band.highFreqReason, kIosBackgroundPromptReason);
    expect(band.highFreqUntil!.isAfter(wakeAt), isTrue,
        reason: 'the background lease ends after the alarm: it "covers" it');

    await app.debugKeepAliveTick();
    for (var i = 0;
        i < 100 && band.highFreqReason == kIosBackgroundPromptReason;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(band.highFreqReason, 'scheduled_alarm',
        reason: 'the tick treated a 900 s background lease as Natural Wake '
            'collection and never requested the 61 s window');
    expect(band.highFreqUntil!.millisecondsSinceEpoch ~/ 1000,
        wakeAt.millisecondsSinceEpoch ~/ 1000);
  });
}
