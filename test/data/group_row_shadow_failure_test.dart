// Group rows are shadow: a failure writing them must never fail or roll back
// the day_result write, and must leave no half-written set.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(dropDb);

  Future<bool> put(String day) => LocalDb.putDayResult(
        dayId: day,
        algoVersion: 500,
        payloadJson: jsonEncode({
          'date': day,
          'sleep': {'a': 1},
          'scalars': {'rhr': 50.0},
        }),
        windowJson: '{}',
        series: const {'rhr': 50.0},
      );

  test('a group_row write failure keeps day_result and leaves no rows',
      () async {
    final db = await freshDb('group_row_shadow_failure.db');
    // Let the first group's row in, fail the second: a part-way failure.
    await db.execute('CREATE TRIGGER gr_boom BEFORE INSERT ON group_row '
        'WHEN (SELECT COUNT(*) FROM group_row) >= 1 '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END");
    final before = groupRowDiagnostics.unsliceable;
    expect(await put('2026-03-10'), isTrue);
    expect(await db.query('day_result'), hasLength(1));
    expect((await db.query('metric_series')), isNotEmpty);
    expect(await db.query('group_row'), isEmpty);
    expect(groupRowDiagnostics.unsliceable, before + 1);
    expect(groupRowDiagnostics.lastProblem, contains('boom'));
  });

  test('after the failure is gone the next write stores the rows', () async {
    final db = await freshDb('group_row_shadow_failure2.db');
    expect(await put('2026-03-10'), isTrue);
    expect(await db.query('group_row'), isNotEmpty);
  });
}
