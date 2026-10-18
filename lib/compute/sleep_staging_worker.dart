// sleep_staging_worker.dart — one night's sleep staging as a registered worker
// entry (design 02). It was an inline closure in
// `DerivationEngine._sleepCandidateForDay` (baselined as
// dispatcherClosureContract); moving it here is also what lets the cardio
// feature rows stay ENCODED on the UI isolate: the engine hands the worker the
// chunks that overlap the staging window, and everything that reads or writes
// them (decode, merge, cut to the window, prune, encode) happens in here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';
import 'cardio_rows_blob.dart';
import 'day_resume_state.dart' show restrictCardioRows;
import 'derive_prepare.dart';
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
  });

  final String dayId;
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
    targetDay: input.dayId,
    override: input.override,
    priorSleep: input.priorSleep,
    confirmedWakeSec: input.confirmedWakeSec,
    rowCache: rowCache,
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
    final obs = ana.takeCardioObservations();
    if (obs.isNotEmpty) {
      obs.sort((a, b) => b.epochs.compareTo(a.epochs));
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
    candidateJson: jsonEncode(candidate.toJson()),
    observationJson: observationJson,
    rowsJson: all.length == 0 ? null : encodeCardioRowsHeavy(all),
    rowsLoSec: all.length == 0 ? 0 : lo,
    rowsHiSec: all.length == 0 ? 0 : hi,
    rowHits: rowCache.hits,
    rowMisses: rowCache.misses,
  );
}
