// ignore_for_file: file_names
// The @SendableShape round trip for the session-windows entry: its input
// carries real sqflite rows, so it owes a real isolate round trip.

import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/session_windows_heavy.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'guards/support/sendability.dart';

Object? _shape(SessionWindowsInput i) => [
      [for (final r in i.rows) Map.of(r)],
      i.sensors,
      i.wearable,
      i.maxHrCeiling,
      i.minHrFloor,
    ];

void main() {
  late Database db;
  late List<Map<String, Object?>> rows;

  setUpAll(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE t (id TEXT, source TEXT, rec_ts INTEGER, hr INTEGER)');
    for (var i = 0; i < 30; i++) {
      await db.insert('t', {
        'id': i < 15 ? 'a' : 'b',
        'source': null,
        'rec_ts': 1000 + i,
        'hr': 60 + i % 7,
      });
    }
    rows = await db.rawQuery('SELECT * FROM t ORDER BY id, rec_ts');
  });

  tearDownAll(() => db.close());
  tearDown(WorkerInit.resetForTest);

  SessionWindowsInput input() => SessionWindowsInput(
      rows: rows,
      sensors: const ['ble-hrs'],
      wearable: null,
      maxHrCeiling: 200,
      minHrFloor: 30);

  test('the input crosses an isolate boundary with every field intact',
      () async {
    await expectIsolateRoundTrip<SessionWindowsInput>(input(), project: _shape);
  });

  test('a worker answers what the same call on this isolate answers',
      () async {
    final inp = input();
    final here = sessionWindowsHeavy(sessionWindowsWorkerInputs, inp);
    WorkerInit.resetForTest();
    final there = await Isolate.run(
        () => sessionWindowsHeavy(sessionWindowsWorkerInputs, inp));
    expect(here.samples.keys.toSet(), {'a', 'b'});
    expect(there.stats, here.stats);
    expect(there.samples, here.samples);
  });
}
