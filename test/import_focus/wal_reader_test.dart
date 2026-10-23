// Import focus: the screen-read WAL connection (LocalDb.reader, commit
// ae149954) is closed for the focus window and reopens lazily after it. While
// focus is active a reader request answers with the writer and opens nothing.
//
// Observed through LocalDb.hasReader and LocalDb.reader only; the close itself
// is driven by ImportFocus.enter()/leave() (void, so the test lets the event
// queue drain before looking).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/import_focus.dart';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  var n = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('import_focus_wal_');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await LocalDb.close();
    await dir.delete(recursive: true);
  });
  setUp(() async {
    await LocalDb.close();
    ImportFocus.debugReset();
    LocalDb.readerEnabled = true;
    await LocalDb.setForeground(true);
    LocalDb.readerOpenerForTest = null;
    LocalDb.dbName = 'import_focus_wal_${n++}.db';
    await LocalDb.instance;
  });
  tearDown(() async {
    ImportFocus.debugReset();
    LocalDb.debugResetForeground();
  });

  test('precondition: a screen read opens the reader', () async {
    await LocalDb.reader;
    expect(LocalDb.hasReader, isTrue);
  });

  test('entering focus closes an open reader', () async {
    await LocalDb.reader;
    expect(LocalDb.hasReader, isTrue);
    ImportFocus.enter();
    await _settle();
    expect(LocalDb.hasReader, isFalse);
  });

  test('while focus is active a reader request is the writer and opens none',
      () async {
    ImportFocus.enter();
    await _settle();
    final writer = await LocalDb.instance;
    final r = await LocalDb.reader;
    expect(identical(r, writer), isTrue);
    expect(LocalDb.hasReader, isFalse,
        reason: 'a read during the import must not reopen the reader');
  });

  test('leaving focus lets the reader open again', () async {
    await LocalDb.reader;
    ImportFocus.enter();
    await _settle();
    expect(LocalDb.hasReader, isFalse, reason: 'closed for the window');
    ImportFocus.leave();
    await _settle();
    final r = await LocalDb.reader;
    expect(LocalDb.hasReader, isTrue);
    expect(identical(r, await LocalDb.instance), isFalse,
        reason: 'a separate query-only connection again');
  });
}
