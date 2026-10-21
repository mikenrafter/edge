// The cursor must be lowered AFTER every table has merged, sync_cursor
// included. A source file carrying a stale `decoded_pruned_before` (the
// owner's broken export has 1791957600) used to reinstate it through the
// sync_cursor INSERT OR REPLACE that runs after the lowering hook.
//
// Contract: after an import, the cursor is never above the local midnight of
// the oldest decoded_onehz second present in the database.

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
    LocalDb.dbName = 'openstrap_prune_cursor_order_test.db';
    dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_cursor_order_');
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

  /// An export whose decoded rows are on [days] and whose sync_cursor holds a
  /// pruned-before far above all of them.
  Future<String> source(List<int> days, int staleCursor) async {
    final path = p.join(tmp.path, 'src_${days.first}.db');
    await databaseFactoryFfi.deleteDatabase(path);
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
    await src.insert('sync_cursor',
        {'name': _cursor, 'value': '$staleCursor', 'updated_at': 1});
    await src.close();
    return path;
  }

  for (final (label, merge) in <(String, Future<Map<String, int>> Function(String))>[
    ('bulk import', LocalDb.importFromDbFile),
    ('row-by-row merge', LocalDb.debugMergeRowByRow),
  ]) {
    group(label, () {
      test('a stale source cursor above its own rows does not survive',
          () async {
        await merge(await source([7, 8, 9], _localSec(10, 20)));
        final c = await LocalDb.getCursorInt(_cursor);
        expect(c, isNotNull, reason: 'the cursor row itself still arrives');
        expect(c! <= _localSec(10, 7), isTrue,
            reason: 'cursor $c is above the oldest imported day (10-07)');
      });

      test('a source cursor at or below its rows is kept as written', () async {
        await merge(await source([7, 8, 9], _localSec(10, 3)));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 3));
      });
    });
  }
}
