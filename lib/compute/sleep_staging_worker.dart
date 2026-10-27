// sleep_staging_worker.dart — one night's sleep staging as a registered worker
// entry (design 02). It was an inline closure in
// `DerivationEngine._sleepCandidateForDay` (baselined as
// dispatcherClosureContract); moving it here is also what lets the cardio
// feature rows stay ENCODED on the UI isolate: the engine hands the worker the
// chunks that overlap the staging window, and everything that reads or writes
// them (decode, merge, cut to the window, prune, encode) happens in here.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';
import 'cardio_rows_blob.dart';
import 'day_resume_state.dart' show restrictCardioRows;
import 'derive_prepare.dart';
import 'vendor_sleep.dart' show VendorNight;
import 'sleep_profile_policy.dart';
import 'substrate.dart';

/// Rows older than this (start second) are dropped from the cache.
const int kCardioRowsKeepSec = 4 * 24 * 3600;

/// Rows within this many seconds of a staging window are handed to it.
const int kCardioRowsSlackSec = 3600;

/// What [stageSleepCandidateHeavy] stages from. Plain data except the
/// substrate, which is the window's decoded samples.
@SendableShape('carries a Substrate (typed-data columns and a Set<String> of '
    'device ids) and a SleepWindowOverride; round trip in '
    'test/sendable_stageSleepCandidateHeavy_test.dart')
class SleepStagingInput {
  const SleepStagingInput({
    required this.dayId,
    required this.searchSub,
    required this.override,
    required this.priorSleep,
    required this.confirmedWakeSec,
    required this.profileJson,
    required this.mayFold,
    required this.rowChunks,
    required this.rowsLoSec,
    required this.rowsHiSec,
    required this.nowSec,
    this.vendorNights = const [],
  this.method = ana.StagingMethod.cardio,
  });

  final String dayId;
  final ana.StagingMethod method;
  final Substrate searchSub;
  final SleepWindowOverride? override;
  final List<({int startSec, int endSec, String dayKey})> priorSleep;
  final int? confirmedWakeSec;

  /// The rolling sleep profile as stored (JSON), read on the UI isolate.
  final String? profileJson;

  /// Whether this staging may produce an observation to fold into the profile.
  final bool mayFold;

  /// Encoded cache rows that may overlap the window ([CardioRowsChunk.json]).
  final List<Uint8List> rowChunks;

  /// The staging window's rows: start seconds in [rowsLoSec, rowsHiSec].
  final int rowsLoSec, rowsHiSec;

  /// The instant, in epoch seconds, that old rows are pruned against.
  final int nowSec;

  /// A device's own staged nights (`vendor_staged`) that may stage the main
  /// sleep, as `prepareSleepSessionCandidate` takes them (upstream #vendor).
  final List<VendorNight> vendorNights;
}

/// What staging gives back. [rowsJson] is ONE chunk holding every row of the
/// input chunks and of this staging that is still within the keep horizon (null
/// when none are); its start seconds lie in [rowsLoSec, rowsHiSec].
@sendable
class SleepStagingResult {
  const SleepStagingResult({
    required this.candidateJson,
    required this.observationJson,
    required this.rowsJson,
    required this.rowsLoSec,
    required this.rowsHiSec,
    required this.rowHits,
    required this.rowMisses,
  });

  final String candidateJson;
  final String? observationJson;
  final Uint8List? rowsJson;
  final int rowsLoSec, rowsHiSec;
  final int rowHits, rowMisses;
}

