// Your data — getting it out, keeping a copy, bringing one back.
//
// Everything here was already written, tested, and reachable from nothing.
// `csv_export.dart`, `LocalDb.exportCopy`, `auto_backup.dart` and the four
// importers all existed; the only code that read the whole database out of
// the app was the UPLOAD path. So the app told the user to "export first"
// immediately before the one destructive action in it, and there was no
// export; and the automatic backup defaulted to off with no way to turn it
// on, which made the foreground hook a permanent no-op and the new-phone
// story "you don't have one".
//
// A local-first app whose data cannot leave is not local-first, it is trapped.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/auto_backup.dart';
import '../../data/csv_export.dart';
import '../../data/db.dart';
import '../../import/backup_crypto.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../activity/share.dart' show shareOrigin;
import '../onboarding/welcome.dart'
    show
        ImportOutcome,
        ImportReport,
        PassphraseCancelled,
        askBackupPassphrase,
        runImport;
import '../screens/home_screen.dart' show dbRebuiltCard;
import '../ui2.dart';
import 'phone_import.dart';
import 'profile.dart';

/// What an action has to say for itself: the line to show, and whether it is a
/// failure. Without the second half every outcome rendered as "Done ✓".
typedef _Note = (String text, bool failed);

class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;
  String? _note;

  /// Whether [_note] is a failure. Every outcome used to render as "Done" with
  /// a green check — a thrown FileSystemException from the export included.
  bool _noteFailed = false;
  ImportOutcome? _outcome;

  void _say(String s, {bool failed = false}) {
    if (mounted) {
      setState(() {
        _note = s;
        _noteFailed = failed;
      });
    }
  }

  /// Run [job] with the screen locked, reporting whatever it says or throws.
  ///
  /// Every action on this screen is slow, destructive-adjacent or both, and a
  /// second tap while one is running would race the first over the same files.
  Future<void> _run(Future<_Note> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
      _outcome = null;
    });
    try {
      final (text, failed) = await job();
      _say(text, failed: failed);
    } on PassphraseCancelled {
      // Closing the passphrase prompt is a decision. "Failed:" over it would
      // report the user's own choice back to them as a fault.
    } catch (e) {
      _say(AppLocalizations.of(context)?.dataFailed(e.toString()) ?? 'Failed: $e',
          failed: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_Note> _exportCsv() async {
    final l = AppLocalizations.of(context);
    // Read before the export runs: an anchor taken after a multi-second await
    // may be measuring a screen the user has already left.
    final origin = shareOrigin(context);
    final res = await exportCsvFiles(kCsvExportSets);
    if (res.paths.isEmpty) {
      return res.hasFailures
          ? (l?.dataNothingExportedFailed(res.failed.join(', ')) ??
                  'Nothing exported (${res.failed.join(', ')} failed).',
              true)
          : (l?.dataNothingToExportYet ?? 'Nothing to export yet.', false);
    }
    await Share.shareXFiles([for (final p in res.paths) XFile(p)],
        subject: 'OpenStrap export', sharePositionOrigin: origin);
    final n = res.paths.length;
    final failed = res.hasFailures
        ? ' ${l?.dataSetsFailed(res.failed.length, res.failed.join(', ')) ?? '${res.failed.length} set(s) failed: ${res.failed.join(', ')}.'}'
        : '';
    return (
      (l?.dataFilesShared(n) ?? '$n file${n == 1 ? '' : 's'} shared.') + failed,
      res.hasFailures
    );
  }

  Future<_Note> _exportDb() async {
    final l = AppLocalizations.of(context);
    final origin = shareOrigin(context);
    // VACUUM INTO — a transactionally consistent snapshot, not a file copy.
    final path = await LocalDb.exportCopy();
    await Share.shareXFiles([XFile(path)],
        subject: 'OpenStrap database', sharePositionOrigin: origin);
    return (
      l?.dataDatabaseShared ?? 'Database shared.',
      false
    );
  }

  /// The same VACUUM'd snapshot as [_exportDb], sealed with AES-256-GCM under
  /// a key derived from a passphrase this app never stores.
  ///
  /// The plaintext intermediate is deleted whatever happens: an encrypted
  /// backup that leaves a readable copy of the whole health record in the
  /// share directory has encrypted nothing.
  Future<_Note> _exportEncrypted() async {
    final pass = await askBackupPassphrase(context, creating: true);
    if (pass == null) return ('', false); // cancelled
    if (!mounted) return ('', false);
    final l = AppLocalizations.of(context);
    final origin = shareOrigin(context);
    final plain = await LocalDb.exportCopy();
    final dest = '$plain.osbk';
    try {
      // 210 000 PBKDF2 rounds is seconds of solid CPU. On the UI isolate that
      // is a frozen app; nothing in the crypto path touches a plugin, which is
      // what makes the worker legal.
      await Isolate.run(
          () => encryptBackupFile(File(plain), File(dest), pass));
    } finally {
      try {
        await File(plain).delete();
      } catch (_) {}
    }
    await Share.shareXFiles([XFile(dest)],
        subject: 'OpenStrap encrypted backup', sharePositionOrigin: origin);
    return (
      l?.dataEncryptedBackupShared ??
          'Encrypted backup shared. Without the passphrase nobody '
          'can open it, including this app and us.',
      false
    );
  }

  Future<_Note> _reanalyze(AppState app) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Rebuild all history?'),
      content: const Text('Recalculating all stored days can take several minutes and use battery. Keep Edge open until it finishes. Days whose recordings were already removed cannot be recomputed.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Rebuild all history'))],
    ));
    if (confirmed != true) return ('', false);
    final n = await app.reanalyzeAll();
    return (
      l?.dataDaysReanalyzed(n) ?? '$n day${n == 1 ? '' : 's'} re-analyzed.',
      false
    );
  }

  Future<_Note> _backupNow(AppState app) async {
    final l = AppLocalizations.of(context);
    final outcome = await app.runBackupNow();
    if (outcome.error != null) {
      return (l?.dataBackupFailed(outcome.error!) ?? 'Backup failed: ${outcome.error}', true);
    }
    if (!outcome.succeeded) return (l?.dataBackupSkipped ?? 'Backup skipped.', false);
    return (l?.dataBackedUpTo(outcome.path!) ?? 'Backed up to ${outcome.path}', false);
  }

  Future<_Note> _import(AppState app) async {
    final l = AppLocalizations.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform
          .pickFiles(allowMultiple: true, withReadStream: false);
    } catch (e) {
      return (
        l?.dataCouldNotOpenPicker(e.toString()) ??
            'Could not open the file picker: $e',
        true
      );
    }
    final paths = (picked?.files ?? const [])
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    // cancelled — not a failure, say nothing
    if (paths.isEmpty) return ('', false);
    final outcome = await runImport(app, paths,
        askPassphrase: () => askBackupPassphrase(context));
    if (mounted) setState(() => _outcome = outcome);
    return ('', false);
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    return DataScreenView(
      rebuiltCard: dbRebuiltCard(app.dbRebuild),
      busy: _busy,
      note: _note,
      noteFailed: _noteFailed,
      outcome: _outcome,
      cadence: app.backupCadence,
      lastBackup: app.lastBackupAt,
      reanalyzeProgress: app.reanalyzeProgress,
      reanalyzing: app.reanalyzing,
      importRollupError: app.importRollupError,
      onExportCsv: () => _run(_exportCsv),
      onExportDb: () => _run(_exportDb),
      onExportEncrypted: () => _run(_exportEncrypted),
      onCycleCadence: () => app.setBackupCadence(_nextCadence(app.backupCadence)),
      onBackupNow: () => _run(() => _backupNow(app)),
      onImport: () => _run(() => _import(app)),
      onPhoneImport: () => goto(c, const PhoneImport()),
      onReanalyze: () => _run(() => _reanalyze(app)),
    );
  }
}

