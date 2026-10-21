part of '../derivation_engine.dart';

// SETTLED DAYS: a day whose derive DECLINED to write is done, not pending.
//
// State: `compute_freshness` key `settled:<day>` = `{v: kAlgoVersion, own,
// prev, edit}`. Owner: the derive engine (this file writes it; `LocalDb` only
// stores it). Readers: `_deriveScope`, `run()`, `rescanRecent`,
// `_quietRepassOwed` and `_quietLevelUnreachable`, through
// [_EngineSettled._finalizedOrSettled]. NOT the raw prune: it holds a settled
// day's raw like any not-finalized day (AGENTS 3.9).
//
// Why it exists: a declined day (edge#305: its sleep-window substrate was
// pruned, or the day has no substrate left) keeps the existing older-version
// row, so it never gets a finalized row at this version and every heavy pass
// selected it again. Settling it records "this raw, at this algo version,
// yields no better answer". New raw changes the fingerprint and reopens it; a
// kAlgoVersion bump invalidates it; a user-triggered re-derive ignores it; a
// written row (LocalDb.putDayResult) clears it; a CHANGED sleep or nap edit
// reopens it (an old, unchanged one does not).
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
  /// The revision of the wearer's sleep window and nap edits for each of
  /// [days] (design 06 1c: both are day-scoped catalogued inputs, bumped by
  /// trigger on any insert, update or delete). Taken with the raw fingerprints,
  /// BEFORE the day is prepared. A day with an old, unchanged edit keeps the
  /// same signature, so only a CHANGED edit reopens a settled day.
  Future<Map<String, String>> _editSigs(Iterable<String> days) async {
    if (days.isEmpty) return const {};
    final sorted = days.toList()..sort();
    final snap = await inputRevSnapshot(
      const ['sleep_override', 'sleep_nap'],
      fromDay: sorted.first,
      toDay: sorted.last,
    );
    int rev(String source, String day) => snap[source]?[day] ?? 0;
    return {
      for (final d in sorted)
        d: '${rev('sleep_override', d)}/${rev('sleep_nap', d)}',
    };
  }

  /// Record [day] as settled at this version. [fps] and [edits] are the raw
  /// fingerprints and edit signatures taken BEFORE the day was prepared, so
  /// rows or edits landing mid-derive leave the record stale (the day
  /// reopens), never falsely current. Required, with no read of the current
  /// state as a fallback: that would settle a day on inputs it never read. A
  /// day with no raw to fingerprint is not settled: unknown is never
  /// "unchanged".
  Future<void> _settleDay(
    String day,
    Map<String, String> fps,
    Map<String, String> edits,
  ) async {
    try {
      final own = fps[day];
      if (own == null) return;
      await LocalDb.putSettledDay(day, kAlgoVersion,
          own: own,
          prev: fps[DerivationEngine._adjacentDayIds(day).first],
          edit: edits[day] ?? '');
    } catch (e) {
      _log('derive $day: could not record settled: $e');
    }
  }

  /// Days settled at this version whose inputs still read as they did. The day
  /// before is part of a night's input, so new rows there reopen the day. Its
  /// rows being GONE do not: the raw prune removes them once settled days
  /// count as done, and that must not undo the settling it follows. A decline
  /// also depends on what the wearer said about the night, so a changed sleep
  /// window or nap edit reopens it; an unchanged one does not.
  Future<Set<String>> _settledDays() async {
    final settled = await LocalDb.settledFingerprints(kAlgoVersion);
    if (settled.isEmpty) return const {};
    final edits = await _editSigs(settled.keys);
    final fps = await LocalDb.decodedDayFingerprints({
      for (final d in settled.keys) ...[
        d,
        DerivationEngine._adjacentDayIds(d).first,
      ],
    });
    return {
      for (final e in settled.entries)
        if (edits[e.key] == e.value.edit &&
            fps[e.key] == e.value.own &&
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
