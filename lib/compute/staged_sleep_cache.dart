// staged_sleep_cache.dart — a bounded RAM cache of staged sleep candidates.
//
// OWNER: exactly one `DerivationEngine` instance holds one of these, on the UI
// isolate. It never crosses an isolate (the worker is handed the staging input,
// not the cache) and is never persisted; a restart starts empty.
//
// WHY. After a restore the heavy pass stages each night (`stage_candidate`) and
// the baseline rescan that follows stages the SAME nights again, although a
// rescan moves only baseline-dependent scalars. A staging is a pure function of
// what `stageSleepCandidateHeavy` receives, so while that input is byte-for-byte
// the same its output is too.
//
// KEY = day + algo version + a 128-bit digest of the EXACT staging input
// ([stagingInputDigest]). A miss only costs a staging; a false hit would serve
// a stale night (AGENTS §3.3), so the digest covers everything the worker
// reads and leaves out only what provably cannot reach its output (see there).

import 'dart:collection';
import 'dart:convert';

import 'sleep_profile_policy.dart';
import 'sleep_staging_worker.dart';
import 'state_fingerprint.dart';
import '../util/worker_init.dart';

/// One staged night as the worker returned it.
class StagedSleepEntry {
  StagedSleepEntry({
    required this.algoVersion,
    required this.digestA,
    required this.digestB,
    required this.stagedWithFold,
    required this.candidateJson,
    required this.observationJson,
  });

  int algoVersion;
  final int digestA, digestB;

  /// Whether the staging ran with `mayFold`. Only then does the worker extract
  /// the profile observation, so an entry staged without it cannot serve a
  /// caller that has to fold; the candidate itself is independent of the flag.
  final bool stagedWithFold;
  final String candidateJson;
  final String? observationJson;
}

class StagedSleepCache {
  /// Day label -> entry, least recently used first. One entry per day: a
  /// re-staged day replaces its own entry, so no stale twin is kept.
  final LinkedHashMap<String, StagedSleepEntry> _byDay = LinkedHashMap();

  int get size => _byDay.length;

  void clear() => _byDay.clear();

  /// The entry for [day] if it was staged from exactly this input at
  /// [algoVersion] and can serve a caller with [mayFold]; refreshes its use.
  StagedSleepEntry? lookup(
    String day,
    int algoVersion,
    (int, int) digest, {
    required bool mayFold,
  }) {
    final e = _byDay[day];
    if (e == null ||
        e.algoVersion != algoVersion ||
        e.digestA != digest.$1 ||
        e.digestB != digest.$2 ||
        (mayFold && !e.stagedWithFold)) {
      return null;
    }
    _byDay.remove(day);
    _byDay[day] = e;
    return e;
  }

  /// Keeps [entry] as [day]'s, evicting the least recently used days beyond
  /// [maxDays].
  void store(String day, StagedSleepEntry entry, int maxDays) {
    _byDay.remove(day);
    if (maxDays <= 0) return;
    _byDay[day] = entry;
    while (_byDay.length > maxDays) {
      _byDay.remove(_byDay.keys.first);
    }
  }

  /// Test seam: as if every entry had been filled at [algoVersion].
  void rekey(int algoVersion) {
    for (final e in _byDay.values) {
      e.algoVersion = algoVersion;
    }
  }
}

