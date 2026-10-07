// The alarm-slot probe over the REAL AppState: its single arm flight, its
// alarm-event handler, its saved alarm and its prefs, with a fake band.
//
//   restore    the real alarm goes back through the normal arm path, after the
//              probe's slots are cleared
//   events     the probe's own alarm events never reach the alarm handler (a
//              fired probe alarm would wipe the real alarm's books)
//   flight     the probe holds the arm flight; it never starts inside a real
//              arm pass, and an arm pass that arrives mid-probe waits
//   marker     a pending-restore marker in prefs survives a crash: the next
//              arm pass cleans up and re-arms, and a restore the band refused
//              keeps the marker so the next pass retries

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';

import 'support/fake_alarm_engine.dart';

const _marker = 'alarm_probe_pending';

class _SlotEngine extends FakeAlarmEngine {
  String? family = 'gen5';

  /// Band-facing calls, in order: arm0/arm1/read0/read1/clear0/clear1, set.
  final order = <String>[];

  @override
  String? get linkDeviceFamily => family;

  @override
  Future<DateTime?> setAlarm(DateTime when,
      {int index = 0, List<int>? haptics}) {
    order.add('set');
    return super.setAlarm(when, index: index, haptics: haptics);
  }

  @override
  Future<AlarmSlotWrite> setAlarmSlot(DateTime when, {required int slot}) async {
    order.add('arm$slot');
    final s = when.millisecondsSinceEpoch ~/ 1000;
    return AlarmSlotWrite(
      written: true,
      answered: true,
      rejected: false,
      resultStatus: 1,
      alarmStatus: 1,
      alarmStatusName: 'valid_input_pattern',
      wallSec: s,
      strapSec: s,
    );
  }

  @override
  Future<AlarmSlotRead> readAlarmSlot({required int slot}) async {
    order.add('read$slot');
    return const AlarmSlotRead.silent();
  }

  @override
  Future<bool> clearAlarmSlot({required int slot}) async {
    order.add('clear$slot');
    return true;
  }
}

List<AlarmScheduleEntry> _week(int hour, int minute) => [
      for (var w = 0; w < 7; w++)
        AlarmScheduleEntry(
            weekday: w, hour: hour, minute: minute, enabled: true),
    ];

List<AlarmScheduleEntry> _soon({int plusHours = 2}) {
  final t = DateTime.now().add(Duration(hours: plusHours));
  return _week(t.hour, t.minute);
}

int _epochOf(List<AlarmScheduleEntry> week) =>
    nextAlarmOccurrence(week, DateTime.now())!.millisecondsSinceEpoch ~/ 1000;

