// What a WARM derive pass keeps of the decoded_onehz substrate it loaded, so the
// next pass reads only the rows that can have changed.
//
// OWNER: DerivationEngine (`_retained`), one [RetainedLoad] per (day, load
// label), replaced whole and never mutated. Nothing else holds or reads them.
//
// THE RULE. A load of `[from, to]` yields rows in time order. The newest second
// it holds lies in some 15-minute revision bucket (`kRevBucketSec`); its start
// is the CUT. Everything before the cut is reusable when nothing behind it can
// have changed, and "nothing changed" is read off three things only, all of
// which the loader itself depends on and nothing else:
//   * `input_rev` of every bucket before the cut (bumped by any insert, update
//     or delete on decoded_onehz / decoded_rr, so a replaced row, an eviction,
//     a counter re-key or a late row in an old bucket all move it);
//   * the resolved ownership spans over `[from, cut)` (the loader's only
//     device-dependent input; priority and coverage reach the rows through
//     them);
//   * the window itself, and the store generation (a wiped or rebuilt store
//     resets `input_rev`).
// Anything else is a full reload, which is the answer a cold load gives.
//
// EXACTNESS. The worker that decodes rows builds the new substrate by feeding
// the retained prefix, then the rows from the cut on, through the SAME
// accumulator a cold load uses (derive_prepare.dart); the engine isolate only
// hands typed lists over and adopts the result. What a cold load derives from
// the whole range and a prefix cannot recover from its own arrays is kept
// beside it: the beat axis before it was monotonised, where each second's beats
// start, and, per bucket, the families, device ids and first skin-temperature
// unit the bucket's rows contributed (the substrate-wide singleton rules read
// them).
import 'dart:typed_data';

import '../ble/adapters/signals.dart';
import '../data/coverage_resolver.dart';
import '../util/heavy.dart';
import 'day_checkpoint_policy.dart' show kRevBucketSec;
import 'substrate.dart';

/// What one revision bucket's rows contributed to the substrate-wide
/// singletons (see `_PrepareAccumulator`). Plain lists so it crosses isolates.
class BucketMeta {
  const BucketMeta(this.bucket, this.families, this.deviceIds, this.skinUnit);

  final int bucket;
  final List<String> families;
  final List<String> deviceIds;

  /// `'raw'` / `'c'`: the unit of the first row of the bucket that had a skin
  /// temperature, or null.
  final String? skinUnit;

  List<Object?> toWire() => [bucket, families, deviceIds, skinUnit];

  static BucketMeta fromWire(List<Object?> w) => BucketMeta(
        w[0] as int,
        (w[1] as List).cast<String>(),
        (w[2] as List).cast<String>(),
        w[3] as String?,
      );
}

/// The owned spans of [spans] inside `[lo, hi)`, normalised: gaps (null owner)
/// dropped, touching spans of one owner merged. Two lists that answer
/// `spanAt(...)?.deviceId` identically over `[lo, hi)` normalise equal.
List<OwnedSpan> clipOwnership(List<OwnedSpan> spans, int lo, int hi) {
  final out = <OwnedSpan>[];
  for (final s in spans) {
    final id = s.deviceId;
    if (id == null) continue;
    final a = s.start < lo ? lo : s.start;
    final b = s.end > hi ? hi : s.end;
    if (b <= a) continue;
    if (out.isNotEmpty && out.last.deviceId == id && out.last.end >= a) {
      out[out.length - 1] =
          (start: out.last.start, end: b > out.last.end ? b : out.last.end, deviceId: id);
    } else {
      out.add((start: a, end: b, deviceId: id));
    }
  }
  return out;
}

class RetainedLoad {
  RetainedLoad({
    required this.from,
    required this.to,
    required this.rrFrom,
    required this.revs,
    required this.ownership,
    required this.multiOwner,
    required this.generation,
    required this.cut,
    required this.sub,
    required this.rrStart,
    required this.rrTsRaw,
    required this.meta,
  });

