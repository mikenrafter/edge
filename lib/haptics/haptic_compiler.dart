// 8AC: notes -> device commands. Given a pattern written as notes and rests
// on the 16th grid, pick the band commands (phrases) and the write delays
// between them (gaps) from a measured device profile so that what is felt
// lands as close to the pattern as the vocabulary allows. Pure Dart, no
// Flutter, no BLE, deterministic.
//
// The search is a dynamic program over 16th positions. A placement costs 4 for
// every cell where the felt side and the target disagree about note versus
// rest, plus dynamicWeight times the loudness distance on cells where both
// are notes. Every command beyond the first adds a small penalty, so one
// command is preferred when it is nearly as good. Plans are ordered by cost,
// then fewer commands, then fewer unstable parts, then less total write
// delay; ties inside that are settled by the fixed order of the profile's
// rows.

import '../gestures/pattern_transcript.dart';
import 'haptic_profile.dart';

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
}

/// What to write and how it should feel.
class HapticPlan {
  const HapticPlan({
    required this.steps,
    required this.feltMin,
    required this.feltMax,
    required this.cost,
    required this.exact,
    required this.usesUnstable,
    required this.summary,
    this.runtimeMs = 0,
  });

  final List<HapticStep> steps;

  /// The pattern as felt when everything runs at its shortest and its longest.
  final List<PatternEntry> feltMin;
  final List<PatternEntry> feltMax;
  final int cost;

  /// True when no cell is felt differently from the target (the command
  /// penalty is not counted): the target is felt as written.
  final bool exact;

  /// How long the plan is felt at its longest: [feltMax] on the 16th grid
  /// times the profile's unit.
  final int runtimeMs;
  final bool usesUnstable;

  /// "2 commands: effect 47, then 300 ms after it ends, effect 14".
  final String summary;
}

/// Cost of one cell that disagrees about note versus rest.
const int _kMismatch = 4;

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
/// note gives null. Without [extended] only the profile's stable phrases and
/// gap rows are used. At most [maxCommands] commands; when the cap bites the
/// plan is not exact. Each command beyond the first adds [commandPenalty] to
/// the cost. With [maxRuntimeMs] a plan that runs longer is skipped, and a
/// target that itself runs longer gives null (it would otherwise be cut short
/// without saying so).
HapticPlan? compile(
  List<PatternEntry> target,
  HapticDeviceProfile p, {
  required bool extended,
  int dynamicWeight = 1,
  int maxCommands = 8,
  int commandPenalty = 2,
  int? maxRuntimeMs,
}) {
  var cells = timeline(target);
  final first = cells.indexWhere((c) => c != null);
  if (first < 0 || maxCommands < 1) return null;
  final last = cells.lastIndexWhere((c) => c != null);
  cells = cells.sublist(first, last + 1);
  final n = cells.length;
  if (maxRuntimeMs != null && n * p.unitMs > maxRuntimeMs) return null;

  final renders = <_Render>[];
  for (final ph in p.phrasesFor(extended: extended)) {
    final lo = _Render(ph, ph.min);
    renders.add(lo);
    final hi = _Render(ph, ph.max);
    if (!_sameCells(lo.cells, hi.cells)) renders.add(hi);
  }
  if (renders.isEmpty) return null;

  final gaps = p.gapsFor(extended: extended);
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
        c += _kMismatch;
      } else if (want != null) {
        c += dynamicWeight * (want.index - got!.index).abs();
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
    final s = _Score(place(r, 0), r.phrase.stable ? 0 : 1, 0);
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
        final gapCost = _kMismatch * notesIn(e, start);
        for (final w in waits) {
          for (final r in renders) {
            final end = start + r.cells.length;
            final s = from.score +
                _Score(
                  gapCost + place(r, start),
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
            _Score(_kMismatch * notesIn(e, n) + commandPenalty * (k - 1), 0, 0),
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

    final steps = <HapticStep>[
      for (final node in ordered)
        HapticStep(
          phrase: node.render.phrase,
          delayMs: node.wait?.delayMs ?? 0,
          restMinUnits: node.wait?.minUnits ?? 0,
          restMaxUnits: node.wait?.maxUnits ?? 0,
          gapStable: node.wait?.stable ?? true,
        ),
    ];
    final feltMax = _felt(steps, useMax: true);
    final runtimeMs = timeline(feltMax).length * p.unitMs;
    if (maxRuntimeMs != null && runtimeMs > maxRuntimeMs) continue;

    return HapticPlan(
      steps: List.unmodifiable(steps),
      feltMin: _felt(steps, useMax: false),
      feltMax: feltMax,
      cost: cand.total.cost,
      exact: cand.total.cost - commandPenalty * (cand.k - 1) == 0,
      usesUnstable: steps.any((s) => !s.phrase.stable || !s.gapStable),
      summary: _summary(steps),
      runtimeMs: runtimeMs,
    );
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
