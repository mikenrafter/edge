// Design 04 phase 1 (RED) - item 2, the store half: attempt groups through
// LocalDb.saveEcgResult / listEcgReadings / ecgAttempts / deleteEcgReading /
// ecgReadingsForExport. Real LocalDb over sqflite_common_ffi.
//
// RULES UNDER TEST (R2'' + R2'''):
//   * Nothing is ever deleted by a save: the replaced-inconclusive delete path
//     is gone. A reading that JOINS (ecgJoinTargetId) gets the group's
//     attempt_group and attempt = previous + 1, and sets superseded_by on the
//     previous latest row IN THE SAME TRANSACTION as its own insert.
//   * A reading that does not join starts a group: attempt_group = its own id,
//     attempt = 1. A legacy row (NULL group) is a group of one.
//   * saveEcgResult returns the id it superseded, or null.
//   * The default history list hides superseded rows; Details and exports see
//     every row.
//   * Deleting any attempt deletes the WHOLE group (rows + packets) in one
//     transaction; raw R16 rows are unlinked, never deleted.
//
// ASSUMED API (lib/data/db.dart): ecgAttempts(id), ecgReadingsForExport(...),
// listEcgReadings(includeSuperseded:).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/cardio_fixtures.dart';

Future<String?> _save(EcgReading r, {int packets = 0}) => LocalDb.saveEcgResult(
  r.toRow(),
  [for (var i = 0; i < packets; i++) cardioPacketRow(i)],
);

Future<List<String>> _ids({bool all = false}) async => [
  for (final r in await LocalDb.listEcgReadings(includeSuperseded: all))
    r['id']! as String,
];

