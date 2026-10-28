// An import killed after the experiment tables were merged, then resumed, must
// still leave one experiment per overlapping range (review R2-10 / T16).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/import_journal.dart';

import '../backup/backup_support.dart';

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
  setUpAll(() async => env = await BackupEnv.create('openstrap_import_experiment_overlap.db'));
  tearDownAll(() async => env.dispose());
  setUp(() async {
    await env.wipe();
    ImportHooks.reset();
  });
  tearDown(ImportHooks.reset);

  Future<void> put(String id, String track, String from, int days, int created) async {
    final db = await LocalDb.instance;
    final first = DateTime.parse(from);
    await db.insert('track_experiment', {
      'id': id,
      'track_id': track,
      'start_date': from,
      'end_date': dayLabelOf(DateTime(first.year, first.month, first.day + days - 1)),
      'weeks': days ~/ 7,
      'seed': 1,
      'created_ms': created,
    });
    for (var i = 0; i < days; i++) {
      await db.insert('track_experiment_day', {
        'experiment_id': id,
        'date': dayLabelOf(DateTime(first.year, first.month, first.day + i)),
        'do_it': i.isEven ? 1 : 0,
      });
    }
  }

  // why: review R2-10. Reconciliation ran only when THIS invocation copied
  // track_experiment; a resumed import skips tables the first run committed, so
  // the conflicting local experiment survived. Interrupt after the parent table
  // (before day_result), resume, and expect the overlap resolved.
  // proves: CLAIM(one-experiment-per-track)
  test('a resumed import still reconciles overlapping experiments', () async {
    await put('xp-a', 'custom', '2026-09-01', 14, 100);
    await put('xp-c', 'custom', '2026-10-01', 14, 120);
    final path = await LocalDb.exportCopy();
    await env.wipe();
    await LocalDb.instance;
    await put('xp-b', 'custom', '2026-09-08', 14, 200);

    ImportHooks.table = _KillAt('day_result');
    await expectLater(LocalDb.importFromDbFile(path), throwsA(isA<StateError>()));
    var db = await LocalDb.instance;
    expect(
      [for (final r in await db.query('track_experiment', orderBy: 'id')) r['id']],
      ['xp-a', 'xp-b', 'xp-c'],
      reason: 'precondition: the parent table committed before the kill',
    );

    ImportHooks.table = null;
    await LocalDb.close(); // a fresh open, as after a process restart
    final r = await ImportJournal.resumeIfUnfinished();
    expect(r.resumed, isTrue);
    db = await LocalDb.instance;
    expect(
      [for (final r in await db.query('track_experiment', orderBy: 'id')) r['id']],
      ['xp-a', 'xp-c'],
    );
    expect(await db.query('track_experiment_day', where: 'experiment_id = ?', whereArgs: ['xp-b']), isEmpty);
    expect(await db.query('track_experiment_day', where: 'experiment_id = ?', whereArgs: ['xp-a']), hasLength(14));
  });
}
