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

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart' show OwnedSpan;
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

/// What the search substrate was read from, as tracked provenance instead of
/// the samples themselves. Hashing every column and beat walked ~345k samples
/// on the UI isolate per night (AGENTS §3.10), a cost paid even on a hit.
///
/// The substrate is a pure function of three things and nothing else
/// (`_loadSubstrateRange` / derive_prepare.dart; the same rule retained loads
/// rest on, substrate_retention.dart):
///  * the `decoded_onehz` / `decoded_rr` rows of `[fromSec, toSec]`, whose
///    `input_rev` bucket counters (kRevBucketSec) are bumped by INSERT, UPDATE
///    and DELETE triggers, so an in-place replace, an eviction or a late row
///    moves them ([revs]);
///  * the resolved ownership spans (which device's row wins each second);
///  * the store itself ([wipeEpoch], [openCount]): a wiped, rebuilt or merged
///    store resets `input_rev`.
/// `substrate_archive` is NOT a source: the derive path never reads it (rows
/// pruned from the live tables are archived write-only), and the prune that
/// moves rows there deletes them, which bumps `input_rev`.
///
/// Read BEFORE the rows are, like a retained load's: a row landing mid-load
/// leaves the key stale (one extra staging), never falsely current.
class StagingProvenance {
  const StagingProvenance({
    required this.fromSec,
    required this.toSec,
    required this.revs,
    required this.ownership,
    required this.wipeEpoch,
    required this.openCount,
  });

  final int fromSec, toSec;

  /// `input_rev` by bucket over `[fromSec ~/ 900, toSec ~/ 900]` (buckets that
  /// were never written have no entry).
  final Map<int, int> revs;
  final Map<InputSignal, List<OwnedSpan>> ownership;
  final int wipeEpoch, openCount;
}

/// The UTC offset in force at an instant. The process zone by default; tests
/// subclass it to stand in for another zone.
class ZoneOffsets {
  const ZoneOffsets();

  int minutesAt(int epochSec) =>
      DateTime.fromMillisecondsSinceEpoch(epochSec * 1000)
          .timeZoneOffset
          .inMinutes;
}

/// UTC offset, in minutes, in force at every [stepSec] over `[loSec, hiSec]`,
/// as `[atSec, minutes]` pairs where it changed (the first sample always).
///
/// The stager's local-day arithmetic reads the offset AT the night's own
/// instants, not today's: two zones that agree today (Denver and Phoenix in
/// winter) still disagree on a summer night. A transition inside the window
/// (DST) shows as a second pair, so its position is keyed too. [zone]
/// defaults to the process zone; tests inject another.
List<List<int>> nightZoneOffsets(
  int loSec,
  int hiSec, {
  int stepSec = 900,
  ZoneOffsets zone = const ZoneOffsets(),
}) {
  final out = <List<int>>[];
  int? last;
  void sample(int t) {
    final m = zone.minutesAt(t);
    if (m == last) return;
    out.add([t, m]);
    last = m;
  }

  for (var t = loSec; t < hiSec; t += stepSec) {
    sample(t);
  }
  sample(hiSec);
  return out;
}

/// 128-bit digest of everything [stageSleepCandidateHeavy] receives, plus the
/// ambient zone the worker's local-day arithmetic reads ([zoneKey], and the
/// offsets at the night's own instants, [nightZoneOffsets]).
///
/// The substrate enters as its [provenance], not its samples (see
/// [StagingProvenance]); the small inputs (override, confirmed wake, vendor
/// nights, profile, history) are hashed as they are.
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
  required StagingProvenance provenance,
  ZoneOffsets zone = const ZoneOffsets(),
}) {
  final fp = PrefixFingerprint();
  void small(Object? v) {
    // [a, b, ...opaque]: nothing passed here is opaque (plain values only).
    final d = dependencyFingerprint(v);
    assert(d.length == 2);
    fp.addInt(d[0] as int);
    fp.addInt(d[1] as int);
  }

  // A day label or a window is not enough on its own: the stager's local
  // midnights reach a day past either end of the window.
  const zoneMarginSec = 86400;
  final p = provenance;
  final s = input.searchSub;
  final revKeys = p.revs.keys.toList()..sort();
  small([
    p.fromSec,
    p.toSec,
    p.wipeEpoch,
    p.openCount,
    [for (final b in revKeys) [b, p.revs[b]]],
    [
      for (final sig in InputSignal.values)
        [
          sig.name,
          for (final o in p.ownership[sig] ?? const <OwnedSpan>[])
            [o.start, o.end, o.deviceId],
        ],
    ],
    nightZoneOffsets(p.fromSec - zoneMarginSec, p.toSec + zoneMarginSec,
        zone: zone),
    // Cheap shape checks on what was loaded; the content is the provenance.
    s.tsSec.length,
    s.tsSec.isEmpty ? null : s.tsSec.first,
    s.tsSec.isEmpty ? null : s.tsSec.last,
    s.rrMs.length,
  ]);
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
