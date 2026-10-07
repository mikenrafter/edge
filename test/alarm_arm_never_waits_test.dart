// The wake alarm must get armed whatever else the app is doing. Last night's
// alarm did not arm; the places an arm could be skipped or deferred, pinned:
//
//   * a link that simply stays up in the background raised no connect, no
//     sync burst and no foreground resume, so once an occurrence had fired the
//     next one waited for somebody to open the app. The 30 s keep-alive tick
//     now arms it, in every power mode;
//   * the connect flows armed AFTER the high-frequency window's database read
//     and band write, which can stall; the alarm now comes first;
//   * the headless (background) run armed only AFTER its drain, so a drain
//     that threw or a slot the OS cut short left it unarmed; it arms before
//     and after, and leaves a line in the sync log file;
//   * a replayed "alarm executed/disabled" event from an earlier night wiped
//     tonight's freshly armed alarm from the app's books.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show AlarmConfirmation;
import 'package:openstrap_edge/compute/calc_power_policy.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
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

/// Wait (briefly, for real) until [done]; the tick's arm is fire-and-forget.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_alarm_arm_never_waits_test.db';
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

  group('the keep-alive tick arms the next occurrence', () {
    late FakeAlarmEngine band;
    late AppState app;
    late FakePowerSource power;

    Future<void> boot(CalcPowerMode mode,
        {bool charging = false, bool saver = true, bool background = true}) async {
      band = FakeAlarmEngine();
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      power = FakePowerSource(charging: charging, powerSaver: saver);
      app.debugPowerSource = power;
      await app.setCalcPowerMode(mode);
      await app.debugAttachPower();
      app.debugBackground = background;
    }

    tearDown(() async {
      app.dispose();
      await power.close();
    });

    Future<void> store(List<AlarmScheduleEntry> week) async {
      await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
      await app.debugLoadAlarmSchedule();
    }

    test('Maximum battery, backgrounded, unplugged, power saver on: the tick '
        'arms the alarm and the strap confirms it', () async {
      await boot(CalcPowerMode.maxBattery);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue,
          reason: 'the mode is in force: automatic derives are held');
      final week = _soon();
      await store(week);
      expect(app.alarmEpoch, isNull);

      await app.debugKeepAliveTick();
      await _until(() => band.sets.isNotEmpty && app.alarmEpoch != null);

      expect(band.setEpochs, [_epochOf(week)]);
      expect(app.alarmEpoch, _epochOf(week));
      app.debugHandleAlarmEvent(56); // the strap's ALARM_SET
      expect(app.alarmConfirmed, isTrue);
      expect(app.debugDeriveScheduler.snapshot()['power_hold'], isTrue,
          reason: 'still held: the arm did not need it released');
    });

    for (final mode in CalcPowerMode.values) {
      test('${mode.name}: a spent occurrence is re-armed by the tick', () async {
        await boot(mode, charging: mode == CalcPowerMode.eager, saver: false);
        final week = _soon();
        await store(week);
        await app.debugArmNextAlarmOccurrence();
        expect(band.setEpochs, [_epochOf(week)]);
        // The alarm fires and the app books it as spent; the link stays up in
        // the background, so no connect, sync or resume follows.
        app.debugHandleAlarmEvent(57);
        expect(app.alarmEpoch, isNull);
        band.sets.clear();
        await app.debugKeepAliveTick();
        await _until(() => band.sets.isNotEmpty);
        expect(band.setEpochs, [_epochOf(week)]);
      });
    }

    test('an alarm already armed in the future costs no write', () async {
      await boot(CalcPowerMode.maxBattery);
      final week = _soon();
      await store(week);
      await app.debugArmNextAlarmOccurrence();
      expect(band.sets, hasLength(1));
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(band.sets, hasLength(1));
    });

    test('with every day off the tick arms nothing', () async {
      await boot(CalcPowerMode.maxBattery);
      await store([
        for (var w = 0; w < 7; w++)
          AlarmScheduleEntry(weekday: w, hour: 7, minute: 0, enabled: false),
      ]);
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(band.sets, isEmpty);
    });

    test('a band that refuses is not hammered every 30 s', () async {
      await boot(CalcPowerMode.maxBattery);
      band.refuse = true;
      await store(_soon());
      await app.debugKeepAliveTick();
      await _until(() => band.sets.isNotEmpty);
      final first = band.sets.length;
      expect(first, greaterThanOrEqualTo(1));
      // Two more ticks inside the throttle: the tick itself asks for nothing.
      band.sets.clear();
      await app.debugKeepAliveTick();
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(band.sets, isEmpty);
    });

    test('disconnected: the tick does nothing', () async {
      await boot(CalcPowerMode.maxBattery);
      await store(_soon());
      band.state.connection = 'disconnected';
      await app.debugKeepAliveTick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(band.sets, isEmpty);
    });
  });

  group('an event from an earlier night does not undo tonight\'s arm', () {
    late FakeAlarmEngine band;
    late AppState app;

    setUp(() async {
      band = FakeAlarmEngine();
      app = AppState.forTesting(engine: band);
      app.debugSetAlarmGraceMs(20);
      final week = _soon();
      await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
      await app.debugLoadAlarmSchedule();
      await app.debugArmNextAlarmOccurrence();
      expect(app.alarmEpoch, isNotNull);
    });

    tearDown(() => app.dispose());

    test('a replayed EXECUTED stamped before the arm is ignored', () {
      final before = DateTime.now().subtract(const Duration(hours: 10));
      final epoch = app.alarmEpoch;
      app.debugHandleAlarmEvent(57, ts: before.millisecondsSinceEpoch ~/ 1000);
      app.debugHandleAlarmEvent(58, ts: before.millisecondsSinceEpoch ~/ 1000);
      app.debugHandleAlarmEvent(59, ts: before.millisecondsSinceEpoch ~/ 1000);
      expect(app.alarmEpoch, epoch);
    });

    test('a fresh EXECUTED still clears it (the alarm really fired)', () {
      app.debugHandleAlarmEvent(57);
      expect(app.alarmEpoch, isNull);
    });
  });

  group('AlarmConfirmation.predatesArm', () {
    test('only fired/disabled events, only well before the SET', () {
      final a = AlarmConfirmation()..set(1000, 10 * 3600 * 1000);
      const slack = AlarmConfirmation.staleSlackMs ~/ 1000;
      final setSec = 10 * 3600;
      for (final id in [57, 58, 59]) {
        expect(a.predatesArm(id, setSec - slack - 1), isTrue, reason: '$id');
        expect(a.predatesArm(id, setSec - slack), isFalse, reason: '$id');
        expect(a.predatesArm(id, setSec + 5), isFalse, reason: '$id');
      }
      expect(a.predatesArm(56, 0), isFalse, reason: 'ALARM_SET is not judged');
      expect(a.predatesArm(60, 0), isFalse);
      expect(AlarmConfirmation().predatesArm(57, 0), isFalse,
          reason: 'nothing armed, nothing to predate');
    });
  });

  group('ordering, pinned in source', () {
    String body(String path, String signature) {
      final src = File(path).readAsStringSync();
      final at = src.indexOf(signature);
      expect(at, greaterThan(0), reason: '$path has $signature');
      return codeOnly(src.substring(at));
    }

    test('connect flows arm the alarm BEFORE the wake window is planned', () {
      final src = codeOnly(File('lib/state/sync_controller.dart').readAsStringSync());
      final arms =
          RegExp(r'await _armNextAlarmOccurrence\(\);').allMatches(src).toList();
      expect(arms, hasLength(5),
          reason: 'connect + after-burst in both flows, and the background start');
      for (final m in arms) {
        final before = src
            .substring(m.start > 150 ? m.start - 150 : 0, m.start)
            .replaceAll(RegExp(r'\s+'), ' ');
        expect(before, isNot(contains('_refreshHighFreqWakeWindow')),
            reason: 'the window must not precede the arm at ${m.start}');
      }
    });

    test('headless: armed before the drain and again after it, even when '
        'the drain throws', () {
      final src = File('lib/sync/background_sync.dart').readAsStringSync();
      final at = src.indexOf('Future<bool> runHeadlessSync(');
      final run = src.substring(at);
      final before = run.indexOf("_headlessArm(engine, 'before the drain')");
      final drain = run.indexOf('await engine.runSync();');
      final finallyAt = run.indexOf('finally {', drain);
      final after = run.indexOf("_headlessArm(engine, 'after the drain')");
      expect(before, greaterThan(0));
      expect(drain, greaterThan(before));
      expect(finallyAt, greaterThan(drain));
      expect(after, greaterThan(finallyAt),
          reason: 'the second pass sits in a finally');
    });

    test('headless arming leaves lines in the persistent dev log', () {
      final src = File('lib/sync/background_sync.dart').readAsStringSync();
      final arm = codeOnly(src.substring(
          src.indexOf('Future<void> _headlessArm('),
          src.indexOf('Future<bool> runHeadlessSync(')));
      expect(arm, contains('_bgLog('));
      final helper = codeOnly(src.substring(src.indexOf('void _bgLog('),
          src.indexOf('bool _mentionsAlarm(')));
      expect(helper, contains('DevLog.write('));
    });

    test('the keep-alive tick reaches the arm before any wake logic and with '
        'no power or foreground condition', () {
      final tick = body('lib/state/app_state.dart',
          'Future<void> _checkSmartWake()');
      final head = tick.substring(0, tick.indexOf('await _wakeOrchestrator.tick'));
      expect(head, contains('_ensureNextAlarmArmed();'));
      final ensure = body('lib/state/app_state.dart',
          'void _ensureNextAlarmArmed()');
      final fn = ensure.substring(0, ensure.indexOf('\n  }\n'));
      for (final word in ['CalcPower', 'calcPower', 'PowerSource', 'PowerState',
          'mayDeriveAutomatically', '_background', 'isForeground']) {
        expect(fn, isNot(contains(word)), reason: word);
      }
    });
  });
}
