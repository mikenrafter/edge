// D38: the foreground-service seam is requested and released on every exit,
// and the journal table arrives through an additive, idempotent schema step.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';

import '../backup/backup_support.dart';
import 'import_resume_support.dart';

void main() {
  late BackupEnv env;
  late String src;
  late FakeService svc;

  setUpAll(() async {
    env = await BackupEnv.create('openstrap_import_service_test.db');
    src = await buildSource(env.root);
  });
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
    svc = FakeService();
    ImportForegroundService.instance = svc;
  });
  tearDown(() {
    ImportHooks.reset();
    ImportForegroundService.instance = FakeService();
  });

  test('requested before the first chunk, released at done', () async {
    var requestedAtFirstChunk = false;
    ImportHooks.chunkRows = kChunk;
    ImportHooks.chunk = (txn, c) async {
      requestedAtFirstChunk = requestedAtFirstChunk || svc.events.isNotEmpty;
    };
    await LocalDb.importFromDbFile(src);
    expect(requestedAtFirstChunk, isTrue);
    expect(svc.events, ['request', 'release']);
  });

  test('released when the copy throws (no sticky latch), and again around '
      'the resume', () async {
    crashAt('decoded_onehz', 1);
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    expect(svc.events, ['request', 'release']);

    ImportHooks.chunk = null;
    await LocalDb.close();
    await ImportJournal.resumeIfUnfinished();
    expect(svc.events, ['request', 'release', 'request', 'release']);
  });

  test('migration adds import_journal; running it twice is a no-op', () async {
    expect(LocalDb.schemaVersion, greaterThan(75),
        reason: 'a new additive schema step');
    final db = await LocalDb.instance;
    Future<List<String>> cols() async => [
          for (final c in await db.rawQuery('PRAGMA table_info(import_journal)'))
            c['name'] as String,
        ];
    expect(await cols(), unorderedEquals(ImportJournal.columns));

    await ImportJournal.ensureSchema(db);
    await ImportJournal.ensureSchema(db);
    expect(await cols(), unorderedEquals(ImportJournal.columns));
    await db.insert('import_journal', {'state': 'done'});
    await ImportJournal.ensureSchema(db);
    expect(await count('import_journal'), 1, reason: 'rows survive a re-run');
  });
}