Future<Map<String, Object?>> _row(String id) async =>
    (await LocalDb.ecgReading(id))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_ecg_attempts_store_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() async {
    final db = await LocalDb.instance;
    await db.delete('ecg_reading_packet');
    await db.delete('ecg_raw_packet');
    await db.delete('ecg_reading');
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('starting and joining a group', () {
    test('a first reading is its own group: attempt_group = its id, attempt 1, '
        'not superseded; the save supersedes nothing', () async {
      expect(await _save(cardioReading(id: 'A')), isNull);
      final a = await _row('A');
      expect(a['attempt_group'], 'A');
      expect(a['attempt'], 1);
      expect(a['superseded_by'], isNull);
    });

    test('an unreadable attempt then a reading 5 minutes later: one group, '
        'attempt 2, the first is superseded and KEPT with its packets',
        () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'), packets: 2);
      final b = cardioReading(id: 'B', startTs: kC0 + 1000 + 300);
      expect(await _save(b, packets: 1), 'A', reason: 'the id it superseded');
      final a = await _row('A');
      final bRow = await _row('B');
      expect(bRow['attempt_group'], 'A');
      expect(bRow['attempt'], 2);
      expect(bRow['superseded_by'], isNull);
      expect(a['superseded_by'], 'B');
      expect(a['attempt_group'], 'A');
      expect(a['attempt'], 1);
      expect(await LocalDb.ecgReadingPackets('A'), hasLength(2),
          reason: 'the earlier attempt keeps its packets');
      expect(await LocalDb.ecgReadingPackets('B'), hasLength(1));
      expect(a['category'], 'unreadable', reason: 'original category as-is');
      expect(a['status'], 'completed', reason: 'original status as-is');
    });

    test('an inconclusive attempt joins the same way (the old "replace" '
        'case): nothing is deleted', () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'), packets: 2);
      expect(await _save(cardioReading(id: 'B', startTs: kC0 + 1000 + 200)), 'A');
      expect(await _ids(all: true), unorderedEquals(['A', 'B']));
      expect((await _row('A'))['status'], 'inconclusive');
    });

    test('the retained packet bytes of a superseded attempt are byte-exact',
        () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'), packets: 3);
      final before = await LocalDb.ecgReadingPackets('A');
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100), packets: 1);
      final after = await LocalDb.ecgReadingPackets('A');
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i]['samples'], before[i]['samples']);
        expect(after[i]['inner_hex'], before[i]['inner_hex']);
        expect(after[i]['ordinal'], before[i]['ordinal']);
      }
    });

    test('the boundary on the real store: gap -1 and 601 start new groups, '
        '0 and 600 join', () async {
      for (final (gap, joins) in [(-1, false), (0, true), (600, true), (601, false)]) {
        final db = await LocalDb.instance;
        await db.delete('ecg_reading_packet');
        await db.delete('ecg_reading');
        await _save(inconclusiveAt(kC0 + 1000, id: 'A'));
        final r = await _save(cardioReading(id: 'B', startTs: kC0 + 1000 + gap));
        expect(r, joins ? 'A' : isNull, reason: 'gap $gap');
        expect((await _row('B'))['attempt_group'], joins ? 'A' : 'B',
            reason: 'gap $gap');
        expect((await _row('B'))['attempt'], joins ? 2 : 1, reason: 'gap $gap');
        expect((await _row('A'))['superseded_by'], joins ? 'B' : isNull,
            reason: 'gap $gap');
      }
    });

    test('a final (completed, rhythm) latest is never joined, even at gap 0',
        () async {
      await _save(cardioReading(id: 'A', endTs: kC0 + 1000));
      expect(await _save(cardioReading(id: 'B', startTs: kC0 + 1000)), isNull);
      expect((await _row('B'))['attempt_group'], 'B');
      expect((await _row('A'))['superseded_by'], isNull);
    });

    test('a partial incoming reading is added beside the inconclusive one, in '
        'a group of its own; the inconclusive is not superseded', () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'));
      expect(await _save(partialAt(kC0 + 1100 + 12, id: 'P')), isNull);
      expect((await _row('P'))['attempt_group'], 'P');
      expect((await _row('A'))['superseded_by'], isNull);
      expect(await _ids(), unorderedEquals(['A', 'P']));
    });

    test('a partial latest is never joined', () async {
      await _save(partialAt(kC0 + 1000, id: 'P'));
      expect(await _save(cardioReading(id: 'B', startTs: kC0 + 1010)), isNull);
      expect((await _row('B'))['attempt_group'], 'B');
    });

    test('only the MOST RECENT reading (by end time) can be joined', () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'));
      await _save(cardioReading(id: 'C', startTs: kC0 + 4000)); // 10+ min later
      expect(await _save(cardioReading(id: 'D', startTs: kC0 + 4040)), isNull);
      expect((await _row('A'))['superseded_by'], isNull);
      expect((await _row('D'))['attempt_group'], 'D');
    });

    test('a chain of three: unreadable -> inconclusive -> good reading; every '
        'link points at the next, only the last is unsuperseded', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'));
      await _save(inconclusiveAt(kC0 + 1000 + 120 + 30, id: 'B'));
      await _save(cardioReading(id: 'C', startTs: kC0 + 1000 + 120 + 30 + 60));
      expect((await _row('A'))['superseded_by'], 'B');
      expect((await _row('B'))['superseded_by'], 'C');
      expect((await _row('C'))['superseded_by'], isNull);
      for (final (id, n) in [('A', 1), ('B', 2), ('C', 3)]) {
        final r = await _row(id);
        expect(r['attempt_group'], 'A', reason: id);
        expect(r['attempt'], n, reason: id);
      }
      expect(await _ids(), ['C'], reason: 'the default history shows the last');
      expect(await _ids(all: true), unorderedEquals(['A', 'B', 'C']));
    });
  });

  group('atomicity', () {
    test('a failed save rolls back EVERYTHING: no new row, no packets, and the '
        'earlier attempt is not marked superseded', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'), packets: 2);
      final bad = cardioReading(id: 'B', startTs: kC0 + 1100);
      await expectLater(
        () => LocalDb.saveEcgResult(bad.toRow(), [
          cardioPacketRow(0),
          cardioPacketRow(1)..remove('sample_count'), // NOT NULL violation
        ]),
        throwsA(isA<DatabaseException>()),
      );
      expect(await _ids(all: true), ['A']);
      expect((await _row('A'))['superseded_by'], isNull);
      expect(await LocalDb.ecgReadingPackets('A'), hasLength(2));
      expect(await LocalDb.ecgReadingPackets('B'), isEmpty);
    });

    test('re-saving the same id is refused and changes nothing', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'));
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100));
      await expectLater(
        () => _save(cardioReading(id: 'B', startTs: kC0 + 1100)),
        throwsA(isA<DatabaseException>()),
      );
      expect(await _ids(all: true), unorderedEquals(['A', 'B']));
      expect((await _row('A'))['superseded_by'], 'B');
      expect((await _row('B'))['attempt'], 2);
    });
  });

  group('the history list and the attempt group', () {
    test('default history hides superseded rows; includeSuperseded shows '
        'them', () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'));
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100));
      await _save(cardioReading(id: 'Z', startTs: kC0 + 90000));
      expect(await _ids(), ['Z', 'B']);
      expect(await _ids(all: true), ['Z', 'B', 'A']);
    });

    test('ecgAttempts from ANY attempt returns the whole group ordered by '
        'attempt', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'));
      await _save(inconclusiveAt(kC0 + 1000 + 150, id: 'B'));
      await _save(cardioReading(id: 'C', startTs: kC0 + 1000 + 150 + 60));
      for (final from in ['A', 'B', 'C']) {
        final g = await LocalDb.ecgAttempts(from);
        expect([for (final r in g) r['id']], ['A', 'B', 'C'], reason: from);
        expect([for (final r in g) r['attempt']], [1, 2, 3], reason: from);
      }
    });

    test('a legacy row (NULL attempt_group / attempt) is a group of one',
        () async {
      final db = await LocalDb.instance;
      await db.insert('ecg_reading', {
        ...cardioReading(id: 'L1').toRow(),
        'attempt_group': null,
        'attempt': null,
        'superseded_by': null,
      });
      final g = await LocalDb.ecgAttempts('L1');
      expect([for (final r in g) r['id']], ['L1']);
      expect(await _ids(), ['L1'], reason: 'NULL superseded_by shows');
    });

    test('another group with the same shape is not mixed in', () async {
      await _save(inconclusiveAt(kC0 + 1000, id: 'A'));
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100));
      await _save(inconclusiveAt(kC0 + 90000, id: 'X'));
      await _save(cardioReading(id: 'Y', startTs: kC0 + 90100));
      expect([for (final r in await LocalDb.ecgAttempts('Y')) r['id']], ['X', 'Y']);
      expect([for (final r in await LocalDb.ecgAttempts('A')) r['id']], ['A', 'B']);
    });
  });

  group('deleting a reading deletes its whole group', () {
    test('from the last attempt: every row and every packet in the group is '
        'gone; another group is untouched', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'), packets: 2);
      await _save(inconclusiveAt(kC0 + 1000 + 150, id: 'B'), packets: 2);
      await _save(cardioReading(id: 'C', startTs: kC0 + 1000 + 150 + 60), packets: 1);
      await _save(cardioReading(id: 'KEEP', startTs: kC0 + 90000), packets: 1);
      await LocalDb.deleteEcgReading('C');
      expect(await _ids(all: true), ['KEEP']);
      for (final id in ['A', 'B', 'C']) {
        expect(await LocalDb.ecgReadingPackets(id), isEmpty, reason: id);
      }
      expect(await LocalDb.ecgReadingPackets('KEEP'), hasLength(1));
    });

    test('from a hidden earlier attempt: the same, the whole group', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'), packets: 1);
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100), packets: 1);
      await LocalDb.deleteEcgReading('A');
      expect(await _ids(all: true), isEmpty);
      expect(await LocalDb.ecgReadingPackets('B'), isEmpty);
    });

    test('raw R16 rows of the group are unlinked, never deleted', () async {
      await _save(unreadableEndingAt(kC0 + 1000, id: 'A'));
      await _save(cardioReading(id: 'B', startTs: kC0 + 1100));
      final db = await LocalDb.instance;
      for (final (hex, rid) in [('aa', 'A'), ('bb', 'B')]) {
        await db.insert('ecg_raw_packet', {
          'hex': hex,
          'device_id': 'D',
          'captured_at': 1,
          'reading_id': rid,
        });
      }
      await LocalDb.deleteEcgReading('B');
      final raw = await db.query('ecg_raw_packet', orderBy: 'hex');
      expect(raw.map((r) => r['hex']), ['aa', 'bb']);
      expect(raw.map((r) => r['reading_id']), [null, null]);
    });

    test('a legacy NULL-group row deletes just itself', () async {
      final db = await LocalDb.instance;
      await db.insert('ecg_reading', cardioReading(id: 'L1').toRow());
      await db.insert('ecg_reading',
          cardioReading(id: 'L2', startTs: kC0 + 90000).toRow());
      await LocalDb.deleteEcgReading('L1');
      expect(await _ids(all: true), ['L2']);
    });
  });

  group('the export reader', () {
    test('pages oldest -> newest by start_ts then id, superseded included, '
        'with no 200-row cap and no gap or repeat across pages', () async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      const n = 450;
      for (var i = 0; i < n; i++) {
        // Ties on start_ts every 5th row: the id breaks them.
        final start = kC0 + (i ~/ 5) * 60;
        batch.insert('ecg_reading', cardioReading(
          id: 'r${(n - i).toString().padLeft(4, '0')}',
          startTs: start,
        ).toRow());
      }
      await batch.commit(noResult: true);
      // Mark some superseded: the export must still return them.
      await db.rawUpdate("UPDATE ecg_reading SET superseded_by = 'x' "
          "WHERE id LIKE 'r00%'");

      final seen = <String>[];
      int? afterTs;
      String? afterId;
      var pages = 0;
      while (true) {
        final page = await LocalDb.ecgReadingsForExport(
          limit: 200,
          afterStartTs: afterTs,
          afterId: afterId,
        );
        if (page.isEmpty) break;
        pages++;
        expect(page.length, lessThanOrEqualTo(200));
        for (final r in page) {
          seen.add(r['id']! as String);
        }
        afterTs = (page.last['start_ts']! as num).toInt();
        afterId = page.last['id']! as String;
      }
      expect(seen.length, n);
      expect(seen.toSet().length, n, reason: 'no repeat across pages');
      expect(pages, 3);
      final all = await db.query('ecg_reading');
      final expected = [...all]..sort((a, b) {
          final c = (a['start_ts']! as int).compareTo(b['start_ts']! as int);
          return c != 0 ? c : (a['id']! as String).compareTo(b['id']! as String);
        });
      expect(seen, [for (final r in expected) r['id']]);
    });

    test('an empty store pages to nothing', () async {
      expect(await LocalDb.ecgReadingsForExport(limit: 200), isEmpty);
    });
  });

  group('source guard', () {
    test('the delete-on-replace path is gone: saveEcgResult joins via '
        'ecgJoinTargetId and deletes nothing', () {
      final src = File('lib/data/db.dart').readAsStringSync();
      expect(src.contains('ecgReplaceTargetId('), isFalse);
      expect(src.contains('ecgJoinTargetId('), isTrue);
    });
  });
}
