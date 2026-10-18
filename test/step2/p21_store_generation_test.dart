// P2.1 store generation, design 02 step 2, section 4.2.
//
// ASSUMED (lib/data/db.dart):
//
//   * `LocalDb.storeGeneration` is the record `({int wipeEpoch, int openCount})`,
//     read synchronously. It changes when the store is wiped, merged into,
//     rebuilt or reopened, and at no other time: ordinary reads and writes
//     leave it alone.
//   * `wipeEpoch` is private (`_wipeEpoch`) and has ONE mutator,
//     `_markStoreReplaced()`. It runs AFTER the wipe or merge transaction
//     COMMITS (a wipe that rolls back changes nothing), on a plain reopen
//     inside `_open()`, and after the salvage merge in `_openOrRebuild`.
//     A reader that captured the old generation before the commit is then
//     rejected by the post-worker fence (P2.2); the ordering is what makes that
//     fence sound.
//   * Callers that used the public `LocalDb.wipeEpoch` (`LastResultCache`,
//     `LocalRepositoryImpl`) read `storeGeneration` instead.
//
// The ordering of a failing wipe is tested by behaviour: a trigger that aborts
// the delete of one table rolls the whole wipe back, and the generation must
// not have moved. The salvage ordering is a source check, because a read
// racing the salvage merge cannot be placed without a test seam.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';

import 'support/p21_support.dart';
import 'support/write_seam_scan.dart';

const _name = 'p21_store_generation.db';
const _day = '2026-03-10';

Future<void> _seed(Database db) async {
  await LocalDb.putDayResult(
    dayId: _day,
    algoVersion: p21Version,
    payloadJson: p21Payload('a'),
    windowJson: '{}',
  );
  await LocalDb.putBaseline('k', '{}');
}

String _dbSource() => File('lib/data/db.dart').readAsStringSync();

