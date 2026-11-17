// A screen read grabs the query-only reader, then the app is backgrounded
// (setForeground(false) closes it) or the store is replaced before the query
// runs. Main's leased reader must finish that read before closing the handle.
// Ordering is proven with Completers, never a delay.
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

  test('background retirement waits for a leased reader query to finish', () async {
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
    final retiring = LocalDb.setForeground(false);
    // Main's leased reader owns the handle across callback awaits. Releasing
    // the query must precede awaiting retirement, as for any in-flight read.
    closed.complete();
    final rows = await read;
    await retiring;
    expect(rows.length, 1);
    expect(seen.length, 1, reason: 'the leased handle stays usable through the query');
    expect((seen.single as Database).isOpen, isFalse);
    expect(w.isOpen, isTrue, reason: 'backgrounding closes only the reader');
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
    final bare = RegExp(r'\b(?:LocalDb\.reader|await\s+reader)\b(?!Run)(?!; // reader-acquire)');
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