  /// The window the load covered, and the second beats were read from (null:
  /// every beat). The substrate holds beats from [rrFrom] on, and a slot for
  /// each earlier second that has any.
  final int from, to;
  final int? rrFrom;

  /// `input_rev` of the buckets `[from ~/ 900, to ~/ 900]`, read BEFORE the rows.
  final Map<int, int> revs;

  /// The resolved spans per exclusive signal, and whether more than one device
  /// owns any of them (it changes which beat seconds the loader asks for).
  final Map<InputSignal, List<OwnedSpan>> ownership;
  final bool multiOwner;
  final ({int wipeEpoch, int openCount}) generation;

  /// The loaded substrate (typed arrays, monotonised beat axis) and what the
  /// loader's worker kept beside it.
  final Substrate sub;
  final Int32List rrStart;
  final Float64List rrTsRaw;
  final List<BucketMeta> meta;

  /// Start of the revision bucket of the newest `decoded_onehz` row the load
  /// read (before ownership dropped any): rows before it are what this keeps
  /// for the next pass, rows from it on are read again.
  final int cut;

  int get samples => sub.length;

  /// How a load of `[from, to]` under [ownership] can start from this one, or
  /// null when it cannot (read everything): rows are read from `cut` on (past
  /// [to] when nothing changed at all), and the beats of the seconds before it
  /// are `keepBeats` (taken from here) or else read again.
  ({int cut, bool keepBeats})? reuse({
    required int from,
    required int to,
    required int? rrFrom,
    required Map<int, int> revs,
    required Map<InputSignal, List<OwnedSpan>> ownership,
    required bool multiOwner,
    required ({int wipeEpoch, int openCount}) generation,
  }) {
    if (from != this.from || to != this.to) return null;
    if (generation != this.generation) return null;
    if (multiOwner != this.multiOwner) return null;
    bool moved(int b) => (revs[b] ?? 0) != (this.revs[b] ?? 0);
    final firstB = from ~/ kRevBucketSec, openB = cut ~/ kRevBucketSec;
    for (var b = firstB; b < openB; b++) {
      if (moved(b)) return null;
    }
    // From the open bucket on, rows are expected to have been added. If not
    // even those moved, nothing changed and nothing needs reading.
    var clean = true;
    for (var b = openB < firstB ? firstB : openB;
        b <= to ~/ kRevBucketSec;
        b++) {
      if (moved(b)) {
        clean = false;
        break;
      }
    }
    final readFrom = clean ? to + 1 : cut;
    for (final sig in kExclusiveOwnershipSignals) {
      final a = clipOwnership(this.ownership[sig] ?? const [], from, readFrom);
      final b = clipOwnership(ownership[sig] ?? const [], from, readFrom);
      if (a.length != b.length) return null;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return null;
      }
    }
    // Beats are held from [this.rrFrom] on; a load that wants earlier ones has
    // to read them again. A later start just drops the earlier ones.
    final held = this.rrFrom;
    final keep = held == null || (rrFrom != null && rrFrom >= held);
    return (cut: readFrom, keepBeats: keep);
  }

  /// The rows of `[a, b]` (inclusive) of this load, as a load of their own: the
  /// substrate, beat axis and per-bucket facts a cold load of `[a, b]` under
  /// [ownership] builds, or null when this one cannot stand in for it.
  ///
  /// THE CROSS-DAY UNION. A day needs three overlapping windows (night search,
  /// day, staged night) and each neighbouring day needs the same hours again.
  /// One load of their union is read once and every window is cut from it
  /// here, so no row is read twice. A cut must be what a load of that window
  /// would have returned, not an approximation of it, so it works on the same
  /// per-second bookkeeping the loader keeps ([rrStart], [rrTsRaw], [meta])
  /// rather than on `Substrate.slice`:
  ///   * beats belong to a window by the SECOND of their record (`rec_ts`),
  ///     the way the loader reads them, not by their reconstructed beat time
  ///     (`slice`), which can put a record's first beat before its second;
  ///   * the beat axis is monotonised from the window's first beat, so it is
  ///     rebuilt from the raw axis when the union's running maximum had lifted
  ///     that beat (an inversion across the window's start);
  ///   * family, device ids and skin-temperature unit are read off the buckets
  ///     the window touches. They are exact only when those buckets agree, so
  ///     a window over more than one family, device or unit is refused and the
  ///     caller loads it from the database as before.
  @heavy
  RetainedLoad? windowHeavy(
    int a,
    int b, {
    required Map<InputSignal, List<OwnedSpan>> ownership,
    required bool multiOwner,
  }) {
    if (rrFrom != null || multiOwner != this.multiOwner) return null;
    if (a < from || b > to || b < a) return null;
    if (!_sameOwnership(this.ownership, ownership, a, b + 1)) return null;
    final n = sub.tsSec.length;
    if (!_perSecondArraysFull(sub, n, rrStart.length)) return null;
    final lo = _lowerBound(sub.tsSec, a), hi = _lowerBound(sub.tsSec, b + 1);
    final r0 = lo < n ? rrStart[lo] : sub.rrMs.length;
    final r1 = hi < n ? rrStart[hi] : sub.rrMs.length;
    final singles = _Singletons.of(meta, a ~/ kRevBucketSec, b ~/ kRevBucketSec);
    // Rows of the other unit than the one this load's first temperature picked
    // were zeroed when it was read; a window that starts later would have
    // picked its own.
    if (!singles.exact || !singles.unitsWithin(_governingUnit(meta))) {
      return null;
    }
    final raw = Float64List.sublistView(rrTsRaw, r0, r1);
    final Float64List axis;
    if (r1 > r0 && sub.rrTsMs[r0] == rrTsRaw[r0]) {
      // The running maximum starts over at this beat anyway: what follows is
      // the union's own, beat for beat.
      axis = Float64List.fromList(sub.rrTsMs.sublist(r0, r1));
    } else {
      axis = Float64List.fromList(raw);
      monotonizeBeatAxis(axis);
    }
    final rs = Int32List(hi - lo);
    for (var k = lo; k < hi; k++) {
      rs[k - lo] = rrStart[k] - r0;
    }
    final cut = hi > lo
        ? (sub.tsSec[hi - 1] ~/ kRevBucketSec) * kRevBucketSec
        : (a ~/ kRevBucketSec) * kRevBucketSec;
    return RetainedLoad(
      from: a,
      to: b,
      rrFrom: null,
      revs: revs,
      ownership: {
        for (final sig in kExclusiveOwnershipSignals)
          sig: ownership[sig] ?? const <OwnedSpan>[],
      },
      multiOwner: multiOwner,
      generation: generation,
      cut: cut,
      sub: Substrate(
        tsSec: sub.tsSec.sublist(lo, hi),
        hr: sub.hr.sublist(lo, hi),
        rrTsMs: axis,
        rrMs: Float64List.fromList(sub.rrMs.sublist(r0, r1)),
        ax: sub.ax.sublist(lo, hi),
        ay: sub.ay.sublist(lo, hi),
        az: sub.az.sublist(lo, hi),
        spo2Red: sub.spo2Red.sublist(lo, hi),
        spo2Ir: sub.spo2Ir.sublist(lo, hi),
        skinTemp: sub.skinTemp.sublist(lo, hi),
        skinContact: sub.skinContact.sublist(lo, hi),
        stepCount: sub.stepCount.sublist(lo, hi),
        hrValid: sub.hrValid.sublist(lo, hi),
        bandSleepState: sub.bandSleepState.sublist(lo, hi),
        deviceFamily: singles.family,
        deviceIds: singles.deviceIds,
      ),
      rrStart: rs,
      rrTsRaw: Float64List.fromList(raw),
      meta: singles.inRange,
    );
  }

  /// One load out of [parts], which tile their range in time order with no
  /// gap, as a load of the whole range would have built it; null when they do
  /// not tile, or when they disagree about the skin-temperature unit (each was
  /// read under its own first unit, so joined they would not be what one load
  /// reads).
  ///
  /// [revs], [ownership], [multiOwner] and [generation] are the ones the parts
  /// were validated or read under, read before any of their rows.
  @heavy
  static RetainedLoad? joinHeavy(
    List<RetainedLoad> parts, {
    required Map<int, int> revs,
    required Map<InputSignal, List<OwnedSpan>> ownership,
    required bool multiOwner,
    required ({int wipeEpoch, int openCount}) generation,
  }) {
    if (parts.isEmpty) return null;
    var n = 0, nRr = 0;
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p.rrFrom != null) return null;
      if (i > 0 && p.from != parts[i - 1].to + 1) return null;
      final pn = p.sub.tsSec.length;
      if (!_perSecondArraysFull(p.sub, pn, p.rrStart.length)) return null;
      if (p.rrTsRaw.length != p.sub.rrMs.length) return null;
      n += pn;
      nRr += p.sub.rrMs.length;
    }
    final ts = Int64List(n), hr = Int64List(n);
    final red = Int64List(n), ir = Int64List(n);
    final skin = Int64List(n), contact = Int64List(n);
    final steps = Int64List(n), valid = Int64List(n), band = Int64List(n);
    final ax = Float64List(n), ay = Float64List(n), az = Float64List(n);
    final rs = Int32List(n);
    final raw = Float64List(nRr), rr = Float64List(nRr);
    var at = 0, rat = 0;
    for (final p in parts) {
      final s = p.sub, pn = s.tsSec.length;
      ts.setRange(at, at + pn, s.tsSec);
      hr.setRange(at, at + pn, s.hr);
      red.setRange(at, at + pn, s.spo2Red);
      ir.setRange(at, at + pn, s.spo2Ir);
      skin.setRange(at, at + pn, s.skinTemp);
      contact.setRange(at, at + pn, s.skinContact);
      steps.setRange(at, at + pn, s.stepCount);
      valid.setRange(at, at + pn, s.hrValid);
      band.setRange(at, at + pn, s.bandSleepState);
      ax.setRange(at, at + pn, s.ax);
      ay.setRange(at, at + pn, s.ay);
      az.setRange(at, at + pn, s.az);
      for (var k = 0; k < pn; k++) {
        rs[at + k] = p.rrStart[k] + rat;
      }
      raw.setRange(rat, rat + s.rrMs.length, p.rrTsRaw);
      rr.setRange(rat, rat + s.rrMs.length, s.rrMs);
      at += pn;
      rat += s.rrMs.length;
    }
    // The page seam the loader repairs once every page is in: a running
    // maximum over the whole range, which a part's own repair cannot see.
    final axis = Float64List.fromList(raw);
    monotonizeBeatAxis(axis);
    // The same bucket can be the last of one part and the first of the next.
    final byBucket = <int, _BucketUnion>{};
    for (final p in parts) {
      for (final m in p.meta) {
        byBucket.putIfAbsent(m.bucket, _BucketUnion.new).add(m);
      }
    }
    final buckets = byBucket.keys.toList()..sort();
    final metas = [for (final k in buckets) byBucket[k]!.toMeta(k)];
    final singles = _Singletons.of(metas, buckets.isEmpty ? 0 : buckets.first,
        buckets.isEmpty ? 0 : buckets.last);
    // Each part picked the unit of its own first temperature.
    final units = {
      for (final p in parts) _governingUnit(p.meta),
    }..remove(null);
    if (units.length > 1) return null;
    var cut = parts.first.cut;
    for (final p in parts) {
      if (p.cut > cut) cut = p.cut;
    }
    return RetainedLoad(
      from: parts.first.from,
      to: parts.last.to,
      rrFrom: null,
      revs: revs,
      ownership: {
        for (final sig in kExclusiveOwnershipSignals)
          sig: ownership[sig] ?? const <OwnedSpan>[],
      },
      multiOwner: multiOwner,
      generation: generation,
      cut: cut,
      sub: Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: axis,
        rrMs: rr,
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: red,
        spo2Ir: ir,
        skinTemp: skin,
        skinContact: contact,
        stepCount: steps,
        hrValid: valid,
        bandSleepState: band,
        deviceFamily: singles.family,
        deviceIds: singles.deviceIds,
      ),
      rrStart: rs,
      rrTsRaw: raw,
      meta: metas,
    );
  }

  /// The `seed` message for the loader's worker: the whole retained load; the
  /// worker cuts it at [cutRecTs] and drops the beats before [rrFromRecTs]
  /// ([keepBeats]), or drops them all because the engine sends them again as
  /// `rr_prefix` messages. Typed lists, so sending is a copy of buffers.
  Map<String, Object?> seedMessage(
          int cutRecTs, int? rrFromRecTs, bool keepBeats) =>
      {
        'type': 'seed',
        'cut': cutRecTs,
        'rr_from': rrFromRecTs,
        'keep_beats': keepBeats,
        'ts_sec': sub.tsSec,
        'hr': sub.hr,
        'ax': sub.ax,
        'ay': sub.ay,
        'az': sub.az,
        'spo2_red': sub.spo2Red,
        'spo2_ir': sub.spo2Ir,
        'skin_temp': sub.skinTemp,
        'skin_contact': sub.skinContact,
        'step_count': sub.stepCount,
        'hr_valid': sub.hrValid,
        'band_sleep_state': sub.bandSleepState,
        'rr_ts_raw': rrTsRaw,
        'rr_ms': sub.rrMs,
        'rr_start': rrStart,
        'meta': [for (final m in meta) m.toWire()],
      };
}

