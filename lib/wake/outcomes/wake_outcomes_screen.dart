// wake_outcomes_screen.dart — developer-only view of the outcome log and the
// shadow policy line. Words stay descriptive: no sleep-inertia, ideal-stage or
// diagnostic claims.

import 'package:flutter/widgets.dart';

import 'wake_outcome.dart';
import 'wake_preference_policy.dart';

/// The log, newest first (the list is given in that order).
///
/// Rendering contract (tests rely on these exact strings):
///  - per morning, one Text per response: "<label>: <value>" with labels
///    "I'm up" (deliberateAck), "App opened" (appInteraction), "Movement"
///    (movement); value is "<n> s" under 60 s, "<m> min" (whole minutes,
///    rounded down) from 60 s, and "not seen" when null.
///  - firedBy text: "Natural Wake", "Gradual Wake", "Alarm at wake time" or
///    "Nothing fired"; with minutesBeforeT, " · <rounded> min before wake
///    time" is appended in the same Text.
///  - exclusions, one Text "Not counted: <words>" each:
///    noDelivery "No wake buzz reached the band", alreadyAwake "You were
///    already using the app", staleStage "Sleep-stage data was too old",
///    competingAlarm "Another alarm was close by", crossedEpisode "First
///    response came hours later".
///  - a rated morning shows "Grogginess: <g> of 5".
///  - always "Shadow mode — nothing changes your alarm". When
///    shadow.wouldChoose is 'window:<W>' a Text "Would choose a <W>-minute
///    window"; when null, no "Would choose" text and, for 'insufficient',
///    "Not enough rated mornings yet".
///  - embeds a [GrogginessPromptCard] for the newest delivered morning with no
///    rating (null pending when there is none); its onRate is [onRate].
class WakeOutcomesScreen extends StatelessWidget {
  const WakeOutcomesScreen({
    super.key,
    required this.outcomes,
    required this.shadow,
    required this.onRate,
  });

  final List<WakeOutcome> outcomes;
  final ShadowPolicyResult shadow;
  final void Function(int wakeSec, int grogginess) onRate;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// "How groggy did you feel on waking?" with five options, each a tappable
/// Text '1'..'5' (1 = least groggy). Calls onRate(pending.wakeSec, n). Renders
/// nothing (no Text at all) when [pending] is null.
class GrogginessPromptCard extends StatelessWidget {
  const GrogginessPromptCard({
    super.key,
    required this.pending,
    required this.onRate,
  });

  final WakeOutcome? pending;
  final void Function(int wakeSec, int grogginess) onRate;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}
