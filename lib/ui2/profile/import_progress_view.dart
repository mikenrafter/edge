// What a running import is doing, as status lines (what is happening now, not
// reassurance). Countable work shows done/total with a determinate bar.
//
// The height is fixed across every stage, so moving from "Opening" to
// "Copying" to "Recalculating" fills the same box instead of pushing the page.
import 'package:flutter/material.dart';

import '../../data/import_progress.dart';
import '../../l10n/app_localizations.dart';
import '../activity/summary.dart' show grouped;
import '../grammar.dart';
import '../status_line.dart';
import '../theme.dart';

class ImportProgressView extends StatelessWidget {
  final ImportProgress progress;
  final bool compact;
  const ImportProgressView(this.progress,
      {super.key, this.compact = false});

  /// Built from its parts, so a nonlinear text scaler (Android 14+) cannot
  /// grow the text without growing the box: fixed parts (padding, spinner,
  /// gaps, bar) plus each text line at its scaled font size. Room for the
  /// header status, its stage label, and a one-line detail.
  static double heightFor(BuildContext c) {
    // Laid-out lines round up to whole pixels, so the box must too.
    final line = (MediaQuery.textScalerOf(c).scale(F.cap.fontSize!) * F.cap.height!)
        .ceilToDouble();
    return 2 * S.x4 + 22 + S.x2 + line * (2 + 1 + 1) + S.x2 + 4;
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final s = progress;
    if (s is ImportDone && s is! ImportCalculating) return const SizedBox.shrink();

    final status = StatusLine.importLine(l, s);
    final stageStatus = statusOf(l, s);
    String? detail;
    double? bar;
    var counted = false;
    switch (s) {
      case ImportPreparing():
        if (s.step == ImportPrepStep.counting && s.done != null &&
            s.total != null && s.total! > 0) {
          counted = true;
          bar = (s.done! / s.total!).clamp(0.0, 1.0);
        }
      case ImportResuming():
        break;
      case ImportCalculating():
        break;
      case ImportCopying():
        detail = l?.importStep('${s.stageIndex}', '${s.stageCount}', grouped(s.rowsDone),
                grouped(s.rowsTotal)) ??
            'Step ${s.stageIndex} of ${s.stageCount} · '
                '${grouped(s.rowsDone)} of ${grouped(s.rowsTotal)} rows';
        counted = true;
        bar = s.rowsTotal > 0 ? s.rowsDone / s.rowsTotal : null;
      case ImportRebuilding():
        counted = true;
        bar = s.daysTotal > 0 ? s.daysDone / s.daysTotal : null;
      case ImportFailed():
        break;
      case ImportDone():
        return const SizedBox.shrink();
    }

    if (compact) {
      // In a settings row (about 60 pt): the spinner beside the text lines,
      // left-aligned and one line each, with no bar and no vertical gaps. The
      // full view below carries the bar and the roomier layout.
      final small = F.over;
      return Surface(
        pad: const EdgeInsets.symmetric(vertical: S.x1, horizontal: S.x3),
        child: Row(children: [
          if (s is! ImportFailed) ...[
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: S.x2),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status,
                    key: s is ImportResuming ? const ValueKey('import-resuming') : null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small.copyWith(color: p.ink2)),
                if (stageStatus != status)
                  Text(stageStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small.copyWith(color: p.ink3)),
                if (s is ImportPreparing && counted)
                  Text(l?.importPrepCountingTables('${s.done}', '${s.total}') ??
                      '${s.done} of ${s.total}', key: const ValueKey('import-prep-count'),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: small.copyWith(color: p.ink3)),
                if (detail != null)
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small.copyWith(color: p.ink3)),
              ],
            ),
          ),
        ]),
      );
    }

    // Fixed at a given text size so stage changes never resize it.
    return SizedBox(
      height: heightFor(context),
      child: Surface(
        pad: const EdgeInsets.symmetric(vertical: S.x4, horizontal: S.x4),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s is! ImportFailed)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const SizedBox(height: S.x2),
              Text(status,
                  key: s is ImportResuming ? const ValueKey('import-resuming') : null,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: F.cap.copyWith(color: p.ink2)),
              if (stageStatus != status)
                Text(stageStatus,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: F.cap.copyWith(color: p.ink3)),
              if (s is ImportPreparing && counted)
                Text(l?.importPrepCountingTables('${s.done}', '${s.total}') ??
                    '${s.done} of ${s.total}', key: const ValueKey('import-prep-count'),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: F.cap.copyWith(color: p.ink3)),
              if (detail != null && s is! ImportResuming)
                Text(detail,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: F.cap.copyWith(color: p.ink3)),
              if (counted) ...[
                const SizedBox(height: S.x2),
                LinearProgressIndicator(value: bar, minHeight: 4),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The first status line for [s], shared with the app-wide StatusLine.
  static String statusOf(AppLocalizations? l, ImportProgress s) {
    switch (s) {
      case ImportPreparing(:final step):
        return switch (step) {
          ImportPrepStep.inflating =>
            l?.importPrepInflating ?? 'Unpacking the backup',
          ImportPrepStep.checking =>
            l?.importPrepChecking ?? 'Checking the backup',
          ImportPrepStep.counting =>
            l?.importPrepCounting ?? 'Counting what is in the backup',
          ImportPrepStep.opening => l?.importPrepOpening ?? 'Opening the backup',
          null => l?.importPrepStarting ?? 'Getting the backup ready',
        };
      case ImportResuming(:final stage):
        final name = _stageName(l, stage);
        return l?.importResuming(name) ?? 'Resuming $name';
      case ImportCopying():
        final name = _stageName(l, s.stage);
        return l?.importCopying(name) ?? 'Copying $name';
      case ImportRebuilding():
        final day = s.day;
        // Rebuilding(0, 0, null) comes before the pass has chosen its days.
        return s.daysTotal == 0
            ? (l?.importRecalculatingStarting ?? 'Recalculating your days')
            : day == null
            ? (l?.importRecalculating('${s.daysDone}', '${s.daysTotal}') ??
                'Recalculating · day ${s.daysDone} of ${s.daysTotal}')
            : (l?.importRecalculatingDay(
                '${s.daysDone}', '${s.daysTotal}', day) ??
                'Recalculating · day ${s.daysDone} of ${s.daysTotal} · $day');
      case ImportFailed(:final error):
        return l?.dataFailed(error) ?? 'Failed: $error';
      case ImportCalculating():
        return l?.deriveProgressCalculating ?? 'Calculating…';
      case ImportDone():
        return '';
    }
  }

  static String _stageName(AppLocalizations? l, ImportStage st) =>
      switch (st) {
        ImportStage.journal => l?.importStageJournal ?? 'journal',
        ImportStage.workouts => l?.importStageWorkouts ?? 'workouts',
        ImportStage.sleep => l?.importStageSleep ?? 'sleep',
        ImportStage.heartRate => l?.importStageHeartRate ?? 'heart rate',
        ImportStage.beats => l?.importStageBeats ?? 'beats',
        ImportStage.events => l?.importStageEvents ?? 'events',
        ImportStage.results =>
          l?.importStageResults ?? 'calculated results',
        ImportStage.archive =>
          l?.importStageArchive ?? 'raw band records',
        ImportStage.other => l?.importStageOther ?? 'other data',
      };
}