/// The unit the first temperature of [meta]'s rows picked (buckets in order),
/// or null when none had one.
String? _governingUnit(List<BucketMeta> meta) {
  BucketMeta? first;
  for (final m in meta) {
    if (m.skinUnit == null) continue;
    if (first == null || m.bucket < first.bucket) first = m;
  }
  return first?.skinUnit;
}

int _lowerBound(List<int> a, int v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m] < v) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// Every per-second array of [s] is as long as [tsSec] and [rrStartLength] is
/// too; anything else is a load this file does not know how to cut.
bool _perSecondArraysFull(Substrate s, int n, int rrStartLength) =>
    rrStartLength == n &&
    s.hr.length == n &&
    s.ax.length == n &&
    s.ay.length == n &&
    s.az.length == n &&
    s.spo2Red.length == n &&
    s.spo2Ir.length == n &&
    s.skinTemp.length == n &&
    s.skinContact.length == n &&
    s.stepCount.length == n &&
    s.hrValid.length == n &&
    s.bandSleepState.length == n;

/// Whether the owned spans of [a] and [b] over `[lo, hi)` answer
/// `spanAt(...)?.deviceId` the same for every exclusive signal.
bool _sameOwnership(Map<InputSignal, List<OwnedSpan>> a,
    Map<InputSignal, List<OwnedSpan>> b, int lo, int hi) {
  for (final sig in kExclusiveOwnershipSignals) {
    final x = clipOwnership(a[sig] ?? const [], lo, hi);
    final y = clipOwnership(b[sig] ?? const [], lo, hi);
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
  }
  return true;
}

