// The whole week goes to the DB in ONE transaction (real sqflite_ffi).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

const _name = 'openstrap_alarm_batch_test.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), _name),
    );
    await LocalDb.close();
    LocalDb.dbName = _name;
  });

  setUp(() async {
    await LocalDb.clearAlarmSchedule();
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), _name),
    );
  });

  test('seven rows land together, wake settings included', () async {
    final week = [
      for (var w = 0; w < 7; w++)
        AlarmScheduleEntry(
          weekday: w,
          hour: 6,
          minute: w,
          enabled: w.isEven,
          naturalWindowMinutes: 30,
          gradualWindowMinutes: 45,
          gradualPattern: GradualPattern.steady,
          gradualCadenceSec: 240,
        ),
    ];
    await LocalDb.setAlarmScheduleRows([for (final e in week) e.toRow()]);
    final back = [
      for (final r in await LocalDb.alarmScheduleRows())
        AlarmScheduleEntry.fromRow(r),
    ]..sort((a, b) => a.weekday.compareTo(b.weekday));
    expect(back, week);
  });

  test('a bad row rolls the whole batch back', () async {
    await LocalDb.setAlarmScheduleRows([
      const AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0).toRow(),
    ]);
    await expectLater(
      LocalDb.setAlarmScheduleRows([
        const AlarmScheduleEntry(weekday: 0, hour: 9, minute: 9).toRow(),
        const AlarmScheduleEntry(weekday: 1, hour: 9, minute: 9).toRow()
          ..remove('hour'),
      ]),
      throwsA(anything),
    );
    final rows = await LocalDb.alarmScheduleRows();
    expect(rows, hasLength(1), reason: 'the second row never landed');
    expect(rows.single['hour'], 7, reason: 'and the first was not applied');
  });
}
