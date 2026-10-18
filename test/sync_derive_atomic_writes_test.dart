// Write sequences on the sync / derive paths run as ONE transaction: a failure
// part-way leaves none of them behind (and a sync/derive pass takes the writer
// once instead of interleaving single statements with screen reads).
//
// A BEFORE-INSERT/DELETE trigger raises on the LAST statement of each
// sequence; the earlier statements must roll back with it. No wall clock.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ble/live_step_runs.dart' show kStepSourceStrap;
import 'package:openstrap_edge/data/db.dart';

Future<int> _count(String table, [String where = '1=1']) async {
  final db = await LocalDb.instance;
  return Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM $table WHERE $where'),
      ) ??
      -1;
}

Future<void> _failOn(String sql) async {
  final db = await LocalDb.instance;
  await db.execute(sql);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  var n = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('atomic_writes_');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await dir.delete(recursive: true);
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'atomic_${n++}.db';
  });

  test('insertEvent: a failing band_events row takes the events row with it',
      () async {
    await _failOn('CREATE TRIGGER t BEFORE INSERT ON band_events '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.insertEvent(1, 1000, 'aa', deviceId: LocalDb.kPrimaryDeviceId,
          receivedAt: DateTime.fromMillisecondsSinceEpoch(5)),
      throwsA(anything),
    );
    expect(await _count('events'), 0);
  });

  test('appendWakeTrace: a failing prune takes the appended row with it',
      () async {
    final db = await LocalDb.instance;
    await db.insert('wake_trace', {
      'wake_epoch': 10, 'at_ms': 1, 'kind': 'old', 'data_json': '{}',
    });
    await _failOn('CREATE TRIGGER t BEFORE DELETE ON wake_trace '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.appendWakeTrace(
          wakeEpochSec: 10 + 15 * 86400, atMs: 2, kind: 'new', dataJson: '{}'),
      throwsA(anything),
    );
    expect(await _count('wake_trace', "kind = 'new'"), 0);
  });

  test('pruneNotifFired: a failing gesture prune undoes the dated prune',
      () async {
    final db = await LocalDb.instance;
    await db.insert('notif_fired', {'key': '2020-01-01|x', 'fired_at': 1});
    await db.insert('notif_fired', {'key': 'gesture:old', 'fired_at': 1});
    await _failOn('CREATE TRIGGER t BEFORE DELETE ON notif_fired '
        "WHEN old.key LIKE 'gesture:%' BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.pruneNotifFired('2021-01-01', nowMs: 10 * 365 * 86400 * 1000),
      throwsA(anything),
    );
    expect(await _count('notif_fired', "key = '2020-01-01|x'"), 1);
  });

  test('putDerivedSessionWrites: a failing suggestion undoes the HRR updates',
      () async {
    final db = await LocalDb.instance;
    await db.insert('sessions', {
      'id': 's1', 'start_ts': 1, 'type': 'run', 'status': 'done', 'created_at': 1,
    });
    await _failOn('CREATE TRIGGER t BEFORE INSERT ON workout_suggestions '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.putDerivedSessionWrites(
        hrr: [('s1', 31.5)],
        suggestions: [
          {
            'id': 'a', 'date': '2026-01-01', 'start_ts': 1, 'end_ts': 2,
            'created_at': 3,
          },
        ],
      ),
      throwsA(anything),
    );
    expect(await _count('sessions', 'hrr_bpm IS NOT NULL'), 0);
  });

  test('putDerivedSessionWrites: all writes land together', () async {
    final db = await LocalDb.instance;
    await db.insert('sessions', {
      'id': 's1', 'start_ts': 1, 'type': 'run', 'status': 'done', 'created_at': 1,
    });
    await LocalDb.putDerivedSessionWrites(
      hrr: [('s1', 31.5)],
      suggestions: [
        {'id': 'a', 'date': '2026-01-01', 'start_ts': 1, 'end_ts': 2, 'created_at': 3},
      ],
    );
    expect(await _count('sessions', 'hrr_bpm = 31.5'), 1);
    expect(await _count('workout_suggestions'), 1);
  });

  test('putBaselines: a failing second row undoes the first', () async {
    await _failOn('CREATE TRIGGER t BEFORE INSERT ON baselines '
        "WHEN new.key = 'rolling' BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.putBaselines({'rolling_artifact': '{}', 'rolling': '{}'}),
      throwsA(anything),
    );
    expect(await _count('baselines', "key = 'rolling_artifact'"), 0);
  });

  test('addLiveCoverageRuns: a failing run undoes the runs before it',
      () async {
    await _failOn('CREATE TRIGGER t BEFORE INSERT ON live_coverage '
        "WHEN new.steps = 99 BEGIN SELECT RAISE(ABORT, 'boom'); END");
    await expectLater(
      LocalDb.addLiveCoverageRuns([
        (startTs: 1000, endTs: 1100, steps: 50, day: '2026-01-01'),
        (startTs: 2000, endTs: 2100, steps: 99, day: '2026-01-01'),
      ], source: kStepSourceStrap),
      throwsA(anything),
    );
    expect(await _count('live_coverage'), 0);
  });

  test('addLiveCoverageRuns: sanitizes like addLiveCoverage (zero steps skipped)',
      () async {
    await LocalDb.addLiveCoverageRuns([
      (startTs: 1000, endTs: 1100, steps: 50, day: '2026-01-01'),
      (startTs: 2000, endTs: 2100, steps: 0, day: '2026-01-01'),
    ], source: kStepSourceStrap);
    expect(await _count('live_coverage'), 1);
  });
}
