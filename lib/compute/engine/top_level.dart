part of '../derivation_engine.dart';

/// The sibling SHAs this version was derived against, asserted against
/// pubspec.yaml in test/db_serve_version_and_reads_test.dart.
///
/// A day_result stamps kAlgoVersion and nothing else, so two builds pinning
/// DIFFERENT analytics at the SAME version serve each other's days as
/// equivalent — and `_pruneOldDecoded` throws the substrate away behind them,
/// so it is not repairable after the fact. That is exactly what happened
/// between v67 and v68. Repinning without touching this block fails the suite,
/// one line above the constant you then have to bump.
// Both siblings move with this bump, and both move NUMBERS this time — which
// is the whole reason the version goes up. analytics: one active-energy gate
// on heart-rate reserve instead of %HRmax (the day and the bout used to
// disagree by 8-35 bpm depending on age and rest), and a measured quiet-waking
// level under strain instead of a population constant that scored a day with
// no activity at all somewhere between 6.9 and 12.1 out of 21. protocol: v25
// stops emitting a gravity vector from offsets that were refuted on real data.
// Both siblings moved again after their own review passes, and kAlgoVersion
// deliberately did NOT: those fixes reject NaN and ±inf, which no sensor ever
// produced and no baseline ever held. For a user whose data is valid, every
// number out of both packages is byte-identical, so a bump would invalidate
// every stored day to recompute the same answers.
//
// This repin picks up the analytics perf pass, and kAlgoVersion holds at 76 for
// the same reason: the stager does the same arithmetic in fewer passes. The one
// place that could have gone wrong was sorting the HR window before `stddev`,
// which re-orders a float summation — that is computed before the sort now, and
// the real overnight capture staged identically down to the last digit of
// confidence.
//
// The protocol repin to b7990e1 also holds at 76, and this one is checkable
// rather than argued: diff the two pins and the gen4 record decoder
// (`lib/src/records.dart`) is untouched, as is every gen4 line in the package
// export. What moved is the gen5 surface — the hello map, the control plane,
// the command surface and the v18/v20/v22/v26 field maps — plus their tests.
// For anyone on a gen4 strap every number out of this package is byte-identical
// across the repin, so a bump would invalidate every stored day to recompute
// the same answers. The gen5 records it adds are new: no released build could
// decode them, so no stored day at v76 was derived from one, and there is
// nothing for a same-version serve to confuse.
//
// The protocol repin to 4ce8f02 (protocol #33 rebased onto b7990e1) holds at
// 76 and is checkable the same way: the whole hop is one commit adding alarm
// COMMAND builders (alarmRev1Payload and friends) plus their exports and
// test. Commands go TO the strap; no decoder line moves, so no stored number
// can.
//
// The analytics repin to a077a4a (the #52 merge, landed via edge#283) is the
// OPPOSITE case from every hop above: it exists to move a number. #52 adds
// the cadence→MET walking term to `Calories.dailyEnergy` (CADENCE-Adults),
// which is exactly what v77 above prices in — the bump and the v77 migration
// cover the hop, and the hop is exactly #52 (diff the two pins: calories.dart
// and its tests, nothing else).
//
// THE ANALYTICS DEBT THIS BLOCK RECORDED IS PAID (v78/v79 above, this
// branch's own work, merged after #283 landed a077a4a on main). Four of the
// items above (A2, A4, C1's window, C9) live in analytics, and for most of
// this branch's life they were UNCOMMITTED: `pubspec_overrides.yaml` pointed
// the local build at `../analytics`, so a dev build already ran them while
// the pin (`d9362a6`) did not contain a line of them — a build shipping this
// constant against that pin would have served days derived from different
// maths under one version number, the exact v67/v68 failure. The pin is
// `d6ba41c` now and carries all four, checkable one at a time:
//   git show d6ba41c:lib/src/onehz/sleep/segment.dart | grep 'valid: trimmedAccel'
//   git show d6ba41c:lib/src/onehz/wellness/readiness_composite.dart \
//     | grep 'readinessCompositeMinBaseline = 14'
//   git show d6ba41c:lib/src/onehz/clinical/nocturnal.dart | grep 'tsSec'
//   git show d6ba41c:lib/src/onehz/util.dart | grep 'sampleCadenceSeconds'
// The guard test compares this constant to pubspec.yaml and would not have
// caught the gap — both were consistent the whole time. Whether the pinned SHA
// contains the change a bump CITES is still a thing a human checks; v43 shipped
// a changelog for an analytics fix its pin never had, and the bug it claimed to
// fix stayed live for three releases.
// Repin to analytics main @ #51 merge (7105256), review-fix pin for this
// branch's own PR (#280). #51 is a strict descendant of a077a4a (#51 merged
// AFTER #52 on analytics main), so this pin carries the walking term too —
// no separate hop needed. No further kAlgoVersion move for THIS repin: the
// only lib/ diff over 353c6bc is #52's `Calories.dailyEnergy` gaining an
// optional `cadenceSpmPerMin` param and a `walking` result field (both edge
// call sites use named field access and never pass the new param), so with
// no caller passing it `active`/`basal`/`total` are byte-identical to before
// — the walking-cadence NUMBER change already happened at v77 above, via
// #283's own a077a4a pin, before this branch's pin moved past it.
// Repin to analytics main @ #53 merge (187e026), one hop on top of 7105256.
// This is the v80 PIN GATE above being closed: #53 lands `nnTimesMs` on
// `irregularBeatScreen`, which onehz_pipeline.dart (this same v80 change) was
// already calling — the pin was never moved when kAlgoVersion went to 80, so
// a clean checkout failed `flutter analyze` (undefined_named_parameter) and
// would have recomputed v80 against a sibling without the sustained-window
// fix it claims. No other symbol changed; no further kAlgoVersion move.
//
// REPIN (this branch) @ 6664854 — protocol main at the OpenStrap/protocol#35
// merge commit ("record HELLO revision instead of gating parsing"). The old
// pin's parser returned null for any hello body whose revision byte was not
// 1; this branch makes HELLO MANDATORY, so under that gate a firmware that
// bumped the revision could not connect at all. #35 records the byte in
// `helloRevision` and reads the fixed revision-1 offsets regardless.
//
// The hop from 19d7291 is ahead 3 / behind 0, and its ONLY lib/ diff is
// #35's `lib/src/control.dart` (+4/-5) — the dropped `if (body[0] != 1)`.
// The other two commits are the #34 merge (2c8448b), whose head 19d7291 this
// pin already WAS, so the oura/generic-HRS wire formats edge#280 imports come
// across unchanged. NO kAlgoVersion bump: hello feeds connection identity and
// state, not the derivation pipeline — no decoder for a persisted record
// moves, so no stored number can. This constant moves together with
// pubspec.yaml's `ref:` and pubspec.lock
// (test/db_serve_version_and_reads_test.dart pins them equal, so a partial
// repin fails the suite).
//
// MERGE (main → this branch): each side moved ONE pin and neither moved
// the other, so this is both repins standing, not a choice between them.
// main took analytics 7105256 → 187e026 (the v80 gate above); this branch
// took protocol 19d7291 → 6664854. kAlgoVersion is main's 81 — this branch
// moves no derivation maths, which is why its own note says NO bump.
// REPIN (this branch) @ 96d47d7 — protocol `feat/garmin-gfdi-protocol`, on
// top of the #42 merge above. Adds `garmin.dart` only: COBS + Multi-Link
// framing, the GFDI frame/CRC16, the device-information parser, and a
// minimal protobuf reader for one battery round trip — a new module, no
// existing decoder touched. NO kAlgoVersion bump: nothing on the
// derivation/persisted-record path moves.
//
// MERGE (main → this branch): main's own repin below (protocol tip fe1464d)
// already contains 96d47d7 as an ancestor (verified: `git merge-base
// --is-ancestor 96d47d7 fe1464d` on the protocol repo) — main's pin is
// strictly ahead, nothing this branch's garmin repin added is lost by
// taking it.
//
// REPIN (this branch): protocol PR #51 head @ 1caf448, on top of 471034c —
// same reasoning as pubspec.yaml's comment beside the `ref:`. This branch
// needs the Ultrahuman wire format that #51 adds and main doesn't have yet.
// NO kAlgoVersion bump: Ultrahuman's `signals` stays `const {}`, so nothing
// this pin adds is ever read by a decoder.
//
// MERGE (main → this branch): main's own repin below (protocol tip fe1464d)
// already contains 1caf448 as an ancestor (verified: `git merge-base
// --is-ancestor 1caf448 fe1464d` on the protocol repo) — main's pin is
// strictly ahead, nothing this branch's repin added is lost by taking it.
// REPIN (this branch) @ fbda904 — protocol OpenStrap/protocol#49 head, which
// adds the o2ring frame envelope/parser. NO kAlgoVersion bump: o2ring's
// adapter `signals` stays `const {}` (excluded from `kDerivableSources`), so
// nothing this pin adds is ever read by a decoder the derivation pipeline
// calls — no stored number can change.
//
// MERGE (main → this branch): main's own repin below (protocol tip fe1464d)
// already contains fbda904 as an ancestor (verified: `git merge-base
// --is-ancestor fbda904 fe1464d` — PR#49/o2ring-protocol is folded in via the
// `d297055` merge commit) — main's pin is strictly ahead, nothing this
// branch's repin added is lost by taking it.
//
// REPIN (this branch): protocol `feat/wearfit-howear-protocol` @ 1cf8e61, one
// commit ahead of #42 (471034c). Adds the wearfit/howear frame codec
// (parseWearFitFrame/wearFitCmdGetBattery/parseWearFitBattery) this branch's
// adapter calls. `signals` for the new adapter is `const {}` (no derivable
// source), so this touches no decoder any existing day_result reads. NO
// kAlgoVersion bump.
//
// REPIN (main) @ b819ee0 — protocol `feat/ringconn`, 2 commits on top of
// 471034c. Adds the ring's frame codec (`parseRingConnFrame` and friends);
// no decoded field, so no kAlgoVersion move. Must match pubspec.yaml's
// `ref:` — see this file's own note above.
//
// MERGE (main → this branch): this branch's repin (wearfit @ 1cf8e61) and
// main's (ringconn @ b819ee0) are parallel protocol commits, neither an
// ancestor of the other. protocol's own `origin/main` already merged both
// (PR#50 wearfit-howear, PR#48 ringconn, and everything after) — this pin
// moves to that tip (fe1464d) to match pubspec.yaml's `ref:` rather than
// picking one single-device SHA over the other. Verified: `1cf8e61` (this
// branch's own pin) IS an ancestor of `fe1464d` — the wearfit protocol
// commit is already folded in, nothing is lost by moving to the tip.
//
// REPIN (main) @ 0441ef9 — analytics main, one commit past #75 above. Fixes
// temp_circadian.dart's zero-variance division producing fabricated
// interdailyStability/intradailyVariability=0.0 instead of null on a flat
// skin-temp window (see pubspec.yaml's comment beside the `ref:` for the
// verification command). kAlgoVersion bumped 96 -> 97, see the changelog
// entry above.
// REPIN @ 9fc1d6a — analytics PR #80 (band-state night end:
// bandTrimmedOffsetSec, segmentSleep(bandSleepState:),
// SleepSegmentation.bandOffsetTrimSec), on OpenStrap/analytics main, for v100
// above.
// REPIN @ c0effea: analytics main, #79 + #86 (rmssd gate), for v105.
// REPIN: feat/multidevice-analytics head (ring settle band), WHOOP output
// unchanged; re-point at the analytics main merge commit.
// REPIN @ 77fe373: analytics main, #95 merge (readiness autonomic
// merge + spread calibration + capped re-centring + robust lnRMSSD
// centre), for v112.
// Fork history (not ancestors of the pin below, which merges them):
// REPIN @ 7fe67a7 — user's fork mikenrafter/openstrap-analytics, branch
// feat/causal-stage-api: 0441ef9 plus the additive causal stage API for
// Natural Wake. No existing analytics output changed, so no
// kAlgoVersion bump comes from the pin itself.
// REPIN @ 7334289 — same fork, branch feat/minute-energy (child of 7fe67a7):
// adds Calories.minuteEnergy + hourlyRollup. dailyEnergy outputs are
// bit-for-bit unchanged (golden == tests in the analytics repo).
// Edge now persists Calories.minuteEnergy, as the `last_result`
// artifact `kcal_minutes|<day>` (the day's minutes sum to its stored active
// calories). It is a new stored output, not a change to an existing one:
// `calories`, `calories_total` and every `day_result` row are untouched, so no
// kAlgoVersion bump.
// REPIN @ 65c8901 — same fork and branch (feat/minute-energy), three commits on
// 7334289: the incremental calculation states, `hrDipFromDayTotals`,
// `IntHistogram`, and the `lombScargle` first-sample time shift. The shift is
// the one OUTPUT CHANGE (see v101 above), so kAlgoVersion bumped 100 -> 101.
// REPIN @ aa67997 (perf/incremental-rr, on 65c8901): correctRr on sliding
// sorted windows (oracle-tested bit-identical, ~37x faster) and the streaming
// RrCorrector / IrregularScreenState the day checkpoint now carries (v102).
// REPIN @ bf1be19 (feat/prv-diagnostics, on aa67997): the screen's
// diagnostics (v103). The verdict code is the same; the payload carries the
// evidence behind it.
// REPIN @ 0fc5768 (same branch, on bf1be19): the diagnostics' artifact fraction
// is absent when the corrector saw no beats (no "100% artifacts" beside zero
// beats). Verdicts unchanged; the persisted output changed, so v104 (§3.4).
// REPIN @ bf79e84 (same branch, on 0fc5768 via the test-only fa77ab4): the
// checkpoint readers refuse impossible saved state instead of restoring it.
// No output change for any valid input, so no kAlgoVersion bump.
// REPIN @ db02896 (feat/aggregator, on bf79e84): the mergeable aggregator API
// (additive); hypnogramMetrics, phillipsSri and readinessLnRmssd now run
// through it bit-identically; exact phase-0 speedups (sliding medians, Welch
// scan) and the exact CardioRowCache staging now reuses; cvhrApneaScreen no
// longer loops forever on a non-finite NN (it never returned before). No
// output change for any input that completed before, so no kAlgoVersion bump.
// REPIN @ 972f0b2 (feat/aggregator, on db02896): exact HrvFreqStream and
// RsaRespStream (snapshot(tail) == hrvFreq / rsaRespRate(prefix) bit for bit),
// additive. No output change, so no kAlgoVersion bump.
// REPIN @ 07d6af0 (feat/aggregator, on 972f0b2): exact CvhrStream
// (snapshot == cvhrApneaScreen(prefix) bit for bit), additive. No output
// change, so no kAlgoVersion bump.
// REPIN @ 914bb6a (feat/aggregator, on 07d6af0): a fresh CvhrStream snapshots
// a tail-only night like cvhrApneaScreen; edge's fallback is gone. No output
// change, so no kAlgoVersion bump.
// REPIN @ e6dd526 (feat/aggregator, on 914bb6a): rsaRespRate / hrvFreq abstain
// on a non-finite beat time (they looped forever).
// INTEGRATION @ 1add367 (mikenrafter/openstrap-analytics integrate/upstream):
// OpenStrap/analytics main @ 724ede9 (77fe373 + the AGPL relicense) merged with
// feat/aggregator @ e6dd526. Upstream's metric rules; the fork's streams and
// aggregators ported to them (merge log D11).
// REPIN @ 07f7126 (same branch): law-test and stream fixes only (D23); batch
// outputs bit-identical, so no kAlgoVersion bump.
// REPIN @ ddb61f7 (same branch): stageMinuteRanges, kStageScoreMargin and
// CardioStagerResult.epochEvidence, additive. Edge stores the ranges as
// sleep.stage_ranges (kAlgoVersion 114, D27 revised).
// REPIN @ d9eda83 (same branch): hrvTime, nocturnalRmssd and session RMSSD abstain on
// a non-finite beat time instead of throwing; finite output unchanged, no bump.
// REPIN @ 6a2a9fc (same branch, analytics #99): RR cap 32, toleranced batch
// aggregators, cosinor abstention, non-finite guards and irregular-screen gaps.
// EpochRows preserves staging labels; checkpoint formats advance. Output
// changes are covered by kAlgoVersion 116; jitter-evidence perf and citations
// are also included.
// REPIN @ 1255e9d (port/628-hmm): opt-in offline HMM staging and measured
// nightly HR p10 / mean epoch RMSSD. Cardio remains the default. Edge stores
// nullable night baselines and staging provenance under kAlgoVersion 117.
// Phase 3: shared live wake evidence, no stored output change; kAlgoVersion 117.
const String kAnalyticsPin = '8bd648748e38f5864214f0b719e069678bd905f8';
// Repinned to analytics main's tip, which carries BOTH PR #72 (hrv_freq
// Welch gap guard) and PR #73 (overreachingConjunction rhr quantum guard) —
// the two independent kAlgoVersion bumps above (93 and 94). Verified both
// fixes are present at this SHA:
//   `git show eed6dc9:lib/src/onehz/human/overreaching_conjunction.dart |
//      grep -n dispersionBelowQuantum`
//   `git show eed6dc9:lib/src/onehz/clinical/hrv_freq.dart |
//      grep -n 'segSec \* 0.8\|segSec \* 0.2'`
// Previously repinned to analytics PR #70's merged main SHA (was the pre-squash branch
// commit 47847fa, orphaned once the PR squash-merged) — same content, see
// pubspec.yaml's comment for the verification command.
// REPIN (this branch, superseded by the merge): polar pmd's own protocol
// needs `feat/polar-pmd-protocol` (87ee803), but protocol's own `origin/main`
// tip below is THAT SAME PR's merge commit — verified
// (`git merge-base --is-ancestor 87ee803… fe1464d…`) — so main's pin already
// carries this branch's wire format; nothing is lost by taking it as-is.
// NO kAlgoVersion bump either way: polar pmd's adapter declares no signal.
//
// REPIN (main): protocol dafit/moyoung head @ 06cb5f2 — the DaFit/MOYOUNG-V2
// frame envelope. NO kAlgoVersion bump: dafit carries no derivable signal.
// Protocol's own origin/main has since merged dafit/moyoung along with #47
// (zetime), #48 (ringconn) and #50 (wearfit) — 06cb5f2 is verified an
// ancestor of the tip below.
// REPIN (main, superseded further): the ring11m adapter's own protocol needs
// `feat/ring11m-protocol` (c6cc5ef), but protocol's own `origin/main` tip
// below is THAT SAME PR's merge commit — verified — so main's pin already
// carries that wire format too. NO kAlgoVersion bump: ring11m declares no
// signal either.
// REPIN (main, superseded further): protocol main @ bc7d8d0 — PR#54 lands
// the Labrador (WHOOP MG ECG) parser this branch's ECG capture pipeline
// calls. NO kAlgoVersion bump: ECG is not a derived `day_result`/
// `metric_series` output, it is its own store (`ecg_reading` etc., schema
// v54) with nothing feeding the existing metrics.
// REPIN: protocol oura sleep-phase decoder (#71 merge) @ f04931b, on top of bc7d8d0.
// NO kAlgoVersion bump: the stage minutes land in `observation`, which no
// derivation reads.
// REPIN: protocol main @ ecb512b (#72-#77).
// REPIN: feat/multidevice-verified-decoders head; re-point at the protocol
// main merge commit. Re-pointed at that branch's Huami gap fix (minutes()
// empty after a counter gap); NO kAlgoVersion bump: the adapter already
// decoded only gap-free transfers, so no output changes.
const String kProtocolPin = '89080bcfac7767b3a871fd3a7d9307f5f30dad26';

