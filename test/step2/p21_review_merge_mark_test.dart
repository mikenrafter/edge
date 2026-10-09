// Sol review r1, finding 1: `_mergeFromDbFile` commits page by page, so the
// generation must move whenever ANY page committed, also when a later table, a
// follow-up write or `src.close()` throws. Otherwise a durable replacement
// leaves the generation alone and a cache keyed on (day, version, computed_at)
// serves the old payload for a replacement written at an equal computed_at.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/bundle_store.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

import 'support/p21_support.dart';

const _name = 'p21_review_merge_mark.db';
const _foreign = 'p21_review_merge_mark_foreign.db';
const _day = '2026-03-10';
const _at = 5000;

String _payload(double rmssd) => jsonEncode({
  'date': _day,
  'scalars': {'rmssd': rmssd},
  'series': {
    'hrv_timeline': [
      {'t': 1700000000, 'v': 40.0},
    ],
  },
});

Future<String> _brokenExport() async {
  final path = await p21Path(_foreign);
  await databaseFactory.deleteDatabase(path);
  final src = await databaseFactory.openDatabase(path);
  await src.execute('''
    CREATE TABLE day_result (
      day_id TEXT NOT NULL, algo_version INTEGER NOT NULL,
      payload_json TEXT NOT NULL, window_json TEXT NOT NULL DEFAULT '{}',
      computed_at INTEGER NOT NULL, finalized INTEGER NOT NULL DEFAULT 0,
      rhr REAL, rmssd REAL, readiness REAL,
      skipped INTEGER NOT NULL DEFAULT 0, partial INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (day_id, algo_version))
  ''');
  await src.insert('day_result', {
    'day_id': _day,
    'algo_version': p21Version,
    'payload_json': _payload(99),
    'computed_at': _at, // equal to the local row's
    'rmssd': 99.0,
  });
  // Merged AFTER day_result; lacks the NOT NULL payload_json the live table
  // demands, so its page throws and a non-tolerant import rethrows.
  await src.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
  await src.insert('baselines', {'key': 'k'});
  await src.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  p21RestoreClockAfterEach();

  late Database db;
  setUp(() async => db = await p21Fresh(_name));
  tearDown(() async {
    await p21Drop(_name);
    await databaseFactory.deleteDatabase(await p21Path(_foreign));
  });

  test('a day_result page commits, a later table throws: the generation still '
      'moves and the repository serves the replacement', () async {
    await db.insert('day_result', {
      'day_id': _day,
      'algo_version': p21Version,
      'payload_json': _payload(55),
      'window_json': '{}',
      'computed_at': _at,
      'finalized': 0,
      'skipped': 0,
      'partial': 0,
      'rmssd': 55.0,
    });
    BundleStore.shared.invalidateAll();
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getDayHrv(_day))['rmssd'], 55, reason: 'warm the memo');
    final before = LocalDb.storeGeneration;
    final src = await _brokenExport();

    await expectLater(
      LocalDb.importFromDbFile(src),
      throwsA(isA<DatabaseException>()),
    );

    expect(
      (await db.query('day_result')).single['payload_json'],
      _payload(99),
      reason: 'the day_result page really committed',
    );
    expect(LocalDb.storeGeneration, isNot(before),
        reason: 'durable replacement with an unmoved generation');
    expect((await repo.getDayHrv(_day))['rmssd'], 99,
        reason: 'the memo key (day, version, computed_at) is equal, so only '
            'the generation can invalidate it');
  });

  test('nothing committed, nothing replaced: a failing first page leaves the '
      'generation alone', () async {
    final path = await p21Path(_foreign);
    await databaseFactory.deleteDatabase(path);
    final src = await databaseFactory.openDatabase(path);
    await src.execute('CREATE TABLE journal (date TEXT PRIMARY KEY)');
    await src.insert('journal', {'date': '2026-01-01'});
    await src.close();
    final before = LocalDb.storeGeneration;
    // The live table refuses the row, so the first page never commits.
    await db.execute(
      'CREATE TRIGGER p21_no_journal BEFORE INSERT ON journal '
      "BEGIN SELECT RAISE(ABORT, 'no'); END",
    );
    await expectLater(
      LocalDb.importFromDbFile(path),
      throwsA(isA<DatabaseException>()),
    );
    expect(LocalDb.storeGeneration, before);
  });
}