/// The text of `LocalDb`'s member named [name] (signature through closing
/// brace), from comment-blanked source. Empty when there is none.
String _member(String src, String name) {
  final code = blankComments(src);
  final m = RegExp('\\n  static [^\\n]*\\b$name\\s*\\(').firstMatch(code);
  if (m == null) return '';
  final open = code.indexOf('{', code.indexOf(')', m.end));
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}' && --depth == 0) return code.substring(m.start, i + 1);
  }
  return '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async => db = await p21Fresh(_name));
  tearDown(() => p21Drop(_name));

  group('what changes the generation', () {
    test('it is a comparable value: two reads with nothing between are equal',
        () async {
      final a = LocalDb.storeGeneration;
      final b = LocalDb.storeGeneration;
      expect(a, b);
      expect(a.wipeEpoch, isNonNegative);
      expect(a.openCount, greaterThan(0), reason: 'the store is open');
    });

    test('ordinary reads and writes leave it alone', () async {
      final before = LocalDb.storeGeneration;
      await _seed(db);
      await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: p21Version,
        payloadJson: p21Payload('b'),
        windowJson: '{}',
      );
      await LocalDb.touchBaseline('k');
      await LocalDb.updateBaseline('k', (c) => '{"v":2}');
      await LocalDb.dayResult(_day);
      await LocalDb.deleteDays({_day});
      expect(LocalDb.storeGeneration, before);
    });

    test('wipeAll changes it, and wipeEpoch only goes up', () async {
      await _seed(db);
      final before = LocalDb.storeGeneration;
      await LocalDb.wipeAll();
      final after = LocalDb.storeGeneration;
      expect(after, isNot(before));
      expect(after.wipeEpoch, greaterThan(before.wipeEpoch));
    });

    test('a plain close and reopen changes it', () async {
      final before = LocalDb.storeGeneration;
      await p21Reopen();
      final after = LocalDb.storeGeneration;
      expect(after, isNot(before));
      expect(after.openCount, greaterThan(before.openCount));
      expect(after.wipeEpoch, greaterThanOrEqualTo(before.wipeEpoch));
    });

    test('a merge (importFromDbFile) changes it', () async {
      await _seed(db);
      final src = await p21MakeForeignExport(
        'p21_gen_foreign.db',
        days: [
          (day: '2026-03-20', version: p21Version, tag: 'f', finalized: false),
        ],
      );
      addTearDown(() async =>
          databaseFactory.deleteDatabase(await p21Path('p21_gen_foreign.db')));
      final before = LocalDb.storeGeneration;

      final counts = await LocalDb.importFromDbFile(src);

      expect(counts['day_result'], 1);
      expect(LocalDb.storeGeneration, isNot(before));
    });

    test('a rebuild (quarantine, fresh file, salvage merge) changes it', () async {
      const bricked = 'p21_gen_bricked.db';
      await LocalDb.close();
      final path = await p21Path(bricked);
      await databaseFactory.deleteDatabase(path);
      final seed = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (d, _) async {
            // The wrong shape makes the ladder's index creation throw.
            await d.execute('CREATE TABLE metric_series (bogus INTEGER)');
            await d.execute('''
              CREATE TABLE journal (
                date TEXT PRIMARY KEY, tags_json TEXT NOT NULL DEFAULT '[]',
                note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)
            ''');
          },
        ),
      );
      await seed.insert('journal', {
        'date': '2026-08-01',
        'tags_json': '[]',
        'note': 'kept',
        'updated_at': 1,
      });
      await seed.close();
      addTearDown(() async {
        await p21Drop(bricked);
        for (final f in Directory(
          (await databaseFactory.getDatabasesPath()),
        ).listSync()) {
          if (f is File && f.path.contains('$bricked.unopenable')) f.deleteSync();
        }
      });

      final before = LocalDb.storeGeneration;
      LocalDb.dbName = bricked;
      await LocalDb.instance;

      expect(LocalDb.lastRebuild, isNotNull, reason: 'the open really bricked');
      expect(LocalDb.lastRebuild!.salvaged['journal'], 1);
      final after = LocalDb.storeGeneration;
      expect(after, isNot(before));
      expect(after.openCount, greaterThan(before.openCount));
    });
  });

  group('the mark comes AFTER the commit', () {
    test('a wipeAll that rolls back leaves the generation and the data alone',
        () async {
      await _seed(db);
      await db.insert('journal', {
        'date': '2026-08-01',
        'tags_json': '[]',
        'note': '',
        'updated_at': 1,
      });
      // The wipe deletes every table in one transaction. Aborting the delete
      // of one of them rolls the whole thing back.
      await db.execute(
        'CREATE TRIGGER p21_block_wipe BEFORE DELETE ON journal '
        "BEGIN SELECT RAISE(ABORT, 'p21 blocked'); END",
      );
      final before = LocalDb.storeGeneration;

      await expectLater(LocalDb.wipeAll(), throwsA(isA<DatabaseException>()));

      expect(
        LocalDb.storeGeneration,
        before,
        reason: 'nothing was replaced; marking before the commit made a '
            'failed wipe look like a wipe to every cache',
      );
      expect(await db.query('day_result'), hasLength(1));
      expect(await db.query('baselines'), hasLength(1));
    });

    test('source: _markStoreReplaced() follows the wipe transaction in wipeAll',
        () {
      final body = _member(_dbSource(), 'wipeAll');
      expect(body, isNotEmpty);
      final tx = body.indexOf('transaction(');
      final mark = body.indexOf('_markStoreReplaced()');
      expect(tx, isNonNegative);
      expect(mark, isNonNegative, reason: 'wipeAll must call the mutator');
      expect(mark, greaterThan(tx),
          reason: 'the wipe transaction must have committed first');
    });

    test('source: the salvage merge is followed by a mark', () {
      final src = _dbSource();
      final rebuild = _member(src, '_openOrRebuild');
      final merge = _member(src, '_mergeFromDbFile');
      expect(rebuild, isNotEmpty);
      expect(merge, isNotEmpty);
      final call = rebuild.indexOf('_mergeFromDbFile(');
      expect(call, isNonNegative);
      final markedInRebuild =
          rebuild.indexOf('_markStoreReplaced()', call) > call;
      final lastTx = merge.lastIndexOf('transaction(');
      final markedInMerge = merge.indexOf('_markStoreReplaced()') > lastTx &&
          merge.contains('_markStoreReplaced()');
      expect(markedInRebuild || markedInMerge, isTrue,
          reason: 'HEAD publishes the fresh handle before the salvage merge, so '
              'a read during the merge captures the pre-merge generation; the '
              'mark after the merge commits is what rejects it');
    });

    test('source: _open() marks a plain reopen', () {
      expect(_member(_dbSource(), '_open'), contains('_markStoreReplaced()'));
    });
  });

  group('the epoch has one owner', () {
    test('wipeEpoch is no longer public, and lib/ never reads it', () {
      final src = blankComments(_dbSource());
      expect(RegExp(r'static\s+int\s+wipeEpoch\b').hasMatch(src), isFalse,
          reason: 'make it private; callers read LocalDb.storeGeneration');
      final readers = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (RegExp(r'LocalDb\s*\.\s*wipeEpoch\b')
            .hasMatch(blankComments(f.readAsStringSync()))) {
          readers.add(f.path);
        }
      }
      expect(readers, isEmpty, reason: 'use LocalDb.storeGeneration');
    });

    test('_wipeEpoch is assigned in exactly one place, _markStoreReplaced', () {
      final src = blankComments(_dbSource());
      final sites = RegExp(r'\b_wipeEpoch\s*(\+\+|--|\+=|-=|=(?!=))|(\+\+|--)\s*_wipeEpoch\b')
          .allMatches(src)
          // The field's own initialiser.
          .where((m) => !src
              .substring(src.lastIndexOf('\n', m.start) + 1, m.start)
              .contains('static int '))
          .toList();
      expect(sites, hasLength(1), reason: 'one mutator');
      final mutator = _member(_dbSource(), '_markStoreReplaced');
      expect(mutator, isNotEmpty, reason: '_markStoreReplaced must exist');
      expect(RegExp(r'_wipeEpoch\s*(\+\+|\+=)|(\+\+)\s*_wipeEpoch').hasMatch(mutator),
          isTrue);
    });
  });
}
