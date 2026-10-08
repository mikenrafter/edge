// Notes -> device commands. Given a pattern written as notes and rests
// on the 16th grid, pick the band commands (phrases) and the write delays
// between them (gaps) from a measured device profile so that what is felt
// lands as close to the pattern as the vocabulary allows. Pure Dart, no
// Flutter, no BLE, deterministic.
//
// The search is a dynamic program over 16th positions. A placement costs 4 for
// every cell where the felt side and the target disagree about note versus
// rest, plus dynamicWeight times the loudness distance on cells where both
// are notes (a target cell written as "any loudness" costs nothing there).
// With HapticPriority.dynamics the two weights swap sides: a cell that
// disagrees costs 1 and a loudness step costs 4, so a plan one sixteenth off
// in timing beats one at the wrong loudness. Every command beyond the first
// adds a small penalty, so one command is preferred when it is nearly as good.
// Plans are ordered by cost,
// then fewer commands, then fewer unstable parts, then less total write
// delay; ties inside that are settled by the fixed order of the profile's
// rows.
//
// A rest the pattern's author wrote is kept. The search above scores
// cells in place, so it can win by merging two pulses over a short rest or by
// dropping the rest. A plan is accepted only if, in both its shortest and its
// longest rendition, it has as many rests between pulses as were written and
// none of them shorter. When no plan of the search above does, a second search
// (_compileKeepingRests) plans pulse by pulse and lengthens a rest to the
// band's nearest measured wait instead; loudness is given up before a rest.

import '../gestures/pattern_transcript.dart';
import 'haptic_priority.dart';
import 'haptic_profile.dart';

export 'haptic_priority.dart' show HapticPriority;

/// One cell per sixteenth: a note cell carries its dynamic, a rest cell is
/// null. Adjacent notes are not distinguished from one long note.
List<PatternDynamic?> timeline(List<PatternEntry> entries) => [
      for (final e in entries)
        for (var i = 0; i < e.length; i++) e.note ? e.dynamic : null,
    ];

/// [units] sixteenths of rest split greedily into allowed lengths, largest
/// first (5 -> R4 R1). Zero or less gives nothing.
List<PatternEntry> restEntries(int units) {
  final out = <PatternEntry>[];
  var left = units;
  for (final l in kPatternLengths.reversed) {
    while (left >= l) {
      out.add(PatternEntry(note: false, length: l));
      left -= l;
    }
  }
  return out;
}

/// The longest a compiled sequence may run by default, felt at its longest.
const Duration kMaxHapticRuntime = Duration(seconds: 10);

/// The runtime cap to compile and deliver with: [kMaxHapticRuntime], or null
/// (no cap) when the user allowed long sequences. The 8-command plan cap and
/// the band's rolling command limit apply either way.
Duration? maxRuntimeFor({required bool allowLong}) =>
    allowLong ? null : kMaxHapticRuntime;

/// One band command in a plan.
class HapticStep {
  const HapticStep({
    required this.phrase,
    required this.delayMs,
    this.restMinUnits = 0,
    this.restMaxUnits = 0,
    this.gapStable = true,
    this.startUnit = 0,
  });

  final HapticPhrase phrase;

  /// Wait after the previous step's "ended" event before writing this one; 0
  /// for the first step.
  final int delayMs;

  /// The silence felt before this step (the shortest and the longest), in
  /// sixteenths; 0 for the first step.
  final int restMinUnits;
  final int restMaxUnits;

  /// False when the gap row behind [delayMs] is an unstable one.
  final bool gapStable;

  /// The sixteenth of the target (counting from its first entry, leading
  /// rests included) where this step's phrase starts: what the editor follows
  /// the playback by.
  final int startUnit;
}

/// What to write and how it should feel.
class HapticPlan {
  const HapticPlan({
    required this.steps,
    required this.feltMin,
    required this.feltMax,
    required this.cost,
    required this.exact,
    required this.asWritten,
    required this.usesUnstable,
    required this.summary,
    this.runtimeMs = 0,
    this.pulseOwners = const [],
  });

  final List<HapticStep> steps;

  /// The pattern as felt when everything runs at its shortest and its longest.
  final List<PatternEntry> feltMin;
  final List<PatternEntry> feltMax;
  final int cost;

  /// True when no cell is felt differently from the target (the command
  /// penalty is not counted): the target is felt as written.
  final bool exact;

