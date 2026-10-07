// The Calculations power mode holds automatic derives and nothing else. It
// must never get in the way of waking someone: not the 30 s wake tick, not
// the band's high-frequency wake window or the drain behind it, not the alarm
// arm.
//
// The state under test is the worst one: Maximum battery, unplugged, power
// saver on. Each behavioural test first shows the mode is really in force (the
// derive scheduler is held, the headless derive gate says no) and then that
// the wake side did its work anyway.
//
//   alarm arm        AppState's arm path, and the headless re-arm, over a fake
//                    band that counts SET_ALARM writes.
//   wake window      the plan for the band's high-frequency sync window and
//                    the ENTER write on a fake link.
//   by construction  the pieces that cannot be driven end to end here (the
//                    keep-alive tick into WakeOrchestrator.tick, and
//                    runHeadlessSync, which needs a real band to connect to)
//                    are pinned in source: no power input anywhere on the wake
//                    side, and only the post-drain derive behind the gate.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/high_freq_wake_window.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/dart_source_lexical.dart';
import 'support/fake_alarm_engine.dart';
import 'support/fake_power_source.dart';

/// Every day on at the time two hours from now, so it is never already past.
List<AlarmScheduleEntry> _soon() {
  final t = DateTime.now().add(const Duration(hours: 2));
  return [
    for (var w = 0; w < 7; w++)
      AlarmScheduleEntry(
          weekday: w, hour: t.hour, minute: t.minute, enabled: true),
  ];
}

int _epochOf(List<AlarmScheduleEntry> week) =>
    nextAlarmOccurrence(week, DateTime.now())!.millisecondsSinceEpoch ~/ 1000;

String _code(String path) => codeOnly(File(path).readAsStringSync());

