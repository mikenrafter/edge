// When a sleep block is FINAL (owner rule 2026-10-07, incremental phase 3b).
//
// A block ends, and its night stops changing, at the first DOUBLE wake
// confirmation: the app is opened (foreground) AND the wake is corroborated by
// band movement over the awake threshold (the caller decides that with
// `NaturalWakePlanner.userAwakeFromInteraction`: a touch at most 5 minutes old
// plus at least 3 one-second gravity steps of 0.05 g within 45 s of it) OR an
// alarm event (fired, acknowledged, or Natural Wake fired). Either signal
// alone never counts, and no end is ever inferred without an observed event.

/// Two pieces of evidence that must coincide count as one confirmation when
/// they fall within this of each other (seconds). Same bar as
/// `kUserInteractionFreshness`.
const int kWakePairingSec = 300;

/// The first instant at which the double confirmation held for the block that
/// began at [onsetSec], or null when it never did.
///
/// All lists are epoch seconds of observed events; events before [onsetSec]
/// belong to an earlier block and are ignored. Pairing:
///  * an app open pairs with band movement when they are within
///    [kWakePairingSec] of each other; the moment is the later of the two;
///  * an app open pairs with an alarm event when it comes at or after the
///    alarm, or at most [kWakePairingSec] before it; the moment is the later
///    of the two.
/// The earliest such moment wins. The result is always one of the given
/// instants (the later of a pair), never an inferred one.
int? confirmedWakeSec({
  required int onsetSec,
  required List<int> appOpenedSec,
  required List<int> bandMovementSec,
  required List<int> alarmSec,
}) {
  final movement = [for (final t in bandMovementSec) if (t >= onsetSec) t];
  final alarms = [for (final t in alarmSec) if (t >= onsetSec) t];
  int? best;
  for (final open in appOpenedSec) {
    if (open < onsetSec) continue;
    for (final m in movement) {
      if ((open - m).abs() > kWakePairingSec) continue;
      final at = open > m ? open : m;
      if (best == null || at < best) best = at;
    }
    for (final a in alarms) {
      if (open < a - kWakePairingSec) continue;
      final at = open > a ? open : a;
      if (best == null || at < best) best = at;
    }
  }
  return best;
}