// Fold idempotency, the minimum-nights warm-up, and legacy-payload handling
// all live in SleepProfilePolicy (pure, unit-tested) — see
// lib/compute/sleep_profile_policy.dart for the evidence behind each rule.

/// Raw is kept this many days behind the data edge, then pruned at a local
/// midnight (derived stays). A day stays recomputable until 48 h past its last
/// record, so its derive window (from the previous noon) keeps at least 48 h
/// of substrate past finalization; the day's own rows last a day longer.
const int rawRetentionDays = 5;

/// A day stays recomputable until the data edge is this far past the day's
/// LAST record (`endSec`, ≈ the end of the calendar day), then FINALIZES
/// (locks). So a full day locks ~72 h after it starts. More flash may still
/// drain within this buffer.
const int _finalizationSec = 48 * 3600;

/// How many trailing derived days feed readiness/composite baselines.
const int _baselineWindowDays = 28;

/// Readiness is meant to be a stable MORNING score, but a day stays recomputable
/// for ~48 h (`_finalizationSec`) and every re-derive overwrites the persisted
/// readiness scalar. As the night's flash finishes draining and the trailing
/// 28-day baseline shifts, the surfaced value legitimately drifts through the
/// day (#128: "morning it was 49, now 45"). Once today's overnight is genuinely
/// COMPLETE we PIN the first such readiness as the headline so it stops moving.
///
/// "Complete" cannot be "a sleep-bearing row exists" — that is true as soon as
/// the FIRST one lands (mid-drain), so pinning on it could freeze a
/// partial-night value. We instead require the drained data edge to
/// have moved at least this far PAST the sleep offset (wake): the whole sleep
/// window is then decoded and the segmentation-placed wake is settled, so the
/// overnight inputs are final. Same "edge past the window" model finalisation
/// uses, anchored at wake+margin rather than wake+48 h. Conservative but still
/// reached within the first post-wake sync in practice; raise it to trade a
/// slightly later freeze for more safety margin.
const int _headlineFreezeMarginSec = 60 * 60;

