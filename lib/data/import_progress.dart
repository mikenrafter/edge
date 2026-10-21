// Where a running import is, for the screen that shows it. Pure data, no
// Flutter: the importer produces it, AppState.importProgress carries it, and
// ImportProgressView draws it.

/// What the importer is doing before it copies anything.
enum ImportPrepStep { inflating, opening, checking, counting }

/// The group of rows being copied.
enum ImportStage {
  journal,
  workouts,
  sleep,
  heartRate,
  beats,
  events,
  results,
  archive,
  other,
}

sealed class ImportProgress {
  const ImportProgress();
}

/// Unpacking, opening or checking the file; null [step] is not yet known.
final class ImportPreparing extends ImportProgress {
  final ImportPrepStep? step;

  /// For [ImportPrepStep.counting]: tables counted so far, of all of them.
  final int? done, total;
  const ImportPreparing([this.step, this.done, this.total]);
}

final class ImportCopying extends ImportProgress {
  final ImportStage stage;
  final int rowsDone, rowsTotal, stageIndex, stageCount;
  const ImportCopying(
      this.stage, this.rowsDone, this.rowsTotal, this.stageIndex, this.stageCount);
}

/// Recalculating days from the imported data. [day] is the label of the last
/// finished day.
final class ImportRebuilding extends ImportProgress {
  final int daysDone, daysTotal;
  final String? day;
  const ImportRebuilding(this.daysDone, this.daysTotal, this.day);
}

final class ImportDone extends ImportProgress {
  const ImportDone();
}

final class ImportFailed extends ImportProgress {
  final String error;
  const ImportFailed(this.error);
}
