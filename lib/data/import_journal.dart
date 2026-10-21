// Durable import journal (decision D38): an import that is interrupted must
// resume, and must never be silent.
//
// Design (see edge.research/merge-decisions-log.md D38):
//  * `import_journal` row per import, advanced IN THE SAME TRANSACTION as each
//    chunk, so journal == data.
//  * The source file is copied into app storage first so a resume can reopen it.
//  * The post-import derive is scheduled only when state == done.
//  * Android: the copy runs under a foreground service, requested/released
//    through [ImportForegroundService] (the existing EdgeTrackingService is
//    started via MethodChannel 'openstrap/edge_tracking', start/stop).
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../sync/edge_tracking.dart';
import 'db.dart';
import 'import_progress.dart';

enum ImportJournalState { copying, extras, done, failed }

/// What the UI reads: an unfinished or failed import is never invisible.
class ImportJournalStatus {
  const ImportJournalStatus({
    required this.state,
    this.table,
    this.tableIdx = 0,
    this.lastRowid = 0,
    this.rowsCopied = 0,
    this.rowsTotal = 0,
    this.interrupted = false,
    this.resuming = false,
    this.interruptedAndResumed = 0,
    this.error,
  });
  final ImportJournalState state;
  final String? table;
  final int tableIdx, lastRowid, rowsCopied, rowsTotal;

  /// Unfinished and nothing is running it right now.
  final bool interrupted;

  /// A resume is running right now.
  final bool resuming;

  /// How many times this import was interrupted and then resumed.
  final int interruptedAndResumed;
  final String? error;
}

/// One chunk of the bulk copy, as the test hook sees it.
class ImportChunk {
  const ImportChunk(this.table, this.index, this.fromRowid, this.toRowid);
  final String table;
  final int index, fromRowid, toRowid;
}

/// Test seams. [chunk] runs INSIDE the chunk's transaction, after the chunk and
/// the journal row were written, so a throw rolls both back together.
/// See [ImportHooks.table].
abstract interface class ImportTableProbe {
  Future<void> beforeTable(String table);
}

class ImportHooks {
  static Future<void> Function(Transaction txn, ImportChunk c)? chunk;

  /// Rows per chunk; null = the production 25,000.
  static int? chunkRows;

  /// Told as the merge reaches each table, before it copies. Tests only:
  /// throw from it to kill an import between tables. An interface, not a
  /// function field, so the heavy-calc guard resolves the call.
  static ImportTableProbe? table;

  static void reset() {
    chunk = null;
    chunkRows = null;
    table = null;
  }
}

/// Seam for the Android foreground service that keeps the copy alive.
abstract class ImportForegroundService {
  static ImportForegroundService instance = _EdgeTrackingImportService();
  Future<void> request(String stage);
  Future<void> release();
}

/// Production seam: the shared Edge Tracking service, held under the name
/// 'import' so releasing it never stops a service BLE tracking started (see
/// [EdgeTracking.hold]). The service shows one fixed notification; it has no
/// stage text, so [stage] is not displayed.
class _EdgeTrackingImportService implements ImportForegroundService {
  @override
  Future<void> request(String stage) => EdgeTracking.hold('import');
  @override
  Future<void> release() => EdgeTracking.release('import');
}


class ImportResumeResult {
  const ImportResumeResult({this.resumed = false, this.error});
  final bool resumed;

  /// Set when a resume ran and failed again; the journal keeps the same text.
  final String? error;
}

/// One import as the merge sees it: where to start, and what to persist.
class ImportRun {
  ImportRun({
    required this.id,
    required this.sourcePath,
    required this.startedAt,
    this.resumed = false,
    this.state = ImportJournalState.copying,
    this.tableIdx = 0,
    this.tableName,
    this.lastRowid = 0,
    this.rowsCopied = 0,
    this.resumes = 0,
    this.fresh = false,
    this.archiveSkipped = 0,
    this.preFinal,
    this.cursorBefore,
  });
  final int id, startedAt;
  final String sourcePath;
  final bool resumed;
  ImportJournalState state;
  int tableIdx, lastRowid, rowsCopied, resumes, archiveSkipped;
  String? tableName;

