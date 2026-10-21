// Lowering `decoded_pruned_before` after an import must not forget prune
// holes. The cursor drops only across the unbroken run of local days that have
// decoded rows, running down from the cursor's day; the first day without rows
// stops the walk (a non-wear day just keeps the cursor higher, which is the
// conservative side). A restore also never erases a local prune claim by
// replacing the cursor with the backup's lower one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _cursor = 'decoded_pruned_before';

int _localSec(int month, int day, [int hour = 0]) =>
    DateTime(2026, month, day, hour).millisecondsSinceEpoch ~/ 1000;

void main() {
  late Directory tmp;
  late String dbDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    LocalDb.dbName = 'openstrap_prune_cursor_holes_test.db';
    dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_cursor_holes_');
  });
  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });
  setUp(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dbDir, LocalDb.dbName));
    SharedPreferences.setMockInitialValues({});
    await LocalDb.instance;
  });

  var n = 0;
  Future<String> source(List<int> days, {int? cursor}) async {
    final path = p.join(tmp.path, 'src_${n++}.db');
    final src = await databaseFactoryFfi.openDatabase(path);
    await src.execute('''CREATE TABLE decoded_onehz (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, counter INTEGER,
      hr INTEGER)''');
    await src.execute('''CREATE TABLE sync_cursor (
      name TEXT PRIMARY KEY, value TEXT, updated_at INTEGER NOT NULL)''');
    for (final d in days) {
      final ts = _localSec(10, d, 9);
      await src.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
        'counter': ts, 'hr': 60,
      });
    }
    if (cursor != null) {
      await src.insert('sync_cursor',
          {'name': _cursor, 'value': '$cursor', 'updated_at': 1});
    }
    await src.close();
    return path;
  }

  Future<void> localRow(int day, int hour) async {
    final ts = _localSec(10, day, hour);
    await (await LocalDb.instance).insert('decoded_onehz', {
      'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts, 'counter': ts,
      'hr': 60, 'device_family': 'gen4',
    });
  }

  for (final (label, merge) in <(String, Future<Map<String, int>> Function(String))>[
    ('bulk import', LocalDb.importFromDbFile),
    ('row-by-row merge', LocalDb.debugMergeRowByRow),
  ]) {
    group(label, () {
      test('the hole case: 10-09 was pruned, an old backup restores '
          '10-01..10-02, the cursor stays above the hole', () async {
        await localRow(10, 20); // the partly kept evening of 10-10
        await LocalDb.setCursor(_cursor, '${_localSec(10, 10)}');
        await merge(await source([1, 2]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 10));
      });

      test('a backup\'s own lower cursor does not replace the local one',
          () async {
        await localRow(10, 20);
        await LocalDb.setCursor(_cursor, '${_localSec(10, 10)}');
        await merge(await source([1, 2], cursor: _localSec(10, 3)));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 10));
      });

      test('the owner\'s case: a whole run 10-05..10-13 below a 10-14 cursor '
          'lowers to 10-05', () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        await merge(await source([5, 6, 7, 8, 9, 10, 11, 12, 13]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 5));
      });

      test('a hole in the middle of the imported range: lowered only to the '
          'day after the hole', () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        await merge(await source([5, 6, 8, 9, 10, 11, 12, 13]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 8));
      });

      test('no rows on the day just below the cursor: no lowering at all',
          () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        await merge(await source([5, 6, 7, 8]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 14));
      });
    });
  }
}
