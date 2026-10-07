// wake_outcomes_screen.dart — developer-only view of the outcome log and the
// shadow policy line. Words stay descriptive: no sleep-inertia, ideal-stage or
// diagnostic claims.

import 'package:flutter/material.dart';

import '../../data/day_label.dart';
import '../../ui2/ui2.dart';

import 'wake_outcome.dart';
import 'wake_preference_policy.dart';

/// The log, newest first (the list is given in that order).
///
/// Rendering contract (tests rely on these exact strings):
///  - per morning, one Text per response: `"LABEL: VALUE"` with labels
///    "I'm up" (deliberateAck), "App opened" (appInteraction), "Movement"
///    (movement); value is `"N s"` under 60 s, `"M min"` (whole minutes,
///    rounded down) from 60 s, and "not seen" when null.
///  - firedBy text: "Natural Wake", "Gradual Wake", "Alarm at wake time" or
///    "Nothing fired"; with minutesBeforeT, a suffix of the form
///    `" · N min before wake time"` (N rounded) is appended in the same Text
///    (not for the native alarm, whose fire time is the wake time).
///  - exclusions, one Text `"Not counted: WORDS"` each:
///    noDelivery "No wake buzz reached the band", alreadyAwake "You were
///    already using the app", staleStage "Sleep-stage data was too old",
///    competingAlarm "Another alarm was close by", crossedEpisode "First
///    response came hours later".
///  - a rated morning shows `"Grogginess: G of 5"`.
///  - always "Shadow mode — nothing changes your alarm". When
///    shadow.wouldChoose is `'window:W'` a Text `"Would choose a W-minute window"`; when null, no "Would choose" text and, for 'insufficient',
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
  Widget build(BuildContext context) {
    final p = P.of(context);
    final pending = _pendingRating(outcomes);
    final window = _wouldChooseWindow(shadow.wouldChoose);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Shadow mode \u2014 nothing changes your alarm',
                  style: F.body.copyWith(color: p.ink)),
              if (window != null)
                Text('Would choose a $window-minute window',
                    style: F.cap.copyWith(color: p.ink2))
              else if (shadow.wouldChoose == null &&
                  shadow.reason == 'insufficient')
                Text('Not enough rated mornings yet',
                    style: F.cap.copyWith(color: p.ink2)),
            ],
          ),
        ),
        if (pending != null)
          GrogginessPromptCard(pending: pending, onRate: onRate),
        if (outcomes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Text('No wakes recorded yet',
                style: F.cap.copyWith(color: p.ink2)),
          ),
        for (final outcome in outcomes)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: _MorningCard(outcome: outcome),
          ),
      ],
    );
  }
}

/// The newest delivered morning that has no rating yet, or null.
WakeOutcome? _pendingRating(List<WakeOutcome> outcomes) {
  WakeOutcome? best;
  for (final o in outcomes) {
    if (!o.delivered || o.grogginess != null) continue;
    if (best == null || o.wakeSec > best.wakeSec) best = o;
  }
  return best;
}

int? _wouldChooseWindow(String? wouldChoose) {
  if (wouldChoose == null || !wouldChoose.startsWith('window:')) return null;
  return int.tryParse(wouldChoose.substring('window:'.length));
}

class _MorningCard extends StatelessWidget {
  const _MorningCard({required this.outcome});
  final WakeOutcome outcome;

  static const _responseLabels = {
    WakeResponseKind.deliberateAck: "I'm up",
    WakeResponseKind.appInteraction: 'App opened',
    WakeResponseKind.movement: 'Movement',
  };

  /// "n s" under a minute, whole minutes from 60 s, "not seen" when the
  /// response was never observed (never 0).
  static String _latency(int? sec) {
    if (sec == null) return 'not seen';
    if (sec < 60) return '$sec s';
    return '${sec ~/ 60} min';
  }

  static String _firedBy(WakeOutcome o) {
    final name = switch (o.firedBy) {
      WakeFiredBy.natural => 'Natural Wake',
      WakeFiredBy.gradual => 'Gradual Wake',
      WakeFiredBy.native => 'Alarm at wake time',
      WakeFiredBy.none => 'Nothing fired',
    };
    final early = o.minutesBeforeT;
    if (early == null || o.firedBy == WakeFiredBy.native) return name;
    return '$name \u00b7 ${early.round()} min before wake time';
  }

  static String _exclusion(WakeExclusion e) => switch (e) {
        WakeExclusion.noDelivery => 'No wake buzz reached the band',
        WakeExclusion.alreadyAwake => 'You were already using the app',
        WakeExclusion.staleStage => 'Sleep-stage data was too old',
        WakeExclusion.competingAlarm => 'Another alarm was close by',
        WakeExclusion.crossedEpisode => 'First response came hours later',
      };

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final stage = outcome.stageAtFire;
    final grogginess = outcome.grogginess;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
                  outcome.wakeSec * 1000)),
              style: F.head.copyWith(color: p.ink)),
          Text(_firedBy(outcome), style: F.cap.copyWith(color: p.ink2)),
          if (stage != null)
            Text('Stage seen at the fire: $stage',
                style: F.cap.copyWith(color: p.ink2)),
          const SizedBox(height: S.x2),
          for (final kind in WakeResponseKind.values)
            Text('${_responseLabels[kind]}: ${_latency(outcome.latencySec[kind])}',
                style: F.body.copyWith(color: p.ink)),
          if (grogginess != null)
            Text('Grogginess: $grogginess of 5',
                style: F.body.copyWith(color: p.ink)),
          for (final e in outcome.exclusions)
            Text('Not counted: ${_exclusion(e)}',
                style: F.cap.copyWith(color: p.on(C.orange))),
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final outcome = pending;
    if (outcome == null) return const SizedBox.shrink();
    final p = P.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How groggy did you feel on waking?',
                key: const ValueKey('grogginess-prompt'),
                style: F.head.copyWith(color: p.ink)),
            const SizedBox(height: S.x1),
            Text('1 is least groggy, 5 is most',
                style: F.cap.copyWith(color: p.ink2)),
            const SizedBox(height: S.x3),
            Row(children: [
              for (var n = 1; n <= 5; n++) ...[
                if (n > 1) const SizedBox(width: S.x2),
                Expanded(
                  child: Pressable(
                    key: ValueKey('grogginess-$n'),
                    semanticLabel: 'Grogginess $n of 5',
                    onTap: () => onRate(outcome.wakeSec, n),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: S.tap),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: p.wash(C.blue), borderRadius: R.rMd),
                      child: Text('$n',
                          style: F.head.copyWith(color: p.on(C.blue))),
                    ),
                  ),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}