/// 128-bit digest of everything [stageSleepCandidateHeavy] receives, plus the
/// ambient zone the worker's local-day arithmetic reads ([zoneKey]).
///
/// Left out, each because it cannot reach the candidate:
///  * `input.mayFold`: it only gates extracting the profile observation after
///    staging (see [StagedSleepEntry.stagedWithFold]).
///  * `inputs.nowEpochMs`, `input.nowSec`: the worker uses them only to age out
///    cardio-row chunks, never in the staging.
///  * `input.rowChunks`, `rowsLoSec`, `rowsHiSec`: the cardio-row cache is
///    exact (a row's key carries every input to it), so a hit is the row a fresh
///    computation produces; the window follows from day and override.
/// The rolling profile enters as what the stager blends in
/// ([_blendedProfile]), not as stored JSON: its bookkeeping (folded days) moves
/// on every fold without moving a staging, while any change to the blended
/// numbers moves the digest.
(int, int) stagingInputDigest(
  WorkerInputs inputs,
  SleepStagingInput input, {
  required String zoneKey,
}) {
  final fp = PrefixFingerprint();
  void ints(List<int> l) {
    fp.addInt(l.length);
    for (var i = 0; i < l.length; i++) {
      fp.addInt(l[i]);
    }
  }

  final digests = ListDigestCache();
  void doubles(List<double> l) {
    fp.addInt(l.length);
    final d = digests.digest(l);
    fp.addInt(d.$1);
    fp.addInt(d.$2);
  }

  void small(Object? v) {
    // [a, b, ...opaque]: nothing passed here is opaque (plain values only).
    final d = dependencyFingerprint(v);
    assert(d.length == 2);
    fp.addInt(d[0] as int);
    fp.addInt(d[1] as int);
  }

  final s = input.searchSub;
  ints(s.tsSec);
  ints(s.hr);
  doubles(s.rrTsMs);
  doubles(s.rrMs);
  doubles(s.ax);
  doubles(s.ay);
  doubles(s.az);
  ints(s.spo2Red);
  ints(s.spo2Ir);
  ints(s.skinTemp);
  ints(s.skinContact);
  ints(s.stepCount);
  ints(s.hrValid);
  ints(s.bandSleepState);
  final ov = input.override;
  small([
    zoneKey,
    inputs.zoneId,
    inputs.localeTag,
    inputs.sleepProfileJson,
    inputs.recordSleepObservations,
    s.deviceFamily,
    (s.deviceIds.toList()..sort()),
    input.dayId,
    ov == null ? null : [ov.dayId, ov.onsetSec, ov.offsetSec, ov.source],
    [
      for (final p in _effectivePriorSleep(input))
        [p.startSec, p.endSec, p.dayKey],
    ],
    input.confirmedWakeSec,
    _blendedProfile(input.profileJson),
    [
      for (final n in input.vendorNights)
        [
          n.deviceId,
          n.source,
          n.decodedAtSec,
          for (final e in n.epochs) [e.startSec, e.endSec, e.stage],
        ],
    ],
  ]);
  return fp.words;
}

/// Distinct days of history `habitualMidsleepSecFromHistory` needs before it
/// answers (its `minDays` default, which `calendarDays` uses). Pinned against
/// analytics in test/staged_sleep_cache_test.dart.
const int kHabitualMidsleepMinDays = 14;

/// The stored sleep history the stager can act on. `calendarDays` adds the
/// days it walks itself to [SleepStagingInput.priorSleep] and consults the sum
/// only once it holds [kHabitualMidsleepMinDays] distinct days. When the
/// stored days plus every day the window can walk stay short of that, the
/// history cannot reach the output and is empty for keying: otherwise each
/// night banked by the pass (which grows this list) would invalidate the
/// nights staged before it, and a rescan could never reuse any.
List<({int startSec, int endSec, String dayKey})> _effectivePriorSleep(
  SleepStagingInput input,
) {
  final prior = input.priorSleep;
  if (prior.isEmpty) return prior;
  final ts = input.searchSub.tsSec;
  // Local days the window touches, +1 for an override day outside the data and
  // +1 for the local-midnight rounding at each end.
  final walked = ts.isEmpty ? 1 : (ts.last - ts.first) ~/ 86400 + 3;
  final stored = {for (final p in prior) p.dayKey}.length;
  return stored + walked < kHabitualMidsleepMinDays ? const [] : prior;
}

/// What [stageSleepCandidateHeavy] blends in for a stored profile: nothing
/// until the warm-up gate opens (the same [SleepProfilePolicy.shouldBlend] the
/// worker applies), else every stored field but the fold bookkeeping, which
/// the stager's `SleepUserProfile.fromJson` never reads. Taken by key rather
/// than by parsing the profile here, so a field analytics adds later is keyed
/// too. An unreadable payload is a cold start, as in the worker.
Map<String, dynamic>? _blendedProfile(String? profileJson) {
  if (profileJson == null) return null;
  try {
    final m = (jsonDecode(profileJson) as Map).cast<String, dynamic>();
    final nights = (m['nights'] as num?)?.toInt() ?? 0;
    if (!SleepProfilePolicy.shouldBlend(nights)) return null;
    return {
      for (final e in m.entries)
        if (e.key != SleepProfilePolicy.foldedDaysKey &&
            e.key != SleepProfilePolicy.foldedObsKey)
          e.key: e.value,
    };
  } catch (_) {
    return null;
  }
}