  /// True when the whole felt range, shortest ([feltMin]) and longest
  /// ([feltMax]), is the requested timing and no wait varies. [exact] only
  /// says one scored rendition matches, so a plan can be exact and still be
  /// felt differently (effect 14 for a three-unit note is felt 3 to 4 units).
  /// Only a plan that is [asWritten] may be said to play as written.
  final bool asWritten;

  /// How long the plan is felt at its longest: [feltMax] on the 16th grid
  /// times the profile's unit.
  final int runtimeMs;
  final bool usesUnstable;

  /// "2 commands: effect 47, then 300 ms after it ends, effect 14".
  final String summary;

  /// Which command plays each pulse (a run of adjacent notes) of the target,
  /// in order: an index into [steps], or null for a pulse no command plays.
  /// Decided here, where the plan is built, so nothing downstream has to
  /// work it out again from start positions or rounded times.
  final List<int?> pulseOwners;
}

/// The runs of notes of [cells] as `[from, to)` cell ranges.
List<(int, int)> pulseRuns(List<PatternDynamic?> cells) {
  final out = <(int, int)>[];
  int? from;
  for (var i = 0; i <= cells.length; i++) {
    final note = i < cells.length && cells[i] != null;
    if (note && from == null) from = i;
    if (!note && from != null) {
      out.add((from, i));
      from = null;
    }
  }
  return out;
}

/// [pulses] handed out in order to commands that play [perCommand] each; any
/// pulses left over go to the last command, and pulses a command has no room
/// for are not played by it (the commands after it get fewer). Where a plan
/// has no positions (a stored one), this is how its commands share the score.
List<int?> allocatePulses(List<int> perCommand, int pulses) {
  final owner = <int>[];
  for (var i = 0; i < perCommand.length; i++) {
    for (var n = 0; n < perCommand[i]; n++) {
      owner.add(i);
    }
  }
  return [
    for (var k = 0; k < pulses; k++)
      perCommand.isEmpty ? null : (k < owner.length ? owner[k] : perCommand.length - 1),
  ];
}

/// Who plays each pulse of the target [cells] (leading rests trimmed; [first]
/// is how many were). When the commands' own pulses add up to the target's,
/// they are handed out in order: that is exact. When they do not (the cap bit,
/// or a pulse was merged or dropped) each pulse goes to the command whose felt
/// notes overlap it most (the earlier on a tie), the nearest one if none does,
/// and null when no command feels any note. Public so a hand-built plan can
/// force the second branch in tests; the compiler calls it for every plan.
List<int?> pulseOwnersOf(
    List<HapticStep> steps, List<PatternDynamic?> cells, int first) {
  final pulses = pulseRuns(cells);
  final counts = [
    for (final s in steps) pulseRuns(timeline(s.phrase.min)).length,
  ];
  if (counts.fold<int>(0, (a, b) => a + b) == pulses.length) {
    return allocatePulses(counts, pulses.length);
  }
  final felt = <Set<int>>[
    for (final s in steps)
      {
        for (final r in [s.phrase.min, s.phrase.max])
          for (var i = 0; i < timeline(r).length; i++)
            if (timeline(r)[i] != null) s.startUnit - first + i,
      },
  ];
  return [
    for (final (a, b) in pulses)
      () {
        int? best;
        var bestOverlap = 0;
        for (var i = 0; i < steps.length; i++) {
          var o = 0;
          for (var c = a; c < b; c++) {
            if (felt[i].contains(c)) o++;
          }
          if (o > bestOverlap) {
            bestOverlap = o;
            best = i;
          }
        }
        if (best != null) return best;
        // None overlaps: the command with the nearest felt note.
        var bestDist = 1 << 30;
        for (var i = 0; i < steps.length; i++) {
          for (final c in felt[i]) {
            final d = c < a ? a - c : c - b + 1;
            if (d < bestDist) {
              bestDist = d;
              best = i;
            }
          }
        }
        return best;
      }(),
  ];
}

/// Cost of one cell that disagrees about note versus rest, and of one loudness
/// step, for [HapticPriority.rhythm]. [HapticPriority.dynamics] uses 1 and 4:
/// a loudness step then outweighs a one-cell shift (two disagreeing cells).
const int _kMismatch = 4;
const int _kDynamicsMismatch = 1;
const int _kDynamicsLoudness = 4;