/// WORKER ENTRY: stages [input]'s night on a worker isolate, never the UI
/// thread. `cardioStager` reads analytics "ambient" globals (the rolling sleep
/// profile it blends in, bounded <= 0.5, and the observation-recording flag it
/// folds back afterwards). They are ISOLATE-LOCAL, so they are re-armed here
/// from plain inputs, and the staging returns the staged candidate and the raw
/// observation as plain JSON for the main isolate to persist and fold. The
/// worker dies after its dispatch, so the recording flag cannot leak into the
/// next day's derivation.
@heavy
SleepStagingResult stageSleepCandidateHeavy(
  WorkerInputs inputs,
  SleepStagingInput input,
) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('stageSleepCandidateHeavy');
  final profileJson = input.profileJson;
  try {
    final p = profileJson == null
        ? null
        : ana.SleepUserProfile.fromJson(
            (jsonDecode(profileJson) as Map).cast<String, dynamic>());
    // Warm-up gate — see SleepProfilePolicy.shouldBlend. Note the profile is
    // only WITHHELD FROM STAGING here; accumulation into it happens on the
    // main isolate in _foldObservationIntoProfile, which re-reads the current
    // profile, so a withheld night still counts toward `nights`.
    ana.cardioUserProfile =
        SleepProfilePolicy.shouldBlend(p?.nights) ? p : null;
  } catch (_) {
    // Defense in depth: an incompatible/outdated persisted profile must fall
    // back to a cold start, never throw inside the worker (an uncaught throw
    // here bubbles to processDay's per-day catch → the day gets stuck marked
    // 'error' every pass until the row is fixed).
    ana.cardioUserProfile = null;
  }
  ana.cardioRecordObservations = true;
  ana.resetCardioObservations();

  // The rows this staging may reuse: every row of the chunks handed in, and the
  // part of them inside the window for the stager (so its hit/miss counts are
  // the window's own).
  final all = mergeCardioRowChunksHeavy(input.rowChunks);
  final rowCache = restrictCardioRows(all,
      loSec: input.rowsLoSec, hiSec: input.rowsHiSec + 1);
  final candidate = prepareSleepSessionCandidate(
    input.searchSub,
    method: input.method,
    targetDay: input.dayId,
    override: input.override,
    priorSleep: input.priorSleep,
    confirmedWakeSec: input.confirmedWakeSec,
    rowCache: rowCache,
    vendorNights: input.vendorNights,
    // The fold below reads only the target night's own observation (D36), so
    // earlier days that cannot change the target are skipped either way.
    skipUnusedDays: true,
    // Only the target night records an observation (D36).
    recordTargetOnly: true,
  );
  // A user's own window carries per-stage minute ranges (D27 revised): from
  // the stager's evidence where the band recorded, as wide as the window
  // where it did not. Detected nights are left exactly as they were.
  final ov = input.override;
  final ranges = input.method != ana.StagingMethod.cardio ||
          ov == null || userBlanksNight(ov.source)
      ? null
      : userWindowStageRangesHeavy(input.searchSub,
          onsetSec: ov.onsetSec, offsetSec: ov.offsetSec, rowCache: rowCache);
  final staged = ranges == null
      ? candidate
      : SleepSessionCandidate(
          dayId: candidate.dayId,
          method: candidate.method,
          confidence: candidate.confidence,
          flags: candidate.flags,
          sleepJson: {...candidate.sleepJson, 'stage_ranges': ranges},
          hypnoStages: candidate.hypnoStages,
          sleepOnsetSec: candidate.sleepOnsetSec,
          sleepOffsetSec: candidate.sleepOffsetSec,
          sleepSource: candidate.sleepSource,
          deviceNight: candidate.deviceNight,
          deviceId: candidate.deviceId,
        );
  // Fold the MAIN sleep (most epochs) of a freshly-staged night into the
  // rolling profile — done here in the worker because the observations live in
  // THIS isolate's globals. Skipped for overrides. EWMA self-seeds.
  String? observationJson;
  // IDEMPOTENT PER DAY. `fold()` is an EWMA step that also increments `nights`,
  // and this path runs on EVERY staging pass for a day — an algo-version bump, a
  // BLE-drain re-derive, a backfill sweep. Without a guard the same handful of
  // real nights fold hundreds of times: a real user export showed `nights: 1348`
  // against 12 days of data, which pins `personalWeight` at its 0.5 cap from day
  // one and collapses the EWMA onto whichever day was re-derived last. Measured
  // effect of that corrupt profile on the same nights: wake 4.3% -> 36.4%, deep
  // 1.9% -> 0.0%. One fold per day_id, ever.
  if (input.mayFold) {
    // ONLY the target day's own observation (D36): the shared buffer holds
    // every walked night, and the longest of those used to be folded under
    // the target's id. No staged night on the target ⇒ nothing to fold.
    final obs = ana.takeCardioObservations()
      ..sort((a, b) => b.epochs.compareTo(a.epochs));
    if (obs.isNotEmpty) {
      final main = obs.first;
      if (main.epochs >= 120) {
        // require ≥60 min — not a nap.
        // Return the raw OBSERVATION, not a folded profile. Folding here would
        // bake in the profile this worker read before staging began, and a
        // concurrent day may have written a newer one since. The fold happens
        // on the main isolate under the profile lock.
        observationJson = jsonEncode({
          'epochs': main.epochs,
          'hr_floor_p5': main.hrFloorP5,
          'hr_floor_p25': main.hrFloorP25,
          'hr_sleep_median': main.hrSleepMedian,
          'hr_arousal': main.hrArousal,
          'rmssd_med': main.rmssdMed,
          'rmssd_mad': main.rmssdMad,
          'enmo_still_cut': main.enmoStillCut,
          'enmo_move_cut': main.enmoMoveCut,
          'lfhf_med': main.lfhfMed,
          'rk_med': main.rkMed,
        });
      }
    }
  }
  // What the cache holds afterwards: the rows it came in with plus what this
  // staging computed, less anything past the keep horizon.
  all.merge(rowCache);
  final keepFrom = input.nowSec - kCardioRowsKeepSec;
  var lo = 1 << 62, hi = -(1 << 62);
  all.retainWhere((k) {
    if (k.startSec < keepFrom) return false;
    if (k.startSec < lo) lo = k.startSec;
    if (k.startSec > hi) hi = k.startSec;
    return true;
  });
  return SleepStagingResult(
    candidateJson: jsonEncode(staged.toJson()),
    observationJson: observationJson,
    rowsJson: all.length == 0 ? null : encodeCardioRowsHeavy(all),
    rowsLoSec: all.length == 0 ? 0 : lo,
    rowsHiSec: all.length == 0 ? 0 : hi,
    rowHits: rowCache.hits,
    rowMisses: rowCache.misses,
  );
}

