// WHY: the band waits on this transaction before it is ACKed, so any statement
// in it that scans a history table or walks only the device_id prefix of a
// composite key costs time per chunk that grows with the retained window. The
// arrival lookup did exactly that unnoticed. This records every statement a
// real band-chunk commit runs inside its transaction, plans each one on the
// same database and names the offenders.
// PROVES: CLAIM(ack-commit-plans-bounded).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/processing_context.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef _Stmt = ({String sql, List<Object?> args});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var inTxn = false;
  final txns = <List<_Stmt>>[];
  late String path;

  void take(String sql, Object? args) {
    if (!inTxn) return;
    txns.last.add((sql: sql, args: args is List ? List<Object?>.of(args) : const []));
  }

  setUpAll(() {
    sqfliteFfiInit();
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
        options: SqfliteLoggerOptions(log: (e) {
      if (e is SqfliteLoggerBatchEvent) {
        for (final o in e.operations) {
          take(o.sql, o.arguments);
        }
      } else if (e is SqfliteLoggerSqlEvent) {
        if (e.sql.startsWith('BEGIN')) {
          inTxn = true;
          txns.add([]);
        } else if (e.sql.startsWith('COMMIT') || e.sql.startsWith('ROLLBACK')) {
          inTxn = false;
        } else {
          take(e.sql, e.arguments);
        }
      }
    }));
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'ack_commit_plan_guard.db';
    path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
    await databaseFactory.deleteDatabase(path);
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
  });

  test('no statement in the band chunk commit scans history or walks a key prefix', () async {
    final base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200;
    RawRecord raw(int i) => RawRecord(
        counter: i,
        packetType: 47,
        hex: '2f18${i.toRadixString(16).padLeft(8, '0')}',
        recTs: base + i,
        capturedAt: 5000);
    Sample sample(int i) =>
        Sample(tsEpoch: base + i, counter: i, hr: 70, rrIntervalsMs: [800]);
    Future<void> chunk(int from) => LocalDb.commitSyncBatch(
        [for (var i = from; i < from + 5; i++) raw(i)],
        [for (var i = from; i < from + 5; i++) sample(i)],
        trimToken: '0011223344556677',
        processingOrigin: ProcessingOrigin.recentSync);
    // The first chunk creates the cursors and the coverage interval; the
    // second is the steady state every later chunk repeats.
    await chunk(1);
    await chunk(100);
    // The chunk commit is the transaction that writes the capture-freshness
    // marker, its last statement; a separate transaction after it is not it.
    final commit = txns.lastWhere(
        (t) => t.any((s) => !s.sql.startsWith('SELECT') && s.sql.contains('compute_freshness')),
        orElse: () => const []);
    expect(commit, isNotEmpty, reason: 'did not find the chunk commit transaction');
    final captured = commit;

    final db = await LocalDb.instance;
    final scan = RegExp(r'^SCAN (TABLE )?(decoded_\w+|\w*raw\w*|\w*history\w*)\b');
    final prefix = RegExp(r'^SEARCH .*\(device_id=\?\)$');
    final offenders = <String>[];
    for (final s in captured) {
      final head = s.sql.trimLeft().toUpperCase();
      final planned = head.startsWith('SELECT') ||
          head.startsWith('UPDATE') ||
          head.startsWith('DELETE') ||
          head.startsWith('WITH') ||
          (head.startsWith('INSERT') && head.contains('SELECT'));
      if (!planned) continue;
      final plan = await db.rawQuery('EXPLAIN QUERY PLAN ${s.sql}', s.args);
      for (final r in plan) {
        final d = r['detail'].toString();
        if (scan.hasMatch(d) || prefix.hasMatch(d)) {
          offenders.add('$d\n    in: ${s.sql.replaceAll(RegExp(r"\s+"), " ")}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'unbounded plans inside the ACK-gating transaction:\n'
            '${offenders.join("\n")}');
  });
}