/// The words that mean "the Calculations power mode" in this code base.
const _powerWords = [
  'CalcPower',
  'calcPower',
  'PowerSource',
  'PowerState',
  'powerHold',
  'power_hold',
  'mayDeriveAutomatically',
  'mayRunHeadlessAutomaticDerive',
  'power_source',
  'calc_power',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_calc_power_wake_test.db';
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
  });

  tearDown(() => debugHeadlessPowerSource = null);

  group('the alarm arm, Maximum battery with the power saver on', () {
    late FakeAlarmEngine band;
    late AppState app;
    late FakePowerSource power;

    setUp(() async {
      band = FakeAlarmEngine();
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      power = FakePowerSource(charging: false, powerSaver: true);
      app.debugPowerSource = power;
      await app.setCalcPowerMode(CalcPowerMode.maxBattery);
      await app.debugAttachPower();
    });

    tearDown(() async {
      app.dispose();
      await power.close();
    });

    Future<void> store(List<AlarmScheduleEntry> week) async {
      await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
      await app.debugLoadAlarmSchedule();
    }

    test('the mode is in force: automatic derives are held', () {
      expect(app.calcPowerMode, CalcPowerMode.maxBattery);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue);
    });

    test('a connect or sync callback still arms the next occurrence',
        () async {
      final week = _soon();
      await store(week);
      final report = await app.debugArmNextAlarmOccurrence();
      expect(report.wrote, isTrue);
      expect(report.error, isNull);
      expect(band.setEpochs, [_epochOf(week)]);
      expect(app.alarmEpoch, _epochOf(week));
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue,
          reason: 'still held: the arm did not need it released');
    });

    test('Save on the Alarm screen still arms', () async {
      final week = _soon();
      await app.saveAlarmDraft(week, confirmWait: Duration.zero);
      expect(band.setEpochs, [_epochOf(week)]);
    });

    test('the headless re-arm after a drain is not gated either', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('calc_power_mode', CalcPowerMode.maxBattery.name);
      debugHeadlessPowerSource =
          FakePowerSource(charging: false, powerSaver: true);
      expect(await mayRunHeadlessAutomaticDerive(), isFalse,
          reason: 'the derive is held in this state');
      final week = _soon();
      final headless = FakeAlarmEngine();
      final result = await armNextScheduledOccurrence(
        engine: headless,
        schedule: week,
        currentArmedEpoch: null,
      );
      expect(result.refused, isFalse);
      expect(result.epoch, _epochOf(week));
      expect(headless.setEpochs, [_epochOf(week)]);
    });
  });

  group('the high-frequency wake window, Maximum battery with the saver on',
      () {
    setUp(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('calc_power_mode', CalcPowerMode.maxBattery.name);
      debugHeadlessPowerSource =
          FakePowerSource(charging: false, powerSaver: true);
    });

    test('the plan for an armed Natural window still enables collection, and '
        'the band is still asked for it', () async {
      expect(await mayRunHeadlessAutomaticDerive(), isFalse,
          reason: 'the derive is held in this state');
      final wake = DateTime.now().add(const Duration(minutes: 40));
      final plan = await HighFreqWakeWindow.planNow(
        scheduledWindowEnd: wake,
        scheduledWindowMinutes: 30,
      );
      expect(plan.shouldEnable, isTrue);
      expect(plan.targetWake, isNotNull);

      final engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {});
      engine.debugInstallFakeLink(onWrite: (_) async => true);
      await engine.applyHighFreqWakeWindow(
        enabled: plan.shouldEnable,
        targetWake: plan.targetWake,
        duration: plan.lease,
        intervalSeconds: 61,
        reason: plan.source,
      );
      expect(engine.offloadSnapshot['high_freq_requested'], isTrue);
    });

    test('with the derive held, the post-drain pass is the only thing that '
        'stops: it builds no engine and does not throw', () async {
      var built = 0;
      debugHeadlessEngineFactory = ({log, background = false}) {
        built++;
        throw StateError('the held derive must not build an engine');
      };
      addTearDown(() => debugHeadlessEngineFactory = null);
      await headlessDeriveAfterSync();
      expect(built, 0);
    });
  });

  group('by construction', () {
    test('nothing on the wake side reads the power mode', () {
      final files = [
        for (final f in dartFilesIn('lib/wake')) f.path,
        'lib/sync/high_freq_wake_window.dart',
        'lib/state/alarm_schedule.dart',
        'lib/state/alarm_draft.dart',
        'lib/ble/ble_engine.dart',
      ];
      for (final path in files) {
        final code = _code(path);
        for (final word in _powerWords) {
          expect(code, isNot(contains(word)), reason: '$path mentions $word');
        }
      }
    });

    test('the keep-alive tick reaches the orchestrator with no power check',
        () {
      final app = File('lib/state/app_state.dart').readAsStringSync();
      final code = codeOnly(app);
      expect(code, contains('onKeepAlive: _checkSmartWake,'));
      final tick = bodyOf(app, 'Future<void> _checkSmartWake()');
      expect(tick, contains('await _wakeOrchestrator.tick(plan);'));
      final from = code.indexOf('late final WakeOrchestrator _wakeOrchestrator');
      final to = code.indexOf('Future<void> _checkLegacySmartWake');
      expect(from, greaterThan(0));
      expect(to, greaterThan(from));
      final wakeSide = code.substring(from, to) + tick;
      for (final word in _powerWords) {
        expect(wakeSide, isNot(contains(word)), reason: 'wake side: $word');
      }
      // The engine's tick hands over to the hook with no condition of its
      // own on the power mode (it never names one; see the previous test).
      final engineCode = _code('lib/ble/ble_engine.dart');
      final at = engineCode.indexOf('final onTick = onKeepAlive;');
      expect(at, greaterThan(0));
      expect(engineCode.substring(at, at + 200),
          contains('unawaited(onTick().catchError'));
    });

    test('headless: the window, the drain and the re-arm come before the '
        'derive, and only the derive sits behind the power gate', () {
      final src = File('lib/sync/background_sync.dart').readAsStringSync();
      final code = codeOnly(src);
      final run = bodyOf(src, 'Future<bool> runHeadlessSync(');
      for (final word in _powerWords) {
        expect(codeOnly(run), isNot(contains(word)),
            reason: 'runHeadlessSync reads $word itself');
      }
      final window = run.indexOf('await headlessWakeWindowPlan();');
      expect(bodyOf(src, 'Future<HighFreqWakePlan> headlessWakeWindowPlan('),
          contains('HighFreqWakeWindow.planNow('),
          reason: 'the plan the run applies is built by planNow');
      final apply = run.indexOf('engine.applyHighFreqWakeWindow(');
      final drain = run.indexOf('await engine.runSync();');
      final armBefore = run.indexOf("_headlessArm(engine, 'before the drain')");
      final rearm = run.indexOf("_headlessArm(engine, 'after the drain')");
      final derive = run.indexOf('await headlessDeriveAfterSync();');
      expect(window, greaterThan(0));
      expect(apply, greaterThan(window));
      expect(armBefore, greaterThan(apply),
          reason: 'the alarm is armed before the long drain');
      expect(drain, greaterThan(armBefore));
      expect(rearm, greaterThan(drain));
      expect(derive, greaterThan(rearm));
      expect(src, contains('armNextScheduledOccurrence('));

      // The gate: defined once, used by the two headless derives (the light
      // pass and the forced re-derive of a night this run's own note
      // confirmed), and its else branch only logs.
      expect('mayRunHeadlessAutomaticDerive'.allMatches(code).length, 3,
          reason: 'its definition, headlessDeriveAfterSync and '
              'headlessDeriveConfirmedWakeDay');
      final confirmedDerive =
          bodyOf(src, 'Future<bool> headlessDeriveConfirmedWakeDay(');
      expect(confirmedDerive, contains('await mayRunHeadlessAutomaticDerive()'));
      expect(codeOnly(confirmedDerive), isNot(contains('throw')),
          reason: 'a held or failed re-derive never fails the run');
      final after = bodyOf(src, 'Future<void> headlessDeriveAfterSync()');
      expect(after, contains('await mayRunHeadlessAutomaticDerive()'));
      final elseAt = codeOnly(after).indexOf('else {');
      expect(elseAt, greaterThan(0));
      final elseBranch = codeOnly(after).substring(elseAt);
      expect(elseBranch, isNot(contains('return')));
      expect(elseBranch, isNot(contains('throw')));
    });
  });
}
