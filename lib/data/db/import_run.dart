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
Future<ImportSummary> _ldbImportPlain(
    String file, void Function(ImportProgress p)? onProgress) async {
  // Before anything merges: "fresh" means this install held no data.
  final source = await openDatabase(file, readOnly: true, singleInstance: false);
  final bool hasSettings;
  try {
    hasSettings = await LocalDb._objectType(source, 'backup_prefs') == 'table';
  } finally { await source.close(); }
  final fresh = hasSettings && await isFreshInstall();
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
Future<ImportSummary> _ldbRunJournaledImport(ImportRun run, void Function(ImportProgress p)? onProgress) async {
    final file = run.sourcePath;
    final perfId = '${run.startedAt}-${run.id}';
    ImportPerf.start(perfId);
    final watch = Stopwatch()..start();
    final phaseWatch = Stopwatch()..start();
    ImportPerf.write(
      perfId,
      'begin',
      'build=0.11.3+78 schema=${LocalDb.schemaVersion} bytes=${await File(file).length()} resumed=${run.resumed}',
    );
    try {
      var counts = <String, int>{};
      if (run.resumed) {
        final st = await ImportJournal.current();
        final stage = _ldbPrivImportStageOf(run.tableName ?? '');
        final total = st?.rowsTotal ?? 0;
        if (onProgress != null) {
          Zone.current.runUnary(
            onProgress,
            ImportResuming(stage, run.lastRowid, total, 0, 1),
          );
        }
      }
      if (run.state != ImportJournalState.extras) {
        counts = await SampleLock.run(
          () => LocalDb._mergeFromDbFile(file, onProgress: onProgress, run: run),
        );
        await ImportJournal.setState(run, ImportJournalState.extras);
      }
      ImportPerf.phase('copy', phaseWatch, run: perfId);
      final extras = await restoreBackupExtras(file, freshInstall: run.fresh);
      final source = await openDatabase(file, readOnly: true, singleInstance: false);
      try {
        if (await LocalDb._objectType(source, 'backup_prefs') == 'table') {
          await LocalDb.setCursor(LocalDb._kSettingsImported, '1');
        }
      } finally { await source.close(); }
      ImportPerf.phase('extras', phaseWatch, run: perfId);
      await recordImportSummary(
        file,
        archiveBucketsSkipped:
            counts['_substrate_archive_skipped'] ?? run.archiveSkipped,
        extras: extras,
        interruptedAndResumed: run.resumes,
        runId: reentryRunIdOf(run.id, run.startedAt),
      );
      if (extras.keysWritten.isNotEmpty) {
        await SettingsRepository.instance.announceRestored(extras.keysWritten);
        settingsRestoredSignal.value++;
      }
      ImportPerf.phase('summary', phaseWatch, run: perfId);
      await ImportJournal.finish(run);
      ImportPerf.phase('journal_finish', phaseWatch, run: perfId);
      var totalRows = 0, totalTables = 0;
      for (final entry in counts.entries) {
        if (!entry.key.startsWith('_')) {
          totalTables++;
          totalRows += entry.value;
        }
      }
      ImportPerf.write(
        perfId,
        'end',
        'status=ok tables=$totalTables rows=$totalRows pages=${ImportPerf.finish(perfId)} ms=${watch.elapsedMilliseconds}',
      );
      return ImportSummary(tables: counts, keysWritten: extras.keysWritten,
          refusedPrefs: extras.refusedPrefs, needsReentry: extras.needsReentry,
          unreadableSecrets: extras.unreadableSecrets,
          prefsRestored: extras.prefsRestored, prefsKept: extras.prefsKept,
          filesRestored: extras.filesRestored, interruptedAndResumed: run.resumes,
          sleepRefused: [for (final e in await SleepImportReport.load()) if (e.refused) e],
          sleepCloseReview: [for (final e in await SleepImportReport.load()) if (!e.refused) e]);
    } catch (_) {
      ImportPerf.write(
        perfId,
        'end',
        'status=failed pages=${ImportPerf.finish(perfId)} ms=${watch.elapsedMilliseconds}',
      );
      rethrow;
    }
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
    await LocalDb.clearDerivedDays(days.toSet(), computedSince: since);
    await LocalDb._markStoreReplaced();
  }
  await ImportJournal.putMeta({'rederiveApplied': '1'});
  }
