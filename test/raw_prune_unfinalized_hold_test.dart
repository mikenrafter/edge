// WHY: a transiently failed nine-day-old day must retain live input for retry.
// CLAIM(raw-hold): this uses the public selector and the real SQLite delete,
// with exactly the no-result state a timed-out preparation leaves behind.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('nine-day unfinalized input remains live for a transient-failure retry', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'raw_prune_unfinalized_hold_test.db';
    final path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
    addTearDown(() async {
      await LocalDb.close();
      await databaseFactory.deleteDatabase(path);
    });
    final db = await LocalDb.instance;
    final old = DateTime(2026, 10, 1, 1).millisecondsSinceEpoch ~/ 1000;
    final edge = DateTime(2026, 10, 10, 12).millisecondsSinceEpoch ~/ 1000;
    for (final ts in [old, edge]) {
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
        'counter': ts, 'hr': 65,
      });
    }
    final finalized = await LocalDb.finalizedDayIds(kAlgoVersion);
    expect(finalized, isEmpty);
    expect(await LocalDb.dayResult('2026-10-01'), isNull);
    final cutoff = DerivationEngine.rawPruneCutoffSec(
      dataNowSec: edge,
      rawDayIds: const ['2026-10-01', '2026-10-10'],
      finalizedDayIds: finalized,
    );
    expect(cutoff, isNotNull);
    await LocalDb.pruneDecodedBeforeRecTs(cutoff!);
    expect(await db.query('decoded_onehz', where: 'rec_ts = ?', whereArgs: [old]),
        hasLength(1), reason: 'the derive retry reads live input, not the archive');
  });
}
