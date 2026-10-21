// D38: no derive on partial data, and an interrupted import is never silent.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:openstrap_edge/data/import_progress.dart';

import '../backup/backup_support.dart';
import 'import_resume_support.dart';

void main() {
  late BackupEnv env;
  late String src;

  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_status_test.db');
    src = await buildSource(env.root);
  });
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
  });
  tearDown(ImportHooks.reset);

  Future<void> interrupt() async {
    crashAt('decoded_onehz', 2);
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    ImportHooks.chunk = null;
    await LocalDb.close();
  }

  test('no post-import derive before state == done; redone after resume',
      () async {
    await interrupt();
    expect(await ImportJournal.deriveAllowed(), isFalse);
    var requests = 0;
    expect(await ImportJournal.requestDeriveWhenDone(() => requests++),
        isFalse);
    expect(requests, 0, reason: 'nothing scheduled while interrupted');

    // A derive that ran on the partial data left a row for an imported day.
    final db = await LocalDb.instance;
    await db.insert('day_result', {
      'day_id': '2026-09-21', 'algo_version': 114, 'payload_json': '{}',
      'computed_at': 2, 'finalized': 0,
    });

    var resumeDerives = 0;
    await ImportJournal.resumeIfUnfinished(requestDerive: () => resumeDerives++);
    expect(resumeDerives, 1, reason: 'one derive, after the copy completed');
    expect(await ImportJournal.deriveAllowed(), isTrue);
    expect(await ImportJournal.daysToRederive(), containsAll(kSourceDays),
        reason: 'the imported range is marked for re-derive');
  });

  test('an unfinished journal is visible at startup and counted on resume',
      () async {
    await interrupt();
    final st = await ImportJournal.current();
    expect(st, isNotNull);
    expect(st!.interrupted, isTrue);
    expect(st.resuming, isFalse);
    expect(st.state, isNot(ImportJournalState.done));
    expect(st.table, 'decoded_onehz');
    expect(st.rowsCopied, 2 * kChunk);
    expect(st.rowsTotal, kRows);

    final events = <ImportProgress>[];
    ImportHooks.chunkRows = kChunk;
    await ImportJournal.resumeIfUnfinished(onProgress: events.add);
    expect(events.whereType<ImportResuming>(), isNotEmpty,
        reason: 'a resume event the UI can show');
    expect(events.first, isA<ImportResuming>());

    final done = await ImportJournal.current();
    expect(done?.state, ImportJournalState.done);
    expect(done?.interrupted, isFalse);
    expect(done?.interruptedAndResumed, 1);
    final summary = await lastImportSummary();
    expect(summary?.interruptedAndResumed, 1);
  });

  test('a failed import also surfaces as interrupted, not as nothing',
      () async {
    await interrupt();
    final st = await ImportJournal.current();
    expect(st?.error, contains('crash'));
  });
}