/// Cost of each unstable phrase or gap row in a plan. The whole vocabulary is
/// always on the table, but stable parts stay preferred: an unstable one wins
/// only where it fits better than one cell's worth (a mismatch costs 4).
const int _kUnstableCost = 1;

// A cost that orders plans by cost, then unstable parts, then total delay.
// (The command count is the outer loop of the search; the final pick orders
// by cost, then command count, then the rest of this.)
class _Score {
  const _Score(this.cost, this.unstable, this.delay);
  final int cost;
  final int unstable;
  final int delay;

  _Score operator +(_Score o) =>
      _Score(cost + o.cost, unstable + o.unstable, delay + o.delay);

  bool lessThan(_Score o) {
    if (cost != o.cost) return cost < o.cost;
    if (unstable != o.unstable) return unstable < o.unstable;
    return delay < o.delay;
  }
}

// One way a phrase can be felt: its phrase and which rendition.
class _Render {
  _Render(this.phrase, this.entries) : cells = timeline(entries);
  final HapticPhrase phrase;
  final List<PatternEntry> entries;
  final List<PatternDynamic?> cells;
}

// One way to wait between two commands: a gap row and a rest length inside it,
// or a rest longer than any measured row, extrapolated.
class _Wait {
  const _Wait(this.delayMs, this.minUnits, this.maxUnits, this.units,
      this.stable);
  final int delayMs;
  final int minUnits;
  final int maxUnits;

  /// The rest length this wait is scored with.
  final int units;
  final bool stable;
}

class _Node {
  _Node(this.score, this.prev, this.wait, this.render);
  final _Score score;
  final int prev; // end position of the step before, -1 for the first step
  final _Wait? wait;
  final _Render render;
}

