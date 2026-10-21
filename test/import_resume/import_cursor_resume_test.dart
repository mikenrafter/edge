// A resumed import reconciles `decoded_pruned_before` against the cursor the
// device had BEFORE the import began, not the one it finds on resume. By then
// the file's own sync_cursor may already have replaced it, and reconciling
// against that forgets the local prune holes (Sol r3).
//
// The cursor as it stood is journaled before any table copies
// (ImportRun.cursorBefore, in the journal's meta).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../backup/backup_support.dart';

const _cursor = 'decoded_pruned_before';

int _localSec(int month, int day, [int hour = 0]) =>
    DateTime(2026, month, day, hour).millisecondsSinceEpoch ~/ 1000;

/// Kills the import as it reaches [table].
class _KillAt implements ImportTableProbe {
  _KillAt(this.table);
  final String table;
  @override
  Future<void> beforeTable(String t) async {
    if (t == table) throw StateError('killed before $t');
  }
}

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('openstrap_import_cursor_resume.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
  });
  tearDown(ImportHooks.reset);

  /// 10-01 and 10-02 in full (a second every 30 min) and a cursor of 10-03.
  Future<String> source() async {
    final path = p.join(env.root.path, 'cursor_resume_src.db');
    await databaseFactoryFfi.deleteDatabase(path);
    final s = await databaseFactoryFfi.openDatabase(path);
    await s.execute('CREATE TABLE decoded_onehz (device_id TEXT, ts_ms INTEGER, '
        'rec_ts INTEGER, counter INTEGER, hr INTEGER)');
    await s.execute('CREATE TABLE sync_cursor (name TEXT PRIMARY KEY, '
        'value TEXT, updated_at INTEGER NOT NULL)');
    final b = s.batch();
    for (var ts = _localSec(10, 1); ts < _localSec(10, 3); ts += 1800) {
      b.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': ts * 1000, 'rec_ts': ts,
        'counter': ts, 'hr': 60,
      });
    }
    b.insert('sync_cursor',
        {'name': _cursor, 'value': '${_localSec(10, 3)}', 'updated_at': 1});
    await b.commit(noResult: true);
    await s.close();
    return path;
  }

  test('a crash after sync_cursor merged, then a resume, reconciles against '
      'the ORIGINAL local cursor', () async {
    // 10-09 was pruned locally; 10-10 keeps its evening only.
    await LocalDb.setCursor(_cursor, '${_localSec(10, 10)}');
    final src = await source();

    ImportHooks.table = _KillAt('substrate_archive');
    await expectLater(
        LocalDb.importFromDbFile(src), throwsA(isA<StateError>()));
    expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 3),
        reason: 'precondition: the file\'s cursor replaced the local one');

    ImportHooks.table = null;
    await LocalDb.close(); // a fresh open, as after a process restart
    final r = await ImportJournal.resumeIfUnfinished();
    expect(r.resumed, isTrue);
    expect(await LocalDb.getCursorInt(_cursor), _localSec(10, 10),
        reason: 'the local prune claim survives the interrupted import');
  });
}
