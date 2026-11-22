// WHY (fix round 1, F5): the measured-series reads build their "imported day"
// exclusion set from `importedDates`. It must not walk every stored day bundle:
// once the foreground maintenance has run, the read comes off a small partial
// index of the imported rows. It keeps the fork's rules: the SERVED version
// decides (a band re-derive of an imported day makes it measured), a non-band
// stamp in `metric_series_version` marks a day imported, and the flag is the
// payload's top-level boolean only (the same test as `finalizedDayIds`).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/finalized_day_index_maintenance.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _sql = <String>[];

Future<void> _put(String day, int version, String payload) =>
    LocalDb.putDayResult(
        dayId: day,
        algoVersion: version,
        payloadJson: payload,
        windowJson: '{}',
        finalized: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
        options: SqfliteLoggerOptions(log: (e) {
      if (e is SqfliteLoggerSqlEvent) _sql.add(e.sql);
    }));
  });
  tearDown(() => LocalDb.close());

  test('imported days: served version, source stamp and exact flag; read off '
      'the partial index once maintenance has built it', () async {
    await LocalDb.close();
    await LocalDb.setForeground(true);
    LocalDb.dbName = 'imported_dates_index.db';
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    final db = await LocalDb.instance;
    await _put('2026-02-01', 7, '{"imported":true}');
    await _put('2026-02-02', 7, '{}');
    // The substring appears but the flag is not the payload's own boolean.
    await _put('2026-02-03', 7, '{"nested":{"imported":true}}');
    // An imported snapshot the band later re-derived: the served version wins.
    await _put('2026-02-04', 6, '{"imported":true}');
    await _put('2026-02-04', 7, '{}');
    // A non-band stamp marks the day imported whatever its bundle says.
    await _put('2026-02-05', 7, '{}');
    await db.insert('metric_series_version',
        {'date': '2026-02-05', 'algo_version': 7, 'source': 'other_vendor'});
    final expected = {'2026-02-01', '2026-02-05'};

    expect(await LocalDb.importedDates(), expected,
        reason: 'before the index exists');
    await const FinalizedDayIndexMaintenance().call();
    expect(
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_day_result_imported'"),
        hasLength(1),
        reason: 'maintenance builds the imported-day index');
    _sql.clear();
    expect(await LocalDb.importedDates(), expected,
        reason: 'after the index exists');
    final read = _sql.lastWhere(
        (s) => s.contains('metric_series_version') && s.contains('UNION'));
    final plan = (await db.rawQuery('EXPLAIN QUERY PLAN $read'))
        .map((r) => r['detail'])
        .join(' | ');
    expect(plan, contains('idx_day_result_imported'));
  });
}