/// How long after a night's wake we stop waiting for the data edge to pass
/// it. A strap that went quiet right after waking (flat battery, taken off and
/// not recording) never moves the edge again, and the night we hold is then
/// the whole night as far as any sync will ever know.
// ponytail: wall-clock give-up; a persisted "drain complete" marker would be exact.
const int kOvernightGiveUpSec = 12 * 60 * 60;

/// Whether a night whose sleep ends at [sleepOffsetSec] is SETTLED: the drained
/// data edge has moved [_headlineFreezeMarginSec] past the wake, so the window
/// is no longer just where the sync happened to stop (#448: mid-drain, the
/// newest record is still inside the night and the stager closes the window at
/// it, so a partial night and its readiness showed as this morning's). Home and
/// the readiness freeze both read this, on the same band-only edge
/// ([LocalDb.lastDecodedRecTs]).
///
/// [nowSec] enables the wall-clock give-up. Only Home passes it: a drain that
/// stalled mid-night looks exactly like a strap that went quiet at wake, and
/// Home recovers on the next derive, but the freeze pins for the whole day, so
/// it waits for the edge.
///
/// A null [sleepOffsetSec] is a night with no window yet. Mid-drain that is
/// usually an edge still before sleep onset, not a night without sleep, so it
/// only settles once the band edge has caught up to [nowSec], or gone quiet
/// for the give-up. A caught-up edge before local noon is still a night that
/// may not have started (awake at 00:30, the coming sleep has no window yet),
/// so "no sleep" waits for noon.
bool overnightSettled({
  required int? sleepOffsetSec,
  required int dataEdgeSec,
  int? nowSec,
}) {
  if (sleepOffsetSec == null) {
    if (nowSec == null) return false;
    final now = DateTime.fromMillisecondsSinceEpoch(nowSec * 1000);
    return (now.hour >= 12 &&
            dataEdgeSec >= nowSec - _headlineFreezeMarginSec) ||
        nowSec >= dataEdgeSec + kOvernightGiveUpSec;
  }
  return dataEdgeSec >= sleepOffsetSec + _headlineFreezeMarginSec ||
      (nowSec != null && nowSec >= sleepOffsetSec + kOvernightGiveUpSec);
}

/// How long the band's data edge must run past a detected wake before that
/// wake counts as CONFIRMED rather than "where the sync happened to stop".
/// Mid-drain the stager closes the window at the newest record, so a wake
/// sitting at the edge is no wake at all.
// ponytail: fixed 30 min; tune against real drain timings if provisional flickers.
const int kWakeConfirmMarginSec = 30 * 60;

/// A pin is only trusted for the night whose wake is within this of its own.
const int kPinWakeToleranceSec = 60 * 60;

/// A night whose wake is before this local hour, or that slept less than
/// [kMinPinSleepSec], is never frozen: the reported 2-instead-of-28 morning was
/// a pin taken off the first three hours of a night still in progress.
// ponytail: population heuristics; a night-shift sleeper never pins and reads
// the live final value instead, which is the safe side.
const int kMinPinWakeHour = 3;
const int kMinPinSleepSec = 3 * 60 * 60;

/// Today's recovery headline, in the one vocabulary every surface reads.
enum RecoveryState { nightInProgress, provisional, finalReady }

extension RecoveryStateWire on RecoveryState {
  String get wire => switch (this) {
        RecoveryState.nightInProgress => 'night_in_progress',
        RecoveryState.provisional => 'provisional',
        RecoveryState.finalReady => 'final',
      };
}

/// Where today's night stands: a wake the edge has not yet run
/// [kWakeConfirmMarginSec] past is still in progress; a confirmed wake whose
/// window has not settled ([overnightSettled]) is provisional; settled is
/// final. No window at all and not settled is null: nothing says the user is
/// asleep (an unworn night reads the same until noon), so no state is claimed.
RecoveryState? recoveryStateOf({
  required int? wakeSec,
  required int dataEdgeSec,
  int? nowSec,
}) {
  if (overnightSettled(
      sleepOffsetSec: wakeSec, dataEdgeSec: dataEdgeSec, nowSec: nowSec)) {
    return RecoveryState.finalReady;
  }
  if (wakeSec == null) return null;
  return dataEdgeSec >= wakeSec + kWakeConfirmMarginSec
      ? RecoveryState.provisional
      : RecoveryState.nightInProgress;
}

/// Whether a night is a plausible MAIN night to freeze (see [kMinPinWakeHour]).
bool pinnableNight({required int wakeSec, int? onsetSec}) {
  final wake = DateTime.fromMillisecondsSinceEpoch(wakeSec * 1000);
  if (wake.hour < kMinPinWakeHour) return false;
  return onsetSec == null || wakeSec - onsetSec >= kMinPinSleepSec;
}

