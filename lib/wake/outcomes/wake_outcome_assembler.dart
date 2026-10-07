// wake_outcome_assembler.dart — PURE: one wake's trace rows plus the app and
// band event times become one WakeOutcome. No clock, no I/O, no timezone: every
// time is epoch seconds (trace rows: `atMs ~/ 1000`), so a DST night is no
// special case.
//
// How the orchestrator's rows (lib/wake/wake_orchestrator.dart) are read:
//   natural      {reason, stage, confidence, runSec, evidenceAgeMs (ms), ...}
//                the row with reason 'fire' just before the request carries the
//                evidence age.
//   natural_haptic {phase:'request', stage ('rem'|'wake'|null)} then
//                {phase:'result', result:'sent'|'notDelivered', delivered:[..]}
//                A 'result' row with result 'sent' is the delivered fire; its
//                atMs is the fire time.
//   natural_repeat {phase:'start'|'result'|'stop', reason on stop:
//                acknowledged|bandDoubleTap|wakeTime|headlessBound|disposed}
//   gradual      {index, result:'sent'|'notDelivered'|'skippedLate'}
//   fallback     {armed, confirmed, rearmed}  (the native alarm at T)
//   ack          {cancelNative, cancelled, fallbackArmed}
//   closed       {naturalFired, gradualSteps, acknowledged}  (T has passed)
// Rows whose wakeEpochSec is not [wakeSec] are ignored; input need not be
// sorted.

import '../wake_orchestrator.dart' show WakeTraceEntry;
import 'wake_outcome.dart';

/// Stage evidence older than this (seconds) at the fire excludes the morning.
const int kOutcomeStaleStageSec = 180;

/// An app touch this close before the fire (seconds) means already awake.
const int kOutcomeAlreadyAwakeSec = 600;

/// Another alarm this close before the fire (seconds) is a competing alarm.
const int kOutcomeCompetingAlarmSec = 900;

/// A first response later than this after the fire (seconds) is another
/// episode.
const int kOutcomeEpisodeSec = 4 * 3600;

/// firedBy:
///  - natural  when a natural_haptic result row with result 'sent' exists
///             (fire = that row's time; stageAtFire from the request row, with
///             'wake' reported as 'awake'; stageAgeSec = evidenceAgeMs / 1000
///             rounded, from the last 'natural' row at or before it that has
///             one);
///  - else gradual when a gradual row has result 'sent' (first such row);
///  - else native when a 'closed' row exists (T passed; fire = wakeSec);
///  - else none (firedAtSec / minutesBeforeT null, delivered false).
/// delivered: natural/gradual yes; native only when the LAST 'fallback' row has
/// armed == true; none no. !delivered adds WakeExclusion.noDelivery.
/// minutesBeforeT = (wakeSec - firedAtSec) / 60 (native: 0.0).
///
/// Latencies (seconds, whole): deliberateAck = first 'ack' row, or first
/// natural_repeat 'stop' row with reason acknowledged|bandDoubleTap, whichever
/// is earlier, strictly after the fire second. appInteraction and movement =
/// first event strictly after the fire second. Earlier or equal events never
/// count (no zero latency from a pre-fire open). Any latency over 4 h is
/// null; crossedEpisode is added when the earliest response across all three
/// kinds is over 4 h after the fire. All three keys are always present;
/// not seen = null.
///
/// Exclusions: alreadyAwake when an appInteraction lies in
/// [fire - 600 s, fire]; staleStage when stageAgeSec > 180; competingAlarm
/// when an otherAlarmSecs value lies in [fire - 900 s, fire]. With no fire
/// there is no fire time: only noDelivery applies.
WakeOutcome assemble({
  required int wakeSec,
  required List<WakeTraceEntry> trace,
  required List<int> appInteractionSecs,
  required List<int> movementSecs,
  int? grogginess,
  List<int> otherAlarmSecs = const [],
}) =>
    throw UnimplementedError();
