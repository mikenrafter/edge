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
import '../theme.dart';

class ImportProgressView extends StatelessWidget {
  final ImportProgress progress;
  const ImportProgressView(this.progress, {super.key});

  /// Spinner row + two text lines + bar. Every stage fits inside it.
  static const double _height = 130;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final s = progress;
    if (s is ImportDone) return const SizedBox.shrink();

    final String status;
    String? detail;
    double? bar;
    var counted = false;
    switch (s) {
      case ImportPreparing(:final step):
        status = switch (step) {
          ImportPrepStep.inflating =>
            l?.importPrepInflating ?? 'Unpacking the backup',
          ImportPrepStep.checking =>
            l?.importPrepChecking ?? 'Checking the backup',
          _ => l?.importPrepOpening ?? 'Opening the backup',
        };
      case ImportCopying():
        final name = _stageName(l, s.stage);
        status = l?.importCopying(name) ?? 'Copying $name';
        detail = l?.importStep('${s.stageIndex}', '${s.stageCount}', grouped(s.rowsDone),
                grouped(s.rowsTotal)) ??
            'Step ${s.stageIndex} of ${s.stageCount} · '
                '${grouped(s.rowsDone)} of ${grouped(s.rowsTotal)} rows';
        counted = true;
        bar = s.rowsTotal > 0 ? s.rowsDone / s.rowsTotal : null;
      case ImportRebuilding():
        final day = s.day;
        status = day == null
            ? (l?.importRecalculating('${s.daysDone}', '${s.daysTotal}') ??
                'Recalculating · day ${s.daysDone} of ${s.daysTotal}')
            : (l?.importRecalculatingDay(
                '${s.daysDone}', '${s.daysTotal}', day) ??
                'Recalculating · day ${s.daysDone} of ${s.daysTotal} · $day');
        counted = true;
        bar = s.daysTotal > 0 ? s.daysDone / s.daysTotal : null;
      case ImportFailed(:final error):
        status = l?.dataFailed(error) ?? 'Failed: $error';
      case ImportDone():
        return const SizedBox.shrink();
    }

    return SizedBox(
      height: _height,
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
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: F.cap.copyWith(color: p.ink2)),
              if (detail != null)
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