  /// This install held no data when the import began (needed again by the
  /// extras step on a resume, when it no longer holds none).
  final bool fresh;

  /// `day|version` of every finalized day_result BEFORE the import. A resume
  /// must protect these, not the finalized rows the import itself has landed.
  List<String>? preFinal;

  /// The local `decoded_pruned_before` BEFORE the import: an integer, or
  /// `none`; null until recorded. Written before any table copies and used on
  /// a resume, because the file's own `sync_cursor` may already have replaced
  /// the live value by then (reconciling against that would forget the local
  /// prune holes).
  String? cursorBefore;

  /// Index into [tables] of the table to start at.
  int startIndex(List<String> tables) {
    if (!resumed) return 0;
    final n = tableName;
    if (n != null && tables.contains(n)) return tables.indexOf(n);
    return tableIdx;
  }

  /// The rowid to continue from inside table [index].
  int startRowid(int index, List<String> tables) =>
      resumed && index == startIndex(tables) && tableName != null
          ? lastRowid
          : 0;
}

/// Latest import's durable state. Owner of the `import_journal` table, the
/// saved copy of the source file and the `import_run_v1` side record.
class ImportJournal {
  static const List<String> columns = [
    'id', 'source_path', 'source_size', 'source_mtime', 'source_sha_prefix',
    'started_at', 'state', 'table_idx', 'table_name', 'last_rowid',
    'rows_copied', 'error', 'resumes',
  ];

  /// A failed import is retried at app start this many times, then left
  /// visible for the user (who can still resume it by hand).
  static const int kMaxAutoResumes = 3;
  static const String _metaKey = 'import_run_v1';

  static bool _running = false, _resuming = false;
  static Future<ImportResumeResult>? _resumeFlight;
  static final StreamController<ImportJournalStatus?> _ctl =
      StreamController<ImportJournalStatus?>.broadcast();
  static bool _notifyBusy = false, _notifyAgain = false;
  static final Map<String, int> _totals = {};

