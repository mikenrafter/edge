import 'db.dart' show LocalDb;

// restore_classification.dart — the tables an import deliberately does NOT
// carry, each with the reason. Every other table in the schema is in
// LocalDb._restoreTables (LocalDb.restoredTableNames); a guard test
// (test/backup/wake_ledger_tables_restore_test.dart) fails when a table is in
// neither, so a new table cannot silently fall out of export -> import.
//
// wake_trace is restored with a row policy: journal-bearing kinds merge by
// event content, local acknowledgements win, and foreign diagnostics are skipped.
// water_moment is durable user history and merges by its stable UUID through
// LocalDb._restoreTables, including two explicit glasses in one minute.
// Same shape as kPrefsNotBackedUp (backup_extras.dart).

/// Table name -> why a restore leaves it alone.
const Map<String, String> kTablesNotRestored = {
  // Derive caches: rebuilt by the next derive from what IS restored.
  'last_result': 'computed-on-open screen view; rebuilt by the next read',
  'wake_day_features': 'interim per-day features; rebuilt from raw by the derive',
  'night_checkpoint': 'night and cardio resume cache belonging to this store',
  'store_identity': 'identity of this database file; never imported',
  'session_ceiling_rev': 'revision counter rebuilt by session triggers',
  'derive_fingerprint': 'input cache rebuilt by the next derivation',
  'day_checkpoint': 'resume scratch keyed to this install\'s calculation state',
  'group_row': 'derive cache keyed to this install\'s counters',
  'day_manifest': 'publication record of this install\'s group rows',
  'derived_day': 'legacy derived-day cache superseded by day_result',
  'session_score_mask': 'rewritten from sessions on every derive',
  'live_workout_tally': 'scratch of a workout in progress on this phone',
  // Bookkeeping of THIS install: values would be false on another phone.
  'compute_freshness': 'derive bookkeeping (fingerprints, cursors) of this install',
  'compute_jobs': 'this install\'s derive queue',
  'import_journal': 'where this install\'s last import stands',
  'input_revision': 'maintained by triggers on the restored tables',
  'input_rev': 'maintained by triggers on the restored decoded rows',
  'input_rev_bulk': 'transient flag while a restore batches its revision bumps',
  'row_rev': 'maintained by triggers on the derived tables',
  'store_rev': 'maintained by triggers; a counter of this install\'s writes',
  // Diagnostics and replay ledgers whose content is carried elsewhere.
  'raw_archive_frames': 'durable archive restored through the raw_archive row adapter',
  'raw_archive_legacy': 'durable archive restored through the raw_archive row adapter',
  'raw_records': 'replay/debug ledger; decoded_onehz, decoded_rr and '
      'raw_archive carry its content',
  'sync_quarantine': 'payloads this phone could not ingest; not user data',
  // Written onto the exported COPY by the extras path, not restored as rows.
  'backup_secrets': 'credential-presence signals restored by restoreBackupExtras',
  'backup_prefs': 'restored by restoreBackupExtras, not by the table merge',
  'backup_files': 'restored by restoreBackupExtras, not by the table merge',
};

enum RestoreClass { merge, localOnly, rebuildable }
final kRestoreClassification = <String, RestoreClass>{
  for (final table in kTablesNotRestored.keys) table: RestoreClass.localOnly,
  for (final table in LocalDb.restoredTableNames) table: RestoreClass.merge,
  'raw_archive_frames': RestoreClass.merge,
  'raw_archive_legacy': RestoreClass.merge,
  'day_checkpoint': RestoreClass.rebuildable,
  'night_checkpoint': RestoreClass.rebuildable,
  'derive_fingerprint': RestoreClass.rebuildable,
  'input_rev': RestoreClass.rebuildable,
  'session_ceiling_rev': RestoreClass.rebuildable,
};
