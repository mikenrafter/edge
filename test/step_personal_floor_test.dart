// The 1 Hz activity estimator's PERSONAL floor — the edge half of the fix for
// the "39,384 steps" bug.
//
// The analytics package decides activity from a calibration-invariant dynamic
// amplitude, but it is pure: it cannot read history, so it cannot know what
// "moving" means for this wearer. Edge supplies that. Each day persists its own
// high quantile of the dynamic amplitude (`dyn_p90`), and the next day's derive
// takes the MEDIAN across trailing days as its floor.
//
// Two properties matter here and neither is obvious from the analytics tests:
//
//   1. COLD START ABSTAINS. Below the minimum history there is no floor, and the
//      estimator must return absent rather than fall back to a constant.
//      Falling back to a constant is precisely the bug: the old estimator's
//      absolute 0.05 g floor was the same magnitude as the gravity-reference
//      error, so a quiet day's sedentary minutes cleared it for hours.
//
//   2. A SINGLE ANOMALOUS DAY CANNOT MOVE THE FLOOR. That is why the anchor is
//      a median across days rather than a same-day quantile — a same-day floor
//      collapses on a quiet day and passes everything, the mirror image of the
//      absolute-constant failure.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

/// Per-minute rows carrying DELIBERATELY MISLEADING ENMO: every sedentary
/// minute sits at 0.055 g, just above the absolute 0.05 g floor the old
/// estimator used. If an ENMO-based decision path is ever reintroduced these
/// tests fail loudly instead of shipping tens of thousands of phantom steps.
List<ana.MotionMinute> rows(List<double> dyn) => [
      for (var i = 0; i < dyn.length; i++)
        ana.MotionMinute(i * 60000.0, 60, 0.055, 0.02, 1.055, dyn[i]),
    ];

void main() {
  group('personal ambulatory floor — stability', () {
    test('the floor a quiet day contributes does not collapse the threshold',
        () {
      // A same-day threshold would collapse here and pass everything; the
      // multi-day median holds the line.
      final withQuietDay =
          <double>[0.44, 0.43, 0.45, 0.001, 0.44, 0.46, 0.45];
      final floor = ana.personalDynFloorFromDailySummaries(withQuietDay)!;
      expect(floor, greaterThan(0.4));

      final est = ana.dailyActiveMinutes(
        rows(List<double>.filled(900, 0.02)),
        personalDynFloorG: floor,
      );
      expect(est.value!.activeMinutes, 0);
    });
  });
}
