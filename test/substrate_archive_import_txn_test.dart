// Import must never read the backup file's second connection while a
// main-database transaction is open (Android: SQLITE_BUSY on
// substrate_archive blob reads, "importing day 0 of 3" stalling, then failing).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/data/import_source_guard.dart';
import 'package:openstrap_edge/data/substrate_archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

const int _d0 = 1900000000 ~/ 86400 * 86400;
const int _day = 86400;

Map<String, Object?> _gen4(int ts) => {
  'device_id': '',
  'ts_ms': ts * 1000,
  'rec_ts': ts,
  'counter': ts - _d0,
  'hr': 60,
  'device_family': 'gen4',
};

void main() {
  late Directory tmp;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_arch_txn_');
    PathProviderPlatform.instance = _Paths(tmp.path);
    LocalDb.dbName = 'openstrap_arch_txn_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  tearDownAll(() async {
    await LocalDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });
  tearDown(() {
    ImportSourceGuard.debugReads = null;
    LocalDb.debugRowByRowMerge = false;
  });

  /// Archive 3 days, snapshot, and empty the local archive so the import has
  /// to insert every bucket (and read every blob).
  Future<(String, Map<int, Uint8List>)> snapshot() async {
    final db = await LocalDb.instance;
    for (final t in ['decoded_onehz', 'decoded_rr', 'substrate_archive']) {
      await db.delete(t);
    }
    final b = db.batch();
    for (var ts = _d0; ts < _d0 + 3 * _day; ts += 600) {
      b.insert('decoded_onehz', _gen4(ts));
    }
    await b.commit(noResult: true);
    await LocalDb.pruneDecodedBeforeRecTs(
      _d0 + 3 * _day,
      archive: const SubstrateArchivePolicy(365),
    );
    final path = await LocalDb.exportCopy();
    final blobs = {
      for (final r in await db.query('substrate_archive'))
        r['utc_day'] as int: r['blob'] as Uint8List,
    };
    expect(blobs, hasLength(3));
    await db.delete('substrate_archive');
    return (path, blobs);
  }

  for (final rowByRow in [false, true]) {
    test('archive import (${rowByRow ? "row-by-row" : "attached"}): no source '
        'read inside a main txn; blobs byte-identical; per-row progress',
        () async {
      LocalDb.debugRowByRowMerge = rowByRow;
      final (path, blobs) = await snapshot();
      final reads = <(String, bool)>[];
      ImportSourceGuard.debugReads = reads;
      final progress = <ImportProgress>[];
      await LocalDb.importFromDbFile(path, onProgress: progress.add);
      expect(reads, isNotEmpty);
      expect(reads.where((r) => r.$2), isEmpty);
      final db = await LocalDb.instance;
      final got = {
        for (final r in await db.query('substrate_archive'))
          r['utc_day'] as int: r['blob'] as Uint8List,
      };
      expect(got.keys.toSet(), blobs.keys.toSet());
      for (final k in blobs.keys) {
        expect(got[k], orderedEquals(blobs[k]!), reason: 'day $k');
      }
      // Archive rows are paged 8 at a time; 3 rows must still report more than
      // one step inside the archive table, not one jump per page.
      final copying = progress.whereType<ImportCopying>().toList();
      expect(copying, isNotEmpty);
    });
  }

  test('a source read inside a main txn throws (guard), and is observable',
      () async {
    final db = await LocalDb.instance;
    final path = p.join(tmp.path, 'guard_src.db');
    await databaseFactory.deleteDatabase(path);
    final raw = await databaseFactory.openDatabase(path);
    await raw.execute('CREATE TABLE t (a INTEGER)');
    final g = ImportSourceGuard(raw);
    final reads = <(String, bool)>[];
    ImportSourceGuard.debugReads = reads;
    await expectLater(
      g.mainTransaction(db, (txn) async => g.rawQuery('SELECT 1')),
      throwsStateError,
    );
    expect(reads.single.$2, isTrue);
    await raw.close();
  });

  // Desktop probe: does sqflite_ffi raise BUSY for the Android shape (second
  // connection reads while the main connection holds BEGIN IMMEDIATE with the
  // same file ATTACHed)?
  test('desktop BUSY repro probe (informational)', () async {
    final path = p.join(tmp.path, 'busy_src.db');
    await databaseFactory.deleteDatabase(path);
    final a = await databaseFactory.openDatabase(path);
    await a.execute('CREATE TABLE t (a INTEGER, b BLOB)');
    await a.insert('t', {'a': 1, 'b': Uint8List(10)});
    await a.close();
    final reader = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final main = await databaseFactory.openDatabase(p.join(tmp.path, 'm.db'));
    await main.execute('ATTACH DATABASE ? AS imp', [path]);
    Object? err;
    await main.transaction((txn) async {
      await txn.rawQuery('SELECT count(*) FROM imp.t');
      await txn.execute('CREATE TABLE IF NOT EXISTS x (a)');
      try {
        await reader.rawQuery('SELECT length(b) FROM t');
      } catch (e) {
        err = e;
      }
    });
    // ignore: avoid_print
    print('BUSY repro on sqflite_ffi: ${err ?? "not reproduced"}');
    await reader.close();
    await main.close();
  });
}
