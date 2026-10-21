// D38: an import killed mid-copy resumes to the same database an
// uninterrupted import produces, and restarts at the recorded rowid.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';

import '../backup/backup_support.dart';
import 'import_resume_support.dart';

void main() {
  late BackupEnv env;
  late String src;

  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_resume_test.db');
    src = await buildSource(env.root);
  });
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
  });
  tearDown(ImportHooks.reset);

  test('crash after N chunks then resume == uninterrupted import', () async {
    ImportHooks.chunkRows = kChunk;
    await LocalDb.importFromDbFile(src);
    final baseline = await snapshot();
    expect(baseline['decoded_onehz'], hasLength(kRows)); // fixture sanity
    await env.wipe();

    crashAt('decoded_onehz', 2);
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    expect(await count('decoded_onehz'), 2 * kChunk,
        reason: 'two chunks committed before the crash');
    expect(await count('decoded_rr'), 0, reason: 'later tables not copied');

    ImportHooks.chunk = null;
    await LocalDb.close(); // a fresh open, as after a process restart
    final r = await ImportJournal.resumeIfUnfinished();
    expect(r.resumed, isTrue);

    final after = await snapshot();
    for (final k in baseline.keys) {
      expect(after[k], baseline[k], reason: 'table/per-day $k');
    }
    expect((await ImportJournal.current())?.state, ImportJournalState.done);
  });

  test('resume restarts at the recorded table/rowid: at most one chunk '
      're-copied', () async {
    crashAt('decoded_onehz', 2);
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    final st = await ImportJournal.current();
    expect(st?.table, 'decoded_onehz');
    expect(st?.lastRowid, 2 * kChunk);
    expect(st?.rowsCopied, 2 * kChunk);

    await LocalDb.close();
    final log = <ImportChunk>[];
    ImportHooks.chunkRows = kChunk;
    ImportHooks.chunk = (txn, c) async => log.add(c);
    await ImportJournal.resumeIfUnfinished();

    final onehz = log.where((c) => c.table == 'decoded_onehz').toList();
    expect(onehz, isNotEmpty);
    expect(onehz.first.fromRowid, greaterThanOrEqualTo(2 * kChunk - kChunk),
        reason: 'no more than one chunk is copied again');
    expect(onehz.fold<int>(0, (n, c) => n + (c.toRowid - c.fromRowid)),
        lessThanOrEqualTo(kRows - 2 * kChunk + kChunk));
    expect(log.map((c) => c.table), isNot(contains('journal')),
        reason: 'finished tables are not walked again');
  });

  test('journal advances in the same transaction as each chunk', () async {
    int? seenInTxn;
    ImportHooks.chunkRows = kChunk;
    ImportHooks.chunk = (txn, c) async {
      if (c.table == 'decoded_onehz' && c.index == 1) {
        final rows = await txn.query('import_journal');
        seenInTxn = rows.isEmpty ? null : rows.first['last_rowid'] as int?;
        throw StateError('inside the chunk transaction');
      }
    };
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    expect(seenInTxn, 2 * kChunk,
        reason: 'the chunk\'s own transaction already carries its journal row');
    // Both roll back together: chunk 1 and its journal advance are gone.
    expect(await count('decoded_onehz'), kChunk);
    expect((await ImportJournal.current())?.lastRowid, kChunk);
    expect(File(src).existsSync(), isTrue);
  });
}