/// The cross-day inputs an importer fills with its vendor's own scores.
const _crossDayVendorScoreKeys = [
  'rhr',
  'rmssd',
  'readiness',
  'resp_rate',
  'skin_temp_z',
];

/// The frozen morning readiness headline that should be persisted/surfaced for
/// [today], given the current pin and a fresh look at today's live readiness and
/// whether today's overnight is genuinely COMPLETE. Pure so the freeze semantics
/// are unit-tested without the derive/DB machinery.
///
/// - Not yet a complete overnight → no pin (the headline tracks the live value).
/// - First complete overnight → pin the live value.
/// - Later same-day looks → keep the FIRST pin (the whole point: no daytime
///   drift — a re-derive that would RAISE or LOWER the score is ignored).
/// - A new day → the prior day's pin no longer applies; re-pins once the new
///   day's overnight completes.
/// - Same day, but the night's wake [wakeSec] moved a margin or more from the
///   pinned one → a different sleep block is now the night (segmentation only
///   bridges gaps under an hour, so a long mid-night awakening settles the
///   first block, then a later one takes over as main sleep). Re-pins once that
///   night settles; until then the old pin holds.
@visibleForTesting
({String day, int value, int? wakeSec})? nextFrozenHeadline({
  required String today,
  required bool overnightComplete,
  required int? liveReadiness,
  required ({String day, int value, int? wakeSec})? current,
  int? wakeSec,
  int? onsetSec,
}) {
  // A pin with no wake (written by an older build) cannot say which night it
  // is, so a night that does know its wake replaces it once that night settles.
  final sameNight = current != null &&
      current.day == today &&
      (wakeSec == null ||
          (current.wakeSec != null &&
              (wakeSec - current.wakeSec!).abs() < kPinWakeToleranceSec));
  final pinnable =
      wakeSec == null || pinnableNight(wakeSec: wakeSec, onsetSec: onsetSec);
  // A re-derive can shrink the same night below a main night (onset moved);
  // its old pin no longer describes a pinnable night, so it is not held.
  if (sameNight) return pinnable ? current : null; // pinned; hold
  if (overnightComplete && pinnable && liveReadiness != null) {
    // first complete settle of this night → pin
    return (day: today, value: liveReadiness, wakeSec: wakeSec);
  }
  if (current != null && current.day == today) return current;
  return null; // nothing to pin yet for today
}

/// Composes one substrate-loader page's `decoded_onehz` rows into the frames
/// the derive worker actually decodes — SIGNAL-LEVEL ownership, not row-level.
///
/// `decoded_onehz`'s key is `(device_id, ts_ms)`, so a contended second can
/// have one row per paired device, each carrying hr AND accel AND ppg AND
/// skin-temp together. A row is admitted by its hr1Hz ownership (hr/rr live
/// nowhere else), but accel1Hz/ppgRedIr/skinTempRaw ride along in that same
/// row — and a user can rank a DIFFERENT device for those via
/// `signal_priority` (the device-priority screen, `LocalDb.setSignalPriority`)
/// without that ranking ever taking effect, because the whole row followed
/// whichever device won hr1Hz. This splices each field group in from
/// whichever row that signal's OWN ownership actually names, when that
/// device has a row at this second — never fabricated, just re-attributed.
///
/// A single-device day, or a signal never actually contended for a given
/// second, never enters the splice path (`group.length < 2` / same owner
/// short-circuits to the row unchanged) — byte-identical to before this
/// existed. `@visibleForTesting` so the splice logic is checkable directly,
/// without staging a whole night through the derive/DB machinery.
@visibleForTesting
List<Map<String, dynamic>> composeOneHzFrames(
  List<Map<String, dynamic>> decodedRows,
  Map<InputSignal, List<OwnedSpan>> ownership,
) {
  final oneHzSpans = ownership[InputSignal.hr1Hz] ?? const <OwnedSpan>[];
  final accelSpans = ownership[InputSignal.accel1Hz] ?? const <OwnedSpan>[];
  final ppgSpans = ownership[InputSignal.ppgRedIr] ?? const <OwnedSpan>[];
  final skinTempSpans = ownership[InputSignal.skinTempRaw] ?? const <OwnedSpan>[];
  if (accelSpans.isEmpty && ppgSpans.isEmpty && skinTempSpans.isEmpty) {
    // No secondary ownership resolved for any spliced signal (the single-
    // device/import case oneHzSpans itself already covers) — skip the
    // grouping allocation entirely and fall back to the plain row filter.
    if (oneHzSpans.isEmpty) return decodedRows;
    return [
      for (final r in decodedRows)
        if (_ownedBy(oneHzSpans, r)) r,
    ];
  }

  final byRecTs = <int, List<Map<String, dynamic>>>{};
  for (final r in decodedRows) {
    final ts = (r['rec_ts'] as num?)?.toInt();
    if (ts != null) byRecTs.putIfAbsent(ts, () => []).add(r);
  }

  Map<String, dynamic> splice(
    Map<String, dynamic> base,
    List<OwnedSpan> spans,
    List<String> cols,
  ) {
    final group = byRecTs[(base['rec_ts'] as num).toInt()]!;
    if (spans.isEmpty || group.length < 2) return base;
    final baseDeviceId = base['device_id'] as String? ?? LocalDb.kPrimaryDeviceId;
    final owner = spanAt(spans, (base['rec_ts'] as num).toInt())?.deviceId;
    if (owner == null || owner == baseDeviceId) return base;
    Map<String, dynamic>? ownerRow;
    for (final r in group) {
      if ((r['device_id'] as String? ?? LocalDb.kPrimaryDeviceId) == owner) {
        ownerRow = r;
        break;
      }
    }
    if (ownerRow == null) return base;
    // COPY THE WHOLE GROUP, including a null column — `device_coverage`
    // declares `ppgRedIr` when EITHER raw PPG channel is present (db.dart),
    // so the owner's row can carry one channel and not the other, and both
    // skin-temp columns are independently nullable. Copying only the
    // non-null columns left the base (wrong device's) value sitting in the
    // other column, combining fields from two devices in one frame.
    //
    // ponytail: `device_family`/`device_id` are deliberately NOT re-stamped
    // here — the returned frame still carries the hr1Hz owner's. `_families`
    // (derive_prepare.dart)'s day-wide family singleton, which
    // `calibrationFor`/`estimatedMaxHr` read for ENMO-cut and HR-max
    // constants, is therefore keyed off whichever device won hr1Hz, not off
    // whoever actually supplied a spliced accel1Hz reading. A gen4+gen5
    // pairing where the user ranks a DIFFERENT device for accel1Hz than for
    // hr1Hz can apply the hr-owner's family calibration to the other
    // family's accel — narrower than the row-level bug this fix closes (it
    // needs both a cross-family pairing AND divergent per-signal priority),
    // but real. Upgrade path: thread a per-signal device/family map through
    // `Substrate` (a new field per anchor signal, not the single
    // `deviceFamily`) to the ENMO/HR-max call sites — real scope, deferred
    // rather than rushed into this fix.
    return {...base, for (final c in cols) c: ownerRow[c]};
  }

  return [
    for (final r in decodedRows)
      if (_ownedBy(oneHzSpans, r))
        splice(
          splice(
            splice(r, accelSpans, const ['ax', 'ay', 'az']),
            ppgSpans,
            const ['spo2_red_raw', 'spo2_ir_raw'],
          ),
          skinTempSpans,
          const ['skin_temp_raw', 'skin_temp_c'],
        ),
  ];
}

bool _ownedBy(List<OwnedSpan> spans, Map<String, dynamic> r) {
  if (spans.isEmpty) return true;
  final owner = spanAt(spans, (r['rec_ts'] as num).toInt())?.deviceId;
  if (owner == null) return true;
  return owner == (r['device_id'] as String? ?? LocalDb.kPrimaryDeviceId);
}

/// The index where [rows]' trailing `rec_ts` group starts — 0 when every row
/// shares one second, `rows.length - 1` when the last row's second is alone.
///
/// `rows` must already be rec_ts-ascending (`decodedOneHzBatchByRecTsRange`'s
/// own order, and the substrate loader's `carry ++ page` concatenation
/// preserves it — carry only ever holds rows from an EARLIER page). Used to
/// hold a contended second's trailing rows back to the next page rather than
/// splicing `composeOneHzFrames` against a group `decodedOneHzBatchByRecTsRange`'s
/// LIMIT happened to cut in half. `@visibleForTesting` so the boundary walk
/// is checkable without staging a 2000-row page through the DB.
@visibleForTesting
int trailingRecTsGroupStart(List<Map<String, dynamic>> rows) {
  final boundaryTs = (rows.last['rec_ts'] as num).toInt();
  var i = rows.length - 1;
  while (i > 0 && (rows[i - 1]['rec_ts'] as num).toInt() == boundaryTs) {
    i--;
  }
  return i;
}

