// circadian_explore_screen.dart — the developer-only explore surface for the
// three circadian outputs. Shown only with Feature.developerMode AND the
// default-off Prefs.exploreCircadian.
//
// Sections: "Your recorded daily rhythm" (sleep timing + experimental HR
// rhythm, with a rejection spelled out in words and no clock time when the fit
// is refused) and, when a plan is given, "Travel schedule based on your usual
// sleep times". Never says "internal clock", melatonin or doses.

import 'package:flutter/material.dart';

import 'hr_rhythm_fit.dart';
import 'sleep_timing_summary.dart';
import 'travel_schedule_planner.dart';

class CircadianExploreScreen extends StatelessWidget {
  const CircadianExploreScreen({
    super.key,
    required this.summary,
    required this.rhythm,
    this.plan,
  });

  final SleepTimingSummary summary;
  final HrRhythm rhythm;
  final TravelPlan? plan;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// The entry tile (key 'circadian-explore-entry'): absent unless developer mode
/// is on and Prefs.exploreCircadian is set. Tapping opens the screen.
class CircadianExploreEntry extends StatelessWidget {
  const CircadianExploreEntry({
    super.key,
    required this.summary,
    required this.rhythm,
    this.plan,
  });

  final SleepTimingSummary summary;
  final HrRhythm rhythm;
  final TravelPlan? plan;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
