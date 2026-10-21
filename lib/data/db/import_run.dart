part of '../db.dart';

// The journaled import (decision D38). Owner of the import's control flow;
// [ImportJournal] owns the durable state, `_ldbPrivMergeFromDbFileBody` the copy.

/// Merges the SQL tables of the plain database at [file], then puts back what
/// rides beside them (settings, recordings) and leaves the summary. Both the
/// real import and the row-by-row oracle end here, so they stay identical.
///
/// The source is first copied into app storage and journaled, so a process
/// killed mid-copy is resumed (and reported) on the next start instead of
/// leaving a silent partial import.
Future<Map<String, int>> _ldbImportPlain(
    String file, void Function(ImportProgress p)? onProgress) async {
  // Before anything merges: "fresh" means this install held no data.
  final fresh = await isFreshInstall();
  return ImportJournal.runExclusive(stage: 'copying', job: () async {
    ImportRun? run;
    try {
      run = await ImportJournal.begin(file, fresh: fresh);
      return await _ldbRunJournaledImport(run, onProgress);
    } catch (e) {
      if (run != null) await ImportJournal.fail(run, e);
      rethrow;
    }
  });
  }

/// Runs (or continues) the journaled import: tables, extras, summary, done.
/// Throws on failure; the caller records it in the journal.
Future<Map<String, int>> _ldbRunJournaledImport(
    ImportRun run, void Function(ImportProgress p)? onProgress) async {
  final file = run.sourcePath;
  var counts = <String, int>{};
  if (run.resumed) {
    final st = await ImportJournal.current();
    final stage = _ldbPrivImportStageOf(run.tableName ?? '');
    final total = st?.rowsTotal ?? 0;
    if (onProgress != null) {
      Zone.current.runUnary(
          onProgress, ImportResuming(stage, run.lastRowid, total, 0, 1));
    }
  }
  if (run.state != ImportJournalState.extras) {
    counts = await SampleLock.run(
        () => LocalDb._mergeFromDbFile(file, onProgress: onProgress, run: run));
    await ImportJournal.setState(run, ImportJournalState.extras);
  }
  final extras = await restoreBackupExtras(file, freshInstall: run.fresh);
  await recordImportSummary(file,
      archiveBucketsSkipped:
          counts['_substrate_archive_skipped'] ?? run.archiveSkipped,
      extras: extras,
      interruptedAndResumed: run.resumes);
  if (extras.keysWritten.isNotEmpty) {
    await SettingsRepository.instance.announceRestored(extras.keysWritten);
    settingsRestoredSignal.value++;
  }
  await ImportJournal.finish(run);
  return counts;
  }

/// Once, after an import is done: drops this build's day_result rows that were
/// computed from a partial range while the import was unfinished, so the next
/// derive redoes those days from the complete data. Imported rows keep their
/// source `computed_at` (older than the import) and are not touched.
Future<void> _ldbApplyImportRederive() async {
  final meta = await ImportJournal.metaSnapshot();
  if (meta['rederiveApplied'] == '1') return;
  final days = ImportJournal.splitList(meta['rederive']);
  final since = await ImportJournal.latestStartedAt();
  if (days.isNotEmpty) {
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      for (final chunk in LocalDb._sqlVarChunks(days)) {
        await txn.rawDelete(
            'DELETE FROM day_result WHERE computed_at >= ? AND day_id IN '
            '(${List.filled(chunk.length, '?').join(',')})',
            [since, ...chunk]);
      }
    });
    LocalDb._markStoreReplaced();
  }
  await ImportJournal.putMeta({'rederiveApplied': '1'});
  }
