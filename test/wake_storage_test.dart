// Storage for Phase 6B against REAL sqflite_ffi: the additive v56 rung, its
// idempotence, the same-version self-heal, and the trace/state stores.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';
import 'package:openstrap_edge/wake/wake_stores.dart';

Future<String> _dbPath(String name) async =>
    p.join(await databaseFactory.getDatabasesPath(), name);

/// A v55 database holding the pre-split alarm_schedule shape and three days:
/// Monday uses Smart Wake (30), Tuesday does not, Wednesday uses 20 minutes
/// (not a step of 15) and is switched off.
Future<void> _seedV55(String name, {bool anySmart = true}) async {
  final path = await _dbPath(name);
  await databaseFactory.deleteDatabase(path);
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 55,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE alarm_schedule (
            weekday INTEGER NOT NULL,
            hour    INTEGER NOT NULL,
            minute  INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            smart_window_minutes INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (weekday)
          )
        ''');
        await db.insert('alarm_schedule', {
          'weekday': 0, 'hour': 7, 'minute': 0, 'enabled': 1,
          'smart_window_minutes': anySmart ? 30 : 0,
        });
        await db.insert('alarm_schedule', {
          'weekday': 1, 'hour': 7, 'minute': 15, 'enabled': 1,
          'smart_window_minutes': 0,
        });
        await db.insert('alarm_schedule', {
          'weekday': 2, 'hour': 6, 'minute': 0, 'enabled': 0,
          'smart_window_minutes': anySmart ? 20 : 0,
        });
      },
    ),
  );
  await db.close();
}

Future<void> _open(String name) async {
  await LocalDb.close();
  LocalDb.lastRebuild = null;
  LocalDb.dbName = name;
  await LocalDb.instance;
  expect(LocalDb.lastRebuild, isNull,
      reason: 'fell back to quarantine-and-rebuild: ${LocalDb.lastRebuild?.cause}');
}

Future<Map<int, Map<String, Object?>>> _rows() async => {
      for (final r in await LocalDb.alarmScheduleRows()) r['weekday'] as int: r,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <String>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await LocalDb.close();
    for (final n in created) {
      await databaseFactory.deleteDatabase(await _dbPath(n));
    }
  });

  test('schemaVersion is at least 56 (the wake split rung)', () {
    expect(LocalDb.schemaVersion, greaterThanOrEqualTo(56));
  });

  group('v56 migration', () {
    const name = 'openstrap_wake_split_test.db';

    test('keeps every existing alarm setting, maps Smart Wake onto a pending '
        'Natural window, and never enables Gradual', () async {
      created.add(name);
      await _seedV55(name);
      await _open(name);
      final rows = await _rows();

      // Alarm settings untouched.
      expect([rows[0]!['hour'], rows[0]!['minute'], rows[0]!['enabled']], [7, 0, 1]);
      expect([rows[1]!['hour'], rows[1]!['minute'], rows[1]!['enabled']], [7, 15, 1]);
      expect([rows[2]!['hour'], rows[2]!['minute'], rows[2]!['enabled']], [6, 0, 0]);
      // The legacy column is preserved for rollback.
      expect(rows[0]!['smart_window_minutes'], 30);
      expect(rows[2]!['smart_window_minutes'], 20);
      // Natural carries the old window, rounded to a 15-minute step.
      expect(rows[0]!['natural_window_minutes'], 30);
      expect(rows[1]!['natural_window_minutes'], 0);
      expect(rows[2]!['natural_window_minutes'], 15);
      // Gradual is never enabled by a migration.
      for (final r in rows.values) {
        expect(r['gradual_window_minutes'], 0);
        expect(r['gradual_pattern'], 'ramp');
        expect(r['gradual_cadence_sec'], kGradualCadenceDefaultSec);
      }
      // Existing Smart Wake users get the explanation first.
      expect(await LocalDb.wakeMetaGet(kWakeUpgradeKey), 'pending');
    });

    test('is idempotent: running the migration again changes nothing, and a '
        'later user choice is not resurrected', () async {
      created.add(name);
      await _seedV55(name);
      await _open(name);
      final once = await _rows();
      await LocalDb.debugRunWakeSplitMigration();
      await LocalDb.debugRunWakeSplitMigration();
      expect(await _rows(), once);

      // The user turns Monday's Natural Wake off, then the app reopens twice.
      await LocalDb.setAlarmScheduleDay(
        weekday: 0, hour: 7, minute: 0, enabled: true,
        smartWindowMinutes: 30, naturalWindowMinutes: 0,
      );
      await _open(name);
      await _open(name);
      expect((await _rows())[0]!['natural_window_minutes'], 0);
      expect(await LocalDb.wakeMetaGet(kWakeUpgradeKey), 'pending');
    });

    test('a user who never used Smart Wake gets no explanation and no '
        'Natural window', () async {
      const n2 = 'openstrap_wake_split_nosmart_test.db';
      created.add(n2);
      await _seedV55(n2, anySmart: false);
      await _open(n2);
      for (final r in (await _rows()).values) {
        expect(r['natural_window_minutes'], 0);
        expect(r['gradual_window_minutes'], 0);
      }
      expect(await LocalDb.wakeMetaGet(kWakeUpgradeKey), isNull);
    });

    test('a fresh install has the new tables and an empty schedule', () async {
      const n3 = 'openstrap_wake_split_fresh_test.db';
      created.add(n3);
      await databaseFactory.deleteDatabase(await _dbPath(n3));
      await _open(n3);
      final db = await LocalDb.instance;
      final tables = (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name'])
          .toSet();
      expect(tables, containsAll(['wake_trace', 'wake_meta', 'alarm_schedule']));
      expect(await LocalDb.alarmScheduleRows(), isEmpty);
    });

    test('same-version self-heal: dropped wake tables come back on open',
        () async {
      const n4 = 'openstrap_wake_split_heal_test.db';
      created.add(n4);
      await databaseFactory.deleteDatabase(await _dbPath(n4));
      await _open(n4);
      var db = await LocalDb.instance;
      await db.execute('DROP TABLE wake_trace');
      await db.execute('DROP TABLE wake_meta');
      await _open(n4);
      db = await LocalDb.instance;
      await db.query('wake_trace');
      await db.query('wake_meta');
    });
  });

  group('stores', () {
    const name = 'openstrap_wake_stores_test.db';

    setUp(() async {
      created.add(name);
      await databaseFactory.deleteDatabase(await _dbPath(name));
      await _open(name);
    });

    test('the trace round-trips in order and is per wake', () async {
      const store = DbWakeTraceStore();
      await store.append(const WakeTraceEntry(
          wakeEpochSec: 1000, atMs: 1, kind: 'plan', data: {'a': 1}));
      await store.append(const WakeTraceEntry(
          wakeEpochSec: 1000, atMs: 2, kind: 'natural', data: {'reason': 'fire'}));
      await store.append(const WakeTraceEntry(
          wakeEpochSec: 2000, atMs: 3, kind: 'plan', data: {}));
      final got = await store.forWake(1000);
      expect(got.map((e) => e.kind), ['plan', 'natural']);
      expect(got.last.data['reason'], 'fire');
      expect((await store.forWake(2000)), hasLength(1));
    });

    test('old nights are pruned when a new wake is traced', () async {
      const store = DbWakeTraceStore();
      const day = 86400;
      await store.append(const WakeTraceEntry(
          wakeEpochSec: 1000000, atMs: 1, kind: 'plan', data: {}));
      await store.append(const WakeTraceEntry(
          wakeEpochSec: 1000000 + 30 * day, atMs: 2, kind: 'plan', data: {}));
      expect(await store.forWake(1000000), isEmpty);
      expect(await store.forWake(1000000 + 30 * day), hasLength(1));
    });

    test('run state survives a reopen', () async {
      const store = DbWakeStateStore();
      expect(await store.load(), isNull);
      await store.save({'wakeEpoch': 5, 'stager': {'v': 1}, 'naturalFired': true});
      await _open(name);
      final back = await store.load();
      expect(back!['wakeEpoch'], 5);
      expect(back['naturalFired'], true);
    });

    test('corrupt stored state reads as absent, not as a crash', () async {
      await LocalDb.wakeMetaSet(kWakeRunStateKey, '{not json');
      expect(await const DbWakeStateStore().load(), isNull);
    });

    test('loadWakeSamples reads the collected 1 Hz store and RR beats, and '
        'omits a NULL hr or accel instead of reading it as zero', () async {
      final db = await LocalDb.instance;
      Future<void> row(int sec, int? hr, double? ax) => db.insert('decoded_onehz', {
            'device_id': '',
            'ts_ms': sec * 1000,
            'rec_ts': sec,
            'counter': sec,
            'hr': hr,
            'ax': ax,
            'ay': ax == null ? null : 0.0,
            'az': ax == null ? null : 1.0,
          });
      await row(100, 55, 0.0);
      await row(101, null, 0.0); // no HR this second
      await row(102, 0, 0.0); // off-skin sentinel is a real value
      await row(103, 57, null); // no accel this second
      await row(200, 60, 0.0); // outside the range
      await db.insert('decoded_rr', {
        'device_id': '', 'ts_ms': 100000, 'rec_ts': 100,
        'beat_index': 0, 'rr_ts_ms': 100000, 'rr_ms': 980,
      });
      final got = await loadWakeSamples(
          DateTime.fromMillisecondsSinceEpoch(100000),
          DateTime.fromMillisecondsSinceEpoch(104000));
      expect(got.hr.map((e) => e[0]), [100000, 102000, 103000]);
      expect(got.hr.map((e) => e[1]), [55, 0, 57]);
      expect(got.accel.map((e) => e[0]), [100000, 101000, 102000]);
      expect(got.rr, [
        [100000.0, 980.0]
      ]);
    });

    test('the upgrade state is stored in wake_meta', () async {
      expect(await loadWakeUpgradeState(), WakeUpgradeState.none);
      await saveWakeUpgradeState(WakeUpgradeState.pending);
      expect(await loadWakeUpgradeState(), WakeUpgradeState.pending);
      await saveWakeUpgradeState(WakeUpgradeState.acknowledged);
      expect(await loadWakeUpgradeState(), WakeUpgradeState.acknowledged);
    });
  });
}