/// What the buckets `[lo, hi]` of a load say about the substrate-wide
/// singletons.
class _Singletons {
  _Singletons._(this.inRange, this.families, this.deviceIds, this.units);

  factory _Singletons.of(List<BucketMeta> meta, int lo, int hi) {
    final inRange = <BucketMeta>[];
    final families = <String>{}, ids = <String>{}, units = <String>{};
    for (final m in meta) {
      if (m.bucket < lo || m.bucket > hi) continue;
      inRange.add(m);
      families.addAll(m.families);
      ids.addAll(m.deviceIds);
      if (m.skinUnit != null) units.add(m.skinUnit!);
    }
    return _Singletons._(inRange, families, ids, units);
  }

  final List<BucketMeta> inRange;
  final Set<String> families, deviceIds, units;

  /// One family, one device and one unit at most: any sub-range of these
  /// buckets reads the same.
  bool get exact =>
      families.length <= 1 && deviceIds.length <= 1 && units.length <= 1;

  /// `deviceFamily` of a substrate over these buckets (null: none, or several).
  String? get family => families.length == 1 ? families.first : null;

  bool unitsWithin(String? governing) =>
      units.isEmpty || (governing != null && units.length == 1 && units.first == governing);
}

/// The facts of one bucket, from every part that holds rows of it.
class _BucketUnion {
  final families = <String>{}, ids = <String>{};
  String? unit;

