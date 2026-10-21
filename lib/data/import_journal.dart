// Durable import journal (decision D38): an import that is interrupted must
// resume, and must never be silent.
//
// RED-PHASE STUBS ONLY. Every member compiles and does nothing; the tests in
// test/import_resume/ pin the behaviour the green phase fills in.
//
// Design (see edge.research/merge-decisions-log.md D38):
//  * `import_journal` row per import, advanced IN THE SAME TRANSACTION as each
//    chunk, so journal == data.
//  * The source file is copied into app storage first so a resume can reopen it.
//  * The post-import derive is scheduled only when state == done.
//  * Android: the copy runs under a foreground service, requested/released
//    through [ImportForegroundService] (the existing EdgeTrackingService is
//    started via MethodChannel 'openstrap/edge_tracking', start/stop).
import 'package:sqflite/sqflite.dart';

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
class ImportHooks {
  static Future<void> Function(Transaction txn, ImportChunk c)? chunk;

  /// Rows per chunk; null = the production 25,000.
  static int? chunkRows;

  static void reset() {
    chunk = null;
    chunkRows = null;
  }
}

/// Seam for the Android foreground service that keeps the copy alive.
abstract class ImportForegroundService {
  static ImportForegroundService instance = _NoService();
  Future<void> request(String stage);
  Future<void> release();
}

class _NoService implements ImportForegroundService {
  @override
  Future<void> request(String stage) async {}
  @override
  Future<void> release() async {}
}

class ImportResumeResult {
  const ImportResumeResult({this.resumed = false});
  final bool resumed;
}

class ImportJournal {
  static const List<String> columns = [
    'id', 'source_path', 'source_size', 'source_mtime', 'source_sha_prefix',
    'started_at', 'state', 'table_idx', 'table_name', 'last_rowid',
    'rows_copied', 'error', 'resumes',
  ];

  /// Idempotent, additive. Called from the schema step and from
  /// `_repairOpenSchema`.
  static Future<void> ensureSchema(DatabaseExecutor db) async {}

  /// The latest import's status, or null when none was ever journaled.
  static Future<ImportJournalStatus?> current() async => null;

  /// Emits on every journal change.
  static Stream<ImportJournalStatus?> get changes => const Stream.empty();

  /// True when no import is unfinished (derive may run on imported days).
  static Future<bool> deriveAllowed() async => true;

  /// Calls [request] only when the import is done; returns whether it did.
  static Future<bool> requestDeriveWhenDone(void Function() request) async {
    request();
    return true;
  }

  /// Imported days whose derive must be (re)done after a resume.
  static Future<Set<String>> daysToRederive() async => <String>{};

  /// On app start / import-screen open: resume an unfinished journal from
  /// (table, last_rowid), then extras, summary, and [requestDerive].
  static Future<ImportResumeResult> resumeIfUnfinished({
    void Function(ImportProgress p)? onProgress,
    void Function()? requestDerive,
  }) async => const ImportResumeResult();
}
