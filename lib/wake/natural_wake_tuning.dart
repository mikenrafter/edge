// Pure product policy; DbWakeJournal owns the durable parameters.
import 'wake_outcome.dart';

// Proposed product bounds, not physiological cutoffs: offset [-60,60] s,
// step 15 s; window lead [-10,10] min, step 1 min. Base trigger remains 120 s.
class NaturalWakeParameters {
  const NaturalWakeParameters({
    this.triggerRunOffsetSec = 0,
    this.windowLeadMinutes = 0,
    this.lastLearnedEpoch,
  });
  final int triggerRunOffsetSec, windowLeadMinutes;
  final int? lastLearnedEpoch;
  // Keep the strongest learned offset once per field. Absolute magnitude orders
  // signed offsets; positive wins ties. Zero is identity, so overlap cannot
  // multiply a nudge learned from the same set of nights.
  NaturalWakeParameters combine(NaturalWakeParameters other) {
    int strongest(int a, int b) =>
        a.abs() == b.abs() ? (a > b ? a : b) : (a.abs() > b.abs() ? a : b);
    return NaturalWakeParameters(
      triggerRunOffsetSec: strongest(
        triggerRunOffsetSec,
        other.triggerRunOffsetSec,
      ),
      windowLeadMinutes: strongest(windowLeadMinutes, other.windowLeadMinutes),
    );
  }
}

class NaturalTuningDecision {
  const NaturalTuningDecision({
    this.parameters = const NaturalWakeParameters(),
    this.applied = false,
    this.reason = 'no_outcomes',
    this.eligibleNights = 0,
    this.expectEarlyRem = true,
    this.dreamContextScore,
  });
  final NaturalWakeParameters parameters;
  final bool applied, expectEarlyRem;
  final String reason;
  final int eligibleNights;
  final double? dreamContextScore;
}

abstract final class NaturalWakeTuning {
  // Alcohol nights learn their own track, with no early-REM expectation.
  // Ebrahim et al. 2013, doi:10.1111/acer.12006: first-half REM is suppressed
  // and delayed; see edge.research/substance-research/SYNTHESIS.md.
  static NaturalTuningDecision evaluate(
    List<WakeNightOutcome> history, {
    NaturalWakeParameters current = const NaturalWakeParameters(),
    WakeSubstance? tonightSubstance,
    int? track,
    String? userTrackId,
    Set<String>? userContext,
  }) {
    // The first occurrence represents each canonical sleep day. Later alarms
    // that day cannot add evidence or turn a replay into another nightly step.
    final ordered = [...history]
      ..sort((a, b) => a.wakeEpochSec.compareTo(b.wakeEpochSec));
    final nights = <String, WakeNightOutcome>{};
    for (final night in ordered) {
      nights.putIfAbsent(night.dayId, () => night);
    }
    final selectedTrack =
        track ??
        (tonightSubstance == WakeSubstance.alcohol
            ? 1
            : nights.values.lastOrNull?.track ?? 0);
    final context =
        userContext ??
        nights.values.lastOrNull?.userTrackIds ??
        const <String>{};
    final selected = nights.values
        .where(
          (n) =>
              n.contextKnown &&
              (userTrackId == null
                  ? n.track == selectedTrack && n.userTrackIds.isEmpty
                  : n.track == selectedTrack &&
                        n.userTrackIds.contains(userTrackId) &&
                        n.userTrackIds.length == context.length &&
                        n.userTrackIds.containsAll(context)),
        )
        .toList();
    bool complete(WakeNightOutcome n) =>
        n.timeToWake != null &&
        !n.timeToWake!.isNegative &&
        n.snoozeCount != null &&
        n.snoozeCount! >= 0;
    final eligible = selected.where(complete).toList();
    var weight = 0.0, dreams = 0.0;
    for (final night in eligible) {
      final answer = night.dream;
      if (answer == null) continue;
      final w = answer.path == WakePath.natural ? 1.0 : .25;
      weight += w;
      if (answer.answer == DreamAnswer.dream) dreams += w;
    }
    NaturalTuningDecision result(
      String reason, {
      NaturalWakeParameters? parameters,
      bool applied = false,
    }) => NaturalTuningDecision(
      parameters: parameters ?? current,
      applied: applied,
      reason: reason,
      eligibleNights: eligible.length,
      expectEarlyRem: (selectedTrack & 1) == 0,
      dreamContextScore: weight == 0 ? null : dreams / weight,
    );
    if (selected.isEmpty) return result('no_outcomes');
    final latest = selected.last;
    if (!complete(latest)) return result('ineligible_outcome');
    if (userTrackId != null &&
        latest.wakeEpochSec - selected.first.wakeEpochSec <
            const Duration(days: 28).inSeconds) {
      return result('global_learning');
    }
    if (eligible.length < 7) return result('insufficient_nights');
    final learned = current.lastLearnedEpoch;
    if (learned != null &&
        (latest.wakeEpochSec <= learned ||
            ordered.any(
              (n) => n.wakeEpochSec == learned && n.dayId == latest.dayId,
            ))) {
      return result('already_learned');
    }
    final answer = latest.dream;
    if (answer == null) return result('missing_answer');
    if (answer.path != WakePath.natural) return result('non_natural');
    final recovery = latest.recovery;
    final tst = latest.mainSleepTst;
    if (recovery == null ||
        !recovery.isFinite ||
        recovery < 50 ||
        tst == null ||
        tst < const Duration(hours: 6)) {
      return result('recovery_or_sleep_hold');
    }
    final easy =
        answer.answer == DreamAnswer.dream &&
        latest.timeToWake! <= const Duration(minutes: 2) &&
        latest.snoozeCount == 0;
    final hard =
        answer.answer == DreamAnswer.normal &&
        (latest.timeToWake! >= const Duration(minutes: 10) ||
            latest.snoozeCount! >= 2);
    if (!easy && !hard) return result('no_adjustment');
    final trigger = (current.triggerRunOffsetSec + (easy ? -15 : 15)).clamp(
      -60,
      60,
    );
    final lead = (current.windowLeadMinutes + (easy ? 1 : -1)).clamp(-10, 10);
    if (trigger == current.triggerRunOffsetSec &&
        lead == current.windowLeadMinutes) {
      return result('at_bounds');
    }
    return result(
      easy ? 'natural_dream_fast' : 'natural_normal_slow',
      applied: true,
      parameters: NaturalWakeParameters(
        triggerRunOffsetSec: trigger,
        windowLeadMinutes: lead,
        lastLearnedEpoch: latest.wakeEpochSec,
      ),
    );
  }
}