/// Test seam: the rolling baseline window the readiness computation actually
/// runs against, loaded exactly as production does. Exposed to assert the read
/// path ignores a polluted `rolling_artifact` and rebuilds from `metric_series`.
@visibleForTesting
Future<List<double>> debugBaselineWindow(String key) async =>
    (await _BaselineHistoryCache.load()).values(key);

/// Test seam: the EXACT per-day baseline windows one derivation sweep would feed
/// the readiness pass, in dispatch order (`orderedDays` is newest-first).
///
/// Pins the two properties the sweep path must have — the snapshot is loaded
/// ONCE and never mutated as days complete, and each day's window self-excludes
/// that day's own date. Both were violated by the old `appendScalars` sweep.
@visibleForTesting
Future<List<List<double>>> debugSweepBaselineWindows(
  String key,
  List<String> orderedDays, {
  String? deviceFamily,
}) async {
  final history = await _BaselineHistoryCache.load();
  return [
    for (final day in orderedDays)
      history.valuesBefore(key, day,
          family: DerivationEngine._baselineFamily(key, deviceFamily)),
  ];
}

/// Test seam: the baseline signature [DerivationEngine.rescanRecent] gates on,
/// rebuilt from the current `metric_series`.
@visibleForTesting
Future<String> debugBaselineSignature() async =>
    (await _BaselineHistoryCache.load()).toArtifactJson()['signature']
        as String;

@visibleForTesting
({List<String> days, String reason}) selectLightDeriveDays({
  required Set<String> rawDays,
  required List<String> pendingDays,
  required String today,
}) {
  if (rawDays.contains(today) && pendingDays.contains(today)) {
    return (days: [today], reason: 'today-priority');
  }
  return (days: [pendingDays.last], reason: 'latest-pending');
}

/// The fingerprint a day's derive is recorded under, or null when the day has
/// no decoded rows to fingerprint (unknown is never "unchanged").
///
/// A day's night search reaches back into the PREVIOUS local day
/// (`kNocturnalSearchLookbackSec`), so the previous day's rows are part of its
/// input. Profile fields feed HRmax/calories/TRIMP, so they are too. The algo
/// version is not folded in: [LocalDb.derivedFingerprints] filters on it.
@visibleForTesting
String? deriveFingerprint({
  required String profileSig,
  required String? own,
  required String? previous,
}) => own == null
    ? null
    : DerivedFingerprint.compose(
        profileSig: profileSig,
        own: own,
        previous: previous,
      );

/// Of [todoDays], the ones a manual sync must derive: those whose input
/// fingerprint differs from the one recorded when they were last derived, plus
/// any day whose raw cannot be pruned until it has a COMPLETE result
/// (invariant 9: a day held by the prune is never skipped, so a transient
/// failure keeps getting its chance). A day with no current fingerprint is not
/// provably unchanged, so it runs.
@visibleForTesting
List<String> selectChangedDays({
  required List<String> todoDays,
  required Map<String, String?> current,
  required Map<String, String> derived,
  required Set<String> prunePending,
}) => [
  for (final day in todoDays)
    if (prunePending.contains(day) ||
        current[day] == null ||
        current[day] != derived[day])
      day,
];

class _DeriveScope {
  final bool fullHistory;
  final List<String> targetDays;
  final String reason;

  /// EVERY day label that still has 1 Hz substrate on disk — not just the ones
  /// this pass targets. The raw-prune guard needs the whole set: a day that
  /// aged out of the light scope while still un-derived is exactly the day
  /// whose raw must not be deleted, and it is by definition not in
  /// [targetDays]. Comes free from the `decodedRecTsMaxByDay()` that selects
  /// the scope, so nothing extra is queried for it.
  final List<String> rawDays;

  const _DeriveScope({
    required this.fullHistory,
    required this.targetDays,
    required this.reason,
    this.rawDays = const [],
  });
}

/// One (date, value) sample of a baseline series.
typedef _DatedValue = ({String date, double value});

class _BaselineHistoryCache {
  _BaselineHistoryCache(this._series, [this._families = const {}])
      : _prefixMax = {
          for (final entry in _series.entries)
            entry.key: _buildPrefixMax(entry.value),
        };

  /// `_prefixMax[key][i]` = the largest value among `_series[key][0..i]`
  /// inclusive. Built once here (the series is frozen for the sweep) so
  /// [maxBefore] can answer in O(log n) instead of rescanning the whole
  /// series on every call — a full-history rescan per target day, per
  /// baseline key, made a sweep over N days of history O(N²).
  static List<double> _buildPrefixMax(List<_DatedValue> series) {
    final out = List<double>.filled(series.length, 0);
    var best = double.negativeInfinity;
    for (var i = 0; i < series.length; i++) {
      if (series[i].value > best) best = series[i].value;
      out[i] = best;
    }
    return out;
  }