/// Compiles [target] for [p]. Leading rests are ignored; a target with no
/// note gives null. Every phrase and gap row of the profile is considered;
/// each unstable one adds a small cost, so stable parts win unless an unstable
/// one fits meaningfully better. At most [maxCommands] commands; when the cap bites the
/// plan is not exact. Each command beyond the first adds [commandPenalty] to
/// the cost. With [maxRuntimeMs] a plan that runs longer is skipped, and a
/// target that itself runs longer gives null (it would otherwise be cut short
/// without saying so). [priority] picks what is given up first when the
/// pattern cannot be played as written.
HapticPlan? compile(
  List<PatternEntry> target,
  HapticDeviceProfile p, {
  int dynamicWeight = 1,
  HapticPriority priority = HapticPriority.rhythm,
  int maxCommands = 8,
  int commandPenalty = 2,
  int? maxRuntimeMs,
}) {
  final mismatch = priority == HapticPriority.dynamics
      ? _kDynamicsMismatch
      : _kMismatch;
  final loudness = priority == HapticPriority.dynamics
      ? dynamicWeight * _kDynamicsLoudness
      : dynamicWeight;
  var cells = timeline(target);
  final first = cells.indexWhere((c) => c != null);
  if (first < 0 || maxCommands < 1) return null;
  final last = cells.lastIndexWhere((c) => c != null);
  cells = cells.sublist(first, last + 1);
  final n = cells.length;
  if (maxRuntimeMs != null && n * p.unitMs > maxRuntimeMs) return null;

  final renders = <_Render>[];
  for (final ph in p.phrases) {
    final lo = _Render(ph, ph.min);
    renders.add(lo);
    final hi = _Render(ph, ph.max);
    if (!_sameCells(lo.cells, hi.cells)) renders.add(hi);
  }
  if (renders.isEmpty) return null;

  final gaps = p.gaps;
  // Beyond the longest measured rest, waiting longer only lengthens the
  // silence: delay grows by one unit per unit, from the longest stable row.
  HapticGap? longest;
  for (final g in gaps) {
    if (g.stable && (longest == null || g.maxUnits > longest.maxUnits)) {
      longest = g;
    }
  }

  // notesBefore[i] = notes among cells[0 .. i).
  final notesBefore = List<int>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    notesBefore[i + 1] = notesBefore[i] + (cells[i] != null ? 1 : 0);
  }
  int notesIn(int from, int to) =>
      notesBefore[to.clamp(0, n)] - notesBefore[from.clamp(0, n)];

  int place(_Render r, int at) {
    var c = 0;
    for (var i = 0; i < r.cells.length; i++) {
      final want = at + i < n ? cells[at + i] : null;
      final got = r.cells[i];
      if ((want != null) != (got != null)) {
        c += mismatch;
      } else if (want != null) {
        c += loudness * want.distanceTo(got!);
      }
    }
    return c;
  }

  // The waits that reach a start inside the target, by rest length. Rest
  // lengths past the longest row are extrapolated.
  List<_Wait> waitsFor(int units) {
    final out = <_Wait>[];
    for (final g in gaps) {
      if (units >= g.minUnits && units <= g.maxUnits) {
        out.add(_Wait(g.delayMs, g.minUnits, g.maxUnits, units, g.stable));
      }
    }
    if (longest != null && units > longest.maxUnits) {
      out.add(_Wait(
        longest.delayMs + (units - (longest.maxUnits - 1)) * p.unitMs,
        units,
        units,
        units,
        true,
      ));
    }
    return out;
  }

  final maxLen =
      renders.fold<int>(0, (m, r) => r.cells.length > m ? r.cells.length : m);
  final span = n + maxLen + 1;
  // best[k][e]: the best way to have placed k commands ending at position e.
  final best = List.generate(maxCommands + 1, (_) => List<_Node?>.filled(span, null));

  for (final r in renders) {
    final e = r.cells.length;
    final s = _Score(
      place(r, 0) + (r.phrase.stable ? 0 : _kUnstableCost),
      r.phrase.stable ? 0 : 1,
      0,
    );
    final cur = best[1][e];
    if (cur == null || s.lessThan(cur.score)) {
      best[1][e] = _Node(s, -1, null, r);
    }
  }

  for (var k = 1; k < maxCommands; k++) {
    for (var e = 1; e < span; e++) {
      final from = best[k][e];
      if (from == null) continue;
      for (var start = e + 1; start < n; start++) {
        final waits = waitsFor(start - e);
        if (waits.isEmpty) continue;
        final gapCost = mismatch * notesIn(e, start);
        for (final w in waits) {
          for (final r in renders) {
            final end = start + r.cells.length;
            final s = from.score +
                _Score(
                  gapCost +
                      place(r, start) +
                      (w.stable ? 0 : _kUnstableCost) +
                      (r.phrase.stable ? 0 : _kUnstableCost),
                  (w.stable ? 0 : 1) + (r.phrase.stable ? 0 : 1),
                  w.delayMs,
                );
            final cur = best[k + 1][end];
            if (cur == null || s.lessThan(cur.score)) {
              best[k + 1][end] = _Node(s, e, w, r);
            }
          }
        }
      }
    }
  }

  // Every end position with a plan, ordered by total cost (the notes left
  // over after the last command paid for, plus the penalty per extra
  // command), then fewer commands, then the rest of the score. The best one
  // that fits the runtime cap wins.
  final candidates = <({int k, int e, _Score total})>[];
  for (var k = 1; k <= maxCommands; k++) {
    for (var e = 1; e < span; e++) {
      final node = best[k][e];
      if (node == null) continue;
      candidates.add((
        k: k,
        e: e,
        total: node.score +
            _Score(mismatch * notesIn(e, n) + commandPenalty * (k - 1), 0, 0),
      ));
    }
  }
  candidates.sort((a, b) {
    if (a.total.cost != b.total.cost) {
      return a.total.cost.compareTo(b.total.cost);
    }
    if (a.k != b.k) return a.k.compareTo(b.k);
    if (a.total.lessThan(b.total)) return -1;
    if (b.total.lessThan(a.total)) return 1;
    return 0;
  });

  final written = _interiorRests(cells);
  HapticPlan? merged; // the best plan that fits the cap but lost a rest
  HapticPlan? kept; // the best of the search above that keeps every rest
  for (final cand in candidates) {
    final chain = <_Node>[];
    var k = cand.k;
    var e = cand.e;
    while (k >= 1) {
      final node = best[k][e]!;
      chain.add(node);
      e = node.prev;
      k--;
    }
    final ordered = chain.reversed.toList();

    // A step starts where the one before it ends (its node's prev) plus the
    // rest the wait covers; the first starts at the first note.
    final steps = <HapticStep>[
      for (final node in ordered)
        HapticStep(
          phrase: node.render.phrase,
          delayMs: node.wait?.delayMs ?? 0,
          restMinUnits: node.wait?.minUnits ?? 0,
          restMaxUnits: node.wait?.maxUnits ?? 0,
          gapStable: node.wait?.stable ?? true,
          startUnit: first + (node.wait == null ? 0 : node.prev + node.wait!.units),
        ),
    ];
    final plan = _assemble(steps, cells, first, p,
        cost: cand.total.cost,
        commands: cand.k,
        unstableParts: cand.total.unstable,
        commandPenalty: commandPenalty,
        dynamics: dynamicWeight > 0);
    if (maxRuntimeMs != null && plan.runtimeMs > maxRuntimeMs) continue;
    merged ??= plan;
    if (_keepsRests(plan, written)) {
      kept = plan;
      break;
    }
  }
  // The best plan overall is usually the first; when it lost a rest the
  // pulse-by-pulse search may do better than the first one that kept them.
  if (kept != null && identical(kept, merged)) return kept;
  final lengthened = _compileKeepingRests(
    cells, first, p,
    mismatch: mismatch,
    loudness: loudness,
    dynamics: dynamicWeight > 0,
    maxCommands: maxCommands,
    commandPenalty: commandPenalty,
    maxRuntimeMs: maxRuntimeMs,
  );
  if (kept != null && lengthened != null) {
    return lengthened.cost < kept.cost ? lengthened : kept;
  }
  return kept ?? lengthened ?? merged;
}

