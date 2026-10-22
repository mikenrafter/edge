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
import 'package:flutter/foundation.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/auto_backup.dart';
import '../../data/backup_extras.dart' show ImportSummary, lastImportSummary;
import '../../data/csv_export.dart';
import '../../data/day_label.dart' show dayLabelOf;
import '../../data/db.dart';
import '../../import/backup_crypto.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/display_text.dart' show withIosUninstallWarning;
import '../../state/app_state.dart';
import '../../state/clock_format.dart' show formatClockOf;
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
import '../../data/import_progress.dart';
import 'import_progress_view.dart';
import 'phone_import.dart';
import 'profile.dart';
import 'settings.dart' show backToRoot;

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

  /// What the running action is doing, shown under the spinner while [_busy].
  String? _busyStatus;
  String? _note;

  /// Whether [_note] is a failure. Every outcome used to render as "Done" with
  /// a green check — a thrown FileSystemException from the export included.
  bool _noteFailed = false;

  /// [_note] came from the import, whose failure the retained
  /// AppState.importProgress already shows.
  bool _noteIsImport = false;
  ImportOutcome? _outcome;
  ImportSummary? _importSummary;

  void _say(String s, {bool failed = false, bool isImport = false}) {
    if (mounted) {
      setState(() {
        _note = s;
        _noteFailed = failed;
        _noteIsImport = isImport;
      });
    }
  }

  /// Run [job] with the screen locked, reporting whatever it says or throws.
  ///
  /// Every action on this screen is slow, destructive-adjacent or both, and a
  /// second tap while one is running would race the first over the same files.
  Future<void> _run(String status, Future<_Note> Function() job,
      {AppState? importApp}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyStatus = status;
      _note = null;
      _outcome = null;
    });
    final l = AppLocalizations.of(context);
    // The retained failure at the start of this attempt. A note is a duplicate
    // of the failure card only if the import published a NEW ImportFailed
    // (AppState makes a fresh instance per failure); a picker or CSV error
    // never reaches AppState, so the old card stays and the new note shows.
    final before = importApp?.importProgress.value;
    bool isImport() {
      final now = importApp?.importProgress.value;
      return now is ImportFailed && !identical(now, before);
    }

    try {
      final (text, failed) = await job();
      _say(text, failed: failed, isImport: isImport());
    } on PassphraseCancelled {
      // Closing the passphrase prompt is a decision. "Failed:" over it would
      // report the user's own choice back to them as a fault.
    } catch (e) {
      _say(l?.dataFailed(e.toString()) ?? 'Failed: $e',
          failed: true, isImport: isImport());
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
        ? ' ${l?.dataSetsFailed(res.failed.length, res.failed.join(', ')) ?? 'Couldn’t export: ${res.failed.join(', ')}.'}'
        : '';
    return (
      (l?.dataFilesShared(n) ?? '$n file${n == 1 ? '' : 's'} shared.') + failed,
      res.hasFailures
    );
  }

  /// Minute-by-minute heart rate for a chosen range. The picker is bounded to
  /// the derived days that exist, and its heading says which those are, so
  /// "what range is there" is answered before anything is chosen.
  Future<_Note> _exportHeartRate() async {
    final days = await LocalDb.availableDayIds();
    if (!mounted) return ('', false);
    final l = AppLocalizations.of(context);
    if (days.isEmpty) {
      return (l?.dataNothingToExportYet ?? 'Nothing to export yet.', false);
    }
    DateTime parse(String d) => DateTime.parse(d);
    final first = parse(days.last), last = parse(days.first);
    final range = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDateRange: DateTimeRange(
        start: () {
          final week = DateTime(last.year, last.month, last.day - 6);
          return week.isBefore(first) ? first : week;
        }(),
        end: last,
      ),
      helpText: l?.dataHeartRateRangeHelp(days.last, days.first) ??
          'Heart rate is kept from ${days.last} to ${days.first}',
    );
    if (range == null || !mounted) return ('', false);
    final origin = shareOrigin(context);
    final path = await exportHeartRateCsv(
        dayLabelOf(range.start), dayLabelOf(range.end));
    if (path == null) {
      return (l?.dataNothingToExportYet ?? 'Nothing to export yet.', false);
    }
    await Share.shareXFiles([XFile(path)],
        subject: 'OpenStrap heart rate', sharePositionOrigin: origin);
    return (l?.dataFilesShared(1) ?? '1 file shared.', false);
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
          'Encrypted backup shared. Without the passphrase, nobody '
          'can open it, including this app.',
      false
    );
  }

  Future<_Note> _reanalyze(AppState app) async {
    final l = AppLocalizations.of(context);
    // Captured before the confirm dialog's await; the context may be gone
    // by the time the re-analysis returns.
    final ml = MaterialLocalizations.of(context);
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Rebuild all history?'),
      content: const Text('Recalculating all stored days can take several minutes and use battery. Keep Edge open until it finishes. Days whose recordings were already removed cannot be recomputed.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Rebuild all history'))],
    ));
    if (confirmed != true) return ('', false);
    Future<Map<String, int>> recovery() async => {
          for (final r in await LocalDb.metricSeries('readiness'))
            r['date'] as String: (r['value'] as num).round(),
        };
    final before = await recovery();
    final n = await app.reanalyzeAll();
    final after = await recovery();
    // Which days' recovery a re-analysis actually moved, newest first.
    // ponytail: first 5 only; the note is a heads-up, not an audit log.
    final changed = [
      for (final e in after.entries)
        if (before[e.key] != null && before[e.key] != e.value)
          (day: e.key, from: before[e.key]!, to: e.value),
    ].reversed.take(5).map((c) {
      final d = DateTime.tryParse(c.day);
      final label = d == null ? c.day : ml.formatShortMonthDay(d);
      return '$label ${c.from} → ${c.to}';
    }).join(', ');
    final done =
        l?.dataDaysReanalyzed(n) ?? '$n day${n == 1 ? '' : 's'} re-analyzed.';
    return (
      changed.isEmpty
          ? done
          : '$done ${l?.dataRecoveryChanged(changed) ?? 'Recovery changed: $changed'}',
      false
    );
  }

  Future<_Note> _backupNow(AppState app) async {
    final l = AppLocalizations.of(context);
    final outcome = await app.runBackupNow();
    if (outcome.error != null) {
      return (l?.dataBackupFailed(outcome.error!) ?? 'Backup failed: ${outcome.error}', true);
    }
    if (!outcome.succeeded) {
      return (l?.dataBackupSkipped ?? 'Backup skipped.', false);
    }
    return (l?.dataBackedUpTo(outcome.path!) ?? 'Backed up to ${outcome.path}', false);
  }

  Future<_Note> _chooseBackupFolder(AppState app) async {
    final l = AppLocalizations.of(context);
    final folder = await AndroidBackupStorage.pick();
    if (folder == null) return ('', false);
    // The grant is already persisted; save it even if the screen closed, and
    // hand it back if saving fails so no unreferenced grant is left behind.
    final current = app.backupFolder?.uri;
    try {
      await app.setBackupFolder(folder);
    } catch (_) {
      if (folder.uri != current) {
        try {
          await AndroidBackupStorage.release(folder);
        } catch (_) {}
      }
      rethrow;
    }
    return (l?.dataBackupFolderSaved ?? 'Backup folder saved.', false);
  }

  Future<_Note> _useDefaultBackupFolder(AppState app) async {
    final l = AppLocalizations.of(context);
    await app.setBackupFolder(null);
    return (l?.dataBackupFolderSaved ?? 'Backup folder saved.', false);
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
    if (!mounted) return ('', false);
    final outcome = await runImport(app, paths,
        askPassphrase: () async => mounted
            ? askBackupPassphrase(context)
            : null);
    if (!mounted) return ('', false);
    final summary = outcome.nothingLanded ||
            !outcome.source.toLowerCase().contains('backup')
        ? null
        : await lastImportSummary();
    if (mounted) setState(() { _outcome = outcome; _importSummary = summary; });
    return ('', false);
  }

  @override
  Widget build(BuildContext c) {
    final app = c.watch<AppState>();
    final l = AppLocalizations.of(c);
    return ValueListenableBuilder<ImportProgress?>(
      valueListenable: app.importProgress,
      builder: (c, importProgress, _) => _view(c, app, l, importProgress),
    );
  }

  Widget _view(BuildContext c, AppState app, AppLocalizations? l,
      ImportProgress? importProgress) {
    final importing = importProgress != null &&
        (importProgress is ImportCalculating ||
            importProgress is! ImportDone && importProgress is! ImportFailed);
    return DataScreenView(
      importProgress: importProgress,
      rebuiltCard: dbRebuiltCard(app.dbRebuild),
      busy: _busy || importing,
      busyStatus: _busyStatus,
      note: _note,
      noteFailed: _noteFailed,
      noteIsImport: _noteIsImport,
      outcome: _outcome,
      importSummary: _importSummary,
      cadence: app.backupCadence,
      lastBackup: app.lastBackupAt,
      backupFolder: app.backupFolder,
      backupError: app.lastBackupError,
      reanalyzeProgress: app.reanalyzeProgress,
      reanalyzing: app.reanalyzing,
      importRollupError: app.importRollupError,
      onExportCsv: () => _run(
          l?.loadingExportCsv ?? 'Exporting your data as CSV', _exportCsv),
      onExportHeartRate: () => _run(
          l?.loadingExportHeartRate ?? 'Exporting your heart rate',
          _exportHeartRate),
      onExportDb: () =>
          _run(l?.loadingExportDb ?? 'Exporting the database', _exportDb),
      onExportEncrypted: () => _run(
          l?.loadingExportEncrypted ?? 'Writing the encrypted backup',
          _exportEncrypted),
      onCycleCadence: () => app.setBackupCadence(_nextCadence(app.backupCadence)),
      onChooseBackupFolder: () => _run(
          l?.loadingBackupFolder ?? 'Setting the backup folder',
          () => _chooseBackupFolder(app)),
      onUseDefaultBackupFolder: () => _run(
          l?.loadingBackupFolder ?? 'Setting the backup folder',
          () => _useDefaultBackupFolder(app)),
      onBackupNow: () => _run(l?.loadingBackupNow ?? 'Writing the backup',
          () => _backupNow(app)),
      onImport: () => _run(l?.loadingImportHistory ?? 'Importing your history',
          () => _import(app),
          importApp: app),
      onPhoneImport: () => goto(c, const PhoneImport()),
      onReanalyze: () => _run(l?.loadingReanalyze ?? 'Recalculating every day',
          () => _reanalyze(app)),
      onReset: () => confirmResetAllData(c, app),
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
    this.busyStatus,
    this.importProgress,
    this.note,
    this.noteFailed = false,
    this.noteIsImport = false,
    this.outcome,
    this.importSummary,
    this.pendingReentry = const [],
    this.onDismissNotes,
    this.cadence = BackupCadence.off,
    this.lastBackup,
    this.backupFolder,
    this.backupError,
    this.reanalyzeProgress = '',
    this.reanalyzing = false,
    this.importRollupError,
    this.onExportCsv,
    this.onExportHeartRate,
    this.onExportDb,
    this.onExportEncrypted,
    this.onCycleCadence,
    this.onChooseBackupFolder,
    this.onUseDefaultBackupFolder,
    this.onBackupNow,
    this.onImport,
    this.onPhoneImport,
    this.onReanalyze,
    this.onReset,
  });

  final Widget? rebuiltCard;

  /// What the running action is doing, under the spinner while [busy].
  final String? busyStatus;

  /// A running import's stage; replaces the busy spinner while non-null.
  final ImportProgress? importProgress;
  final bool busy, noteFailed, reanalyzing;

  /// [note] reports the import whose failure the retained [importProgress]
  /// already shows; it is then not drawn a second time.
  final bool noteIsImport;
  final String? note, importRollupError;
  final String reanalyzeProgress;
  final ImportOutcome? outcome;

  /// RED STUB: not passed on to ImportReport yet.
  final ImportSummary? importSummary;

  /// RED STUB: notes kept on the app after the page was left; not drawn yet.
  final List<String> pendingReentry;
  final VoidCallback? onDismissNotes;
  final BackupCadence cadence;
  final DateTime? lastBackup;

  /// The chosen Android backup folder; null is the app's own folder.
  final BackupFolder? backupFolder;

  /// Why the last automatic backup failed, if it did.
  final String? backupError;
  final VoidCallback? onExportCsv,
      onExportHeartRate,
      onExportDb,
      onExportEncrypted,
      onCycleCadence,
      onChooseBackupFolder,
      onUseDefaultBackupFolder,
      onBackupNow,
      onImport,
      onPhoneImport,
      onReanalyze,
      onReset;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final last = lastBackup;
    final folder = backupFolder;
    final importingProgress = importProgress != null &&
        (importProgress is ImportCalculating ||
            importProgress is! ImportDone && importProgress is! ImportFailed);
    final importing = importingProgress;
    final failedProgress = importProgress;
    final folderLabel = folder == null
        ? (l?.dataBackupFolderDefault ?? 'App folder (default)')
        : folder.name.isEmpty
            ? (l?.dataBackupFolder ?? 'Backup folder')
            : folder.name;
    final o = outcome;
    final rebuilt = rebuiltCard;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          NavBar(l?.dataNavTitle ?? 'Your data'),
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
                          '${kCsvExportSets.length} CSV files: daily metrics, workouts, sleep, journal and labs.',
                      onTap: busy ? null : onExportCsv),
                  SetRow(LucideIcons.heartPulse, C.red,
                      l?.dataExportHeartRate ?? 'Export heart rate, minute by minute',
                      sub: l?.dataExportHeartRateSub ??
                          'One CSV for the days you pick, one row per minute.',
                      onTap: busy ? null : onExportHeartRate),
                  SetRow(LucideIcons.database, C.blue,
                      l?.dataExportDatabase ?? 'Export the database',
                      sub: l?.dataExportDatabaseSub ??
                          'One file with everything, and the only format that restores onto another phone. Anyone with the file can read it.',
                      onTap: busy ? null : onExportDb),
                  SetRow(LucideIcons.lock, C.purple,
                      l?.dataExportEncrypted ?? 'Export an encrypted backup',
                      sub: l?.dataExportEncryptedSub ??
                          'The same full copy, locked with a passphrase, for somewhere like iCloud. Forget the passphrase and no one can open the file',
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
                      sub: l?.dataHowOftenSub(folder == null ? kBackupDirName : folderLabel, kBackupsKept) ??
                          'Saves an unencrypted copy to '
                              '${folder == null ? kBackupDirName : folderLabel} and keeps the last $kBackupsKept.',
                      value: cadence.label,
                      onTap: busy ? null : onCycleCadence),
                  if (defaultTargetPlatform == TargetPlatform.android)
                    SetRow(LucideIcons.folder, C.purple,
                        l?.dataBackupFolder ?? 'Backup folder',
                        sub: '$folderLabel\n${l?.dataBackupFolderSub ?? 'Choose where new backups are saved. Existing backups stay where they are'}',
                        onTap: busy ? null : onChooseBackupFolder),
                  // Disabled, not hidden, while the default folder is in use.
                  if (defaultTargetPlatform == TargetPlatform.android)
                    SetRow(LucideIcons.folderClosed, C.n500,
                        l?.dataBackupFolderUseDefault ?? 'Use default folder',
                        enabled: folder != null,
                        onTap: busy ? null : onUseDefaultBackupFolder),
                  SetRow(LucideIcons.clock, C.n500,
                      l?.dataLastBackup ?? 'Last backup',
                      value: last == null
                          ? (l?.dataNever ?? 'Never')
                          : _stamp(last),
                      chevron: false),
                  if (backupError != null)
                    SetRow(LucideIcons.triangleAlert, C.orange,
                        l?.dataBackupFailed(backupError!) ?? 'Backup failed: $backupError',
                        sub: defaultTargetPlatform == TargetPlatform.android
                            ? (l?.dataBackupFolderRetry ?? 'Retry with Back up now, or choose another folder')
                            : (l?.dataBackUpNow ?? 'Back up now'),
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
                          'A backup, a journal CSV or another app’s export. Days your band already measured are kept.',
                      onTap: busy ? null : onImport,
                      replacement: importingProgress
                          ? ImportProgressView(importProgress!, compact: true)
                          : null),
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
                          'Recalculates every day from stored data. Use after changing time zones or importing.',
                      value: reanalyzeProgress,
                      onTap: busy || reanalyzing ? null : onReanalyze),
                  // Last, and inside Advanced: it was a red row at the foot of
                  // Settings. The dialog and the flow behind it are unchanged.
                  SetRow(LucideIcons.trash2, C.red,
                      l?.settingsResetAllDataRowTitle ?? 'Reset all data',
                      danger: true,
                      chevron: false,
                      onTap: busy ? null : onReset),
                ]),
                // The retained import failure and the current action are
                // independent: each shows its own state.
                if (failedProgress is ImportFailed) ...[
                  const SizedBox(height: S.x5),
                  ImportProgressView(failedProgress),
                ],
                if (busy && !importing) ...[
                  const SizedBox(height: S.x6),
                  InlineLoading(
                    status: busyStatus ??
                        l?.loadingDataBusy ??
                        'Working on your data'),
                ],
                if (note != null &&
                    note!.isNotEmpty &&
                    !(noteIsImport && importProgress is ImportFailed)) ...[
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
                        'Trends didn’t update',
                    l?.dataSummariesDidNotBodyShort(
                            '$importRollupError') ??
                        'Imported data was saved, but trends couldn’t update ($importRollupError).',
                    // The Advanced row this runs is "Rebuild all history"; the
                    // fix names it the same way.
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
                  ImportReport(o, summary: importSummary),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// "Reset all data": confirm, delete everything, then unwind to the gate. It
/// lives in Your data > Advanced (it used to be the last row of Settings, front
/// and centre) and has no other door.
Future<void> confirmResetAllData(BuildContext c, AppState app) async {
  final l = AppLocalizations.of(c);
  final ok = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(l?.settingsResetTitle ?? 'Delete everything?'),
      // Enumerated, because the previous wording ("every measured day, session
      // and profile field") was false in about twenty places: it deleted the
      // derived days and left the labs, the meals, the doses, the breathing
      // sessions, the logged sets, the baselines, the consent flags, the
      // install id, the stored API key and the home-screen widget standing.
      // It now removes all of that, so it can say so.
      content: Text(
        withIosUninstallWarning(c, l?.settingsResetBody ??
            'This permanently deletes this app\'s data on this device:\n\n'
                '· every measured day, sleep, workout and route\n'
                '· every lab result, meal, medication dose, habit, breathing session '
                'and logged set\n'
                '· your journal, cycle log and what the app has learned as your usual\n'
                '· your profile, every preference and any stored AI key\n'
                '· the home-screen widget and every scheduled reminder\n\n'
                'Exported copies and backups in previous or unavailable folders '
                'may remain. Delete those separately.\n\n'
                'The band is unpaired, and it cannot re-send history it has already '
                'handed over. Export from Your data first if you want a copy.'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(l?.settingsResetKeepData ?? 'Keep my data')),
        TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(l?.settingsResetDeleteEverything ?? 'Delete everything')),
      ],
    ),
  );
  if (ok != true || !c.mounted) return;
  final messenger = ScaffoldMessenger.of(c);
  // resetAllData deletes the automatic backups itself (and releases the
  // chosen folder); it returns why that cleanup was incomplete, if it was.
  String? backupCleanupError;
  try {
    backupCleanupError = await app.resetAllData();
  } catch (e) {
    if (c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(
        content: Text(l?.dataFailed(e.toString()) ?? 'Failed: $e'),
      ));
    }
    return;
  }
  // resetAllData swaps the gate to Welcome, which is UNDER this screen —
  // without this the user stays on Settings, reading a profile that has been
  // deleted.
  if (c.mounted) backToRoot(c);
  if (backupCleanupError != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(
      content: Text(l?.settingsResetBackupWarning ??
          'App data deleted. Backup cleanup was incomplete. '
              'Some files or folder access may remain.'),
    ));
  }
}

/// Off → Daily → Weekly → Off. Three states cycle in a row; a picker for three
/// options is a sheet nobody needs.
BackupCadence _nextCadence(BackupCadence c) => BackupCadence
    .values[(c.index + 1) % BackupCadence.values.length];

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${formatClockOf(t)}';
}
