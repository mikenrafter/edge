import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/wake_db.dart';

Future<void> _requireWakeSchema(Database db) async {
  final columns = await db.rawQuery('PRAGMA table_info(alarm_schedule)');
  expect(columns.map((r) => r['name']).toSet(),
      {'weekday', 'hour', 'minute', 'enabled', 'smart_window_minutes'});
  expect(await LocalDb.tableNames(), contains('wake_meta'));
}

Future<void> _legacy(Database db) async {
  await db.execute('''CREATE TABLE alarm_schedule (
    weekday INTEGER PRIMARY KEY, hour INTEGER NOT NULL,
    minute INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1,
    smart_window_minutes INTEGER NOT NULL DEFAULT 0)''');
  await db.insert('alarm_schedule', {'weekday': 0, 'hour': 6, 'minute': 35,
    'enabled': 1, 'smart_window_minutes': 45});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async => dir = await openWakeDb());
  tearDown(() async => closeWakeDb(dir));

  test('fresh create keeps minimal alarm rows and stores global defaults', () async {
    final db = await LocalDb.instance;
    await _requireWakeSchema(db);
    final rows = await db.query('wake_meta', where: 'key = ?', whereArgs: ['settings']);
    expect(jsonDecode(rows.single['value'] as String), {
      'naturalEnabled': false, 'naturalWindowMinutes': 30, 'gradualEnabled': false,
      'gradualWindowMinutes': 30, 'gradualCadenceSec': 180, 'gradualPattern': 'ramp',
    });
    expect(LocalDb.lastRebuild, isNull);
  });

  Future<void> legacyDb(int version, Future<void> Function(Database) seed) async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(LocalDb.dbName);
    final old = await databaseFactory.openDatabase(LocalDb.dbName,
        options: OpenDatabaseOptions(version: version, onCreate: (db, _) async {
          await _legacy(db);
          await seed(db);
        }));
    await old.close();
  }

  for (final oldVersion in [58, 59, 60]) {
    test('v$oldVersion rung 61 copies largest enabled Natural window once', () async {
      await legacyDb(oldVersion, (db) async {
        await db.insert('alarm_schedule', {'weekday': 1, 'hour': 7, 'minute': 0,
          'enabled': 1, 'smart_window_minutes': 20});
        await db.insert('alarm_schedule', {'weekday': 2, 'hour': 7, 'minute': 0,
          'enabled': 0, 'smart_window_minutes': 120});
      });
      final db = await LocalDb.instance;
      await _requireWakeSchema(db);
      expect(await db.getVersion(), 61);
      final settings = await const DbWakeSettingsStore().load();
      expect(settings.naturalEnabled, true);
      expect(settings.naturalWindowMinutes, 45);
      expect(settings.gradualEnabled, false);
      expect((await LocalDb.alarmScheduleRows()).first['smart_window_minutes'], 45);
      await const DbWakeSettingsStore().save(settings.copyWith(naturalEnabled: false));
      for (var i = 0; i < 2; i++) {
        await LocalDb.close();
        await LocalDb.instance;
        expect((await const DbWakeSettingsStore().load()).naturalEnabled, false);
        expect(LocalDb.lastRebuild, isNull);
      }
    });
  }

  for (final enabled in [false, true]) {
    test('legacy ${enabled ? 'zero' : 'disabled positive'} windows copy Natural off', () async {
      await legacyDb(60, (db) async {
        await db.update('alarm_schedule', {'enabled': enabled ? 1 : 0,
          'smart_window_minutes': enabled ? 0 : 45});
      });
      await LocalDb.instance;
      final settings = await const DbWakeSettingsStore().load();
      expect(settings.naturalEnabled, false);
      expect(settings.gradualEnabled, false);
    });
  }

  test('legacy picker uses 15-minute grid, off-grid legacy value snaps to nearest', () async {
    await legacyDb(60, (db) async => db.update('alarm_schedule', {'smart_window_minutes': 23}));
    await LocalDb.instance;
    expect((await const DbWakeSettingsStore().load()).naturalWindowMinutes, 30);
  });

  test('same-version repair copies legacy only when settings are missing', () async {
    await legacyDb(LocalDb.schemaVersion, (_) async {});
    await _requireWakeSchema(await LocalDb.instance);
    expect((await const DbWakeSettingsStore().load()).naturalWindowMinutes, 45);
    await const DbWakeSettingsStore().save(const WakeSettings(gradualEnabled: true,
        gradualWindowMinutes: 60, gradualPattern: GradualPattern.steady));
    await LocalDb.close();
    await _requireWakeSchema(await LocalDb.instance);
    final settings = await const DbWakeSettingsStore().load();
    expect(settings.naturalEnabled, false);
    expect(settings.gradualEnabled, true);
    expect(settings.gradualWindowMinutes, 60);
    expect(settings.gradualPattern, GradualPattern.steady);
  });

  test('global JSON CRUD survives reopen and invalid save leaves it intact', () async {
    const store = DbWakeSettingsStore();
    const settings = WakeSettings(naturalEnabled: true, naturalWindowMinutes: 120,
        gradualEnabled: true, gradualWindowMinutes: 90, gradualCadenceSec: 420,
        gradualPattern: GradualPattern.steady);
    await store.save(settings);
    await LocalDb.close();
    expect((await store.load()).toJson(), settings.toJson());
    await expectLater(store.save(settings.copyWith(gradualWindowMinutes: 16)), throwsArgumentError);
    expect((await store.load()).gradualWindowMinutes, 90);
    expect(await LocalDb.alarmScheduleRows(), isEmpty);
  });

  test('DbWakeStateStore survives close and cannot alias caller-owned maps', () async {
    final state = <String, Object?>{'wakeEpoch': 1792911600,
        'gradualNext': 4, 'gradualDelivered': 1, 'acknowledged': false};
    await const DbWakeStateStore().save(state);
    state['gradualNext'] = 99;
    await LocalDb.close();
    final read = await const DbWakeStateStore().load();
    expect(read, {'wakeEpoch': 1792911600, 'gradualNext': 4,
        'gradualDelivered': 1, 'acknowledged': false});
    read!['gradualNext'] = 100;
    expect((await const DbWakeStateStore().load())!['gradualNext'], 4);
  });

  test('corrupt run state reads as absent and a later save repairs it', () async {
    final db = await LocalDb.instance;
    await _requireWakeSchema(db);
    await db.insert('wake_meta', {'key': 'run_state', 'value': '{broken'});
    expect(await const DbWakeStateStore().load(), isNull);
    await const DbWakeStateStore().save({'gradualNext': 2});
    expect(await const DbWakeStateStore().load(), {'gradualNext': 2});
  });

  test('restore includes alarm settings and excludes another installation run', () async {
    final db = await LocalDb.instance;
    await _requireWakeSchema(db);
    await LocalDb.setAlarmScheduleDay(weekday: 0, hour: 6, minute: 45,
        enabled: true, smartWindowMinutes: 15);
    await const DbWakeSettingsStore().save(const WakeSettings(gradualEnabled: true,
        gradualWindowMinutes: 90, gradualCadenceSec: 420, gradualPattern: GradualPattern.steady));
    await const DbWakeStateStore().save({'wakeEpoch': 42, 'gradualNext': 6,
        'acknowledged': true});
    expect(await const DbWakeStateStore().load(),
        {'wakeEpoch': 42, 'gradualNext': 6, 'acknowledged': true});
    // Real SQLite snapshot and the production importer, no backup mock.
    final backup = '${dir.path}/donor.db';
    await db.execute('VACUUM INTO ?', [backup]);
    await LocalDb.wipeAll();
    expect(await LocalDb.alarmScheduleRows(), isEmpty);
    expect(await const DbWakeStateStore().load(), isNull);
    await const DbWakeSettingsStore().save(const WakeSettings(naturalEnabled: true));
    await LocalDb.importFromDbFile(backup);
    final imported = await const DbWakeSettingsStore().load();
    expect(imported.naturalEnabled, false);
    expect(imported.gradualWindowMinutes, 90);
    expect(imported.gradualCadenceSec, 420);
    expect(imported.gradualPattern, GradualPattern.steady);
    expect((await LocalDb.alarmScheduleRows()).single, {
      'weekday': 0, 'hour': 6, 'minute': 45, 'enabled': 1,
      'smart_window_minutes': 15,
    });
    expect(await const DbWakeStateStore().load(), isNull);
    await const DbWakeStateStore().save({'wakeEpoch': 84, 'gradualNext': 1});
    await LocalDb.importFromDbFile(backup);
    expect(await const DbWakeStateStore().load(), {'wakeEpoch': 84, 'gradualNext': 1},
        reason: 'restore must not clobber a local in-flight occurrence either');
  });

  test('import without settings preserves local settings and local run', () async {
    final db = await LocalDb.instance;
    await db.delete('wake_meta');
    final backup = '${dir.path}/old-donor.db';
    await db.execute('VACUUM INTO ?', [backup]);
    await const DbWakeSettingsStore().save(const WakeSettings(gradualEnabled: true,
        gradualWindowMinutes: 120));
    await const DbWakeStateStore().save({'epoch': 123, 'gradualNext': 2});
    await LocalDb.importFromDbFile(backup);
    final settings = await const DbWakeSettingsStore().load();
    expect(settings.gradualEnabled, true);
    expect(settings.gradualWindowMinutes, 120);
    expect(await const DbWakeStateStore().load(), {'epoch': 123, 'gradualNext': 2});
  });

  test('wipeAll removes persisted run state and Gradual alarm settings', () async {
    await const DbWakeStateStore().save({'wakeEpoch': 42, 'gradualNext': 3});
    expect(await const DbWakeStateStore().load(), {'wakeEpoch': 42, 'gradualNext': 3});
    await LocalDb.setAlarmScheduleDay(weekday: 0, hour: 7, minute: 0,
        enabled: true);
    await const DbWakeSettingsStore().save(const WakeSettings(gradualEnabled: true));
    await LocalDb.wipeAll();
    expect(await const DbWakeStateStore().load(), isNull);
    expect(await LocalDb.alarmScheduleRows(), isEmpty);
    expect(await (await LocalDb.instance).query('wake_meta'), isEmpty);
  });

  test('issue-report slices classify wake metadata explicitly', () {
    expect(kSliceTables['wake_meta']?.$1, SliceKeep.all);
    expect(kSliceTables['wake_meta']?.$2, isNull);
  });
}