// The plan for [steps] against the target [cells] (leading rests trimmed):
// what is felt at the shortest and the longest, and whether that is the
// pattern as written.
HapticPlan _assemble(
  List<HapticStep> steps,
  List<PatternDynamic?> cells,
  int first,
  HapticDeviceProfile p, {
  required int cost,
  required int commands,
  required int unstableParts,
  required int commandPenalty,
  required bool dynamics,
}) {
  final feltMin = _felt(steps, useMax: false);
  final feltMax = _felt(steps, useMax: true);
  final exact =
      cost - commandPenalty * (commands - 1) - _kUnstableCost * unstableParts ==
          0;
  return HapticPlan(
    steps: List.unmodifiable(steps),
    feltMin: feltMin,
    feltMax: feltMax,
    cost: cost,
    exact: exact,
    asWritten: exact &&
        steps.every((s) => s.restMinUnits == s.restMaxUnits) &&
        _sameTiming(timeline(feltMin), cells, dynamics: dynamics) &&
        _sameTiming(timeline(feltMax), cells, dynamics: dynamics),
    usesUnstable: steps.any((s) => !s.phrase.stable || !s.gapStable),
    summary: _summary(steps),
    runtimeMs: timeline(feltMax).length * p.unitMs,
    pulseOwners: pulseOwnersOf(steps, cells, first),
  );
}

// The lengths of the rest runs strictly between the first and the last note.
List<int> _interiorRests(List<PatternDynamic?> cells) {
  final first = cells.indexWhere((c) => c != null);
  final last = cells.lastIndexWhere((c) => c != null);
  if (first < 0) return const [];
  final out = <int>[];
  var run = 0;
  for (var i = first; i <= last; i++) {
    if (cells[i] == null) {
      run++;
    } else if (run > 0) {
      out.add(run);
      run = 0;
    }
  }
  return out;
}

// Whether [plan] has the [written] rests between pulses in both renditions:
// as many, none shorter.
bool _keepsRests(HapticPlan plan, List<int> written) {
  for (final felt in [plan.feltMin, plan.feltMax]) {
    final got = _interiorRests(timeline(felt));
    if (got.length != written.length) return false;
    for (var i = 0; i < got.length; i++) {
      if (got[i] < written[i]) return false;
    }
  }
  return true;
}

// A target or a phrase rendition as pulses (runs of notes) and the rests
// between them. Leading and trailing rests are not kept.
class _Shape {
  _Shape(List<PatternDynamic?> cells) {
    var run = 0;
    for (final c in cells) {
      if (c != null) {
        if (pulses.isEmpty) {
          pulses.add([c]);
        } else if (run > 0) {
          rests.add(run);
          run = 0;
          pulses.add([c]);
        } else {
          pulses.last.add(c);
        }
      } else if (pulses.isNotEmpty) {
        run++;
      }
    }
  }
  final List<List<PatternDynamic?>> pulses = [];
  final List<int> rests = [];
}

// One command of the pulse-by-pulse search: [phrase] starts at target pulse
// [at], after [wait] (null for the first).
class _Seg {
  _Seg(this.score, this.prev, this.wait, this.phrase, this.at);
  final _Score score;
  final int prev; // pulses covered before this command; -1 for the first
  final _Wait? wait;
  final HapticPhrase phrase;
  final int at;
}

