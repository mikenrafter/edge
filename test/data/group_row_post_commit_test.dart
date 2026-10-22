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

  group('Sol r2', () {
    Future<Map<String, Object?>> stored() async =>
        (await db.query('day_result')).single;

    Future<void> after(Map<String, Object?> row, {InputStamp? stamp}) =>
        writeGroupRowsAfterCommit(
            dayId: _day,
            algoVersion: 500,
            finalized: false,
            partial: false,
            skipped: false,
            userOverride: false,
            expectedPayload: row['payload_json'] as String,
            expectedComputedAt: (row['computed_at'] as num).toInt(),
            stamp: stamp);

    test('history stamp: a metric_series bump after the history load does '
        'not reach the stored stamp', () async {
      await bumpInputRev('metric_series', '2026-03-01');
      final history = await captureMetricSeriesRevs(); // before history load
      await bumpInputRev('metric_series', '2026-03-01'); // after, pre-prepare
      await bumpInputRev('metric_series', '2026-03-02'); // a new scope too
      final dayStamp = await captureInputStamp(_day);
      expect(dayStamp['metric_series'], {'2026-03-01': 2, '2026-03-02': 1});
      final held = stampNotLaterThan(dayStamp, history)!;
      expect(held['metric_series'], {'2026-03-01': 1});
      expect(await _put(stamp: held), isTrue);
      final s = await _stamp(db, 'edge.assembly');
      expect(s['metric_series'], {'2026-03-01': 1});
      expect(s.containsKey('_unpinned'), isFalse);
    });

    test('a history capture that failed leaves the day unpinned', () {
      expect(stampNotLaterThan({'zone': {'': 1}}, null), isNull);
      expect(stampNotLaterThan(null, {'a': 1}), isNull);
    });

    test('write B replaced the day between A commit and A shadow write: '
        'A writes nothing, B rows stay B', () async {
      expect(await _put(), isTrue);
      final a = await stored();
      await db.delete('group_row');
      // B: a different payload at the same (day, version).
      await LocalDb.putDayResult(
          dayId: _day,
          algoVersion: 500,
          payloadJson: jsonEncode({
            'date': _day,
            'sleep': {'a': 2},
            'scalars': <String, Object?>{'rhr': 51.0},
          }),
          windowJson: '{}',
          series: const {'rhr': 51.0});
      final bRows = await db.query('group_row', orderBy: 'group_id');
      final before = groupRowDiagnostics.superseded;
      await after(a);
      expect(groupRowDiagnostics.superseded, before + 1);
      expect(await db.query('group_row', orderBy: 'group_id'), bRows);
    });

    test('the day deleted in the gap: no rows are recreated', () async {
      expect(await _put(), isTrue);
      final a = await stored();
      await LocalDb.deleteDays({_day});
      final before = groupRowDiagnostics.superseded;
      await after(a);
      expect(await db.query('group_row'), isEmpty);
      expect(groupRowDiagnostics.superseded, before + 1);
    });

    test('an unchanged day still takes its shadow write', () async {
      expect(await _put(), isTrue);
      final a = await stored();
      await db.delete('group_row');
      await after(a);
      expect(await db.query('group_row'), isNotEmpty);
    });

    test('a broken stamp read does not stop the derive write', () async {
      stampReadFaultForTest = true;
      addTearDown(() => stampReadFaultForTest = false);
      final before = groupRowDiagnostics.stampReadFailures;
      final stamp = await captureInputStampBestEffort(_day);
      expect(stamp, isNull);
      expect(groupRowDiagnostics.stampReadFailures, before + 1);
      expect(await _put(stamp: stamp), isTrue);
      expect(await db.query('day_result'), hasLength(1));
      expect((await _stamp(db, 'sleep.stage'))['_unpinned'], isTrue);
    });
  });
}