  /// Idempotent, additive. Called from the schema step and from
  /// `_repairOpenSchema`.
  static Future<void> ensureSchema(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS import_journal ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, source_path TEXT, '
        'source_size INTEGER, source_mtime INTEGER, source_sha_prefix TEXT, '
        'started_at INTEGER, state TEXT NOT NULL, '
        'table_idx INTEGER NOT NULL DEFAULT 0, table_name TEXT, '
        'last_rowid INTEGER NOT NULL DEFAULT 0, '
        'rows_copied INTEGER NOT NULL DEFAULT 0, error TEXT, '
        'resumes INTEGER NOT NULL DEFAULT 0)');
  }

  static ImportJournalState _parse(Object? s) => ImportJournalState.values
      .firstWhere((e) => e.name == s, orElse: () => ImportJournalState.failed);

  /// The latest import's status, or null when none was ever journaled.
  static Future<ImportJournalStatus?> current() async {
    final db = await LocalDb.instance;
    final rows = await db.query('import_journal', orderBy: 'id DESC', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final state = _parse(r['state']);
    final unfinished = state != ImportJournalState.done;
    final table = r['table_name'] as String?;
    return ImportJournalStatus(
      state: state,
      table: table,
      tableIdx: (r['table_idx'] as int?) ?? 0,
      lastRowid: (r['last_rowid'] as int?) ?? 0,
      rowsCopied: (r['rows_copied'] as int?) ?? 0,
      rowsTotal:
          unfinished && table != null ? await _total(r['source_path'], table) : 0,
      interrupted: unfinished && !_running,
      resuming: unfinished && _resuming,
      interruptedAndResumed: (r['resumes'] as int?) ?? 0,
      error: r['error'] as String?,
    );
  }

  /// MAX(rowid) of [table] in the saved source: the same measure the copy
  /// advances by (a sparse table counts its gaps).
  static Future<int> _total(Object? path, String table) async {
    if (path is! String || !File(path).existsSync()) return 0;
    final key = '$path|$table';
    final hit = _totals[key];
    if (hit != null) return hit;
    Database? src;
    try {
      src = await openDatabase(path, readOnly: true, singleInstance: false);
      final v = Sqflite.firstIntValue(await src
              .rawQuery('SELECT MAX(rowid) FROM "${table.replaceAll('"', '""')}"')) ??
          0;
      return _totals[key] = v;
    } catch (_) {
      return 0;
    } finally {
      await src?.close();
    }
  }

  /// Emits on every journal change.
  static Stream<ImportJournalStatus?> get changes => _ctl.stream;

  static void notify() {
    if (!_ctl.hasListener) return;
    if (_notifyBusy) {
      _notifyAgain = true;
      return;
    }
    _notifyBusy = true;
    unawaited(_pump());
  }

  static Future<void> _pump() async {
    try {
      do {
        _notifyAgain = false;
        _ctl.add(await current());
      } while (_notifyAgain);
    } catch (_) {
      /* a status read must never fail an import */
    } finally {
      _notifyBusy = false;
    }
  }

  /// True when no import is unfinished (derive may run on imported days).
  static Future<bool> deriveAllowed() async {
    final st = await current();
    return st == null || st.state == ImportJournalState.done;
  }

  /// Calls [request] only when the import is done; returns whether it did.
  /// An unfinished import is resumed from app start, which asks again.
  static Future<bool> requestDeriveWhenDone(void Function() request) async {
    if (!await deriveAllowed()) return false;
    await LocalDb.applyImportRederive();
    Zone.current.run(request);
    return true;
  }

  /// Imported days whose derive must be (re)done after a resume.
  static Future<Set<String>> daysToRederive() async {
    final m = await metaSnapshot();
    return splitList(m['rederive']).toSet();
  }

  // ── side record ────────────────────────────────────────────────────────────

  /// The side record: `key=value` lines; lists are comma-joined day labels
  /// (no commas inside a label). Plain text on purpose: it is small, owned by
  /// this class, and not a stored payload anyone else decodes.
  static Future<Map<String, String>> metaSnapshot() async {
    final row = await LocalDb.computeFreshness(_metaKey);
    final out = <String, String>{};
    for (final line in '${row?['payload_json'] ?? ''}'.split('\n')) {
      final i = line.indexOf('=');
      if (i > 0) out[line.substring(0, i)] = line.substring(i + 1);
    }
    return out;
  }

  /// Merges [patch] into the record; a null value removes the key.
  static Future<void> putMeta(Map<String, String?> patch) async {
    final m = await metaSnapshot();
    for (final e in patch.entries) {
      if (e.value == null) {
        m.remove(e.key);
      } else {
        m[e.key] = e.value!;
      }
    }
    await LocalDb.putComputeFreshness(_metaKey,
        [for (final e in m.entries) '${e.key}=${e.value}'].join('\n'));
  }

  static List<String> splitList(String? v) =>
      v == null || v.isEmpty ? <String>[] : v.split(',');

  // ── lifecycle ──────────────────────────────────────────────────────────────

  static Future<Directory> _dir() async {
    // Beside the database: app-private, never the OS cache, and available
    // wherever the database is (no path_provider needed).
    final d = Directory(p.join(await getDatabasesPath(), 'import_resume'));
    await d.create(recursive: true);
    return d;
  }

  /// Hash of the first 64 KB: with the size, enough to tell that the saved
  /// copy is the file that was journaled (mtime is not stable across reads).
  static Future<String> _shaPrefix(File f) async {
    final h = await f.open();
    try {
      return sha256.convert(await h.read(65536)).toString().substring(0, 16);
    } finally {
      await h.close();
    }
  }

  /// Copies [src] into app storage and opens the journal row, replacing any
  /// earlier one (only the latest import is tracked).
  static Future<ImportRun> begin(String src, {required bool fresh}) async {
    // One file per import, never a fixed name: the directory is shared by every
    // database in this databases dir, and a fixed name let one import's cleanup
    // (or its replacing the copy) delete the copy another still needs.
    final dest = p.join((await _dir()).path,
        'source-${DateTime.now().microsecondsSinceEpoch}-$pid.db');
    final f = File(dest);
    await File(src).copy(dest);
    final stat = await f.stat();
    final sha = await _shaPrefix(f);
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await LocalDb.instance;
    final earlier = [
      for (final r in await db.query('import_journal', columns: ['source_path']))
        r['source_path'],
    ];
    final id = await db.transaction((txn) async {
      await txn.delete('import_journal');
      return txn.insert('import_journal', {
        'source_path': dest,
        'source_size': stat.size,
        'source_mtime': stat.modified.millisecondsSinceEpoch,
        'source_sha_prefix': sha,
        'started_at': now,
        'state': ImportJournalState.copying.name,
      });
    });
    // Only the latest import is tracked: the replaced row's copy goes with it.
    for (final e in earlier) {
      await _removeSource(e);
    }
    await LocalDb.putComputeFreshness(
        _metaKey, 'fresh=${fresh ? 1 : 0}');
    notify();
    return ImportRun(
        id: id, sourcePath: dest, startedAt: now, fresh: fresh);
  }

  /// Advances the journal. Called INSIDE the chunk's transaction, so the
  /// journal and the rows it describes commit or roll back together.
  static Future<void> advance(DatabaseExecutor x, ImportRun run, int idx,
      String table, int lastRowid, int rowsDelta) async {
    await x.rawUpdate(
        'UPDATE import_journal SET table_idx = ?, table_name = ?, '
        'last_rowid = ?, rows_copied = CASE WHEN table_name IS ? '
        'THEN rows_copied + ? ELSE ? END WHERE id = ?',
        [idx, table, lastRowid, table, rowsDelta, rowsDelta, run.id]);
  }

  /// Table [idx] - 1 is complete; the copy continues at [idx].
  static Future<void> tableDone(ImportRun run, int idx, String? next,
      {int archiveSkipped = 0}) async {
    final db = await LocalDb.instance;
    await db.update(
        'import_journal',
        {'table_idx': idx, 'table_name': next, 'last_rowid': 0, 'rows_copied': 0},
        where: 'id = ?', whereArgs: [run.id]);
    if (archiveSkipped != run.archiveSkipped) {
      run.archiveSkipped = archiveSkipped;
      await putMeta({'archiveSkipped': '$archiveSkipped'});
    }
    notify();
  }

  static Future<void> setState(ImportRun run, ImportJournalState s) async {
    final db = await LocalDb.instance;
    run.state = s;
    await db.update('import_journal', {'state': s.name, 'error': null},
        where: 'id = ?', whereArgs: [run.id]);
    notify();
  }

  /// Records the failure. A failure before anything was copied leaves nothing
  /// to resume (a file that is not a backup): the journal is dropped and the
  /// thrown error is the whole report.
  static Future<void> fail(ImportRun run, Object e) async {
    try {
      final db = await LocalDb.instance;
      final r = (await db.query('import_journal',
              where: 'id = ?', whereArgs: [run.id]))
          .firstOrNull;
      if (r == null) return;
      final untouched = r['table_idx'] == 0 &&
          r['last_rowid'] == 0 &&
          r['resumes'] == 0 &&
          r['state'] == ImportJournalState.copying.name;
      if (untouched) {
        await db.delete('import_journal', where: 'id = ?', whereArgs: [run.id]);
        await _removeSource(run.sourcePath);
        await LocalDb.deleteComputeFreshness(_metaKey);
      } else {
        await db.update(
            'import_journal',
            {'state': ImportJournalState.failed.name, 'error': '$e'},
            where: 'id = ?', whereArgs: [run.id]);
      }
    } catch (_) {
      /* the original error is the one that matters */
    }
    notify();
  }

  /// Deletes the saved copy at [path] (this journal's own, by its row) and
  /// nothing else in the directory.
  static Future<void> _removeSource(Object? path) async {
    try {
      if (path is! String) return;
      final f = File(path);
      if (p.equals(p.dirname(path), (await _dir()).path) && f.existsSync()) {
        await f.delete();
      }
    } catch (_) {}
  }

  /// A copy no journal row names, left by a wiped journal or a killed process.
  /// Old ones only: a younger file may belong to another database's import
  /// that is running right now.
  static Future<void> _sweepOrphans() async {
    try {
      final db = await LocalDb.instance;
      final named = {
        for (final r in await db.query('import_journal', columns: ['source_path']))
          r['source_path'],
      };
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final e in (await _dir()).list()) {
        if (e is File &&
            !named.contains(e.path) &&
            e.statSync().modified.isBefore(cutoff)) {
          await e.delete();
        }
      }
    } catch (_) {}
  }

  /// All tables and extras are in: mark the imported days for re-derive,
  /// close the journal, drop the saved copy.
  static Future<void> finish(ImportRun run) async {
    final db = await LocalDb.instance;
    final days = await _sourceDays(run.sourcePath);
    // Days derived while the copy was unfinished (or a resume happened at all)
    // were computed from a partial range; this build's rows for them are redone.
    var mark = <String>{};
    if (run.resumes > 0) {
      mark = days;
    } else if (days.isNotEmpty) {
      for (final d in days) {
        final hit = await db.query('day_result',
            columns: ['day_id'],
            where: 'day_id = ? AND computed_at >= ?',
            whereArgs: [d, run.startedAt],
            limit: 1);
        if (hit.isNotEmpty) mark.add(d);
      }
    }
    await putMeta({
      'rederive': (mark.toList()..sort()).join(','),
      'rederiveApplied': '0',
      'preFinal': null,
      'cursorBefore': null,
    });
    await db.update(
        'import_journal',
        {'state': ImportJournalState.done.name, 'error': null},
        where: 'id = ?', whereArgs: [run.id]);
    run.state = ImportJournalState.done;
    await _removeSource(run.sourcePath);
    notify();
  }

  /// Local days of the source's 1 Hz rows plus its day_result days.
  static Future<Set<String>> _sourceDays(String path) async {
    final out = <String>{};
    Database? src;
    try {
      src = await openDatabase(path, readOnly: true, singleInstance: false);
      for (final q in const [
        "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS d "
            'FROM decoded_onehz WHERE rec_ts > 0 GROUP BY d',
        'SELECT DISTINCT day_id AS d FROM day_result',
      ]) {
        try {
          for (final r in await src.rawQuery(q)) {
            if (r['d'] != null) out.add('${r['d']}');
          }
        } on DatabaseException {
          /* the export lacks that table */
        }
      }
    } catch (_) {
      /* unreadable copy: nothing to mark */
    } finally {
      await src?.close();
    }
    return out;
  }

  /// The pre-import finalized-day record, written once at the start of the
  /// merge and read back by a resume.
  /// When the latest import began (ms), for the re-derive cut-off.
  static Future<int> latestStartedAt() async {
    final db = await LocalDb.instance;
    final r = await db.query('import_journal',
        columns: ['started_at'], orderBy: 'id DESC', limit: 1);
    return r.isEmpty ? 0 : (r.first['started_at'] as int?) ?? 0;
  }

  static Future<List<String>?> loadPreFinal() async {
    final l = (await metaSnapshot())['preFinal'];
    return l == null ? null : splitList(l);
  }

  // ── exclusion + service ────────────────────────────────────────────────────

  /// Runs [job] as THE import: one at a time, under the foreground service,
  /// with the service released and the flags cleared on every exit.
  static Future<T> runExclusive<T>(
      {required String stage,
      bool resuming = false,
      required Future<T> Function() job}) async {
    if (_running) throw StateError('An import is already running');
    _running = true;
    _resuming = resuming;
    notify();
    final svc = ImportForegroundService.instance;
    try {
      await svc.request(stage);
      return await Zone.current.run(job);
    } finally {
      _running = false;
      _resuming = false;
      try {
        await svc.release();
      } catch (_) {}
      notify();
    }
  }

  static bool get isRunning => _running;

  // ── resume ─────────────────────────────────────────────────────────────────

  /// On app start / import-screen open: resume an unfinished journal from
  /// (table, last_rowid), then extras, summary, and [requestDerive]. Never
  /// throws: a resume that fails again is recorded in the journal and returned.
  /// [force] retries a failed import past [kMaxAutoResumes].
  static Future<ImportResumeResult> resumeIfUnfinished({
    void Function(ImportProgress p)? onProgress,
    void Function()? requestDerive,
    bool force = false,
  }) {
    if (_running) return Future.value(const ImportResumeResult());
    return _resumeFlight ??= _resume(onProgress, requestDerive, force)
        .whenComplete(() => _resumeFlight = null);
  }

  static Future<ImportResumeResult> _resume(
      void Function(ImportProgress p)? onProgress,
      void Function()? requestDerive,
      bool force) async {
    final db = await LocalDb.instance;
    final rows = await db.query('import_journal', orderBy: 'id DESC', limit: 1);
    final r = rows.firstOrNull;
    if (r == null || r['state'] == ImportJournalState.done.name) {
      if (r == null) await _sweepOrphans(); // a copy of a wiped journal
      return const ImportResumeResult();
    }
    final failed = r['state'] == ImportJournalState.failed.name;
    if (failed && !force && ((r['resumes'] as int?) ?? 0) >= kMaxAutoResumes) {
      return const ImportResumeResult();
    }
    final path = r['source_path'] as String?;
    final f = path == null ? null : File(path);
    if (f == null ||
        !f.existsSync() ||
        f.lengthSync() != r['source_size'] ||
        await _shaPrefix(f) != r['source_sha_prefix']) {
      const why = 'The saved copy of the import file is missing or changed; '
          'import the file again.';
      await db.update(
          'import_journal',
          {
            'state': ImportJournalState.failed.name,
            'error': why,
            'resumes': ((r['resumes'] as int?) ?? 0) + 1000, // no auto retry
          },
          where: 'id = ?', whereArgs: [r['id']]);
      notify();
      return const ImportResumeResult(error: why);
    }
    final meta = await metaSnapshot();
    final run = ImportRun(
      id: r['id'] as int,
      sourcePath: path!,
      startedAt: (r['started_at'] as int?) ?? 0,
      resumed: true,
      state: _parse(r['state']) == ImportJournalState.extras
          ? ImportJournalState.extras
          : ImportJournalState.copying,
      tableIdx: (r['table_idx'] as int?) ?? 0,
      tableName: r['table_name'] as String?,
      lastRowid: (r['last_rowid'] as int?) ?? 0,
      rowsCopied: (r['rows_copied'] as int?) ?? 0,
      resumes: ((r['resumes'] as int?) ?? 0) + 1,
      fresh: meta['fresh'] == '1',
      archiveSkipped: int.tryParse(meta['archiveSkipped'] ?? '') ?? 0,
      preFinal: await loadPreFinal(),
      cursorBefore: meta['cursorBefore'],
    );
    await db.update('import_journal',
        {'state': run.state.name, 'error': null, 'resumes': run.resumes},
        where: 'id = ?', whereArgs: [run.id]);
    try {
      await runExclusive(
          stage: 'resuming',
          resuming: true,
          job: () => LocalDb.runJournaledImport(run, onProgress));
    } catch (e) {
      await fail(run, e);
      return ImportResumeResult(resumed: true, error: '$e');
    }
    if (requestDerive != null) await requestDeriveWhenDone(requestDerive);
    return const ImportResumeResult(resumed: true);
  }
}