  /// The count of entries in [series] (sorted ascending by date) whose date
  /// is strictly before [beforeDate] — i.e. the exclusive end index of the
  /// "before" window. Binary search: [series] is immutable for the sweep and
  /// already date-ascending (see [_series]'s doc comment).
  static int _beforeIndex(List<_DatedValue> series, String beforeDate) {
    var lo = 0, hi = series.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (series[mid].date.compareTo(beforeDate) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  final Map<String, List<double>> _prefixMax;

  /// `key -> date -> method family` of each stored value (`metric_method`,
  /// else the day's stamped device family). BASELINES ARE PER METHOD FAMILY:
  /// a day derived from a 1-min wearable is scored only against 1-min days,
  /// a band day only against band days. A date with no family is never
  /// foreign (unknown is not a seam), and a band-only history has nothing to
  /// exclude, so it reads exactly as before.
  final Map<String, Map<String, String>> _families;
  final Map<String, List<_DatedValue>> _byFamily = {};

  /// The wearable's and the band's newest rows, read once per pass (this
  /// cache lives exactly one pass) for [_agingEdgeFor]: the wearable read
  /// scans its whole HR history, too much to repeat for every day.
  Future<int?>? _wearableEdge, _bandEdge;

  /// [key]'s series restricted to [family] (see [_families]); the whole
  /// series when nothing in it is of another family.
  List<_DatedValue> _seriesFor(String key, String? family) {
    final all = _series[key] ?? const <_DatedValue>[];
    final fams = _families[key];
    // A day of no single family (a strap swap, legacy rows) is a band's, so
    // its baselines are the band's method family: a wearable's days never
    // reach them. A band-only history is all that family (or unstamped), so
    // it still reads whole.
    if (family == null && key != 'skin_temp_adc') {
      family = methodFamily('gen4');
    }
    // A wearable's skin temperature takes only the nights stamped as that
    // device's: an unstamped day (written before the stamp existed) is most
    // likely a band's, in another sensor's unit.
    bool wearable(String? f) => isWearableFamily(f);
    final strict = key == 'skin_temp_adc' && wearable(family);
    // A day of no single family (a strap swap, legacy rows) is a band's, and
    // a band's skin temperature never takes a wearable's nights either.
    if (key == 'skin_temp_adc' &&
        family == null &&
        fams != null &&
        fams.values.any(wearable)) {
      return _byFamily.putIfAbsent('$key|', () => [
            for (final v in all)
              if (!wearable(fams[v.date])) v,
          ]);
    }
    if (!strict &&
        (family == null ||
            fams == null ||
            fams.values.every((f) => f == family))) {
      return all;
    }
    return _byFamily.putIfAbsent('$key|$family', () => [
          for (final v in all)
            if ((fams?[v.date] ?? (strict ? null : family)) == family) v,
        ]);
  }

  /// The baseline series this cache carries, keyed by `metric_series.key`.
  static const List<String> keys = [
    'ln_rmssd',
    'rmssd',
    'rhr',
    'resp_rate',
    'skin_temp_adc',
    'readiness',
    // The readiness composite z — later days' scores are calibrated against
    // its spread (`calibratedReadinessScore`).
    'readiness_z',
    // Per-day high quantile of the calibration-invariant dynamic accel
    // amplitude. The 1 Hz activity estimator's floor is anchored on the MEDIAN
    // of this series across trailing days, never on a same-day value: a
    // single-day threshold collapses on a quiet day and passes everything,
    // which is the mirror image of the absolute-constant failure it replaced.
    'dyn_p90',
    // TS-03 — the per-day OBSERVED heart-rate ceiling (bpm). Not a baseline
    // like the rest: nothing is z-scored against it and it is never averaged.
    // It rides in this cache because it is a `metric_series` key the day's
    // derive needs the PRIOR days' values of, which is exactly what this
    // snapshot is (see [maxBefore]).
    'hr_ceiling_bpm',
    // Each day's own quiet-waking level (median wake %HRR). Strain is priced
    // against the median of the PRIOR days' values — a trait, never the day
    // under test. Unitless, so no family-seam mask applies.
    'quiet_hrr',
  ];

  /// DATED baseline samples, ascending by date, one entry per day (metric_series
  /// is keyed `(date, key)` with REPLACE, so it is structurally de-duplicated).
  ///
  /// IMMUTABLE for the lifetime of one derivation sweep. There is deliberately
  /// no mutator: the previous `appendScalars` mutated this shared snapshot as
  /// each day of a sweep finished, which re-introduced exactly the duplicate-day
  /// pollution the load path was rewritten to prevent — `load()` had ALREADY
  /// read the persisted values of the days about to be re-derived, so appending
  /// each finished day again (and evicting a real old day to stay at 28) left
  /// later days in the sweep reading a window with up to 21 duplicated recent
  /// values in descending date order. Median/MAD then collapsed toward the
  /// repeated value and readiness went blank/wrong — the load-path bug, moved
  /// into the sweep path. A sweep now reads ONE frozen snapshot, and each day
  /// derives its own window from it by date.
  final Map<String, List<_DatedValue>> _series;

  /// Load the rolling baseline window that feeds the readiness/illness
  /// computations. This ALWAYS rebuilds from `metric_series` — the canonical
  /// scalar store, keyed `(date, key)` with REPLACE, so it is structurally one
  /// value per day.
  ///
  /// We deliberately do NOT trust the persisted `rolling_artifact` for history.
  /// That artifact was written from an in-memory cache with no day identity, so
  /// repeated same-day re-derives could stack duplicate copies of today into the
  /// window; once enough slots matched, the readiness composite's robust z-score
  /// hit MAD=0 and went absent — the blank readiness ring. A polluted artifact
  /// is still valid JSON, so trusting it on read would let that pollution reach
  /// the computation on the first post-upgrade derive (and, when every day is
  /// finalized and `run()` does no work, forever). Rebuilding from the
  /// de-duplicated store on every load makes the read path immune and self-heals
  /// any already-polluted install.
  ///
  /// NOTE ON THE QUERY: `LocalDb.metricSeries(key)` with NO `limit` is the whole
  /// series, `date ASC` — the dates are what make a per-day `date < target`
  /// window possible at all. It must NOT be given a `limit` (that is `date ASC
  /// LIMIT n`, i.e. the OLDEST n — the opposite of a trailing window); the
  /// trailing window is taken here, in Dart, per target day.
  ///
  /// IMPORTED DAYS ARE EXCLUDED. `LocalDb.isMeasuredDay` kept another vendor's
  /// export from OVERWRITING a measured day, but nothing kept it out of the
  /// window on the way back in: a WHOOP or cloud import writes real
  /// `metric_series` rows for `rhr`, `rmssd`, `readiness` and `resp_rate`, and
  /// this load read them like any other day. Their scores are a different
  /// algorithm's output over a different (or no) substrate, so blending them in
  /// moves the median every personal z-score is taken against — silently, for
  /// as long as the window is, and worst exactly when someone imports their
  /// history on day one and has nothing else in the window at all.
  ///
  /// The mask is taken ONCE per load and applied to every key, because the
  /// query behind it scans day bundles (see [LocalDb.importedDates]).
  ///
  /// A SECOND, NARROWER MASK rides along: days measured by a different BAND
  /// FAMILY, applied only to [LocalDb.familySeamKeys]. That one is not about a
  /// foreign algorithm — it is this app's own maths over a sensor whose units
  /// differ (`skin_temp_adc` is a gen4 ADC count on one side of a strap swap
  /// and a gen5 centi-degree on the other), so it is masked PER-METRIC rather
  /// than blanket: a family seam that only makes a number noisier (RHR, RMSSD)
  /// stays in the window. Empty for a user who has never changed generation,
  /// which is why it moves no number today.
  static Future<_BaselineHistoryCache> load() async {
    // Before anything is read: see [metricSeriesRevs].
    final metricRevs = await captureMetricSeriesRevs();
    final imported = await LocalDb.importedDates();
    final foreignFamily =
        await LocalDb.foreignFamilyDates(ignore: kWearableFamilies);
    Future<List<_DatedValue>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key);
      final seam =
          LocalDb.familySeamKeys.contains(key) ? foreignFamily : const <String>{};
      final out = <_DatedValue>[];
      for (final row in rows) {
        final date = row['date'];
        final value = row['value'];
        if (date is! String || date.isEmpty || value is! num) continue;
        if (imported.contains(date) || seam.contains(date)) continue;
        out.add((date: date, value: value.toDouble()));
      }
      return out;
    }

    final loaded = await Future.wait([for (final k in keys) hist(k)]);
    // Each value's method family (see [_families]).
    final dayFamily = <String, String>{
      for (final r in await LocalDb.metricSeriesVersions())
        if (r['date'] case final String d)
          if (methodFamily(r['device_family'] as String?) case final String f)
            d: f,
    };
    final families = <String, Map<String, String>>{
      for (final k in keys)
        k: {...dayFamily, ...await LocalDb.metricFamilies(k)},
    };
    // A wearable's skin temperature is its own sensor's unit and site (a
    // ring's finger in centi-°C is not another ring's, nor a band's wrist),
    // so its baseline is that device family's nights, not the resolution's
    // (see [_seriesFamily]). Band days keep their method family.
    for (final r in await LocalDb.metricSeriesVersions()) {
      final d = r['date'], f = r['device_family'] as String?;
      if (d is String && isWearableFamily(f)) {
        families['skin_temp_adc']![d] = f!;
      }
    }
    return _BaselineHistoryCache({
      for (var i = 0; i < keys.length; i++) keys[i]: loaded[i],
    }, families)
      ..metricSeriesRevs = metricRevs;
  }

  /// `metric_series` revisions (scope -> rev) as they stood BEFORE this
  /// history was read; null when that read failed. A day's input stamp holds
  /// its metric_series scopes to these (the history is frozen for the pass,
  /// the rows are not).
  Map<String, int>? metricSeriesRevs;

  /// The trailing [_baselineWindowDays] values for [key], oldest→newest.
  ///
  /// This is the WHOLE window including the newest day; it backs the persisted
  /// rolling artifact + the rescan signature, which describe "the baseline as it
  /// currently stands". Per-day derivation must use [valuesBefore] instead.
  List<double> values(String key) => _trailing(_series[key] ?? const []);

  /// The trailing [_baselineWindowDays] values for [key] STRICTLY BEFORE
  /// [beforeDate] (`date < ?`), oldest→newest — the baseline for deriving the
  /// day labelled [beforeDate].
  ///
  /// SELF-EXCLUSION IS THE POINT. The previous derive of the same day has
  /// already written its own row to `metric_series`, so an unfiltered trailing
  /// window contained TODAY: every light pass after the first z-scored today's
  /// RHR/HRV/temp against a baseline that already contained today (pulling the
  /// baseline toward the value under test and understating a genuinely
  /// off day), and the lnRMSSD stack — which is contractually handed
  /// `[...history, today]` and takes all-but-last as its baseline — counted it
  /// a second time. v38 fixed precisely this self-inclusion inside analytics;
  /// this is the same defect at the edge layer that feeds it. Dates strictly
  /// AFTER the target are excluded too: a baseline is prior days, and a backfill
  /// sweep must not let later days leak into an older day's baseline (which
  /// would also make the result depend on sweep order).
  /// The set of dates that actually have a stored value for [key].
  ///
  /// Used to detect wear GAPS: a date with no `dyn_p90` row means the band
  /// produced no usable motion that day.
  Set<String> datesFor(String key) => {
        for (final s in _series[key] ?? const <_DatedValue>[]) s.date,
      };

  /// The LARGEST value of [key] over every stored day strictly before
  /// [beforeDate], or null when there is none.
  ///
  /// Deliberately NOT windowed to the trailing 28 like [valuesBefore]: this
  /// backs "highest we've seen", and a ceiling that silently drops out of the
  /// window would move every zone boundary in the app with nothing on screen
  /// saying why. The date it happened is shown next to it, so an old one is
  /// visible rather than anonymous.
  double? maxBefore(String key, String beforeDate, {String? family}) {
    final series = _seriesFor(key, family);
    final end = _beforeIndex(series, beforeDate);
    if (end == 0) return null;
    if (!identical(series, _series[key])) {
      return series.take(end).map((v) => v.value).reduce(math.max);
    }
    // Every key present in _series has a matching _prefixMax entry by
    // construction (built together in the constructor from the same
    // entries) — this is unreachable today, but `?[...]` costs nothing and
    // survives a future refactor that builds one map without the other.
    return _prefixMax[key]?[end - 1];
  }

  List<double> valuesBefore(String key, String beforeDate, {String? family}) {
    final series = _seriesFor(key, family);
    final end = _beforeIndex(series, beforeDate);
    final from = end <= _baselineWindowDays ? 0 : end - _baselineWindowDays;
    return [for (var i = from; i < end; i++) series[i].value];
  }

