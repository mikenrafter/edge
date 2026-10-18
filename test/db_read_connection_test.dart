// Screen reads run on their own query-only WAL connection, so a sync commit or
// a derive write holding the writer's transaction open no longer stalls them.
//
// Real (FFI) database in a temp dir. No wall clock: ordering is proven with
// Completers and an event log, never with a delay.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

Future<void> _putSeries(String date, double v) async {
  final db = await LocalDb.instance;
  await db.insert('metric_series', {'date': date, 'key': 'k', 'value': v});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  var n = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('read_conn_');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await dir.delete(recursive: true);
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.readerEnabled = true;
    // The reader exists only in the foreground; the UI sets this on resume.
    await LocalDb.setForeground(true);
    LocalDb.readerOpenerForTest = null;
    LocalDb.dbName = 'read_conn_${n++}.db';
    await _putSeries('2026-08-01', 1);
    await _putSeries('2026-08-02', 2);
  });

  test('a read completes while a write transaction is still open, '
      'and returns only committed rows', () async {
    final db = await LocalDb.instance;
    final inTxn = Completer<void>();
    final log = <String>[];
    List<Map<String, dynamic>>? seen;
    final txn = db.transaction((t) async {
      await t.insert('metric_series', {'date': '2026-08-03', 'key': 'k', 'value': 3});
      inTxn.complete();
      // The writer keeps its transaction open until the read has finished.
      // On a shared handle that read would queue behind this transaction and
      // the two would wait on each other forever.
      seen = await LocalDb.metricSeries('k');
      log.add('read');
    });
    await inTxn.future;
    await txn;
    log.add('commit');
    expect(log, ['read', 'commit']);
    expect([for (final r in seen!) r['date']], ['2026-08-01', '2026-08-02']);
    expect((await LocalDb.metricSeries('k')).length, 3);
  });

  test('with the reader disabled the same read queues behind the transaction',
      () async {
    LocalDb.readerEnabled = false;
    final db = await LocalDb.instance;
    final inTxn = Completer<void>();
    final release = Completer<void>();
    final log = <String>[];
    final txn = db.transaction((t) async {
      await t.insert('metric_series', {'date': '2026-08-03', 'key': 'k', 'value': 3});
      inTxn.complete();
      await release.future;
    }).then((_) => log.add('commit'));
    await inTxn.future;
    final read = LocalDb.metricSeries('k').then((r) {
      log.add('read');
      return r;
    });
    release.complete();
    final rows = await read;
    await txn;
    expect(log, ['commit', 'read']);
    expect(rows.length, 3);
  });

  test('the reader cannot write', () async {
    final w = await LocalDb.instance;
    final r = await LocalDb.reader;
    expect(identical(r, w), isFalse);
    final q = await r.rawQuery('PRAGMA query_only');
    expect(q.first.values.first, 1);
    await expectLater(
      r.insert('metric_series', {'date': '2026-08-09', 'key': 'k', 'value': 9}),
      throwsA(isA<DatabaseException>()),
    );
    expect((await LocalDb.metricSeries('k')).length, 2);
  });

  test('wipe closes the reader; the next read reopens it on the new store',
      () async {
    expect((await LocalDb.metricSeries('k')).length, 2);
    expect(LocalDb.hasReader, isTrue);
    await LocalDb.wipeAll();
    expect(LocalDb.hasReader, isFalse);
    expect(await LocalDb.metricSeries('k'), isEmpty);
    expect(LocalDb.hasReader, isTrue);
    await _putSeries('2026-09-01', 7);
    final rows = await LocalDb.metricSeries('k');
    expect([for (final r in rows) r['date']], ['2026-09-01']);
  });

  test('closing the store closes the reader and a later read reopens both',
      () async {
    await LocalDb.metricSeries('k');
    expect(LocalDb.hasReader, isTrue);
    await LocalDb.close();
    expect(LocalDb.hasReader, isFalse);
    expect((await LocalDb.metricSeries('k')).length, 2);
    expect(LocalDb.hasReader, isTrue);
  });

  test('a reader that cannot open falls back to the writer handle', () async {
    LocalDb.readerOpenerForTest = (_) async => throw StateError('no reader');
    final w = await LocalDb.instance;
    expect(identical(await LocalDb.reader, w), isTrue);
    expect((await LocalDb.metricSeries('k')).length, 2);
    expect(LocalDb.hasReader, isFalse);
  });

  // A failed open must not be retried on every read: each attempt opens a
  // connection, which would make the fallback slower than having no reader.
  test('a failed reader open is not retried until the store changes', () async {
    var opens = 0;
    LocalDb.readerOpenerForTest = (_) async {
      opens++;
      throw StateError('no reader');
    };
    await LocalDb.metricSeries('k');
    await LocalDb.metricSeries('k');
    await LocalDb.metricSeries('k');
    expect(opens, 1);
    await LocalDb.close();
    await LocalDb.metricSeries('k');
    expect(opens, 2, reason: 'a new writer may open a reader again');
  });

  test('reads still work with the reader switched off', () async {
    LocalDb.readerEnabled = false;
    expect(identical(await LocalDb.reader, await LocalDb.instance), isTrue);
    expect((await LocalDb.metricSeries('k')).length, 2);
  });

  // ── foreground-only ────────────────────────────────────────────────────────
  test('a process starts with no reader: background/headless never opens one',
      () async {
    await LocalDb.close();
    LocalDb.debugResetForeground();
    LocalDb.dbName = 'read_conn_${n++}.db';
    await _putSeries('2026-08-01', 1);
    expect((await LocalDb.metricSeries('k')).length, 1);
    expect(LocalDb.hasReader, isFalse);
    expect(identical(await LocalDb.reader, await LocalDb.instance), isTrue);
  });

  test('backgrounding closes the reader and reads use the writer without '
      'reopening it', () async {
    await LocalDb.metricSeries('k');
    expect(LocalDb.hasReader, isTrue);
    await LocalDb.setForeground(false);
    expect(LocalDb.hasReader, isFalse);
    final w = await LocalDb.instance;
    expect(identical(await LocalDb.reader, w), isTrue);
    expect((await LocalDb.metricSeries('k')).length, 2);
    expect((await LocalDb.metricSeries('k')).length, 2);
    expect(LocalDb.hasReader, isFalse);
  });

  test('resuming allows the next read to reopen the reader', () async {
    await LocalDb.setForeground(false);
    await LocalDb.metricSeries('k');
    expect(LocalDb.hasReader, isFalse);
    await LocalDb.setForeground(true);
    expect(LocalDb.hasReader, isFalse, reason: 'lazy: opens on the next read');
    await LocalDb.metricSeries('k');
    expect(LocalDb.hasReader, isTrue);
  });

  test('backgrounding during an in-flight reader open leaves no reader',
      () async {
    final opening = LocalDb.metricSeries('k');
    final bg = LocalDb.setForeground(false);
    await opening;
    await bg;
    expect(LocalDb.hasReader, isFalse);
  });
}