Future<void> _until(bool Function() done, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

StrapEvent _ev(int id, int ts) => StrapEvent(
      eventId: id,
      tsEpoch: ts,
      receivedAt: DateTime.now(),
      hex: '',
      deviceId: 'd',
    );

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_alarm_slot_probe_state_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  late _SlotEngine band;
  late AppState app;

  Future<void> boot([Map<String, Object> prefs = const {}]) async {
    SharedPreferences.setMockInitialValues(prefs);
    band = _SlotEngine();
    app = AppState.forTesting(engine: band);
    await Prefs.ensureLoaded();
    app.setDevMode(true);
    app.debugSetAlarmGraceMs(20);
    await LocalDb.clearAlarmSchedule();
  }

  setUp(() async => boot());
  tearDown(() async {
    app.setDevMode(false);
    app.dispose();
  });

  Future<void> store(List<AlarmScheduleEntry> week) async {
    await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
    await app.debugLoadAlarmSchedule();
  }

  /// A real alarm at [week], armed through the normal path.
  Future<int> armReal(List<AlarmScheduleEntry> week) async {
    await store(week);
    await app.debugArmNextAlarmOccurrence();
    return _epochOf(week);
  }

  /// Start the probe and let it get as far as arming B.
  Future<({Future<void> run})> startProbe() async {
    final run = app.alarmSlotProbe.run();
    await _until(() => band.order.contains('arm1'));
    expect(band.order, contains('arm1'), reason: 'the probe got going');
    return (run: run);
  }

  group('restore', () {
    test('the real alarm goes back through the normal arm path, after the '
        'clears', () async {
      final e = await armReal(_soon());
      expect(band.setEpochs, [e]);
      band.order.clear();

      final run = (await startProbe()).run;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_marker), e, reason: 'pending-restore marker set');

      app.alarmSlotProbe.cancel();
      await run;

      expect(band.order, containsAllInOrder(['arm0', 'arm1', 'clear1', 'set']));
      expect(band.setEpochs, [e, e], reason: 'one restore write');
      expect(app.alarmEpoch, e);
      expect(app.alarmSlotProbe.restoreOk, isTrue);
      expect(prefs.getInt(_marker), isNull, reason: 'cleared on success');
    });

    test('with no real alarm both probe slots are cleared and no alarm is '
        'written', () async {
      final run = (await startProbe()).run;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_marker), 0, reason: 'marker 0: nothing to restore');
      app.alarmSlotProbe.cancel();
      await run;
      expect(band.order, containsAll(['clear0', 'clear1']));
      expect(band.order, isNot(contains('set')));
      expect(app.alarmEpoch, isNull);
      expect(prefs.getInt(_marker), isNull);
    });

    test('a restore the band refuses keeps the marker; the next arm pass '
        'retries and clears it', () async {
      final e = await armReal(_soon());
      final run = (await startProbe()).run;
      band.refuse = true; // the restore write will be refused
      app.alarmSlotProbe.cancel();
      await run;
      final prefs = await SharedPreferences.getInstance();
      expect(app.alarmSlotProbe.restoreOk, isFalse);
      expect(prefs.getInt(_marker), e, reason: 'still pending');

      band.refuse = false;
      band.order.clear();
      await app.debugArmNextAlarmOccurrence();
      expect(band.order, contains('set'), reason: 'forced, despite the dedupe');
      expect(prefs.getInt(_marker), isNull);
      expect(app.alarmEpoch, e);
    });
  });

  group('crash recovery', () {
    test('a leftover marker makes the next arm pass clean up and re-arm',
        () async {
      final week = _soon();
      final e = _epochOf(week);
      await boot({_marker: e, 'alarm_epoch': e});
      await store(week);
      await app.debugArmNextAlarmOccurrence();
      expect(band.order.indexOf('clear1'), isNonNegative);
      expect(band.order.indexOf('clear1'),
          lessThan(band.order.indexOf('set')));
      expect(band.setEpochs, [e], reason: 'rewritten once, not twice');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_marker), isNull);
    });
  });

  group('events', () {
    test('the probe alarms\' own events never reach the real alarm', () async {
      final e = await armReal(_soon());
      final run = (await startProbe()).run;

      // A fired probe alarm, and its auto-disable, while the probe runs.
      app.debugOnLiveEvent(_ev(57, _nowSec()));
      app.debugOnLiveEvent(_ev(59, _nowSec()));
      expect(app.alarmEpoch, e, reason: 'a fired event would have wiped it');

      app.alarmSlotProbe.cancel();
      await run;

      // A probe event arriving late, stamped before the restore.
      app.debugOnLiveEvent(_ev(59, _nowSec() - 60));
      expect(app.alarmEpoch, e);

      // After that, an event stamped after the restore is the real alarm's.
      app.debugOnLiveEvent(_ev(57, _nowSec() + 60));
      expect(app.alarmEpoch, isNull, reason: 'normal handling is back');
    });
  });

  group('the arm flight', () {
    test('the probe will not start inside a real arm pass', () async {
      final week = _soon();
      await store(week);
      final writing = Completer<void>();
      final release = Completer<void>();
      band.onSet = (_, _) async {
        writing.complete();
        await release.future;
      };
      final pass = app.debugArmNextAlarmOccurrence();
      await writing.future;
      expect(app.alarmSlotProbe.blockedReason, contains('alarm write'));
      await app.alarmSlotProbe.run();
      expect(band.order, isNot(contains('arm0')));
      release.complete();
      await pass;
    });

    test('an arm pass that arrives mid-probe waits for it and writes nothing',
        () async {
      final e = await armReal(_soon());
      final run = (await startProbe()).run;
      var joined = false;
      final pass = app.debugArmNextAlarmOccurrence().then((_) => joined = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(joined, isFalse, reason: 'it shares the probe\'s flight');

      app.alarmSlotProbe.cancel();
      await run;
      await pass;
      expect(joined, isTrue);
      expect(band.setEpochs, [e, e], reason: 'the original arm and the '
          'probe\'s restore; the joined pass found it unchanged');
    });
  });

  group('gates', () {
    test('unknown band family', () async {
      band.family = null;
      expect(app.alarmSlotProbe.blockedReason, contains('family'));
      await app.alarmSlotProbe.run();
      expect(band.order, isEmpty);
    });

    test('developer mode off', () async {
      app.setDevMode(false);
      expect(app.alarmSlotProbe.blockedReason, contains('Developer mode'));
      await app.alarmSlotProbe.run();
      expect(band.order, isEmpty);
    });

    test('a real alarm within 10 minutes', () async {
      final soon = DateTime.now().add(const Duration(minutes: 7));
      await armReal(_week(soon.hour, soon.minute));
      expect(app.alarmSlotProbe.blockedReason, contains('10 minutes'));
      band.order.clear();
      await app.alarmSlotProbe.run();
      expect(band.order, isEmpty);
    });
  });
}
