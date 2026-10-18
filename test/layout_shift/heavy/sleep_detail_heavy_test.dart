// Heavy: SleepDetail against a real export (see support/heavy_db_fixture.dart).
// Skipped unless LAYOUT_SHIFT_HEAVY=1 and LAYOUT_SHIFT_HEAVY_DB is set.
import 'package:openstrap_edge/ui2/screens/screens.dart';

import '../../support/heavy_db_fixture.dart';
import '../../support/heavy_shift_run.dart';

void main() {
  heavyScreen('SleepDetail', [
    // Yesterday = the export's newest day after re-dating.
    HeavyCase('SleepDetail yesterday', () => SleepDetail(day: yesterdayLabel()),
        // The rough-night read only runs when the shown day IS today, and the
        // re-dated export ends yesterday; time it on its own.
        after: (repo) async {
      await loadRoughNight(repo, yesterdayLabel());
    }),
    // No day: today, which also runs the rough-night read.
    HeavyCase('SleepDetail today', () => const SleepDetail()),
    // Synthetic: a writer committing 10k-row replaces back to back while the
    // page loads (a drain landing as the user opens it).
    HeavyCase('SleepDetail yesterday + concurrent ingest writer',
        () => SleepDetail(day: yesterdayLabel()),
        prepare: startIngestWriter),
  ]);
}
