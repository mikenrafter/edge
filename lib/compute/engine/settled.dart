part of '../derivation_engine.dart';

// SETTLED DAYS: a day whose derive DECLINED to write is done, not pending.
//
// State: `compute_freshness` key `settled:<day>` = `{v: kAlgoVersion, own,
// prev}`. Owner: the derive engine (this file writes it; `LocalDb` only
// stores it). Readers: `_deriveScope`, `run()`, `rescanRecent`, the raw
// prune, `_quietRepassOwed` and `_quietLevelUnreachable`, all through
// [_EngineSettled._finalizedOrSettled].
//
// Why it exists: a declined day (edge#305: its sleep-window substrate was
// pruned, or the day has no substrate left) keeps the existing older-version
// row, so it never gets a finalized row at this version and every heavy pass
// selected it again. Settling it records "this raw, at this algo version,
// yields no better answer". New raw changes the fingerprint and reopens it; a
// kAlgoVersion bump invalidates it; a user-triggered re-derive ignores it.
//
// The fingerprint carries no profile on purpose: a decline depends on the
// stored night and the prune cursor, never on profile fields. It is kept as
// two parts (the day, and the day before it) so a pruned previous day can be
// told apart from new rows landing there.

/// How one day's derive ended.
enum DayDerive {
  /// A result was written (or, for the audit's reference pass, computed).
  committed,

  /// Deliberately wrote nothing and kept the existing result. Not a derive:
  /// must not count as done, and settles the day.
  declined,

  /// A frozen (finalized) row refused the write; nothing was stored.
  refused,
}

extension _EngineSettled on DerivationEngine {
  /// Record [day] as settled at this version. [fps] are raw fingerprints taken
  /// before the derive read anything (so rows landing mid-derive leave it
  /// stale, never falsely current); read now when not given. A day with no raw
  /// to fingerprint is not settled: unknown is never "unchanged".
  Future<void> _settleDay(String day, [Map<String, String>? fps]) async {
    try {
      final prevDay = DerivationEngine._adjacentDayIds(day).first;
      final known = fps ?? await LocalDb.decodedDayFingerprints({day, prevDay});
      final own = known[day];
      if (own == null) return;
      await LocalDb.putSettledDay(day, kAlgoVersion,
          own: own, prev: known[prevDay]);
    } catch (e) {
      _log('derive $day: could not record settled: $e');
    }
  }

  /// Days settled at this version whose raw still reads as it did. The day
  /// before is part of a night's input, so new rows there reopen the day. Its
  /// rows being GONE do not: the raw prune removes them once settled days
  /// count as done, and that must not undo the settling it follows.
  Future<Set<String>> _settledDays() async {
    final settled = await LocalDb.settledFingerprints(kAlgoVersion);
    if (settled.isEmpty) return const {};
    final fps = await LocalDb.decodedDayFingerprints({
      for (final d in settled.keys) ...[
        d,
        DerivationEngine._adjacentDayIds(d).first,
      ],
    });
    return {
      for (final e in settled.entries)
        if (fps[e.key] == e.value.own &&
            (fps[DerivationEngine._adjacentDayIds(e.key).first] == null ||
                fps[DerivationEngine._adjacentDayIds(e.key).first] ==
                    e.value.prev))
          e.key,
    };
  }

  /// Finalized at this version, or settled: what selection treats as done.
  Future<Set<String>> _finalizedOrSettled() async => {
        ...await LocalDb.finalizedDayIds(kAlgoVersion),
        ...await _settledDays(),
      };
}
