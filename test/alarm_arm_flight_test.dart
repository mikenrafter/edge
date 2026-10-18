// The real AppState arm path, over a fake band that only counts writes.
//   N. one flight: concurrent arms share one write, and a change made while a
//      write is in flight ends in a final write of the NEWEST state.
//   M. the single grace retry goes through that flight, never overlaps another
//      write, and happens at most once.
//   O. an ALARM_SET (event 56) that beats the write's reply is kept, so no
//      needless retry follows.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/fake_alarm_engine.dart';

/// All seven days on at [hour]:[minute].
List<AlarmScheduleEntry> _week(int hour, int minute) => [
  for (var w = 0; w < 7; w++)
    AlarmScheduleEntry(weekday: w, hour: hour, minute: minute, enabled: true),
];

/// A wake time a couple of hours from now, so it is never "already passed".
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_alarm_arm_flight_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  late FakeAlarmEngine band;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    band = FakeAlarmEngine();
    app = AppState.forTesting(engine: band);
    app.debugSetAlarmGraceMs(20); // grace timer = 20 + 250 ms
    await LocalDb.clearAlarmSchedule();
  });

  tearDown(() => app.dispose());

  Future<void> store(List<AlarmScheduleEntry> week) async {
    await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
    await app.debugLoadAlarmSchedule();
  }

  group('N: one flight', () {
    test('concurrent arms (a sync, a connect, a wake tick) write once',
        () async {
      final week = _soon();
      await store(week);
      await Future.wait([
        app.debugArmNextAlarmOccurrence(),
        app.debugArmNextAlarmOccurrence(),
        app.debugArmNextAlarmOccurrence(),
      ]);
      expect(band.setEpochs, [_epochOf(week)]);
      expect(band.maxInFlight, 1);
      expect(app.alarmEpoch, _epochOf(week));
    });

    test('Save racing a sync callback is still one write', () async {
      final week = _soon();
      final sync = app.debugArmNextAlarmOccurrence(); // schedule not saved yet
      final save = app.saveAlarmDraft(week, confirmWait: Duration.zero);
      await Future.wait([sync, save]);
      expect(band.setEpochs, [_epochOf(week)]);
    });

    test('a change made while a write is in flight ends on the newest state',
        () async {
      final first = _soon(plusHours: 2);
      final second = _soon(plusHours: 3);
      await store(first);

      final writing = Completer<void>();
      final release = Completer<void>();
      band.onSet = (_, n) async {
        if (n == 1) {
          writing.complete();
          await release.future; // the older write is still on the wire
        }
      };
      final older = app.debugArmNextAlarmOccurrence();
      await writing.future;

      await store(second); // the user saved something else meanwhile
      final newer = app.debugArmNextAlarmOccurrence(); // joins; no 2nd write yet
      expect(band.sets, hasLength(1));
      release.complete();
      await Future.wait([older, newer]);

      expect(band.setEpochs, [_epochOf(first), _epochOf(second)]);
      expect(band.maxInFlight, 1, reason: 'never two writes at once');
      expect(app.alarmEpoch, _epochOf(second),
          reason: 'the older completion must not clobber the newer state');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('alarm_epoch'), _epochOf(second));
    });

    test('a flight that fails is cleared: the next arm runs', () async {
      final week = _soon();
      await store(week);
      band.refuse = true;
      final bad = await app.debugArmNextAlarmOccurrence();
      expect(bad.failed, isTrue);
      band.refuse = false;
      final good = await app.debugArmNextAlarmOccurrence();
      expect(good.failed, isFalse);
      expect(band.sets, hasLength(2));
    });
  });

  group('M: the grace retry', () {
    test('an unconfirmed arm is sent once more, and only once', () async {
      final week = _soon();
      await store(week);
      await app.debugArmNextAlarmOccurrence();
      expect(band.sets, hasLength(1));
      await _until(() => band.sets.length >= 2);
      expect(band.sets, hasLength(2), reason: 'one safety retry');
      expect(band.setEpochs[1], band.setEpochs[0]);
      // Past a second grace window: no third write.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(band.sets, hasLength(2));
      expect(app.alarmResentUnconfirmed, isTrue);
    });

    test('a confirmed arm is not retried', () async {
      await store(_soon());
      await app.debugArmNextAlarmOccurrence();
      app.debugHandleAlarmEvent(56);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(band.sets, hasLength(1));
      expect(app.alarmResentUnconfirmed, isFalse);
    });

    test('never writes while another arm is in flight', () async {
      final first = _soon(plusHours: 2);
      final second = _soon(plusHours: 3);
      await store(first);
      await app.debugArmNextAlarmOccurrence(); // grace timer now running

      // A newer arm is on the wire when the grace deadline passes.
      await store(second);
      final writing = Completer<void>();
      final release = Completer<void>();
      band.onSet = (_, n) async {
        writing.complete();
        await release.future;
      };
      final newer = app.debugArmNextAlarmOccurrence();
      await writing.future;
      await Future<void>.delayed(const Duration(milliseconds: 600)); // > grace
      expect(band.sets, hasLength(2),
          reason: 'the retry must wait for the flight, not write beside it');
      expect(band.maxInFlight, 1);
      release.complete();
      await newer;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // The stale alarm was replaced: its retry is moot. The new one's own
      // grace window is the only thing that can retry now.
      expect(band.setEpochs.take(2), [_epochOf(first), _epochOf(second)]);
      expect(band.maxInFlight, 1);
    });

    test('a retry that met a flight which did not re-arm still happens after it',
        () async {
      final first = _soon(plusHours: 2);
      final second = _soon(plusHours: 3);
      await store(first);
      await app.debugArmNextAlarmOccurrence(); // A is on the band, unconfirmed
      await store(second);
      final writing = Completer<void>();
      final release = Completer<void>();
      band.refuseIf = (n) => n == 2; // the newer arm will be refused
      band.onSet = (_, n) async {
        if (n == 2) {
          writing.complete();
          await release.future;
        }
      };
      final newer = app.debugArmNextAlarmOccurrence();
      await writing.future;
      await Future<void>.delayed(const Duration(milliseconds: 600)); // > grace
      expect(band.sets, hasLength(2), reason: 'nothing written beside the flight');
      release.complete();
      await newer;
      await _until(() => band.sets.length >= 3);
      expect(band.setEpochs, [
        _epochOf(first),
        _epochOf(second),
        _epochOf(first),
      ], reason: 'A was never replaced, so its one retry still runs');
      expect(band.maxInFlight, 1);
    });

    test('Save header: reports the resend honestly', () async {
      final week = _soon();
      final out = await app.saveAlarmDraft(
        week,
        confirmWait: const Duration(milliseconds: 600),
      );
      expect(out.status, AlarmSaveStatus.sentUnconfirmed);
      expect(band.sets, hasLength(2), reason: 'one write plus one retry');
      expect(app.alarmResentUnconfirmed, isTrue);
      expect(out.headline, isNot(contains('Sent again')));
      expect(
        out.headlineFor(resent: app.alarmResentUnconfirmed),
        'Saved. Sent again: the band had not confirmed the first send',
      );
    });
  });

  group('O: an event 56 that beats the write reply', () {
    test('is kept: confirmed, persisted, and no needless retry', () async {
      await store(_soon());
      band.onSet = (_, _) async => app.debugHandleAlarmEvent(56);
      await app.debugArmNextAlarmOccurrence();
      expect(app.alarmConfirmed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('alarm_epoch_confirmed'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(band.sets, hasLength(1), reason: 'no retry for a confirmed arm');
      expect(app.alarmResentUnconfirmed, isFalse);
    });

    test('Save then reports the band confirmed it', () async {
      band.onSet = (_, _) async => app.debugHandleAlarmEvent(56);
      final out = await app.saveAlarmDraft(_soon());
      expect(out.status, AlarmSaveStatus.sentToBand);
      expect(band.sets, hasLength(1));
    });

    test('an event 56 with no write in flight is not carried to the next',
        () async {
      await store(_soon());
      app.debugHandleAlarmEvent(56); // nothing pending: an old confirmation
      await app.debugArmNextAlarmOccurrence();
      expect(app.alarmConfirmed, isFalse,
          reason: 'a fresh arm still waits for its own confirmation');
    });

    test('a refused write leaves nothing pending', () async {
      await store(_soon());
      band.refuse = true;
      band.onSet = (_, _) async => app.debugHandleAlarmEvent(56);
      await app.debugArmNextAlarmOccurrence();
      band.refuse = false;
      band.onSet = null;
      await app.debugArmNextAlarmOccurrence();
      expect(app.alarmConfirmed, isFalse);
    });
  });
}
