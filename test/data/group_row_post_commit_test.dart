// Design 06 1d, Sol r1: group rows are written AFTER the day_result
// transaction commits, in their own small transaction, from a stamp captured
// BEFORE the derive prepared its inputs.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/db/group_row_store.dart';
import 'package:openstrap_edge/data/db/input_revision_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/frozen_day_result_fixtures.dart' show freshDb, dropDb;

const String _day = '2026-03-10';

Map<String, Object?> _bundle() => {
      'date': _day,
      'sleep': {'a': 1},
      'scalars': <String, Object?>{'rhr': 50.0},
    };

Future<bool> _put({InputStamp? stamp, int version = 500}) =>
    LocalDb.putDayResult(
      dayId: _day,
      algoVersion: version,
      payloadJson: jsonEncode(_bundle()),
      windowJson: '{}',
      series: const {'rhr': 50.0},
      inputStamp: stamp,
    );

Future<Map> _stamp(Database db, String group) async {
  final r = await db.query('group_row',
      where: 'day_id = ? AND group_id = ?', whereArgs: [_day, group]);
  return jsonDecode(r.single['input_stamp_json'] as String) as Map;
}

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => db = await freshDb('group_row_post_commit.db'));
  tearDownAll(dropDb);

  test('a group_row failure cannot touch the committed day_result', () async {
    await db.execute('CREATE TRIGGER gr_boom BEFORE INSERT ON group_row '
        "BEGIN SELECT RAISE(ABORT, 'boom'); END");
    final before = groupRowDiagnostics.unsliceable;
    expect(await _put(), isTrue);
    expect(await db.query('day_result'), hasLength(1));
    expect(await db.query('group_row'), isEmpty);
    expect(groupRowDiagnostics.unsliceable, before + 1);
  });

  test('the stored stamp is the one captured before the inputs moved',
      () async {
    final stamp = await captureInputStamp(_day);
    // Moves between prepare and write: a decoded bucket and a day-scoped
    // input.
    await db.insert('input_rev', {
      'bucket': DateTime(2026, 3, 10, 12).millisecondsSinceEpoch ~/ 900000,
      'rev': 7,
    });
    await bumpInputRev('sleep_override', _day);
    expect(await _put(stamp: stamp), isTrue);
    final s = await _stamp(db, 'sleep.stage');
    expect(s.containsKey('decoded'), isFalse, reason: 'pre-bump decoded');
    expect(s.containsKey('sleep_override'), isFalse);
    expect(s.containsKey('_unpinned'), isFalse);
  });

  test('a writer with no stamp is marked unpinned (never reusable)',
      () async {
    await bumpInputRev('sleep_override', _day);
    expect(await _put(), isTrue);
    final s = await _stamp(db, 'sleep.stage');
    expect(s['_unpinned'], isTrue);
    for (final r in await db.query('group_row')) {
      expect(jsonDecode(r['input_stamp_json'] as String)['_unpinned'], isTrue,
          reason: '${r['group_id']}');
    }
  });

  test('refused writes write nothing, even with a stamp', () async {
    final stamp = await captureInputStamp(_day);
    await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: 500,
        payloadJson: jsonEncode(_bundle()),
        windowJson: '{}',
        finalized: true);
    await db.delete('group_row');
    expect(await _put(stamp: stamp), isFalse);
    expect(await db.query('group_row'), isEmpty);
  });

  test('deleting a day deletes its group rows', () async {
    await _put();
    expect(await db.query('group_row'), isNotEmpty);
    await LocalDb.deleteDays({_day});
    expect(await db.query('group_row'), isEmpty);
  });

  group('cost', () {
    test('the stamp query is served by an index on the scope', () async {
      final plan = await db.rawQuery(
          'EXPLAIN QUERY PLAN $kStampQuerySql', ['2026-02-10', '2026-03-11']);
      final detail = plan.map((r) => r['detail']).join(' | ');
      expect(detail, contains('idx_input_revision_scope'));
      expect(detail, isNot(contains('SCAN input_revision')));
    });

    test('the index exists after open and survives a repeat open', () async {
      final r = await db.rawQuery("SELECT name FROM sqlite_master WHERE "
          "type = 'index' AND name = 'idx_input_revision_scope'");
      expect(r, hasLength(1));
    });

    test('the latest-revision read carries no payload', () {
      expect(kLatestRevisionSql, isNot(contains('payload')));
      expect(kLatestRevisionSql, contains('MAX(revision)'));
    });
  });
}
