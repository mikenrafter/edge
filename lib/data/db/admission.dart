part of '../db.dart';

// ── SUBSTRATE ADMISSION — the one predicate that decides what may become a
//    number ───────────────────────────────────────────────────────────────────
//
// THE THREE PROVENANCE COLUMNS ON `decoded_onehz` / `decoded_rr`, AND THE RULE
// THAT THEY DO NOT OVERLAP:
//
//   device_id      WHICH UNIT.       '' is the primary band, permanently
//                                    (see [_createDecodedStore]); a real id
//                                    belongs to a secondary.
//   device_family  THE CALIBRATION KEY. Which sensor's constants a metric must
//                                    look itself up under. NULL = unknown, and
//                                    unknown is its own case, never gen4.
//   source         THE ADMISSION FLAG. NULL = the primary band. Non-NULL names
//                                    the adapter that wrote the row.
//
// None of the three is a stand-in for another. `source` in particular is NOT a
// provenance id you may read to find out what a row came from — `device_id` and
// `device_family` are — it exists so this file can answer ONE question in SQL:
// may this row become a number?
//
// Why an adapter's rows are stored but not derived by default: correctness of a
// community decoder cannot be enforced by review, and a decoder with a 2x scale
// error reads a resting 50 bpm as 100 and passes every generic physiological
// bound. So an unverified adapter's seconds bank, sync, back up and show up in
// diagnostics — and produce no metric at all until the owner has held that
// hardware in his own hands (ASSUMPTIONS R6/E5/E6). Silent, on purpose: the
// alternative is a plausible wrong number, which is the one failure this
// project treats as worse than an absent one.
//
// NOTE THE DIFFERENCE FROM MULTIBAND_PLAN §3.3, which said a verified adapter
// would write `source IS NULL` and so need no read-side change. It is written
// the other way round here — every non-band writer stamps its id, always, and
// ADMISSION IS A READ-SIDE DECISION — for two reasons that only show up later:
// verification is then REVOCABLE (a decoder bug found in v3 of an adapter is
// one edit to [kDerivableSources], not a data migration over rows that can no
// longer be told apart), and `source` keeps meaning something after a strap is
// verified, which is what lets [kPrimaryBandSourceSql] below still exist.

/// Non-NULL `source` values admitted to derivation: adapters the OWNER has
/// personally held and cross-confirmed (ASSUMPTIONS R6).
///
/// EMPTY TODAY, AND CORRECTLY SO. The only owner-confirmed band is the WHOOP 4,
/// which is the primary band and therefore writes `source IS NULL` — so the set
/// of *non-NULL* sources that may be derived from is genuinely empty, and
/// [derivableSourceSql] renders byte-identical SQL to the bare predicate it
/// replaced. It becomes non-empty the first time a strap earns it.
///
/// NOT the same set as `kOwnerConfirmedBandIds` in `ui2/profile/devices.dart`,
/// and deliberately not shared with it: that one holds BAND FAMILY ids
/// (`device_family`) and decides whether a badge says EXPERIMENTAL; this one
/// holds SOURCE values and decides whether a row may become a number. They
/// answer different questions off different columns and will diverge the moment
/// a family is decoded but its adapter is not yet trusted. Both are `ponytail:`
/// placeholders for the CODEOWNERS-gated `_verified.dart` (ASSUMPTIONS E5) —
/// when that lands it owns the owner-confirmation fact and BOTH of these read
/// from it. It must never become a CI rule, which hands the key to the PR
/// author.
const Set<String> kDerivableSources = <String>{};

/// SQL fragment for every read whose rows may become a NUMBER — a metric, a
/// baseline, a session aggregate, a day that gets derived.
///
/// [col] is the column expression, so a joined query passes `'d.source'`.
///
/// Interpolates [kDerivableSources] directly rather than binding parameters:
/// these are compile-time `const` identifiers from this repo's own source, and
/// the callers are `rawQuery` strings assembled at every call site. The
/// admission test pins the ids to `[a-z0-9_]` so this cannot become an
/// injection seam by accident.
String derivableSourceSql([String col = 'source']) => kDerivableSources.isEmpty
    ? '$col IS NULL'
    : '($col IS NULL OR $col IN '
          "(${kDerivableSources.map((s) => "'$s'").join(', ')}))";

/// The rows a read INSIDE one session window keeps, out of [rows]: every row
/// of the window (`source`, `rec_ts`, `hr`), in any order. With no flagged-on
/// workout sensor ([LocalDb.sessionSensorSources]) in the window, exactly the
/// [derivableSourceSql] rows. With one, the session override as the derive
/// lays it over a wearable's day (`withStrapSessions`): the sensor that
/// recorded most of the window (one, never two blended) from its first worn
/// row to its last, and outside that span the active wearable's rows
/// ([LocalDb.sessionWearableSource]), so a strap put on late leaves the
/// minutes before it to the wrist, on the workout card as in the day.
///
/// Never over the primary band: a window the band has rows in stays the
/// band's, as the day's strain, zones and recovery are, so a band's workout
/// and its day agree. The check is per window, not per day: on a band day, a
/// window the band has NO rows in (taken off to charge mid-workout) is the
/// strap's, while the day's strain and zones still read the band substrate,
/// which leaves that gap empty.
///
/// ponytail: on that gap the workout screen and the day disagree; give the
/// band day the strap's window too (or drop the override there) once the
/// owner decides whether a strap may fill a band gap.
List<T> sessionWindowRows<T extends Map<String, Object?>>(List<T> rows) {
  bool derivable(Object? s) => s == null || kDerivableSources.contains(s);
  List<T> plain() => [
        for (final r in rows)
          if (derivable(r['source'])) r,
      ];
  bool worn(T r) => ((r['hr'] as num?) ?? 0) > 0;
  final n = <Object?, int>{};
  for (final r in rows) {
    final s = r['source'];
    if (s == null) return plain();
    if (LocalDb.sessionSensorSources.contains(s) && worn(r)) {
      n[s] = (n[s] ?? 0) + 1;
    }
  }
  if (n.isEmpty) return plain();
  final owner = n.entries
      .reduce((a, b) => b.value > a.value ||
              (b.value == a.value && '${b.key}'.compareTo('${a.key}') < 0)
          ? b
          : a)
      .key;
  int? lo, hi;
  for (final r in rows) {
    if (r['source'] != owner || !worn(r)) continue;
    final t = (r['rec_ts'] as num).toInt();
    if (lo == null || t < lo) lo = t;
    if (hi == null || t > hi) hi = t;
  }
  final wearable = LocalDb.sessionWearableSource;
  return [
    for (final r in rows)
      if (r['source'] == owner ||
          ((derivable(r['source']) ||
                  (wearable != null && r['source'] == wearable)) &&
              ((r['rec_ts'] as num) < lo! || (r['rec_ts'] as num) > hi!)))
        r,
  ];
}

/// SQL fragment for the reads that mean THE PRIMARY BAND SPECIFICALLY, not
/// "admitted to derive" — they look identical today and they are not the same
/// question, which is the whole reason both have names.
///
/// Three sites, one meaning each: where the band's own data starts and ends,
/// how far the band has synced, and what we are willing to write into the
/// operating system's health store under our name. A verified chest strap must
/// widen [derivableSourceSql] and must NOT widen this one.
const String kPrimaryBandSourceSql = 'source IS NULL';