// The second search: plans the pattern one pulse at a time instead of one
// sixteenth at a time, so a written rest can be kept by lengthening it. A
// command may carry several pulses (the pair, the arcs) when its own rests are
// no shorter than the ones written there; between commands the wait's SHORTEST
// felt rest must reach the written rest, so a rest comes out the same or
// longer in every rendition. Pulse lengths and loudness are scored as in
// [compile]; each unit a rest's shortest rendition runs past the written one
// costs one (so a lengthened rest is not exact, one that is only inside the
// wait's range is). A rest longer than the
// longest measured wait is extrapolated, one unit per unit. Null when no plan
// of at most [maxCommands] fits [maxRuntimeMs].
HapticPlan? _compileKeepingRests(
  List<PatternDynamic?> cells,
  int first,
  HapticDeviceProfile p, {
  required int mismatch,
  required int loudness,
  required bool dynamics,
  required int maxCommands,
  required int commandPenalty,
  required int? maxRuntimeMs,
}) {
  final target = _Shape(cells);
  final m = target.pulses.length;
  if (m < 2) return null;
  // Where each target pulse starts, counting from the first note.
  final startAt = <int>[];
  var at = 0;
  for (var i = 0; i < m; i++) {
    startAt.add(at);
    at += target.pulses[i].length +
        (i < target.rests.length ? target.rests[i] : 0);
  }

  int pulseCost(List<PatternDynamic?> want, List<PatternDynamic?> got) {
    var c = 0;
    final n = want.length > got.length ? want.length : got.length;
    for (var t = 0; t < n; t++) {
      final w = t < want.length ? want[t] : null;
      final g = t < got.length ? got[t] : null;
      if ((w != null) != (g != null)) {
        c += mismatch;
      } else if (w != null) {
        c += loudness * w.distanceTo(g!);
      }
    }
    return c;
  }

  // What each phrase costs when it carries target pulses [i, i + its count):
  // null when it cannot (too many pulses, or a rest of its own shorter than
  // the one written there).
  final shapes = <HapticPhrase, (_Shape, _Shape)>{
    for (final ph in p.phrases)
      ph: (_Shape(timeline(ph.min)), _Shape(timeline(ph.max))),
  };
  final usable = [
    for (final ph in p.phrases)
      if (shapes[ph]!.$1.pulses.length == shapes[ph]!.$2.pulses.length) ph,
  ];
  int? fit(HapticPhrase ph, int i) {
    final (lo, hi) = shapes[ph]!;
    final c = lo.pulses.length;
    if (i + c > m) return null;
    // As in [compile], a phrase is as good as its better rendition matches the
    // pulses; the rests it carries must hold in both.
    var viaLo = 0, viaHi = 0, longer = 0;
    for (var j = 0; j < c; j++) {
      viaLo += pulseCost(target.pulses[i + j], lo.pulses[j]);
      viaHi += pulseCost(target.pulses[i + j], hi.pulses[j]);
      if (j < c - 1) {
        final want = target.rests[i + j];
        final shortest = lo.rests[j] < hi.rests[j] ? lo.rests[j] : hi.rests[j];
        if (shortest < want) return null;
        longer += shortest - want;
      }
    }
    return (viaLo < viaHi ? viaLo : viaHi) + longer;
  }

  HapticGap? longest;
  for (final g in p.gaps) {
    if (g.stable && (longest == null || g.maxUnits > longest.maxUnits)) {
      longest = g;
    }
  }
  // The waits whose shortest rest reaches [units].
  List<_Wait> waitsAtLeast(int units) {
    final out = [
      for (final g in p.gaps)
        if (g.minUnits >= units)
          _Wait(g.delayMs, g.minUnits, g.maxUnits, g.minUnits, g.stable),
    ];
    if (out.isEmpty && longest != null) {
      out.add(_Wait(
        longest.delayMs + (units - longest.minUnits) * p.unitMs,
        units,
        units,
        units,
        true,
      ));
    }
    return out;
  }

  // best[k][i]: the best way to have placed k commands over the first i pulses.
  final best = List.generate(maxCommands + 1, (_) => List<_Seg?>.filled(m + 1, null));
  void offer(int k, int i, _Seg s) {
    final cur = best[k][i];
    if (cur == null || s.score.lessThan(cur.score)) best[k][i] = s;
  }

  for (final ph in usable) {
    final c = shapes[ph]!.$1.pulses.length;
    final f = fit(ph, 0);
    if (f == null) continue;
    final u = ph.stable ? 0 : 1;
    offer(1, c, _Seg(_Score(f + u * _kUnstableCost, u, 0), -1, null, ph, 0));
  }
  for (var k = 1; k < maxCommands; k++) {
    for (var i = 1; i < m; i++) {
      final from = best[k][i];
      if (from == null) continue;
      final want = target.rests[i - 1];
      final waits = waitsAtLeast(want);
      for (final w in waits) {
        for (final ph in usable) {
          final f = fit(ph, i);
          if (f == null) continue;
          final u = (w.stable ? 0 : 1) + (ph.stable ? 0 : 1);
          offer(
            k + 1,
            i + shapes[ph]!.$1.pulses.length,
            _Seg(
              from.score +
                  _Score(f + (w.minUnits - want) + u * _kUnstableCost, u,
                      w.delayMs),
              i,
              w,
              ph,
              i,
            ),
          );
        }
      }
    }
  }

  final done = <({int k, _Score total})>[
    for (var k = 1; k <= maxCommands; k++)
      if (best[k][m] != null)
        (
          k: k,
          total: best[k][m]!.score + _Score(commandPenalty * (k - 1), 0, 0),
        ),
  ]..sort((a, b) {
      if (a.total.cost != b.total.cost) {
        return a.total.cost.compareTo(b.total.cost);
      }
      if (a.k != b.k) return a.k.compareTo(b.k);
      return a.total.lessThan(b.total) ? -1 : (b.total.lessThan(a.total) ? 1 : 0);
    });
  for (final cand in done) {
    final chain = <_Seg>[];
    var k = cand.k;
    var i = m;
    while (k >= 1) {
      final seg = best[k][i]!;
      chain.add(seg);
      i = seg.prev;
      k--;
    }
    final steps = [
      for (final seg in chain.reversed)
        HapticStep(
          phrase: seg.phrase,
          delayMs: seg.wait?.delayMs ?? 0,
          restMinUnits: seg.wait?.minUnits ?? 0,
          restMaxUnits: seg.wait?.maxUnits ?? 0,
          gapStable: seg.wait?.stable ?? true,
          startUnit: first + startAt[seg.at],
        ),
    ];
    final plan = _assemble(steps, cells, first, p,
        cost: cand.total.cost,
        commands: cand.k,
        unstableParts: cand.total.unstable,
        commandPenalty: commandPenalty,
        dynamics: dynamics);
    if (maxRuntimeMs != null && plan.runtimeMs > maxRuntimeMs) continue;
    return plan;
  }
  return null;
}

