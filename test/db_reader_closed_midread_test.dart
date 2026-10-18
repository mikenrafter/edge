// A screen read grabs the query-only reader, then the app is backgrounded
// (setForeground(false) closes it) or the store is replaced before the query
// runs. The read must come back from the writer, not throw on a closed
// handle. Ordering is proven with Completers, never a delay.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  var n = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('reader_closed_');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await dir.delete(recursive: true);
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.readerEnabled = true;
    await LocalDb.setForeground(true);
    LocalDb.readerOpenerForTest = null;
    LocalDb.dbName = 'reader_closed_${n++}.db';
    final db = await LocalDb.instance;
    await db.insert('metric_series', {'date': '2026-08-01', 'key': 'k', 'value': 1});
  });

  test('a reader closed between fetching the handle and the query retries '
      'once on the writer', () async {
    final w = await LocalDb.instance;
    final fetched = Completer<void>();
    final closed = Completer<void>();
    final seen = <Object>[];
    final read = LocalDb.readerRun((db) async {
      seen.add(db);
      if (seen.length == 1) {
        fetched.complete();
        await closed.future;
      }
      return db.query('metric_series', where: 'key = ?', whereArgs: ['k']);
    });
    await fetched.future;
    expect(identical(seen.first, w), isFalse, reason: 'started on the reader');
    await LocalDb.setForeground(false);
    closed.complete();
    final rows = await read;
    expect(rows.length, 1);
    expect(seen.length, 2);
    expect(identical(seen.last, w), isTrue, reason: 'retried on the writer');
  });

  test('a failure that is not a closed reader is rethrown, not retried',
      () async {
    var calls = 0;
    await expectLater(
      LocalDb.readerRun((db) async {
        calls++;
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(calls, 1);
  });

  test('every screen read goes through readerRun', () {
    final bare = RegExp(r'\bawait\s+(LocalDb\.)?reader\b(?!; // reader-acquire)');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (bare.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
