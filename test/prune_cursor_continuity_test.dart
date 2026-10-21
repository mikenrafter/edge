// Lowering `decoded_pruned_before` after an import needs CONTINUITY, not just
// presence: any row in a day used to count as proof the whole day is back. A
// backup that restores 10-09's morning leaves its evening missing, and
// lowering to 10-09 would make a truncated night on 10-10 look whole (edge#305
// could then overwrite a good result with partial-night scalars).
//
// The walk goes down from the cursor and stops at the first hour-aligned
// window with no decoded second (so any gap over 2 h always stops it).

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
    LocalDb.dbName = 'openstrap_prune_cursor_continuity_test.db';
    dbDir = await databaseFactory.getDatabasesPath();
    tmp = await Directory.systemTemp.createTemp('openstrap_cursor_cont_');
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

  /// A source whose decoded_onehz has a second every 30 minutes over each
  /// [spans] entry, given as (startMonthDay-hour, endMonthDay-hour) in local
  /// time: `(day, hourFrom, hourTo)` on month 10, hourTo exclusive.
  var n = 0;
  Future<String> source(List<(int, int, int)> spans) async {
    final path = p.join(tmp.path, 'src_${n++}.db');
    final src = await databaseFactoryFfi.openDatabase(path);
    await src.execute('''CREATE TABLE decoded_onehz (
      device_id TEXT, ts_ms INTEGER, rec_ts INTEGER, counter INTEGER,
      hr INTEGER)''');
    final b = src.batch();
    for (final (d, from, to) in spans) {
      for (var ts = _localSec(10, d, from);
          ts < _localSec(10, d, to);
          ts += 1800) {
        b.insert('decoded_onehz', {
          'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
          'counter': ts, 'hr': 60,
        });
      }
    }
    await b.commit(noResult: true);
    await src.close();
    return path;
  }

  for (final (label, merge) in <(String, Future<Map<String, int>> Function(String))>[
    ('bulk import', LocalDb.importFromDbFile),
    ('row-by-row merge', LocalDb.debugMergeRowByRow),
  ]) {
    group(label, () {
      test('Sol\'s case: 10-09 restored in the morning only, the evening '
          'missing: the cursor stays at 10-10', () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 10)}');
        await merge(await source([(9, 0, 12)]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 10));
      });

      test('the owner\'s continuous 10-05..10-13 is still lowered to 10-05',
          () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        await merge(await source([for (var d = 5; d <= 13; d++) (d, 0, 24)]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 5));
      });

      test('a run broken by a 3 h gap stops above it', () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        // 10-07 has 09:00-12:00 missing, so 10-07 is not whole.
        await merge(await source([
          (5, 0, 24),
          (6, 0, 24),
          (7, 0, 9),
          (7, 12, 24),
          for (var d = 8; d <= 13; d++) (d, 0, 24),
        ]));
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 8));
      });

      test('short dropouts (under the threshold) do not stop the walk',
          () async {
        await LocalDb.setCursor(_cursor, '${_localSec(10, 14)}');
        // 90 minutes missing inside each day: a link drop, not prune damage.
        await merge(await source([
          for (var d = 10; d <= 13; d++) ...[(d, 0, 10), (d, 11, 24)],
        ]));
        // 10:00-11:00 is empty here (a 1 h dropout; rows every 30 min leave
        // a 1.5 h gap between 09:30 and 11:00).
        expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 10));
      });
    });
  }
}