/// Per-stage minute ranges (`sleep.stage_ranges`) for a user-asserted window
/// [onsetSec, offsetSec) over [sub], as analytics `stageMinuteRanges` gives them:
/// `{wake, light, deep, rem} -> {lo, hi}`. Null for an empty window.
///
/// The evidence is the cardio stager's own, from the same calls
/// `segmentSleep`'s forced-window path makes (`AdvancedSleepStager.
/// _stageSessionCardio`, which keeps its result private): the window is split
/// into runs of usable accel (a real sample or a carry-forward of at most
/// [ana.AdvancedSleepStager.maxAccelCarryForwardSec]), each run of at least
/// three epochs is staged on its own, and the runs' epochs are concatenated.
/// The arrays are built exactly as there, and [rowCache] holds the rows the
/// staging just computed, so these calls reproduce its labels.
///
/// Every 30 s of the window that no staged epoch covers (no samples, a gap, a
/// run too short to stage, or one the stager abstained on) is added as an
/// UNCOVERED, unlabelled epoch: it could be any stage, so it widens every range
/// and raises no `lo`. Nothing is labelled for it; the point minutes stay the
/// segmentation's, from recorded time only. With no samples at all every
/// stage is `{lo: 0, hi: window minutes}`.
@heavy
Map<String, Map<String, double>>? userWindowStageRangesHeavy(
  Substrate sub, {
  required int onsetSec,
  required int offsetSec,
  ana.CardioRowCache? rowCache,
}) {
  final span = offsetSec - onsetSec;
  if (span <= 0) return null;
  const epSec = 30;
  final evidence = <ana.StageEpochEvidence>[];
  final accel = sub.isEmpty ? const <ana.AccelSample>[] : sub.accelSamples();
  final hr1hz = sub.isEmpty ? const <double>[] : sub.hr1hz();
  final n = math.min(accel.length, hr1hz.length);
  bool inWindow(int ts) => ts >= onsetSec && ts < offsetSec;
  // Same maps as the stager: the last sample of a second wins.
  final gBy = <int, ana.AccelSample>{
    for (var i = 0; i < n; i++)
      if (accel[i].valid && inWindow(accel[i].tsMs ~/ 1000))
        accel[i].tsMs ~/ 1000: accel[i],
  };
  final hBy = <int, double>{
    for (var i = 0; i < n; i++)
      if (hr1hz[i] > 0 && inWindow(accel[i].tsMs ~/ 1000))
        accel[i].tsMs ~/ 1000: hr1hz[i],
  };
  final rMs = <double>[], rTs = <double>[];
  for (var i = 0; i < math.min(sub.rrMs.length, sub.rrTsMs.length); i++) {
    final ms = sub.rrMs[i];
    if (!ms.isFinite || ms <= 0) continue;
    final ts = (sub.rrTsMs[i] / 1000.0).round();
    if (!inWindow(ts)) continue;
    rMs.add(ms);
    rTs.add(ts * 1000.0);
  }
  if (span >= 3 * epSec && gBy.isNotEmpty) {
    final acc = List<ana.AccelSample>.filled(
        span, ana.AccelSample(onsetSec * 1000.0, 0, 0, 1.0));
    final hr = List<double>.filled(span, 0.0);
    final usable = List<bool>.filled(span, false);
    var last = -1;
    for (var i = 0; i < span; i++) {
      final ts = onsetSec + i;
      final g = gBy[ts];
      if (g != null) {
        acc[i] = ana.AccelSample(ts * 1000.0, g.x, g.y, g.z);
        last = i;
        usable[i] = true;
      } else if (last >= 0 &&
          i - last <= ana.AdvancedSleepStager.maxAccelCarryForwardSec) {
        final p = acc[i - 1];
        acc[i] = ana.AccelSample(ts * 1000.0, p.x, p.y, p.z);
        usable[i] = true;
      }
      hr[i] = hBy[ts] ?? 0.0;
    }
    // Evidence only: this second pass must not record another observation
    // for the rolling sleep profile.
    final recording = ana.cardioRecordObservations;
    ana.cardioRecordObservations = false;
    try {
      var i = 0;
      while (i < span) {
        if (!usable[i]) {
          i++;
          continue;
        }
        var j = i;
        while (j < span && usable[j]) {
          j++;
        }
        if (j - i >= 3 * epSec) {
          evidence.addAll(ana
              .cardioStager(hr.sublist(i, j), acc.sublist(i, j),
                  rrMs: rMs, rrTsMs: rTs, rowCache: rowCache)
              .epochEvidence);
        }
        i = j;
      }
    } finally {
      ana.cardioRecordObservations = recording;
    }
  }
  final uncovered = span ~/ epSec - evidence.length;
  for (var k = 0; k < uncovered; k++) {
    evidence.add(const ana.StageEpochEvidence(covered: false));
  }
  return ana.stageMinuteRanges(evidence, epochSec: epSec)?.toJson();
}
