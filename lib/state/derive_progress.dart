// How far a running derive pass has got, for screens that show it (the import
// screen's "recalculating" stage). Pure data. DeriveCoordinator.deriveProgress
// carries it; null whenever no pass runs.

class DeriveProgress {
  /// Days finished so far and days the pass covers; null until the pass has
  /// said how many.
  final int? dayIndex, dayTotal;

  /// Label of the last finished day.
  final String? day;

  /// The pass is queued behind something else and has not started.
  final bool waiting;

  const DeriveProgress({
    this.dayIndex,
    this.dayTotal,
    this.day,
    this.waiting = false,
  });
}
