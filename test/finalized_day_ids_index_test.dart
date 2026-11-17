// WHY: imported-day classification must depend on the top-level boolean, and
// the lookup must use a covering index without another day_result writer.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/finalized_day_index_maintenance.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/import_gate.dart';

const _algo = 7;
final _maintenanceConnections = <Database>[];
const _expr = "CASE WHEN json_valid(payload_json) THEN "
    "COALESCE(json_type(payload_json, '\$.imported') = 'true', 0) ELSE 0 END";

Future<void> _fresh(String name) async {
  await LocalDb.close();
  await LocalDb.setForeground(true);
  LocalDb.dbName = name;
  await databaseFactory.deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
}
Future<void> _put(String day, String payload, {bool finalized = true}) =>
    LocalDb.putDayResult(dayId: day, algoVersion: _algo, payloadJson: payload,
      windowJson: '{}', finalized: finalized);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    // Observe real handles, including a failed SQL statement's cleanup.
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
      options: SqfliteLoggerOptions(log: (e) {
        if (e is SqfliteLoggerDatabaseOpenEvent &&
            e.options?.singleInstance == false && e.db != null) {
          _maintenanceConnections.add(e.db!);
        }
      }));
  });
  tearDown(() => LocalDb.close());

  // WHY: native SQL errors must not leak a connection or keep sync/import shut.
  // CLAIM(index-sync-exclusion); catches: close/release only on success.
  test('a refused index build closes its connection and releases the gate', () async {
    await _fresh('finalized_index_failure.db');
    final db = await LocalDb.instance;
    await db.execute('CREATE TABLE idx_day_result_finalized_payload (id INTEGER)');
    final before = _maintenanceConnections.length;
    await const FinalizedDayIndexMaintenance().call();
    expect(_maintenanceConnections.length, before + 1);
    expect(_maintenanceConnections.last.isOpen, isFalse);
    expect(ImportGate.check('after failed build'), isA<SyncAllowed>());
    await db.execute('DROP TABLE idx_day_result_finalized_payload');
    await const FinalizedDayIndexMaintenance().call();
    expect(_maintenanceConnections.last.isOpen, isFalse);
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_day_result_finalized_payload'"), hasLength(1));
    await LocalDb.setForeground(false);
    final closedCount = _maintenanceConnections.length;
    await const FinalizedDayIndexMaintenance().call();
    expect(_maintenanceConnections.length, closedCount);
  });

  // WHY: CREATE INDEX owns the WAL writer lock. Maintenance must yield to a
  // live drain/import/headless task rather than risking the ACK-gating commit.
  // CLAIM(index-sync-exclusion); catches: starting maintenance without gates.
  for (final owner in ['drain', 'import', 'headless']) {
    test('index maintenance skips an active $owner and retries later', () async {
      await _fresh('finalized_gate_$owner.db');
      ImportGate.resetForTest();
      HeadlessSyncGate.resetForTest();
      final db = await LocalDb.instance;
      final drain = Object();
      try {
        if (owner == 'drain') ImportGate.drainChanged(drain, true);
        if (owner == 'import') ImportGate.enter();
        if (owner == 'headless') {
          await HeadlessSyncGate.tryRun('index-test', () async {
            await const FinalizedDayIndexMaintenance().call();
            return true;
          });
        } else {
          await const FinalizedDayIndexMaintenance().call();
        }
        expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'idx_day_result_finalized_payload'"), isEmpty);
      } finally {
        ImportGate.drainChanged(drain, false);
        ImportGate.leave();
      }
      await const FinalizedDayIndexMaintenance().call();
      expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'idx_day_result_finalized_payload'"), hasLength(1));
    });
  }

  test('top-level boolean only; parity with main for canonical row shapes', () async {
    await _fresh('finalized_shapes.db');
    final db = await LocalDb.instance;
    final shapes = <String, bool>{
      '{}': false, '{"imported":true}': true, '{"imported":false}': false,
      '{"nested":{"imported":true}}': false,
      jsonEncode({'note': '"imported":true'}): false,
      '{"not_imported":true}': false, '{"imported":1}': false,
      '{"imported":"true"}': false, '{"imported":null}': false,
      '{ "imported" : true }': true, 'invalid JSON': false,
    };
    var n = 0;
    final expected = <String>{};
    for (final entry in shapes.entries) {
      final day = '2026-01-${(++n).toString().padLeft(2, '0')}';
      await _put(day, entry.key);
      if (!entry.value) expected.add(day);
      final official = await db.rawQuery(
        'SELECT ? LIKE \'%"imported":true%\' AS imported', [entry.key]);
      // Main's actual trigger expression has two known bugs: nested keys and
      // noncanonical spacing. Those differences are intentional corrections.
      if (entry.key != '{"nested":{"imported":true}}' &&
          entry.key != '{ "imported" : true }') {
        expect(official.single['imported'], entry.value ? 1 : 0, reason: entry.key);
      }
    }
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    await LocalDb.putDayResult(dayId: '2026-01-02', algoVersion: _algo,
      payloadJson: '{}', windowJson: '{}', finalized: true,
      reason: DayResultWrite.userOverride); // authorized replacement of a frozen row
    expected.add('2026-01-02');
    expect(await LocalDb.finalizedDayIds(_algo), expected);
  });

  test('open/read do not create an index or triggers; explicit maintenance is indexed', () async {
    await _fresh('finalized_index.db');
    final db = await LocalDb.instance;
    for (var i = 0; i < 450; i++) {
      await _put('d$i', i % 3 == 0 ? '{"imported":true}' : '{}', finalized: i % 5 != 0);
    }
    final expected = {for (var i = 0; i < 450; i++) if (i % 3 != 0 && i % 5 != 0) 'd$i'};
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE name LIKE 'idx_day_result_finalized%'"), isEmpty);
    // This API is invoked after the first painted frame in the app. SQLite
    // executes the atomic CREATE INDEX on its worker; retry is idempotent.
    await const FinalizedDayIndexMaintenance().call();
    await const FinalizedDayIndexMaintenance().call();
    expect(await LocalDb.finalizedDayIds(_algo), expected);
    final plan = await db.rawQuery('EXPLAIN QUERY PLAN SELECT day_id FROM day_result '
      'WHERE algo_version = ? AND finalized = 1 AND ($_expr) = 0', [_algo]);
    expect(plan.map((r) => r['detail']).join(' '), contains('idx_day_result_finalized_payload'));
    // SQLite labels expression indexes as INDEX, even when they cover the
    // lookup. Inspect VM opcodes to prove no payload table column is fetched.
    final vm = await db.rawQuery('EXPLAIN SELECT day_id FROM day_result '
      'WHERE algo_version = ? AND finalized = 1 AND ($_expr) = 0', [_algo]);
    final tableCursor = vm.singleWhere((r) => r['opcode'] == 'OpenRead' && r['p4'] != null && !'${r['p4']}'.startsWith('k('))['p1'];
    expect(vm.where((r) => r['opcode'] == 'Column' && r['p1'] == tableCursor), isEmpty);
    expect(await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'trg_day_result_imported_%'"), isEmpty);
    await db.execute('DROP INDEX idx_day_result_finalized_payload');
    await const FinalizedDayIndexMaintenance().call();
    expect(await LocalDb.finalizedDayIds(_algo), expected);
  });
}
