// The `decoded_pruned_before` cursor says "decoded rows below here are gone".
// It must stay true to that in two places it currently does not:
//
//  * An import that merges complete `decoded_onehz` BELOW the cursor makes the
//    cursor a lie: `windowTruncatedByPrune` then keeps treating whole days as
//    cut, and their derive is declined forever. The import lowers the cursor
//    to the local midnight of the imported MIN(rec_ts).
//  * A prune that deletes nothing has not cut anything, so it must not raise
//    the cursor (on a fresh install the first prune raised it to "today" with
//    nothing below it, and every later import landed under a stale cursor).
//
// Assumed API: none new. The cursor is read with LocalDb.getCursorInt.

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
    LocalDb.dbName = 'openstrap_prune_cursor_import_test.db';
    dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_cursor_');
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

  /// An export whose `decoded_onehz` holds a second at 09:00 on each of the
  /// local days [days] (month 10).
  Future<String> source(List<int> days) async {
    final path = p.join(tmp.path, 'src_${days.first}_${days.last}.db');
    await databaseFactoryFfi.deleteDatabase(path);
    final src = await databaseFactoryFfi.openDatabase(path);
    await src.execute('''CREATE TABLE decoded_onehz (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, counter INTEGER,
      hr INTEGER)''');
    for (final d in days) {
      final ts = _localSec(10, d, 9);
      await src.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
        'counter': ts, 'hr': 60,
      });
    }
    await src.close();
    return path;
  }

  for (final (label, merge) in <(String, Future<Map<String, int>> Function(String))>[
    ('bulk import', LocalDb.importFromDbFile),
    ('row-by-row merge', LocalDb.debugMergeRowByRow),
  ]) {
    group(label, () {
      test('lowers an advanced cursor to the local midnight of the imported '
          'MIN(rec_ts)', () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        await merge(await source([7, 8, 9, 10, 11, 12, 13]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 7),
            reason: 'rows for 10-07..10-13 are whole below a cursor of 10-14');
      });

      test('leaves a cursor that is already below the imported rows alone',
          () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 1)}');
        await merge(await source([7, 8]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 1));
      });

      test('does not invent a cursor when there was none', () async {
        await merge(await source([7, 8]));
        expect(await LocalDb.getCursorInt(_cursor), isNull);
      });
    });
  }

  group('a prune that deletes nothing', () {
    Future<void> insertSecond(int ts) async {
      final db = await LocalDb.instance;
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
        'counter': ts, 'hr': 60, 'device_family': 'gen4',
      });
    }

    test('does not raise the cursor', () async {
      // Everything on disk is at or after the cutoff: nothing to cut.
      await insertSecond(_localSec(10, 10, 9));
      final deleted = await LocalDb.pruneDecodedBeforeRecTs(
        _localSec(10, 5),
        cursorName: _cursor,
      );
      expect(deleted, 0, reason: 'precondition: nothing was below the cutoff');
      expect(await LocalDb.getCursorInt(_cursor), isNull,
          reason: 'nothing was cut, so nothing is "pruned before" the cutoff');
    });

    test('control: a prune that does delete raises it to the cutoff',
        () async {
      await insertSecond(_localSec(10, 3, 9));
      await insertSecond(_localSec(10, 10, 9));
      await LocalDb.pruneDecodedBeforeRecTs(
        _localSec(10, 5),
        cursorName: _cursor,
      );
      expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 5));
    });
  });
}