  static List<double> _trailing(List<_DatedValue> samples) {
    final from = samples.length <= _baselineWindowDays
        ? 0
        : samples.length - _baselineWindowDays;
    return [for (var i = from; i < samples.length; i++) samples[i].value];
  }

  /// Strain's quiet-waking level is a baseline too, and [rescanRecent] has to
  /// re-price the recent days when ANY of their windows moves — a count and a
  /// median of the whole series do not see that: each day is priced on the
  /// median of the days strictly BEFORE it, so a value can change under one
  /// day's window while the overall count and median stay put (e.g. yesterday
  /// .15 → .25 in [.10,.10,.20,.20,.20,.15,.30] moves today's baseline .175 →
  /// .20 and leaves both unchanged). So this fingerprints the DATED entries
  /// themselves — every one that can sit in the window of a day the rescan
  /// covers: the [_rescanWindowDays] + [_baselineWindowDays] stored days
  /// before the newest.
  ///
  /// THE NEWEST IS LEFT OUT while no stored day comes after it. It is then
  /// normally today's, rewritten on every light derive as the wake series
  /// grows, and no day yet sits on a window holding it. Hashing it re-ran the
  /// whole rescan window on every heavy pass for nothing. Once ANY baseline
  /// series has a later day (one too short to write its own level, say, which
  /// may already be finalized), that day was priced on it, so it is hashed.
  String _quietFingerprint() {
    final series = _series['quiet_hrr'] ?? const <_DatedValue>[];
    const span = _rescanWindowDays + _baselineWindowDays;
    final newest = series.isEmpty ? null : series.last.date;
    final laterDay = newest != null &&
        _series.entries.any((e) =>
            e.key != 'quiet_hrr' &&
            e.value.isNotEmpty &&
            e.value.last.date.compareTo(newest) > 0);
    final end = series.isEmpty ? 0 : series.length - (laterDay ? 0 : 1);
    final from = end <= span ? 0 : end - span;
    final dated = [
      for (var i = from; i < end; i++)
        '${series[i].date}=${series[i].value.toStringAsFixed(6)}',
    ].join(',');
    return sha1.convert(utf8.encode(dated)).toString().substring(0, 12);
  }

  Map<String, dynamic> toArtifactJson() {
    double? avg(List<double> xs) {
      if (xs.isEmpty) return null;
      return xs.reduce((a, b) => a + b) / xs.length;
    }

    String fmt(double? v) => v == null ? 'na' : (v * 100).round().toString();
    final rhr = values('rhr');
    final rmssd = values('rmssd');
    final temp = values('skin_temp_adc');
    final resp = values('resp_rate');
    final readiness = values('readiness');
    final signature =
        'v$kAlgoVersion|n${rhr.length}|rhr${fmt(_median(rhr))}|rmssd${fmt(_median(rmssd))}'
        '|temp${fmt(_median(temp))}|resp${fmt(_median(resp))}'
        '|q${_quietFingerprint()}';
    return {
      'algo_version': kAlgoVersion,
      'signature': signature,
      'series': {
        'ln_rmssd': values('ln_rmssd'),
        'rmssd': rmssd,
        'rhr': rhr,
        'resp_rate': resp,
        'skin_temp_adc': temp,
        'readiness': readiness,
      },
      'rolling': {
        'rhr': avg(rhr),
        'rmssd': avg(rmssd),
        'readiness': avg(readiness),
        'n': rhr.length,
      },
    };
  }
}

/// Background re-trigger window: how far back from the DATA EDGE a
/// baseline-dirty rescan re-derives days (including finalized ones). Kept ≤ the
/// raw-retention window so every day in scope still has raw to re-derive from;
/// older days simply aren't in the substrate and are naturally excluded.
const int _rescanWindowDays = 21;

/// The union a day's prepare loaded ([DerivationEngine._loadUnion]), shared
/// between the night search and the day / staged-night windows cut from it.
class _UnionHolder {
  RetainedLoad? load;
}

/// Per-day-local page/row accumulator for the prepare stage (see
/// `_prepareTargetDay`/`_loadSubstrateRange`). Deliberately NOT shared
/// `_diag` state — under concurrent per-day processing, multiple days
/// resetting/incrementing the same shared counters would race and produce
/// garbage diagnostics. Each day gets its own instance; only the final
/// per-day total is merged into the shared running max, once.
class _PrepareStats {
  int pages = 0;
  int rows = 0;

  /// A load of this day found a retained substrate it could not reuse and read
  /// the whole range ([DerivationEngine._retained]).
  bool fullReload = false;
}

/// Run [worker] over [items] with at most [concurrency] running at once. Each
/// of up to [concurrency] "lanes" pulls the next unclaimed item as soon as
/// it's free — a mix of fast (empty/mostly-empty day) and slow (heavy
/// backlog day) items keeps every lane continuously busy, rather than
/// lock-stepping in fixed-size batches where one slow item stalls an entire
/// batch. Pure orchestration: no DB/isolate awareness of its own — every
/// caller in this file catches errors INSIDE [worker] itself (a day that
/// fails is marked skipped and processing continues), so a throwing [worker]
/// is not part of the normal contract here, but note that (per
/// `Future.wait`'s default behavior) an uncaught throw would propagate out
/// and NOT stop already-in-flight sibling lanes from completing their
/// current item first.
///
/// This is the ONE place run()/runDays()/rescanRecent() get their real,
/// multi-core parallelism from — replacing what used to be a fully
/// sequential `for` loop that left every core but one idle during a
/// multi-day backlog sweep.
@visibleForTesting
Future<void> runWithConcurrency<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) worker,
) async {
  if (items.isEmpty) return;
  final poolSize = math.min(concurrency, items.length).clamp(1, items.length);
  var nextIndex = 0;
  Future<void> lane() async {
    while (true) {
      final myIndex = nextIndex;
      if (myIndex >= items.length) return;
      nextIndex++; // no `await` since the read above — atomic claim
      await worker(items[myIndex]);
    }
  }

  await Future.wait(List.generate(poolSize, (_) => lane()));
}

/// Minimal async mutex: serializes read-modify-write sections that concurrent
/// day workers ([runWithConcurrency]) would otherwise interleave.
///
/// Dart's scheduler makes a single statement atomic, but NOT a
/// read → decide → write sequence with `await`s in it: every lane can observe
/// the pre-write state before any of them writes. The shared movement floor is
/// exactly that shape, so it needs one.
class _AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous
        .then((_) => action())
        .whenComplete(completer.complete);
  }
}

/// "Now, in data time": [bandEdge] (the band's newest row, or null) or the
/// active wearable's newest reading, whichever is later. A user who moved
/// from the band to a wearable keeps the band's old rows, and their edge
/// alone would hold every newer wearable day short of finalizing. With no
/// active wearable this is [bandEdge] unchanged.
Future<int?> _withWearableEdge(int? bandEdge) async {
  final w = await wearableLastTs();
  if (w == null || bandEdge == null) return bandEdge ?? w;
  return math.max(bandEdge, w);
}

/// The edge a day of [family] ages against before it finalizes: the edge of
/// the device that supplied it. [_withWearableEdge]'s max is right for "now"
/// (scope, pruning), but a band day aged on the ring's edge would lock while
/// the band still holds an undrained backlog for it. A wearable day ages on
/// the wearable's edge, every other day (band, unstamped, mixed) on the
/// band's. With no active wearable this is [dataNowSec] unchanged.
///
/// ponytail: a day that only had wearable rows when derived still ages on the
/// wearable's edge even if a band backlog for it drains later; telling a
/// stale band from a lagging one needs the band's last-sync time.
Future<int> _agingEdgeFor(String? family, int dataNowSec,
    [_BaselineHistoryCache? pass]) async {
  final w = await (pass == null
      ? wearableLastTs()
      : pass._wearableEdge ??= wearableLastTs());
  if (w == null) return dataNowSec;
  if (isWearableFamily(family)) return w;
  final band = await (pass == null
      ? LocalDb.lastDecodedRecTs()
      : pass._bandEdge ??= LocalDb.lastDecodedRecTs());
  return band ?? dataNowSec;
}

/// Test seam for [_agingEdgeFor].
@visibleForTesting
Future<int> debugAgingEdge(String? family, int dataNowSec) =>
    _agingEdgeFor(family, dataNowSec);



/// Wrapper for a cancellable-isolate result, so a computation whose OWN result
/// happens to be a `List` (the uncaught-error wire format) or `null` (the
/// `onExit` signal) can never be misread as a failure.
class _IsolateValue {
  final Object? value;
  const _IsolateValue(this.value);
}

/// Test seam for [DerivationEngine._runIsolateCancellable] — the isolate
/// lifecycle guarantees (value / error / killed-on-timeout) are what the engine
/// depends on to never hang, so they're pinned directly.
@visibleForTesting
Future<R> runCancellableIsolate<R>(
  FutureOr<R> Function() compute,
  Duration timeout, {
  String label = 'test',
}) =>
    DerivationEngine._runIsolateCancellable(compute, timeout, label: label);

