// D38: the saved copy of an import's source lives in a directory beside the
// database. Two installs of the database in one databases dir (tests running in
// parallel, or any second journal) must not delete each other's copy: an
// import finishing used to wipe the whole directory.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';

import '../backup/backup_support.dart';
import 'import_resume_support.dart';

void main() {
  late BackupEnv env;
  late String src;

  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_shared_a.db');
    src = await buildSource(env.root);
  });
  tearDownAll(() async {
    LocalDb.dbName = 'openstrap_import_shared_b.db';
    await env.wipe();
    LocalDb.dbName = 'openstrap_import_shared_a.db';
    await env.dispose();
  });
  tearDown(ImportHooks.reset);

  test('another journal finishing does not delete an unfinished import\'s '
      'saved copy', () async {
    crashAt('decoded_onehz', 2);
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    ImportHooks.reset();

    // A second database in the same databases dir runs a whole import.
    await LocalDb.close();
    LocalDb.dbName = 'openstrap_import_shared_b.db';
    await env.wipe();
    await LocalDb.importFromDbFile(src);
    expect((await ImportJournal.current())?.state, ImportJournalState.done);
    await LocalDb.close();

    LocalDb.dbName = 'openstrap_import_shared_a.db';
    final r = await ImportJournal.resumeIfUnfinished();
    expect(r.error, isNull, reason: 'the saved copy must still be there');
    expect(r.resumed, isTrue);
    expect((await ImportJournal.current())?.state, ImportJournalState.done);
    expect(await count('decoded_onehz'), kRows);
  });
}