  void add(BucketMeta m) {
    families.addAll(m.families);
    ids.addAll(m.deviceIds);
    unit ??= m.skinUnit;
  }

  BucketMeta toMeta(int bucket) =>
      BucketMeta(bucket, families.toList(), ids.toList(), unit);
}

/// The stretches of `[from, to]` that [bases] still hold exactly as a load
/// under [ownership] would read them now, in time order, none overlapping.
///
/// A stretch of a base is usable while every revision bucket under it is the
/// one the base was read at ([revs] is now), the ownership over it is the
/// same, and the store was not wiped. Where two bases hold the same seconds,
/// the one that reaches further forward is taken, so the fewest cuts (and gaps
/// between them) remain.
List<({int a, int b, RetainedLoad base})> usableStretches(
  Iterable<RetainedLoad> bases, {
  required int from,
  required int to,
  required Map<int, int> revs,
  required Map<InputSignal, List<OwnedSpan>> ownership,
  required bool multiOwner,
  required ({int wipeEpoch, int openCount}) generation,
}) {
  final cands = <({int a, int b, RetainedLoad base})>[];
  for (final base in bases) {
    if (base.rrFrom != null ||
        base.generation != generation ||
        base.multiOwner != multiOwner) {
      continue;
    }
    final oa = base.from > from ? base.from : from;
    final ob = base.to < to ? base.to : to;
    if (ob < oa) continue;
    int? runStart;
    void close(int lastBucket) {
      if (runStart == null) return;
      final ra = runStart! > oa ? runStart! : oa;
      final rb = (lastBucket + 1) * kRevBucketSec - 1 < ob
          ? (lastBucket + 1) * kRevBucketSec - 1
          : ob;
      runStart = null;
      if (rb < ra) return;
      if (!_sameOwnership(base.ownership, ownership, ra, rb + 1)) return;
      cands.add((a: ra, b: rb, base: base));
    }

    final b0 = oa ~/ kRevBucketSec, b1 = ob ~/ kRevBucketSec;
    for (var b = b0; b <= b1; b++) {
      final same = (revs[b] ?? 0) == (base.revs[b] ?? 0);
      if (same) {
        runStart ??= b * kRevBucketSec;
      } else {
        close(b - 1);
      }
    }
    close(b1);
  }
  final out = <({int a, int b, RetainedLoad base})>[];
  var pos = from;
  while (pos <= to) {
    ({int a, int b, RetainedLoad base})? best;
    for (final c in cands) {
      if (c.a <= pos && c.b >= pos && (best == null || c.b > best.b)) best = c;
    }
    if (best == null) {
      int? next;
      for (final c in cands) {
        if (c.a > pos && (next == null || c.a < next)) next = c.a;
      }
      if (next == null) break;
      pos = next;
      continue;
    }
    out.add((a: pos, b: best.b, base: best.base));
    pos = best.b + 1;
  }
  return out;
}
