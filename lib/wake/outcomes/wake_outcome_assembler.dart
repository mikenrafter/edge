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
//                `delivered` is the transport's TARGETS ('band', 'phone'), and
//                the result is 'sent' when ANY target worked. Only a row whose
//                targets include 'band' is a delivered fire; its atMs is the
//                fire time.
//   plan         {naturalMinutes, ...} once per run: the configured Natural
//                window for that night.
//   natural_repeat {phase:'start'|'result'|'stop', reason on stop:
//                acknowledged|bandDoubleTap|wakeTime|headlessBound|disposed}
//                A repeat sends to the band only and its result row carries no
//                targets: 'sent' there means the band.
//   gradual      {index, result:'sent'|'notDelivered'|'skippedLate',
//                delivered:[targets]}
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

/// A band alarm-fired stamp this close to the wake's T (seconds, either side) is
/// taken to be THIS wake's own native alarm, not another alarm. Known limit: a
/// different alarm that fires inside this slack of T cannot be told apart from
/// it and is not counted.
const int kOutcomeNativeAlarmSlackSec = 120;

/// A first response later than this after the fire (seconds) is another
/// episode.
const int kOutcomeEpisodeSec = 4 * 3600;

/// firedBy (a row is "band-delivered" when result is 'sent' and its `delivered`
/// targets include 'band'; a natural_repeat row has no targets and counts):
///  - natural  when a band-delivered natural_haptic / natural_repeat result row
///             exists
///             (fire = that row's time; stageAtFire from the request row, with
///             'wake' reported as 'awake'; stageAgeSec = evidenceAgeMs / 1000
///             rounded, from the last 'natural' row at or before it that has
///             one);
///  - else gradual when a band-delivered gradual row exists (first such row);
///  - else native when a 'closed' row exists (T passed; fire = wakeSec);
///  - else none (firedAtSec / minutesBeforeT null, delivered false).
/// delivered: natural/gradual yes; native only when the LAST 'fallback' row has
/// armed == true AND confirmed == true; none no. !delivered adds WakeExclusion.noDelivery.
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
/// when
///  - an otherAlarmSecs value (band alarm-fired stamps) lies in
///    [fire - 900 s, fire], not counting stamps within
///    [kOutcomeNativeAlarmSlackSec] of wakeSec (this wake's own native alarm);
///  - or any wake stimulus that was sent (a natural_haptic / natural_repeat /
///    gradual result row with result 'sent', to ANY target, phone included)
///    lies in [fire - 900 s, fire). The attributed fire is the first
///    band-delivered row, so such an earlier row is a second wake stimulus the
///    response cannot be told apart from (a phone-only sound just before a band
///    repeat is one). A row that sounded nowhere ('notDelivered') is not.
/// With no fire there is no fire time: only noDelivery applies.
///
/// configuredWindowMinutes = naturalMinutes of the last 'plan' row, else null.
WakeOutcome assemble({
  required int wakeSec,
  required List<WakeTraceEntry> trace,
  required List<int> appInteractionSecs,
  required List<int> movementSecs,
  int? grogginess,
  List<int> otherAlarmSecs = const [],
}) {
  final rows = [
    for (final row in trace) if (row.wakeEpochSec == wakeSec) row,
  ]..sort((a, b) => a.atMs.compareTo(b.atMs));

  // Sent AND the band among the delivered targets. A natural_repeat result has
  // no targets (it only ever sends to the band), so absent means band.
  bool bandSent(WakeTraceEntry row) {
    if (row.data['result'] != 'sent') return false;
    final targets = row.data['delivered'];
    if (targets == null) return row.kind == 'natural_repeat';
    return targets is List && targets.contains('band');
  }

  bool hasResult(WakeTraceEntry row, String kind) =>
      row.kind == kind && row.data['phase'] == 'result' && bandSent(row);

  // A wake stimulus that sounded somewhere (any target), whoever it reached.
  bool anySent(WakeTraceEntry row) {
    if (row.data['result'] != 'sent') return false;
    if (row.kind == 'gradual') return true;
    return (row.kind == 'natural_haptic' || row.kind == 'natural_repeat') &&
        row.data['phase'] == 'result';
  }

  final naturalFire = <WakeTraceEntry>[
    for (final row in rows)
      if (hasResult(row, 'natural_haptic') || hasResult(row, 'natural_repeat'))
        row,
  ];
  final gradualFire = <WakeTraceEntry>[
    for (final row in rows)
      if (row.kind == 'gradual' && bandSent(row)) row,
  ];
  final closed = rows.where((row) => row.kind == 'closed').toList();

  WakeFiredBy firedBy;
  int? firedAtSec;
  String? stageAtFire;
  int? stageAgeSec;
  var delivered = false;

  if (naturalFire.isNotEmpty) {
    final fire = naturalFire.first;
    firedBy = WakeFiredBy.natural;
    firedAtSec = fire.atMs ~/ 1000;
    delivered = true;

    WakeTraceEntry? request;
    WakeTraceEntry? evidence;
    for (final row in rows) {
      if (row.atMs > fire.atMs) break;
      if (row.kind == 'natural_haptic' && row.data['phase'] == 'request') {
        request = row;
      }
      if (row.kind == 'natural' && row.data['evidenceAgeMs'] is num) {
        evidence = row;
      }
    }
    final rawStage = request?.data['stage'];
    if (rawStage == 'rem') stageAtFire = 'rem';
    if (rawStage == 'wake') stageAtFire = 'awake';
    final ageMs = evidence?.data['evidenceAgeMs'];
    if (ageMs is num) stageAgeSec = (ageMs / 1000).round();
  } else if (gradualFire.isNotEmpty) {
    firedBy = WakeFiredBy.gradual;
    firedAtSec = gradualFire.first.atMs ~/ 1000;
    delivered = true;
  } else if (closed.isNotEmpty) {
    firedBy = WakeFiredBy.native;
    firedAtSec = wakeSec;
    WakeTraceEntry? fallback;
    for (final row in rows) {
      if (row.kind == 'fallback') fallback = row;
    }
    delivered = fallback?.data['armed'] == true &&
        fallback?.data['confirmed'] == true;
  } else {
    firedBy = WakeFiredBy.none;
  }

  int? firstAfter(Iterable<int> seconds, int fire) {
    int? first;
    for (final second in seconds) {
      if (second > fire && (first == null || second < first)) first = second;
    }
    return first;
  }

  final latency = <WakeResponseKind, int?>{
    for (final kind in WakeResponseKind.values) kind: null,
  };
  var alreadyAwake = false;
  var staleStage = false;
  var competingAlarm = false;
  var crossedEpisode = false;

  if (firedAtSec != null) {
    final fire = firedAtSec;
    final ackSeconds = <int>[
      for (final row in rows)
        if (row.kind == 'ack') row.atMs ~/ 1000,
      for (final row in rows)
        if (row.kind == 'natural_repeat' &&
            row.data['phase'] == 'stop' &&
            (row.data['reason'] == 'acknowledged' ||
                row.data['reason'] == 'bandDoubleTap'))
          row.atMs ~/ 1000,
    ];
    final responseSeconds = <WakeResponseKind, int?>{
      WakeResponseKind.deliberateAck: firstAfter(ackSeconds, fire),
      WakeResponseKind.appInteraction: firstAfter(appInteractionSecs, fire),
      WakeResponseKind.movement: firstAfter(movementSecs, fire),
    };
    final observed = <int>[];
    for (final entry in responseSeconds.entries) {
      final response = entry.value;
      if (response == null) continue;
      final elapsed = response - fire;
      observed.add(elapsed);
      if (elapsed <= kOutcomeEpisodeSec) latency[entry.key] = elapsed;
    }
    if (observed.isNotEmpty && observed.reduce((a, b) => a < b ? a : b) > kOutcomeEpisodeSec) {
      crossedEpisode = true;
    }
    alreadyAwake = appInteractionSecs
        .any((second) => second >= fire - kOutcomeAlreadyAwakeSec && second <= fire);
    staleStage = stageAgeSec != null && stageAgeSec > kOutcomeStaleStageSec;
    competingAlarm = otherAlarmSecs.any((second) =>
            (second - wakeSec).abs() > kOutcomeNativeAlarmSlackSec &&
            second >= fire - kOutcomeCompetingAlarmSec &&
            second <= fire) ||
        rows.any((row) {
          final second = row.atMs ~/ 1000;
          return anySent(row) &&
              second >= fire - kOutcomeCompetingAlarmSec &&
              second < fire;
        });
  }

  int? configuredWindowMinutes;
  for (final row in rows) {
    final minutes = row.data['naturalMinutes'];
    if (row.kind == 'plan' && minutes is int) configuredWindowMinutes = minutes;
  }

  final exclusionSet = <WakeExclusion>{
    if (!delivered) WakeExclusion.noDelivery,
    if (alreadyAwake) WakeExclusion.alreadyAwake,
    if (staleStage) WakeExclusion.staleStage,
    if (competingAlarm) WakeExclusion.competingAlarm,
    if (crossedEpisode) WakeExclusion.crossedEpisode,
  };
  return WakeOutcome(
    wakeSec: wakeSec,
    firedBy: firedBy,
    firedAtSec: firedAtSec,
    stageAtFire: stageAtFire,
    stageAgeSec: stageAgeSec,
    delivered: delivered,
    latencySec: latency,
    grogginess: grogginess,
    minutesBeforeT:
        firedAtSec == null ? null : (wakeSec - firedAtSec) / 60.0,
    configuredWindowMinutes: configuredWindowMinutes,
    exclusions: [
      for (final exclusion in WakeExclusion.values)
        if (exclusionSet.contains(exclusion)) exclusion,
    ],
  );
}
