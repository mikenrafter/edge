// 8N source guard: nothing in lib/ reads `ecg_raw_packet` without excluding
// gesture contact (`origin = 'gesture'`), and the coach cannot reach either the
// raw packet table or the gesture-session table.
//
// A reader is any statement that selects from, joins, or `.query`s the table.
// Every reader must mention `origin` and `gesture` in the same statement.
// Everything else that names the table must match the ALLOW-LIST below, which
// is only the schema/insert/tag/cleanup code itself. A new mention that is
// neither fails here, so a new consumer cannot be added silently.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _stripComments(String s) =>
    s.split('\n').map((l) {
      final t = l.trimLeft();
      return t.startsWith('//') ? '' : l;
    }).join('\n');

/// Non-reader mentions that are allowed: the code that creates, fills, tags,
/// repairs and clears the table. Each pattern is matched against the text
/// immediately around a mention (comments removed).
final _allow = <String, RegExp>{
  'DDL: create table': RegExp(r'CREATE TABLE IF NOT EXISTS\s+ecg_raw_packet'),
  'DDL: index': RegExp(r'CREATE INDEX[^;]*?ON ecg_raw_packet'),
  'DDL: add origin column':
      RegExp(r"_addColumnIfMissing\(\s*db,\s*'ecg_raw_packet'"),
  'insert during the history commit':
      RegExp(r"batch\.insert\('ecg_raw_packet'"),
  'tag packets inside a gesture interval':
      RegExp(r"UPDATE ecg_raw_packet\s+SET origin"),
  'clear the reading link when a reading is deleted':
      RegExp(r"txn\.update\(\s*'ecg_raw_packet'"),
  'restore: retag after merging ecg tables':
      RegExp(r"counts\['ecg_raw_packet'\]"),
  'ownership lists (salvage / restore) and the coach deny list':
      RegExp(r"'ecg_reading_packet',\s*'ecg_raw_packet'"),
};

final _reader = RegExp(
  r"(\bFROM|\bJOIN)\s+ecg_raw_packet|\.(query|rawQuery|delete)\(\s*'ecg_raw_packet'",
);

void main() {
  test('every reader of ecg_raw_packet excludes origin = gesture', () {
    final problems = <String>[];
    var readers = 0;
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final text = _stripComments(f.readAsStringSync());
      for (final m in RegExp('ecg_raw_packet').allMatches(text)) {
        final from = (m.start - 90).clamp(0, text.length);
        final to = (m.end + 400).clamp(0, text.length);
        final around = text.substring(from, m.end + 40 > text.length
            ? text.length
            : m.end + 40);
        final window = text.substring(m.start, to);
        if (_reader.hasMatch(text.substring(from, m.end + 1))) {
          readers++;
          // The statement is the next string/closing: look to the end of the
          // call, not just the next line.
          if (!(window.contains('origin') && window.contains('gesture'))) {
            problems.add('${f.path}: reader without an origin = gesture '
                'exclusion near "${around.replaceAll('\n', ' ').trim()}"');
          }
          continue;
        }
        if (!_allow.values.any((re) => re.hasMatch(around))) {
          problems.add('${f.path}: unclassified mention of ecg_raw_packet '
              'near "${around.replaceAll('\n', ' ').trim()}" - add it to the '
              'allow-list if it is schema/insert/tag code, otherwise exclude '
              "origin = 'gesture'");
        }
      }
    }
    expect(readers, greaterThan(0), reason: 'the guard found no reader at all');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  group('coach deny list', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_ecg_gesture_coach_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.instance;
    });

    tearDownAll(() async {
      await CoachDb.close();
      await LocalDb.close();
    });

    for (final t in ['ecg_raw_packet', 'ecg_gesture_session']) {
      test('layer 1 rejects $t', () {
        expect(() => CoachDb.guardAndPrepare('SELECT * FROM $t'),
            throwsA(isA<SqlGuardError>()));
        expect(
            () => CoachDb.guardAndPrepare(
                'WITH x AS (SELECT 1) SELECT * FROM v_ecg_readings, $t'),
            throwsA(isA<SqlGuardError>()));
      });

      test('layer 2 (parser bypassed) rejects $t', () async {
        await expectLater(
          CoachDb.debugAssertAllowedBtrees('SELECT * FROM $t LIMIT 5'),
          throwsA(isA<SqlGuardError>()),
        );
      });
    }
  });
}