bool _sameCells(List<PatternDynamic?> a, List<PatternDynamic?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// Whether two timelines are the same length with notes and rests in the same
// cells, and with [dynamics] the same loudness too. A cell written as any
// loudness in [b] (the target) accepts every loudness in [a] (the felt side).
bool _sameTiming(
  List<PatternDynamic?> a,
  List<PatternDynamic?> b, {
  required bool dynamics,
}) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] != null) != (b[i] != null)) return false;
    if (dynamics && b[i] != PatternDynamic.any && a[i] != b[i]) return false;
  }
  return true;
}

List<PatternEntry> _felt(List<HapticStep> steps, {required bool useMax}) => [
      for (final s in steps) ...[
        ...restEntries(useMax ? s.restMaxUnits : s.restMinUnits),
        ...(useMax ? s.phrase.max : s.phrase.min),
      ],
    ];

String _effects(HapticPhrase ph) {
  final list = ph.effects.join(', ');
  final base = ph.effects.length == 1 ? 'effect $list' : 'effects $list';
  return ph.loop > 1 ? '$base, ${ph.loop} times' : base;
}

String _summary(List<HapticStep> steps) {
  final b = StringBuffer(
    steps.length == 1 ? '1 command: ' : '${steps.length} commands: ',
  );
  for (var i = 0; i < steps.length; i++) {
    if (i > 0) {
      final d = steps[i].delayMs;
      b.write(
        d == 0
            ? ', then straight after it ends, '
            : ', then $d ms after it ends, ',
      );
    }
    b.write(_effects(steps[i].phrase));
  }
  return b.toString();
}