/// Sendable input for [DerivationEngine._computeDayBlocks] — crosses the
/// `Isolate.run` boundary, so every field is plain data (Substrate is int/double
/// lists; Profile is a primitive data class). DB reads that the
/// pure compute needs are performed by the caller and passed in here.
class _DayBlocksInput {
  final DayCalculationState calculationState;
  final ana.CalculationMode calculationMode;

  /// The beat-driven day figures of a resumed pass, from the checkpoint's
  /// streaming state; null computes them from [daySub]'s beats.
  final DayTailResult? streamed;

  /// Finished sessions whose observed ceiling is already known, by session id.
  final Map<String, ({Map<String, dynamic> json, double? bpm})> ceilingReuse;
  final Substrate daySub;
  final Substrate napSub;
  final Substrate sleepSub;
  final Profile profile;
  final int onsetSec;
  final int offsetSec;

  /// Where nap detection's main-sleep exclusion ends: [offsetSec] plus the
  /// band trim (`sleep.band_offset_trim_sec`), i.e. the UNTRIMMED auto end, so
  /// a lie-in the band rule cut off the night is not reclaimed as a nap. Null
  /// = [offsetSec].
  final int? napExcludeEndSec;

  /// NOCTURNAL resting HR for this day (`scalars.rhr_nocturnal`) — null unless a
  /// sleep session was detected. NOT `scalars.rhr`, which is allowed to fall
  /// back to daytime HR for the resting-HR card and is not a TRIMP reference.
  final double? rhr;

  /// Prior nights' median resting HR, for strain and energy on a day with no
  /// night of its own ([rhrFallbackFromHistory]). Never used for workout
  /// detection, which keeps needing a real night.
  final double? rhrFallback;
  final int? maxHrUsed;
  final int liveStepsReal;
  /// Step-counter calibration read on the main isolate; null = uncalibrated.
  final StepCalibrationProfile? counterProfile;
  /// `Wearing` code the profile is keyed to, 0 when refused for this day.
  final int counterWearing;

  /// How much of [liveStepsReal] the BAND's own 100 Hz pedometer was credited
  /// with after the per-window resolution; the rest is the phone's. Carried so
  /// the bundle can say which sensor counted without re-reading the DB from the
  /// isolate, which has no handle.
  final int liveStepsFromStrap;

  /// The SAME resolution's credited spans, as `[startSec, endSec, steps]` —
  /// the walking-cadence energy term prices wake minutes off these (see
  /// `cadenceSpmForMinutes`). Credited, never raw rows, so a step the ladder
  /// took back off a span cannot be priced here either.
  final List<List<int>> stepSpans;

  /// PERSONAL ambulatory floor (g, dynAmp units) from trailing days, or null
  /// when there isn't enough history yet — in which case the 1 Hz estimator
  /// abstains rather than falling back to a constant. Computed on the main
  /// isolate (it needs metric_series) and carried in, like the other history.
  final double? dynFloorG;

  /// How many trailing days backed [dynFloorG] — only for the cold-start note.
  final int dynHistoryDays;

  /// Prior days' `quiet_hrr` (strictly before [date]) — the same window the
  /// pure pipeline was handed, so both halves price strain on one level.
  final List<double> quietHrrHistory;

  final List<Map<String, dynamic>> savedSessions;
  final List<int> typicalMealMinutes;

  /// The user's nap edits for this day, replayed over the detector's output.
  final List<NapEdit> napEdits;

  /// Strap-reported off-wrist spans ([startSec, endSec]) over the nap window.
  /// A band on a table is motionless and reads as deep rest — this is the
  /// dominant nap false positive, and the strap already tells us about it.
  final List<List<int>> wristOffSpans;

  /// Strap-reported charging spans — off-wrist by definition, and motionless.
  final List<List<int>> chargingSpans;

  /// The user's rejected / hand-set main-sleep window ([startSec, endSec]), or
  /// empty. Nap detection must not re-detect it as a nap.
  final List<List<int>> blankedSpans;

  /// Main-sleep TST (minutes) and efficiency (0..1) from ISOLATE 1.
  ///
  /// Carried explicitly because `_computeDayBlocks` builds its own fresh
  /// `scMap` seeded with `rhr` alone — reading `scMap['tst_min']` in there
  /// silently yields null forever, which is how the main sleep period came to
  /// report "—" for its duration.
  final int? mainTstMin;
  final double? mainEfficiency;

  final String date;

  /// Local midnight opening this calendar day — where `napSub` starts. Nap
  /// attribution needs BOTH boundaries: [dayEndSec] pushes a nap starting in
  /// the borrowed buffer onto tomorrow, and this one drops the tail of a nap
  /// yesterday already owns. See `_attachNaps`.
  final int dayStartSec;
  final int dayEndSec;
  final int dataNowSec;

  /// See `PreparedDerivationDay.tonightSleepOnsetSec`. 0 = none.
  final int tonightSleepOnsetSec;
  final int tonightSleepOffsetSec;
  const _DayBlocksInput({
    required this.calculationState,
    required this.calculationMode,
    this.streamed,
    required this.ceilingReuse,
    required this.daySub,
    required this.napSub,
    required this.sleepSub,
    required this.profile,
    required this.onsetSec,
    required this.offsetSec,
    this.napExcludeEndSec,
    required this.rhr,
    this.rhrFallback,
    required this.maxHrUsed,
    required this.liveStepsReal,
    this.counterProfile,
    this.counterWearing = Wearing.wrist,
    this.liveStepsFromStrap = 0,
    this.stepSpans = const [],
    required this.dynFloorG,
    required this.dynHistoryDays,
    this.quietHrrHistory = const [],
    required this.savedSessions,
    this.typicalMealMinutes = const [],
    this.napEdits = const [],
    required this.wristOffSpans,
    required this.chargingSpans,
    this.blankedSpans = const [],
    required this.mainTstMin,
    required this.mainEfficiency,
    required this.date,
    required this.dayStartSec,
    required this.dayEndSec,
    required this.dataNowSec,
    this.tonightSleepOnsetSec = 0,
    this.tonightSleepOffsetSec = 0,
  });
}

/// Sendable output of [DerivationEngine._computeDayBlocks]. [bundlePatch] /
/// [seriesPatch] / [scalarPatch] are merged into the isolate-1 bundle on the main
/// isolate; [wake] is persisted; candidates are reconciled and session HRR
/// writes are applied by the database-owning caller.
class _DayBlocksOutput {
  final List<Map<String, dynamic>> mealSuggestions;
  final List<Map<String, dynamic>> napSuggestions;

  /// Per-minute sleep-window HR and the day's known nap spans, for track
  /// detection (not stored).
  final List<Map<String, num>> sleepHrMinutes;
  final List<List<int>> napSpans;
  final DayCalculationState calculationState;

  /// Finished sessions whose observed ceiling was scanned this pass, by id.
  final Map<String, ({Map<String, dynamic> json, double? bpm})> ceilingComputed;
  final Map<String, dynamic> bundlePatch;
  final Map<String, dynamic> seriesPatch;
  final Map<String, dynamic> scalarPatch;
  final Map<String, dynamic> wake;

  /// The `kcal_minutes|<day>` payload, or null (see `kcalMinutesForDayHeavy`).
  final Map<String, dynamic>? kcalMinutes;
  final List<Map<String, dynamic>> suggestionsToPersist;
  final List<(String, double)> sessionHrrWrites;
  const _DayBlocksOutput({
    required this.calculationState,
    required this.ceilingComputed,
    required this.bundlePatch,
    this.napSuggestions = const [],
    this.mealSuggestions = const [],
    this.sleepHrMinutes = const [],
    this.napSpans = const [],
    required this.seriesPatch,
    required this.scalarPatch,
    required this.wake,
    required this.kcalMinutes,
    required this.suggestionsToPersist,
    required this.sessionHrrWrites,
  });
}

/// Result of the pure workout compute ([DerivationEngine._computeWorkouts]).
class _WorkoutCompute {
  final List<Map<String, dynamic>> boutJson;
  final double? hrrBpm;
  final double? hrrTauS;
  final List<(String, double)> sessionHrrWrites;
  final List<Map<String, dynamic>> suggestionsToPersist;
  const _WorkoutCompute({
    required this.boutJson,
    required this.hrrBpm,
    required this.hrrTauS,
    required this.sessionHrrWrites,
    required this.suggestionsToPersist,
  });
  const _WorkoutCompute.empty()
      : boutJson = const [],
        hrrBpm = null,
      hrrTauS = null,
        sessionHrrWrites = const [],
        suggestionsToPersist = const [];
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final vs = List<double>.from(xs)..sort();
  final mid = vs.length ~/ 2;
  return vs.length.isOdd ? vs[mid] : (vs[mid - 1] + vs[mid]) / 2;
}
