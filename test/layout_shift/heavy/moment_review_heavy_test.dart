// Heavy: the marked-moment review screen, loading from a real export's journal.
// Skipped unless LAYOUT_SHIFT_HEAVY=1 and LAYOUT_SHIFT_HEAVY_DB is set.
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';

import '../../support/heavy_db_fixture.dart';
import '../../support/heavy_shift_run.dart';

void main() {
  heavyScreen('MomentReview', [
    HeavyCase(
      'MomentReview open',
      () => const MomentFollowUpScreen(),
      // The follow-up setting turned on ten days before yesterday, so the
      // real journal's moments from that window are pending.
      prepare: (app) => app.gestureSettings.setFollowUpMoments(true,
          now: DateTime.parse(shiftLabel(yesterdayLabel(), -10))),
    ),
  ]);
}
