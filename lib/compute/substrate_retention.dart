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