/// Your data without AppState, so it can be pumped headless. Every input is
/// optional; a null callback is an inert row.
class DataScreenView extends StatelessWidget {
  const DataScreenView({
    super.key,
    this.rebuiltCard,
    this.busy = false,
    this.note,
    this.noteFailed = false,
    this.outcome,
    this.cadence = BackupCadence.off,
    this.lastBackup,
    this.reanalyzeProgress = '',
    this.reanalyzing = false,
    this.importRollupError,
    this.onExportCsv,
    this.onExportDb,
    this.onExportEncrypted,
    this.onCycleCadence,
    this.onBackupNow,
    this.onImport,
    this.onPhoneImport,
    this.onReanalyze,
  });

  final Widget? rebuiltCard;
  final bool busy, noteFailed, reanalyzing;
  final String? note, importRollupError;
  final String reanalyzeProgress;
  final ImportOutcome? outcome;
  final BackupCadence cadence;
  final DateTime? lastBackup;
  final VoidCallback? onExportCsv,
      onExportDb,
      onExportEncrypted,
      onCycleCadence,
      onBackupNow,
      onImport,
      onPhoneImport,
      onReanalyze;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final last = lastBackup;
    final o = outcome;
    final rebuilt = rebuiltCard;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.dataNavTitle ?? 'Your data'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                // Home shows this too, on the launch it happened. It belongs
                // here as well because this is the screen someone opens when
                // they notice their food log is empty, and it is the only
                // screen where the card is ALSO an instruction: "Import a
                // file" three rows down reads the quarantined file back.
                // (It is named `openstrap.db.unopenable-<ms>`, not `.db` —
                // `runImport` matches that shape explicitly, because routing
                // on the suffix alone sent a SQLite file into the vendor-CSV
                // importer.)
                if (rebuilt != null) ...[
                  rebuilt,
                  const SizedBox(height: S.x5),
                ],
                SettingsAccordion(l?.dataExportGroup ?? 'Export',
                    id: 'data_export',
                    children: [
                  SetRow(LucideIcons.fileSpreadsheet, C.green,
                      l?.dataExportSpreadsheets ?? 'Export as spreadsheets',
                      // export-provenance: the daily file now carries `source`
                      // and `algo_version` per day, so an imported vendor
                      // snapshot and a day derived from 1 Hz rows stop being
                      // byte-identical. An empty source cell is unknown
                      // provenance — never back-filled to 'band'.
                      sub: l?.dataExportSpreadsheetsSub(kCsvExportSets.length) ??
                          '${kCsvExportSets.length} CSV files: daily metrics, '
                          'workouts, sleep, journal, labs and your manual '
                          'entries. Each day lists its data source and the '
                          'algorithm version that scored it.',
                      onTap: busy ? null : onExportCsv),
                  SetRow(LucideIcons.database, C.blue,
                      l?.dataExportDatabase ?? 'Export the database',
                      sub: l?.dataExportDatabaseSub ??
                          'One .db file with all your data. It is the only format '
                          'that restores onto another phone. Any SQLite reader '
                          'can open it, so anyone who gets the file can read '
                          'your data.',
                      onTap: busy ? null : onExportDb),
                  SetRow(LucideIcons.lock, C.purple,
                      l?.dataExportEncrypted ?? 'Export an encrypted backup',
                      sub: l?.dataExportEncryptedSub ??
                          'The same copy as the database export, encrypted with '
                          'a passphrase. Store it somewhere like iCloud. If '
                          'you forget the passphrase, the file cannot be opened '
                          'and there is no recovery.',
                      onTap: busy ? null : onExportEncrypted),
                ]),
                SettingsAccordion(l?.dataAutoBackupGroup ?? 'Automatic backup',
                    id: 'data_auto_backup',
                    children: [
                  SetRow(LucideIcons.calendarClock, C.purple,
                      l?.dataHowOften ?? 'How often',
                      // Unencrypted, and it says so. The encrypted format is
                      // new and its restore path has not yet run green against
                      // a file written by an older build — defaulting the
                      // automatic copy to a format that might not open is
                      // worse than the plaintext it replaced.
                      sub: l?.dataHowOftenSub(kBackupDirName, kBackupsKept) ??
                          'Writes a compressed, unencrypted copy to '
                              '$kBackupDirName, keeping the last $kBackupsKept',
                      value: cadence.label,
                      onTap: busy ? null : onCycleCadence),
                  SetRow(LucideIcons.clock, C.n500,
                      l?.dataLastBackup ?? 'Last backup',
                      value: last == null
                          ? (l?.dataNever ?? 'Never')
                          : _stamp(last),
                      chevron: false),
                  SetRow(LucideIcons.hardDriveDownload, C.teal,
                      l?.dataBackUpNow ?? 'Back up now',
                      onTap: busy ? null : onBackupNow),
                ]),
                SettingsAccordion(l?.dataBringDataInGroup ?? 'Bring data in',
                    id: 'data_bring_in',
                    children: [
                  SetRow(LucideIcons.upload, C.orange,
                      l?.dataImportFile ?? 'Import a file',
                      sub: l?.dataImportFileSub ??
                          'Accepts an OpenStrap backup (encrypted or not), an edited journal CSV, a raw sensor export, or a vendor CSV. '
                          'Import never overwrites days this band already measured.',
                      onTap: busy ? null : onImport),
                  // Progressive disclosure: two health-store reads, each with
                  // its own consent and its own ceiling, behind one row rather
                  // than two more rows on this screen.
                  SetRow(LucideIcons.smartphone, C.blue,
                      l?.dataFromYourPhone ?? 'From your phone',
                      sub: l?.dataFromYourPhoneSub ??
                          'Resting heart rate, blood pressure, glucose and '
                              'body temperature',
                      onTap: busy ? null : onPhoneImport),
                ]),
                SettingsAccordion('Advanced',
                    id: 'data_advanced',
                    children: [
                  // The engine puts days on hold after a ≥3 h timezone jump
                  // "until Re-analyze data runs" — and nothing in the app ran
                  // it. A flight abroad quietly stopped days updating with no
                  // control anywhere to release them.
                  SetRow(LucideIcons.refreshCcw, C.blue,
                      'Rebuild all history',
                      sub: l?.dataReanalyzeEverythingSub ??
                          'Recalculates every day from stored data. Run it after a long-haul flight or after an import that added days out of order.',
                      value: reanalyzeProgress,
                      onTap: busy || reanalyzing ? null : onReanalyze),
                ]),
                if (busy) ...[
                  const SizedBox(height: S.x6),
                  Center(child: CircularProgressIndicator(color: p.on(C.blue))),
                ],
                if (note != null && note!.isNotEmpty) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                      noteFailed
                          ? (l?.dataThatDidNotWork ?? 'That did not work')
                          : (l?.actionDone ?? 'Done'),
                      note!,
                      icon: noteFailed
                          ? LucideIcons.triangleAlert
                          : LucideIcons.check),
                ],
                if (importRollupError != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                    l?.welcomeSummariesDidNotTitle ??
                        'Days imported, summaries not rebuilt',
                    l?.dataSummariesDidNotBodyShort(
                            '$importRollupError') ??
                        'The import saved every row, but rebuilding the cross-day summaries failed ($importRollupError). '
                        'Trends and insights still reflect your data from before the import. Run Rebuild all history to retry.',
                    fix: 'Rebuild all history',
                    icon: LucideIcons.triangleAlert,
                    onFix: busy ? null : onReanalyze,
                  ),
                ],
                // The onboarding report, not a second copy of it. This
                // screen used to render its own paraphrase, which had already
                // drifted: it lost the rollup error entirely and stated the
                // loss counts in one run-on sentence.
                if (o != null) ...[
                  const SizedBox(height: S.x5),
                  ImportReport(o),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Off → Daily → Weekly → Off. Three states cycle in a row; a picker for three
/// options is a sheet nobody needs.
BackupCadence _nextCadence(BackupCadence c) => BackupCadence
    .values[(c.index + 1) % BackupCadence.values.length];

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
