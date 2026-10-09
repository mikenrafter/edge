// LAWS of the day-state folds (design 05, pilot cluster C2, edge side): the
// checkpoint the day pass resumes from (`foldDayCheckpoint`, the codec
// `encodeDayResumeState` / `decodeDayResumeState`, kDayCheckpointFmt 4), its
// streaming RR half (`DayRrState`: analytics `RrCorrector` + `IrregularScreenState`),
// the three day curves (`DayCurveStates`), the activity summaries
// (`day_activity_state.dart`) and the registered tail entry `foldDayTailHeavy`.
//
//   L1   chunk invariance: a day folded in ANY valid chunking (restarting from
//        the bytes between chunks, the sleep window moving on every chunk,
//        beats handed over ahead of / behind the accelerometer watermark)
//        gives the bytes of one fold of the whole day. This is NOT a monoid
//        claim (there is no `combine`); it is a law of the append transition.
//        Two corrections to the plain statement, both from the code:
//         * the documented REFUSAL (the first beats after a beatless prefix
//           whose rows the curve state never kept, day_curve_states.dart
//           `continuesWith`) is asserted as a refusal, exactly where the model
//           says it is, not as a failure;
//         * "bytes are canonical" (day_curve_states.dart header) holds when the
//           first beats are in the first chunk. After a beatless prefix the
//           curve state keeps no rows (a beatless stretch costs no bytes), so
//           the rows older than the first beat that one fold keeps within 300 s
//           of the newest beat are absent: every other part is byte-identical
//           and the curve state READS the same (pinned by its own test below,
//           which also fails if the code ever becomes canonical there).
//   L1b  resumed vs batch: at chunk seams the decoded state reads what the
//        batch functions give over the same prefix. Counts, flags, abstentions,
//        the three curves, the step total and the per-minute motion buckets are
//        exact; SD1 / SD2 / ratio are within 1e-9 relative and confidence
//        within 1e-12 (the analytics tolerance: running sums against a two-pass
//        batch, analytics irregular_screen_state_test.dart). The PERSISTED text
//        rounds to six places, so it can differ from the batch only where a
//        value sits within the tolerance of a rounding boundary (about one in
//        1e7 per field; test/day_stream_state_test.dart header); the law
//        accepts that case and counts it. NOT covered here: heart-rate
//        statistics, wake minutes, active minutes and the activity curve, whose
//        batch versions are private to `DerivationEngine` (they are checked
//        against their own `sync` path in L2 and by day_checkpoint_test); wear
//        runs are checked against the batch's stated rule (a hole of more than
//        two minutes ends a run).
//   L2   checkpoint round trip: write(read(b)) == b byte for byte, and the
//        decoded state reads what the live (never serialised) state reads on an
//        explicit PROJECTION, whether it was brought up to date by `appendTail`
//        or by `sync`. The projection leaves out the work counters
//        (processedSamples, retainedSamples) and the sleep-window fields the
//        argument-less readers use (they are not stored; design 05 section 7).
//   L3   an old or foreign blob is refused whole, never partly read (fmt < 4,
//        analytics IrregularScreenState v1, wrong magic, truncation, padding,
//        flipped bytes, parts that disagree), by the codec, by
//        `foldDayCheckpoint` and by the tail entry.
//   L4   identity: an empty tail with the metadata, the bills and the watermark
//        held fixed leaves the checkpoint unchanged; and, the other way round,
//        the same call with another age, counter modulus, quiet cut or folded
//        count is refused.
//   L5   conservation in the integrated corrector + screen, provisional NN
//        included: nn_in == rr_raw - dropped; the windows cover the kept NN
//        (independent partition oracle); flagged <= valid <= total; an invalid
//        window config gives no window evidence and no flag.
//   T    `foldDayTailHeavy` called directly equals the in-isolate fold it
//        replaced, and the batch over the whole day.
//
// Work counters (`processedSamples` ...) are performance contracts and stay in
// the example tests (day_checkpoint_test.dart); they are outside every law
// here. So are the engine, the database and the revision/context policy.
//
// These laws describe the CURRENT behaviour (edge e2a8ac97, analytics
// 0fc57682). A law that fails is first checked against the module's contract;
// only a violation of the intended contract is a bug, and a wrong oracle is
// fixed here, never in lib/.
//
// A day is a RECIPE (flavour, span, beats, ..., seed) expanded
// deterministically, so a failing input shrinks to a few readable integers, not
// to thousands of doubles. Beats are capped at 3,000 per day and the chunking
// at 6 split points. No clock is read; the days are fixed epoch days. The
// flavours take turns with the case index so a handful of cases still meets
// them all; the scenarios that matter (thin, flagged, backwards, an artefact
// run, pending beats, a beatless prefix, the refusal and its edge, a counter
// reset on a seam, 23 h / 25 h days) are FORCED examples, checked by a test of
// their own. Each law runs ~10-12 generated cases after the forced ones: the
// per-property budget (2 s) and the cost of a fold set that, not the harness.
//
// PROPERTY_REACH_REPORT=1 prints what each law's generated cases reached, to
// retune the shares in `_caseShares` after a generator change.
//
// Replay a failure with the command in its report, e.g.
//   PROPERTY_SEED=<s> PROPERTY_CASE=<n> TZ=UTC flutter test \
//     test/properties/day_fold_laws_test.dart --plain-name '<name>'

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_activity_state.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_curve_states.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/day_rr_state.dart';
import 'package:openstrap_edge/compute/day_tail_fold.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/minute_bills.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import '../support/day_stream_fixture.dart';
import '../support/property.dart';

// ── the recipe of a day ─────────────────────────────────────────────────────

/// 2025-10-09 08:53:20 UTC. Every day starts here; nothing reads a clock.
const int _start = 1760000000;

const _flavours = [
  'clean', // regular beats, no artefacts, no dropouts
  'mixed', // ectopic pairs, missed / extra beats, noise runs, dropouts
  'flagged', // sustained irregular rhythm (the screen flags)
  'gappy', // a dropout every ~90 s
  'backwards', // beat times that step backwards (a counter reset)
  'artefact runs', // heavy artefacts + one run of 120 beats (longer than the corrector window)
  'thin edge', // forced only: an outlier every 13th beat, so a thin window has exactly 8 of its 10 differences
];

/// The flavours the generator cycles through (the last one is forced only).
const int _cycle = 6;

/// How far past the last accelerometer row beats may reach, in seconds.
const _overrunSec = [0, 0, 5, 400];

/// ((age, step modulus, quiet cut, has bills), ...) the constant config of a case.
typedef _Cfg = (int?, int?, double, bool);
const List<_Cfg> _cfgs = [
  (35, 65536, 0.02, false),
  (null, null, 0.02, true),
  (70, 256, 0.05, true),
  (20, 65536, 0.02, true),
  (null, 65536, 0.05, false),
];

/// ((flavour, span s, beats, first beat after s), (seed, row gaps, overrun idx,
/// config idx, row stride s)).
typedef _DayR = ((int, int, int, int), (int, int, int, int, int));

/// (splits, cut seed (< 0: also cut exactly at the step-counter reset), beat
/// edge idx (beats handed over ahead of / behind the rows), window seed).
typedef _ChunkR = (int, int, int, int);

typedef _Case = (_DayR, _ChunkR);

/// Roughly the spans of the shapes that matter: empty, thin, a minute either
/// side, and the day-sized spans (23 h / 25 h days are forced with sparse rows).
class _SpanGen extends Gen<int> {
  static const _pool = [0, 1, 2, 59, 60, 61, 300, 900, 1800, 2700];
  static final Gen<int> _base = G.intIn(0, 2800);
  @override
  int generate(Rng r, int size) {
    // (The flagged-rhythm flavour, case index 2 mod 6, needs a long day.)
    if (size % _cycle == 2) return r.intIn(1800, 2800);
    final p = r.nextDouble();
    if (p < .15) return _pool[r.nextInt(_pool.length)];
    if (p < .6) return r.intIn(1500, 2800);
    return _base.generate(r, size);
  }

  @override
  Iterable<int> shrink(int v) => _base.shrink(v);
}

class _BeatsGen extends Gen<int> {
  static const _pool = [0, 1, 2, 3, 9, 10, 11, 59, 60, 61, 99, 100, 101, 300];
  @override
  int generate(Rng r, int size) {
    // The flagged-rhythm flavour (case index 2 mod 6) needs enough beats to flag.
    if (size % _cycle == 2) return r.intIn(1200, 1800);
    final p = r.nextDouble();
    if (p < .2) return _pool[r.nextInt(_pool.length)];
    if (p < .4) return r.intIn(1000, 2000);
    return r.intIn(0, 700);
  }

  @override
  Iterable<int> shrink(int v) => G.intIn(0, 3000).shrink(v);
}

class _BeatStartGen extends Gen<int> {
  @override
  int generate(Rng r, int size) =>
      r.nextBool(.7) ? 0 : r.elementOf(const [30, 60, 600, 1200]);
  @override
  Iterable<int> shrink(int v) => G.intIn(0, 1200).shrink(v);
}

extension on Rng {
  T elementOf<T>(List<T> xs) => xs[nextInt(xs.length)];
}

/// Five ints, each shrunk on its own.
class _Gen5 extends Gen<(int, int, int, int, int)> {
  _Gen5(this.gs);
  final List<Gen<int>> gs;
  @override
  (int, int, int, int, int) generate(Rng r, int size) {
    final v = [for (final g in gs) g.generate(r, size)];
    return (v[0], v[1], v[2], v[3], v[4]);
  }

  @override
  Iterable<(int, int, int, int, int)> shrink((int, int, int, int, int) t) sync* {
    final v = [t.$1, t.$2, t.$3, t.$4, t.$5];
    for (var i = 0; i < 5; i++) {
      for (final c in gs[i].shrink(v[i])) {
        final w = [...v]..[i] = c;
        yield (w[0], w[1], w[2], w[3], w[4]);
      }
    }
  }

  @override
  String show((int, int, int, int, int) t) => '$t';
}

/// The flavours take turns with the case index (the harness's `size` is
/// 10 + the case index), so every run of six cases meets all of them.
class _FlavourGen extends Gen<int> {
  @override
  int generate(Rng r, int size) => size % _cycle;
  @override
  Iterable<int> shrink(int v) => G.intIn(0, _flavours.length - 1).shrink(v);
}

/// Negative: the chunking also cuts exactly where the step counter resets.
class _CutSeedGen extends Gen<int> {
  @override
  int generate(Rng r, int size) =>
      r.nextBool(.12) ? -(1 + r.nextInt(1000)) : r.nextInt(1 << 20);
  @override
  Iterable<int> shrink(int v) => v < 0
      ? [-v, ...G.intIn(-1000, 0).shrink(v)]
      : G.intIn(0, 1 << 20).shrink(v);
}

final Gen<_DayR> _dayGen = G.pair(
  G.quad(_FlavourGen(), _SpanGen(), _BeatsGen(), _BeatStartGen()),
  _Gen5([
    G.intIn(0, 1 << 20),
    G.intIn(0, 1),
    G.intIn(0, 3),
    G.intIn(0, _cfgs.length - 1),
    G.elements(const [1, 1, 1, 1, 30]),
  ]),
);

final Gen<_ChunkR> _chunkGen = G.quad(
  G.intIn(0, 6),
  _CutSeedGen(),
  G.intIn(0, 3),
  G.intIn(0, 1 << 20),
);

// ── a day, expanded ─────────────────────────────────────────────────────────

class _Day {
  _Day(this.r, this.ts, this.hr, this.ax, this.ay, this.az, this.step, this.rr,
      this.rrTs, this.cfg, this.resetAt);
  final _DayR r;
  final List<int> ts, hr, step;
  final List<double> ax, ay, az;

  /// Beats exactly as handed to the fold (a `backwards` day is NOT monotone).
  final List<double> rr, rrTs;
  final _Cfg cfg;

  /// Row index where the step counter resets (or -1).
  final int resetAt;

  int get n => ts.length;
  int get beats => rr.length;
  int? get age => cfg.$1;
  int? get modulus => cfg.$2;
  double get cut => cfg.$3;
  MinuteBills? get bills => cfg.$4 ? _bills(1) : null;

  /// The second every accelerometer row below which has been given, at the end.
  int get through => n == 0 ? _start : ts.last + 1;

  Accel get accel => Accel(ts, ax, ay, az);
  String get name {
    final ((f, span, b, bs), (seed, gaps, over, cfgI, stride)) = r;
    return '${_flavours[f]} span=$span beats=$b beatStart=$bs seed=$seed '
        'gaps=$gaps overrun=${_overrunSec[over]} cfg=$cfgI stride=$stride';
  }
}

/// Regular beats (800 ms, a little jitter) with a 1200 ms outlier at every 13th
/// beat from the fourth: the eleven beats of a first HRV point then hold exactly
/// eight usable successive differences (the outlier spoils two).
Beats _thinEdgeBeats(int n, int startSec) {
  final rr = <double>[], ts = <double>[];
  var t = 0.0;
  for (var i = 0; i < n; i++) {
    final v = i % 13 == 3 ? 1200.0 : 800.0 + (i % 5) * 2;
    t += v / 1000.0;
    rr.add(v);
    ts.add((startSec + t).floorToDouble() * 1000.0);
  }
  return Beats(rr, ts);
}

MinuteBills _bills(int seed) => MinuteBills(
      restingHr: 55,
      maxHr: 190,
      sex: 'f',
      profile: (weightKg: 60, heightCm: 170, age: 30, sex: 'f'),
      basalPerMinute: 1.1,
      bills: [
        MinuteBill(
            key: 29333000 + seed,
            hr: 61,
            cadence: null,
            trimp: 0.01,
            source: 'hr',
            active: 0,
            walking: 0),
        MinuteBill(
            key: 29333001 + seed,
            hr: 64,
            cadence: 80,
            trimp: 0.02,
            source: null,
            active: 1,
            walking: 1),
      ],
    );

final Map<_DayR, _Day> _dayCache = {};

_Day _dayOf(_DayR r) => _dayCache.putIfAbsent(r, () {
      if (_dayCache.length > 600) _dayCache.clear();
      return _expandDay(r);
    });

_Day _expandDay(_DayR r) {
  final ((flav, span, nBeats, bStart), (seed, gaps, over, cfgI, stride)) = r;
  // Rows: 1 Hz gravity vectors with long still stretches, absent vectors and
  // gaps; a sparse stride stands for the 23 h / 25 h days (the fold is
  // epoch-based, so the length of the day matters only through its rows).
  // A sparse day is generated on a compressed clock and stretched, so a 25 h
  // day costs the rows it has, not 90,000 steps of generator.
  final all = synthAccel(seed + 1, 0, span ~/ stride,
      gapPerHour: gaps == 0 ? 0 : 40);
  final ts = [for (final t in all.tsSec) _start + t * stride];
  final ax = all.ax, ay = all.ay, az = all.az;
  if (gaps == 1 && ts.length > 400) {
    // Two holes at the edge of the wear-run rule (more than 120 s ends a run):
    // one of exactly 120 s (the run goes on), one of exactly 121 s (it ends).
    for (var i = ts.length ~/ 3; i < ts.length; i++) {
      ts[i] += 119;
    }
    for (var i = 2 * ts.length ~/ 3; i < ts.length; i++) {
      ts[i] += 120;
    }
  }
  final g = Rng(seed * 7919 + 3);
  final hr = <int>[];
  final step = <int>[];
  var c = 65500;
  final int resetAt =
      ts.length > 120 ? (100 + seed % math.min(500, ts.length - 110)).toInt() : -1;
  for (var i = 0; i < ts.length; i++) {
    final p = g.nextInt(100);
    hr.add(p < 4 ? 0 : (p < 6 ? 250 : 55 + (i ~/ 90) % 70 + g.nextInt(5)));
    if (i % 997 > 900) {
      step.add(-1);
    } else {
      if (i == resetAt) {
        c = 40000; // a reset: the next delta is unreadable and must be dropped
      } else if (i == resetAt + 1) {
        c = 0;
      } else {
        // Steps come a few a second; now and then a burst (100: within the
        // plausibility budget of a short gap; 400: past it, so dropped).
        final burst = i == 0 ? 0 : (i % 613 == 0 ? 100 : (i % 1009 == 0 ? 400 : 0));
        c = (c + burst + g.nextInt(3)) % 65536;
      }
      step.add(c);
    }
  }
  // Beats.
  final secs = nBeats + 60;
  final base = _start + bStart;
  final beats = nBeats == 0
      ? Beats(<double>[], <double>[])
      : flav == 6
          ? _thinEdgeBeats(nBeats, base)
          : synthBeats(switch (flav) {
          0 => SynthBeats(
              seed: seed,
              seconds: secs,
              startSec: base,
              ectopicPerMin: 0,
              missedPerMin: 0,
              extraPerMin: 0,
              noiseRunPerMin: 0,
              gapPerHour: 0),
          2 => SynthBeats(
              seed: seed,
              seconds: secs,
              startSec: base,
              ectopicPerMin: 0.05,
              missedPerMin: 0,
              extraPerMin: 0,
              noiseRunPerMin: 0,
              gapPerHour: 0,
              irregularBurst: (0, secs),
              irregularRangeMs: (600, 1000)),
          3 => SynthBeats(seed: seed, seconds: secs, startSec: base, gapPerHour: 40),
          4 => SynthBeats(
              seed: seed, seconds: secs, startSec: base, backwardsPerHour: 120),
          5 => SynthBeats(
              seed: seed,
              seconds: secs,
              startSec: base,
              ectopicPerMin: 1.0,
              noiseRunPerMin: 0.6),
          _ => SynthBeats(seed: seed, seconds: secs, startSec: base),
        });
  final limitMs = (_start + span + _overrunSec[over]) * 1000.0;
  final rr = <double>[], rrTs = <double>[];
  for (var i = 0; i < beats.length && rr.length < nBeats; i++) {
    if (beats.ts[i] >= limitMs) break;
    rr.add(beats.rr[i]);
    rrTs.add(beats.ts[i]);
  }
  if (flav == 5 && rr.length > 240) {
    // One run of 120 artefact beats: longer than the corrector's window (91).
    final at = rr.length ~/ 3;
    for (var i = at; i < at + 120; i++) {
      rr[i] = 250 + g.nextInt(2100).toDouble();
    }
  }
  return _Day(r, ts, hr, ax, ay, az, step, rr, rrTs, _cfgs[cfgI], resetAt);
}

// ── a chunking, expanded ────────────────────────────────────────────────────

/// Window pairs a pass may ask: none, inside the day, reversed (offset before
/// onset: no window), the whole day and beyond, a one-second window.
(int, int) _window(Rng r, int span) {
  final s = math.max(1, span);
  switch (r.nextInt(5)) {
    case 0:
      return (0, 0);
    case 1:
      final on = _start + r.nextInt(s);
      return (on, on + r.nextInt(s));
    case 2:
      final on = _start + r.nextInt(s);
      return (on, on - 1 - r.nextInt(s));
    case 3:
      return (_start - 1000, _start + s + 1000);
    default:
      final on = _start + r.nextInt(s);
      return (on, on + 1);
  }
}

class _Plan {
  _Plan(this.day, this.bounds, this.through, this.g, this.windows, this.edgeSec,
      this.splits);
  final _Day day;

  /// Row boundaries `[0, cuts..., n]`.
  final List<int> bounds;

  /// The watermark of each chunk.
  final List<int> through;

  /// Beat boundaries `[0, ..., beats]`: chunk k hands over beats `[g[k], g[k+1])`.
  final List<int> g;
  final List<(int, int)> windows;
  final int edgeSec;
  final int splits;
  int get chunks => bounds.length - 1;
  int rowsOf(int k) => bounds[k + 1] - bounds[k];

  /// Chunk that hands over the first beat (-1 when the day has none).
  int get firstBeatChunk {
    for (var k = 0; k < chunks; k++) {
      if (g[k + 1] > g[k]) return k;
    }
    return -1;
  }
}

final Map<_Case, _Plan> _planCache = {};

_Plan _planOf(_Case c) => _planCache.putIfAbsent(c, () {
      if (_planCache.length > 600) _planCache.clear();
      return _expandPlan(_dayOf(c.$1), c.$2);
    });

_Plan _expandPlan(_Day d, _ChunkR c) {
  final (splits, cutSeed, edgeIdx, winSeed) = c;
  final n = d.n;
  final cuts = <int>{};
  if (n >= 2) {
    final r = Rng(cutSeed.abs() + 17);
    final special = <int>[1, n - 1];
    for (var i = 1; i < n; i++) {
      if (d.ts[i] - d.ts[i - 1] > 1) special.add(i); // a gap in the rows
    }
    if (cutSeed < 0 && d.resetAt > 0) {
      // A counter reset exactly on a chunk seam (reset reading first of its chunk).
      cuts.add(d.resetAt);
      cuts.add(math.min(n - 1, d.resetAt + 1));
    }
    var guard = 0;
    final want = splits + cuts.length;
    while (cuts.length < math.min(want, n - 1) && guard++ < 200) {
      final v = r.nextBool(.3) ? special[r.nextInt(special.length)] : r.intIn(1, n - 1);
      if (v >= 1 && v < n) cuts.add(v);
    }
  }
  final bounds = [0, ...(cuts.toList()..sort()), n];
  final chunks = bounds.length - 1;
  final through = [
    for (var k = 0; k < chunks; k++)
      bounds[k + 1] == n ? d.through : d.ts[bounds[k + 1]]
  ];
  // Beats are handed over in order, each once. A chunk takes the beats whose
  // (running-maximum) time is before its watermark + the edge offset; the last
  // chunk takes the rest.
  final edgeSec = const [-30, 0, 30, 400][edgeIdx];
  final g = <int>[0];
  var mx = double.negativeInfinity;
  var at = 0;
  for (var k = 0; k < chunks; k++) {
    if (k == chunks - 1) {
      at = d.beats;
    } else {
      final edgeMs = (through[k] + edgeSec) * 1000.0;
      while (at < d.beats) {
        final run = math.max(mx, d.rrTs[at]);
        if (run >= edgeMs) break;
        mx = run;
        at++;
      }
    }
    g.add(at);
  }
  final wr = Rng(winSeed);
  final windows = [for (var k = 0; k < chunks; k++) _window(wr, d.n == 0 ? 1 : d.ts.last - _start)];
  return _Plan(d, bounds, through, g, windows, edgeSec, splits);
}

// ── folding ─────────────────────────────────────────────────────────────────

Uint8List? _foldChunk(_Day d, Uint8List? base, int a, int b, int through,
    int beatFrom, int beatTo, (int, int) win, MinuteBills? bills) {
  return foldDayCheckpoint(
    base: base,
    alreadyFolded: a,
    ts: d.ts.sublist(a, b),
    hr: d.hr.sublist(a, b),
    ax: d.ax.sublist(a, b),
    ay: d.ay.sublist(a, b),
    az: d.az.sublist(a, b),
    stepCounter: d.step.sublist(a, b),
    sleepOnsetSec: win.$1,
    sleepOffsetSec: win.$2,
    age: d.age,
    stepModulus: d.modulus,
    bills: bills,
    rrMs: d.rr.sublist(beatFrom, beatTo),
    rrTsMs: d.rrTs.sublist(beatFrom, beatTo),
    throughSec: through,
    quietCutG: d.cut,
  );
}

final Map<_DayR, Uint8List> _singleCache = {};

/// The whole day in one call, under no window (the bytes do not depend on it).
Uint8List _single(_Day d) => _singleCache.putIfAbsent(d.r, () {
      if (_singleCache.length > 300) _singleCache.clear();
      final blob =
          _foldChunk(d, null, 0, d.n, d.through, 0, d.beats, (0, 0), d.bills);
      if (blob == null) fail('${d.name}: the fold of the whole day was refused');
      return blob;
    });

/// What a chunked fold did: the blob after each accepted chunk, and the chunk
/// that was refused (-1: none).
class _Run {
  _Run(this.blobs, this.refusedAt);
  final List<Uint8List> blobs;
  final int refusedAt;
}

/// The bills handed over with chunk [k]. Only the last chunk's survive (they
/// replace the base's); the others alternate so a stale set would show.
MinuteBills? _billsOf(_Plan p, int k) =>
    k == p.chunks - 1 ? p.day.bills : (k.isOdd ? null : _bills(7));

_Run _runPlan(_Plan p) {
  final d = p.day;
  final blobs = <Uint8List>[];
  Uint8List? blob;
  for (var k = 0; k < p.chunks; k++) {
    final bills = _billsOf(p, k);
    blob = _foldChunk(d, blob, p.bounds[k], p.bounds[k + 1], p.through[k],
        p.g[k], p.g[k + 1], p.windows[k], bills);
    if (blob == null) return _Run(blobs, k);
    blobs.add(blob);
  }
  return _Run(blobs, -1);
}

/// The documented refusal, from the contract and not from the code under test:
/// a resumed fold whose curve state has never seen a beat keeps no rows, so the
/// first beats it is handed must not reach back before the first row handed
/// with them (day_curve_states.dart `continuesWith`; the rows of those seconds
/// went with a pass that kept none of them). -1: no chunk is refused.
int _modelRefusal(_Plan p) {
  final d = p.day;
  var touched = false;
  for (var k = 0; k < p.chunks; k++) {
    final nb = p.g[k + 1] - p.g[k];
    if (k > 0 && !touched && nb > 0) {
      final firstBeatSec = d.rrTs[p.g[k]] ~/ 1000;
      final firstRow = p.rowsOf(k) > 0 ? d.ts[p.bounds[k]] : null;
      if (firstRow == null || firstBeatSec < firstRow) return k;
    }
    if (nb > 0) touched = true;
  }
  return -1;
}

/// Whether the bytes of a chunked fold must equal the bytes of one fold. They
/// do unless a beatless prefix chunk dropped rows (they are never read, but a
/// single fold keeps those within 300 s of the newest beat).
bool _bytesCanonical(_Plan p) => p.day.beats == 0 || p.firstBeatChunk == 0;

DayResumeState _decode(Uint8List b, String why) {
  final s = decodeDayResumeState(b);
  if (s == null) fail('$why: the checkpoint did not decode');
  return s;
}

/// The bytes of each part of a state, in the order the blob writes them.
List<Uint8List> _partBytes(DayResumeState s) {
  Uint8List of(void Function(ResumeWriter) f) {
    final w = ResumeWriter();
    f(w);
    return w.takeBytes();
  }

  return [
    of(s.hrPipeline.write),
    of(s.hrActivity.write),
    of(s.motion.write),
    of(s.steps.write),
    of(s.dyn.write),
    of((w) {
      w.bool_(s.bills != null);
      s.bills?.write(w);
    }),
    of(s.rr.write),
    of(s.curves.write),
  ];
}

const _partNames = [
  'hrPipeline',
  'hrActivity',
  'motion',
  'steps',
  'dyn',
  'bills',
  'rr',
  'curves'
];

// ── the projection (L2) ─────────────────────────────────────────────────────

/// Windows the readers are asked under.
const List<(int, int)> _projWindows = [
  (0, 0),
  (_start + 100, _start + 900),
  (_start + 900, _start + 100),
];

/// What a reader can see of a state, as JSON text. EXCLUDES the work counters
/// (`processedSamples`, `retainedSamples`) and the argument-less window readers
/// (`wakeMinutes()`, `wakeHr`, `activeMinutes()`: their window is not stored and
/// a decoded state reads the default one). `dyn.minutes()` leaves out its three
/// NaN "not computed" fields.
String _project(DayResumeState s) {
  return jsonEncode({
    'folded': s.folded,
    'hrPipeline': _hrView(s.hrPipeline),
    'hrActivity': _hrView(s.hrActivity),
    'motion': {
      'len': s.motion.length,
      'curve': s.motion.activityCurve(),
      'runs': s.motion.wearRuns(),
      'active': [
        for (final w in _projWindows)
          s.motion.activeMinutesFor(sleepOnsetSec: w.$1, sleepOffsetSec: w.$2)
      ],
    },
    'steps': {'len': s.steps.length, 'steps': s.steps.steps},
    'dyn': {
      'len': s.dyn.length,
      'minutes': [
        for (final m in s.dyn.minutes()) [m.tsMinStartMs, m.nSamples, m.dynAmp]
      ],
    },
    'bills': s.bills?.toMetricsJson(),
    'rr': {
      'beats': s.rr.beats,
      'last': s.rr.lastTsMs,
      'screen': s.rr.irregular24hDetailedHeavy().toJson(),
    },
    'curves': {
      'cut': s.curves.cut,
      'pending': s.curves.pending,
      'untouched': s.curves.untouched,
      'hrv': s.curves.hrvCurve(),
      'resp': s.curves.respCurve(),
      'daytime': [
        for (final w in _projWindows)
          s.curves.daytimeHrv(onsetSec: w.$1, offsetSec: w.$2)
      ],
    },
  });
}

Map<String, Object?> _hrView(DayHrSummary h) => {
      'len': h.length,
      'stats': h.hrStats(),
      'wake': [
        for (final w in _projWindows)
          {
            'minutes': () {
              final m = h.wakeMinutesFor(sleepOnsetSec: w.$1, sleepOffsetSec: w.$2);
              return [m.keys, m.hr];
            }(),
            'hr': () {
              final m = h.wakeHrFor(sleepOnsetSec: w.$1, sleepOffsetSec: w.$2);
              return [m.count, m.sum];
            }(),
          }
      ],
    };

/// The state of the day folded in one piece IN MEMORY, never serialised.
DayResumeState _live(_Day d) {
  final s = DayResumeState(curves: DayCurveStates(cut: d.cut), bills: d.bills);
  final ok = s.appendTail(
    ts: d.ts,
    hr: d.hr,
    ax: d.ax,
    ay: d.ay,
    az: d.az,
    stepCounter: d.step,
    sleepOnsetSec: _start + 500,
    sleepOffsetSec: _start + 900,
    age: d.age,
    stepModulus: d.modulus,
  );
  expect(ok, isTrue, reason: 'the live fold of ${d.name}');
  s.rr.fold(d.rr, d.rrTs);
  expect(s.curves.fold(d.rr, d.rrTs, d.ts, d.ax, d.ay, d.az, d.through), isTrue);
  return s;
}

/// The same summaries brought up to date by `sync` (the engine's live ingest,
/// which re-reads the whole prefix) instead of `appendTail` (the resume path).
/// Two ways in, one state: they must read alike.
DayResumeState _synced(_Day d, DayResumeState live) {
  final s = DayResumeState(
      curves: live.curves, rr: live.rr, bills: d.bills);
  s.hrPipeline.sync(d.ts, d.hr,
      sleepOnsetSec: _start + 500, sleepOffsetSec: _start + 900, age: d.age);
  s.hrActivity.sync(d.ts, d.hr,
      sleepOnsetSec: _start + 500, sleepOffsetSec: _start + 900, age: d.age);
  s.motion.sync(d.ts, d.ax, d.ay, d.az,
      sleepOnsetSec: _start + 500, sleepOffsetSec: _start + 900);
  s.steps.sync(d.ts, d.step, modulus: d.modulus);
  s.dyn.sync(d.ts, d.hr, d.ax, d.ay, d.az);
  return s;
}

// ── the batch oracle (L1b) ──────────────────────────────────────────────────

/// How a persisted (rounded) figure can differ from the batch's while both are
/// within the tolerance: only across a rounding boundary of the six-place text.
bool _acrossRoundingBoundary(double a, double b) =>
    a != b &&
    (a * 1e6).round() != (b * 1e6).round() &&
    (a - b).abs() <= 1e-9 * math.max(1.0, b.abs());

/// The quiet-second cut the batch curves use for `gen4` (and `gen5`).
const double _familyCut = 0.02;

class _Oracle {
  int boundaryDiffs = 0;
}

final _Oracle _oracle = _Oracle();

void _close(double got, double want, String why, {double rel = 1e-9}) {
  final tol = rel * math.max(1.0, want.abs());
  if (!((got - want).abs() <= tol)) fail('$why: got $got want $want (tol $tol)');
}

/// The batch screen over the first [g] beats, as `deriveDayBundle` computes it
/// (correct, then screen with the corrector's counts), under the state's config.
ana.IrregularScreenResult _batchScreen(List<double> rr, List<double> ts,
    {double windowMinutes = 5,
    int minWindowBeats = 40,
    double sustainedFraction = 0.5,
    ana.RrCorrectionResult? corrected}) {
  final c = corrected ?? ana.correctRr(rr, rrTsMs: ts.isEmpty ? null : ts);
  return ana.irregularBeatScreenDetailed(
    c.nn,
    nnTimesMs: c.nnTimesMs,
    artifactFraction: (1.0 - c.cleanFraction).clamp(0.0, 1.0),
    windowMinutes: windowMinutes,
    minWindowBeats: minWindowBeats,
    sustainedFraction: sustainedFraction,
    cleaning: ana.RrCleaningCounts(
        raw: rr.length, corrected: c.correctedCount, dropped: c.droppedCount),
  );
}

/// Counts, flags, abstentions, notes and diagnostics exact; SD1 / SD2 / ratio
/// 1e-9 relative, confidence 1e-12 (the analytics tolerance).
void _sameScreen(ana.IrregularScreenResult got, ana.IrregularScreenResult want,
    String why) {
  final g = got.metric, w = want.metric;
  expect(g.present, w.present, reason: 'present $why');
  expect(g.note, w.note, reason: 'note $why');
  expect(g.tier, w.tier, reason: 'tier $why');
  expect(g.inputs_used, w.inputs_used, reason: 'inputs $why');
  expect(jsonEncode(got.diagnostics.toJson()), jsonEncode(want.diagnostics.toJson()),
      reason: 'diagnostics $why');
  if (!w.present) {
    expect(g.value, isNull, reason: 'absent => no value $why');
    expect(g.confidence, 0, reason: 'absent => confidence 0 $why');
    return;
  }
  final a = g.value!, b = w.value!;
  expect(a.flag, b.flag, reason: 'flag $why');
  expect(a.nBeats, b.nBeats, reason: 'nBeats $why');
  expect(a.pnnPct, b.pnnPct, reason: 'pnn $why');
  _close(a.sd1, b.sd1, 'sd1 $why');
  _close(a.sd2, b.sd2, 'sd2 $why');
  _close(a.sd1sd2, b.sd1sd2, 'sd1sd2 $why');
  _close(g.confidence, w.confidence, 'confidence $why', rel: 1e-12);
  // The persisted text rounds to six places: equal, unless a value sits within
  // the tolerance of a rounding boundary (documented, counted, never expected).
  final gt = jsonEncode(got.toJson()), wt = jsonEncode(want.toJson());
  if (gt != wt) {
    final across = _acrossRoundingBoundary(a.sd1, b.sd1) ||
        _acrossRoundingBoundary(a.sd2, b.sd2) ||
        _acrossRoundingBoundary(a.sd1sd2, b.sd1sd2) ||
        _acrossRoundingBoundary(g.confidence, w.confidence);
    if (!across) fail('persisted text differs away from a rounding boundary $why\n$gt\n$wt');
    _oracle.boundaryDiffs++;
  }
}

/// Everything the decoded state at a seam must read as the batch does over the
/// same prefix: [g] beats handed over, rows `[0, b)`.
void _expectSeam(_Day d, DayResumeState s, int g, int b, String why) {
  final rr = d.rr.sublist(0, g), ts = d.rrTs.sublist(0, g);
  expect(s.folded, b, reason: 'folded $why');
  expect(s.rr.beats, g, reason: 'beats $why');
  expect(s.rr.lastTsMs, g == 0 ? isNull : ts.last, reason: 'last beat time $why');
  _sameScreen(s.rr.irregular24hDetailedHeavy(), _batchScreen(rr, ts), 'screen $why');

  final acc = Accel(d.ts.sublist(0, b), d.ax.sublist(0, b), d.ay.sublist(0, b),
      d.az.sublist(0, b));
  // The HRV curve reads no accelerometer: every beat handed over.
  expect(curveText(s.curves.hrvCurve()),
      curveText(DerivationEngine.dayHrvCurve(substrateOf(Beats(rr, ts), acc))),
      reason: 'hrv curve $why');
  // The other two see what was handed over AND released: a beat whose second
  // the accelerometer has not closed waits, and is not in the oracle's prefix.
  final done = g - s.curves.pending;
  expect(done, greaterThanOrEqualTo(0), reason: 'pending is a suffix $why');
  // The batch reads the quiet cut of the device family (0.02 for gen4 / gen5,
  // the only calibration there is); a state folded under another cut has no
  // batch to equal, so the accelerometer-dependent oracles need the family's.
  if (d.cut == _familyCut) {
    final sub = substrateOf(
        Beats(d.rr.sublist(0, done), d.rrTs.sublist(0, done)), acc);
    expect(curveText(s.curves.respCurve()), curveText(DerivationEngine.dayRespCurve(sub)),
        reason: 'resp curve $why');
    for (final w in _projWindows.take(3)) {
      expect(jsonEncode(s.curves.daytimeHrv(onsetSec: w.$1, offsetSec: w.$2)),
          jsonEncode(DerivationEngine.daytimeHrv(sub, w.$1, w.$2)),
          reason: 'daytime hrv $why window $w');
    }
  }
  // The band's own step counter: the same fold, run once.
  final stepSub = Substrate(
        tsSec: d.ts.sublist(0, b),
        hr: List.filled(b, 70),
        rrTsMs: const [],
        rrMs: const [],
        ax: d.ax.sublist(0, b),
        ay: d.ay.sublist(0, b),
        az: d.az.sublist(0, b),
        spo2Red: List.filled(b, 1),
        spo2Ir: List.filled(b, 1),
        skinTemp: List.filled(b, 3000),
        skinContact: List.filled(b, 1),
        stepCount: d.step.sublist(0, b),
        deviceFamily: 'gen5',
      );
  expect(s.steps.steps,
      hardwareStepsFromCounter(stepSub, cumulativeCounterModulus: d.modulus),
      reason: 'steps $why');
  // Wear runs, from the contract in the batch (`_wearBlock`): a hole of more
  // than two minutes in the 1 Hz stream ends a run, which is [first, last + 1).
  final runs = <List<int>>[];
  if (b > 0) {
    var runStart = d.ts[0], prev = d.ts[0];
    for (var i = 1; i < b; i++) {
      if (d.ts[i] - prev > 120) {
        runs.add([runStart, prev + 1]);
        runStart = d.ts[i];
      }
      prev = d.ts[i];
    }
    runs.add([runStart, prev + 1]);
  }
  expect(s.motion.wearRuns(), runs, reason: 'wear runs $why');
  // The per-minute motion buckets: `enmoSeries`' minutes, bit for bit, for the
  // fields the app reads (test/day_dyn_minutes_test.dart).
  final want = ana.enmoSeries(<ana.AccelSample>[
    for (var i = 0; i < b; i++)
      ana.AccelSample(d.ts[i] * 1000.0, d.ax[i], d.ay[i], d.az[i],
          valid: d.hr[i] > 0 && stepSub.accelPresentAt(i)),
  ], expectedMinutes: 1440).minutes;
  final got = s.dyn.minutes();
  expect(got.length, want.length, reason: 'motion minutes $why');
  for (var i = 0; i < want.length; i++) {
    expect(
        [got[i].tsMinStartMs, got[i].nSamples, got[i].dynAmp],
        [want[i].tsMinStartMs, want[i].nSamples, want[i].dynAmp],
        reason: 'motion minute $i $why');
  }
}

// ── the registry and reach (as in the other law files) ──────────────────────

class _Reach<T> {
  const _Reach(this.shares, this.observe);

  /// Share of the default case count a situation must reach.
  final Map<String, double> shares;
  final void Function(T arg, void Function(String) bump) observe;
}

class _Registered {
  _Registered(this.name, this.cases, this.shares, this.measure);
  final String name;
  final int cases;
  final Map<String, double> shares;
  final Map<String, int> Function() measure;
}

final List<_Registered> _registry = [];

void _lawWith<T>(String name, Gen<T> gen, void Function(T) body,
    {required _Reach<T> reach, List<T> examples = const [], int cases = 30}) {
  _registry.add(_Registered(name, cases, reach.shares, () {
    final got = <String, int>{for (final k in reach.shares.keys) k: 0};
    final r = runProperty<T>(
      name: name,
      gen: gen,
      config: PropertyConfig(cases: cases, budget: const Duration(seconds: 60)),
      body: (v) => reach.observe(v, (k) => got[k] = (got[k] ?? 0) + 1),
    );
    if (!r.passed) fail(r.failure!.report);
    return got;
  }));
  forAll<T>(name, gen, body,
      examples: examples, cases: cases, genVersion: 'g1');
}

// ── forced scenarios ────────────────────────────────────────────────────────

_DayR _day(int flavour, int span, int beats,
        {int beatStart = 0,
        int seed = 5,
        int gaps = 0,
        int over = 0,
        int cfg = 0,
        int stride = 1}) =>
    ((flavour, span, beats, beatStart), (seed, gaps, over, cfg, stride));

/// Thin, present, artefact, flat, boundary: the scenarios every law always
/// meets (design 05 section 7 / manifest decision 13), with the chunking each
/// one is about.
final List<_Case> _forced = [
  (_day(1, 0, 0), (3, 1, 0, 1)), // no rows, no beats
  (_day(1, 600, 0), (3, 2, 0, 2)), // rows only, no beats: the curve state stays empty
  (_day(0, 600, 1), (2, 3, 0, 3)), // one beat
  (_day(0, 600, 2), (2, 4, 0, 4)), // two beats
  (_day(0, 900, 9), (3, 5, 0, 5)), // under 10 gated beats: no HRV curve
  (_day(0, 900, 10), (3, 6, 0, 6)), // exactly 10
  (_day(1, 1200, 59), (3, 7, 1, 7)), // under 60: no breathing curve
  (_day(1, 1200, 61), (3, 8, 1, 8)), // over 60
  (_day(0, 1800, 1700, cfg: 1), (1, 9, 1, 9)), // clean day, one seam
  (_day(1, 700, 420, seed: 11, gaps: 1, cfg: 3), (6, 10, 0, 10)), // mixed + row dropouts, six seams
  (_day(2, 1400, 1300, seed: 3, cfg: 1), (4, 11, 2, 11)), // flagged rhythm
  (_day(3, 600, 350, seed: 17, gaps: 1), (5, 12, 1, 12)), // dropouts in beats and rows
  (_day(4, 600, 350, seed: 81, cfg: 0), (5, 13, 1, 13)), // beat times step backwards
  (_day(5, 600, 400, seed: 9, cfg: 0), (4, 14, 0, 14)), // heavy artefacts, a 120-beat run
  (_day(1, 300, 600, seed: 21, over: 3), (5, 15, 3, 15)), // accelerometer 400 s behind: beats wait at the end
  (_day(1, 300, 600, seed: 23, over: 3), (4, 16, 2, 16)), // beats 30 s ahead of the rows
  (_day(1, 600, 350, seed: 29, cfg: 1), (3, -5, 0, 17)), // counter reset exactly on a seam
  (_day(1, 800, 300, beatStart: 450, seed: 31), (4, 18, 1, 18)), // beatless prefix
  (_day(1, 1100, 220, beatStart: 900, seed: 33, cfg: 3), (6, 19, 0, 19)), // longer prefix
  // DST-length days (23 h / 25 h): the fold is epoch-based, so the length of the
  // day shows only through sparse rows; the beats come late in the day.
  (_day(1, 82800, 250, beatStart: 79000, seed: 41, stride: 60), (4, 20, 1, 20)),
  (_day(1, 90000, 250, beatStart: 86000, seed: 43, stride: 60, cfg: 2), (4, 21, 1, 21)),
  (_day(1, 90000, 250, beatStart: 3000, seed: 47, stride: 60, cfg: 1), (3, 22, 0, 22)),
  (_day(1, 2800, 3000, seed: 51, cfg: 1), (6, 23, 1, 23)), // 3,000 beats, 6 seams
  // The documented refusal, found rather than hand-placed: the first beats of a
  // resumed fold reach back before the first row handed with them (a cut falls
  // inside the 30 s the beats trail the rows by).
  _refusalCase(splits: 2, cutSeed: -3),
  _refusalCase(splits: 4, cutSeed: 77, gaps: 1),
  // The edge of the refusal: the first beat falls in the very second of the
  // first row handed with it (accepted), not one second before (refused).
  _boundaryCase(),
  // The thresholds, exactly on them: the first HRV point needs 11 gated beats
  // (10 earlier ones to difference against), the breathing curve 60 gated beats.
  (_day(0, 900, 11, seed: 6), (2, 26, 0, 26)),
  (_day(0, 900, 60, seed: 7), (3, 27, 1, 27)),
  (_day(6, 600, 11, seed: 4), (2, 28, 0, 28)), // eleven beats, eight usable differences
  (_day(6, 600, 14, seed: 4), (2, 29, 1, 29)),
];

/// For the laws about the stored bytes (round trip, identity, refusal): every
/// thin day, and one day of each kind that puts something different into the
/// blob (row dropouts, beat times stepping backwards, pending beats, a beatless
/// prefix, a refused tail, the thresholds). The expensive days are left to the
/// chunking and oracle laws.
final List<_Case> _forcedCodec = [
  for (final i in const [0, 1, 2, 3, 4, 5, 6, 7, 9, 12, 14, 17, 23, 25, 26, 27, 28, 29])
    _forced[i]
];

/// For the tail entry: the codec's days, the flagged rhythm and an artefact run.
final List<_Case> _forcedT = [
  ..._forcedCodec,
  _forced[10],
  _forced[13],
];

/// For the conservation law: the thin days, one day of every flavour, the
/// flagged rhythm, a long artefact run, and the refusal (no long days).
final List<_Case> _forcedL5 = [
  for (final i in const [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 16, 17, 23, 26, 27, 28, 29])
    _forced[i]
];

/// For the chunking law: everything but the 1,700-beat day.
final List<_Case> _forcedL1 = [
  for (var i = 0; i < _forced.length; i++)
    if (i != 8) _forced[i]
];

/// For the batch oracle, whose cost grows with the beats: no long days, and the
/// 3,000-beat day stays with the chunking and conservation laws.
final List<_Case> _forcedForOracle = [
  for (var i = 0; i < _forced.length; i++)
    if (!const [19, 20, 21, 22].contains(i)) _forced[i]
];

_Case _boundaryCase() {
  for (var bs = 0; bs < 400; bs++) {
    for (var seed = 29; seed < 37; seed++) {
      final c = (_day(1, 600, 300, beatStart: bs, seed: seed), (2, -3, 0, 5));
      final p = _planOf(c);
      final k = p.firstBeatChunk;
      if (k > 0 &&
          _modelRefusal(p) < 0 &&
          _dayOf(c.$1).rrTs[p.g[k]] ~/ 1000 == _dayOf(c.$1).ts[p.bounds[k]]) {
        return c;
      }
    }
  }
  throw StateError('no boundary scenario found');
}

_Case _refusalCase({required int splits, required int cutSeed, int gaps = 0}) {
  for (var bs = 0; bs < 400; bs++) {
    for (var seed = 29; seed < 33; seed++) {
      // (Only a beat edge before the watermark can refuse: the engine's -30 s.)
      final c = (_day(1, 600, 300, beatStart: bs, seed: seed, gaps: gaps), (splits, cutSeed, 0, 5));
      if (_modelRefusal(_planOf(c)) >= 0) return c;
    }
  }
  throw StateError('no refusing scenario found: the generator no longer reaches the documented refusal');
}

// ── the registered laws ─────────────────────────────────────────────────────

/// Situations of a case, from the MODEL (cheap: no fold runs).
void _observeCase(_Case c, void Function(String) bump) {
  final d = _dayOf(c.$1);
  final p = _planOf(c);
  bump('flavour: ${_flavours[c.$1.$1.$1]}');
  if (d.beats == 0) bump('beats: none');
  if (d.beats > 0 && d.beats < 60) bump('beats: thin (under 60)');
  if (d.beats >= 60 && d.beats < 1000) bump('beats: 60 to 999');
  if (d.beats >= 1000) bump('beats: 1000 or more');
  if (d.n == 0) bump('rows: none');
  if (p.chunks >= 2) bump('chunks: two or more');
  if (p.chunks >= 4) bump('chunks: four or more');
  if (p.chunks >= 7) bump('chunks: seven');
  final refused = _modelRefusal(p);
  if (refused < 0 && d.beats > 0 && p.firstBeatChunk > 0) {
    bump('beatless prefix accepted');
  }
  if (refused < 0 && d.beats > 0 && p.firstBeatChunk == 0) {
    bump('first beats in the first chunk');
  }
  if (p.edgeSec > 0) bump('beats ahead of the rows');
  if (p.edgeSec < 0) bump('beats behind the rows');
  if (d.n > 0 && d.beats > 0 && d.rrTs.last ~/ 1000 >= d.through) {
    bump('beats pending at the end');
  }
  if (d.resetAt > 0 && p.bounds.contains(d.resetAt)) bump('counter reset on a seam');
  if (p.windows.any((w) => w.$2 < w.$1)) bump('window reversed');
  if (p.windows.map((w) => w).toSet().length > 1) bump('window moves between chunks');
  if (d.bills != null) bump('bills held');
  if (d.age == null) bump('age unknown');
  if (d.modulus == null) bump('no step modulus');
}

/// Shares of a law's default cases (need = max(1, floor(cases * share))), about
/// 60% of the smallest count measured over the laws that use them. A law whose
/// generated cases cannot reach a situation drops it and leaves it to the
/// forced scenarios (which every law runs; see the test that checks them).
const Map<String, double> _caseShares = {
  'flavour: clean': .05,
  'flavour: mixed': .05,
  'flavour: flagged': .05,
  'flavour: gappy': .05,
  'flavour: backwards': .05,
  'flavour: artefact runs': .05,
  'beats: none': .05,
  'beats: thin (under 60)': .05,
  'beats: 60 to 999': .3,
  'beats: 1000 or more': .05,
  'chunks: two or more': .3,
  'chunks: four or more': .15,
  'beatless prefix accepted': .05,
  'first beats in the first chunk': .4,
  'beats ahead of the rows': .3,
  'beats behind the rows': .12,
  'window reversed': .1,
  'window moves between chunks': .3,
  'bills held': .25,
  'age unknown': .12,
  'no step modulus': .05,
};

void _law(String name, void Function(_Case) body,
    {int cases = 8,
    List<_Case>? examples,
    Map<String, double> extra = const {},
    Set<String> drop = const {},
    int maxSplits = 6,
    void Function(_Case, void Function(String))? extraObserve}) {
  // A law about the stored bytes, not about how many seams led to them, clips
  // the chunking to keep itself cheap (the reach is counted on what it ran).
  _Case clip(_Case c) =>
      (c.$1, (math.min(c.$2.$1, maxSplits), c.$2.$2, c.$2.$3, c.$2.$4));
  _lawWith<_Case>(name, G.pair(_dayGen, _chunkGen), (c) => body(clip(c)),
      examples: examples ?? _forced,
      cases: cases,
      reach: _Reach<_Case>({
        for (final e in {..._caseShares, ...extra}.entries)
          if (!drop.contains(e.key)) e.key: e.value
      }, (c0, bump) {
        final c = clip(c0);
        _observeCase(c, bump);
        extraObserve?.call(c, bump);
      }));
}


/// The mutation kinds take turns with the case index, so a few cases meet them
/// all.
class _KindGen extends Gen<int> {
  @override
  int generate(Rng r, int size) => size % _mutNames.length;
  @override
  Iterable<int> shrink(int v) => G.intIn(0, _mutNames.length - 1).shrink(v);
}

// ── L3 mutations ────────────────────────────────────────────────────────────

/// (kind, a, b); see [_mutNames]. Every kind but 9 MUST be refused; 9 flips one
/// payload bit under a valid checksum, where a refusal is not required but a
/// partial read is forbidden.
typedef _Mut = (int, int, int);

const _mutNames = [
  'layout version',
  'magic',
  'truncated, re-signed',
  'truncated',
  'bit flipped',
  'padded, re-signed',
  'RR state tampered, re-signed',
  'version 1 screen state',
  'layout 3 as written',
  'payload bit flipped, re-signed',
  'parts disagree about the seconds folded',
];

Uint8List _resign(List<int> body) {
  final b = Uint8List.fromList(body);
  final out = Uint8List(b.length + 4)..setRange(0, b.length, b);
  ByteData.sublistView(out).setUint32(b.length, checksum32(b, b.length));
  return out;
}

int _indexOfSub(Uint8List hay, Uint8List needle) {
  outer:
  for (var i = hay.length - needle.length; i >= 0; i--) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// [blob] with its RR state's JSON changed by [edit] (the length field and the
/// checksum are rewritten, so only the content is wrong).
Uint8List _tamperRr(Uint8List blob, void Function(Map<String, dynamic> j) edit) {
  final s = _decode(blob, 'tamper');
  final rr = _partBytes(s)[6];
  final at = _indexOfSub(blob, rr);
  if (at < 0) fail('the RR part was not found in the blob');
  final head = 8 + (rr[8] == 1 ? 9 : 1); // beats, optional last time
  final text = utf8.decode(rr.sublist(head + 4));
  final j = jsonDecode(text) as Map<String, dynamic>;
  edit(j);
  final t = utf8.encode(jsonEncode(j));
  final len = ByteData(4)..setInt32(0, t.length);
  final newRr = [...rr.sublist(0, head), ...len.buffer.asUint8List(), ...t];
  return _resign([
    ...blob.sublist(0, at),
    ...newRr,
    ...blob.sublist(at + rr.length, blob.length - 4),
  ]);
}

/// The mutated blob, and whether it MUST be refused.
(Uint8List, bool) _mutate(Uint8List blob, _Mut m) {
  final (kind, a, b) = m;
  final body = Uint8List.sublistView(blob, 0, blob.length - 4);
  switch (kind) {
    case 0:
      const fmts = [0, 1, 2, 3, 5, kDayCheckpointFmt + 1, -1, 0x7fffffff];
      final x = Uint8List.fromList(body);
      ByteData.sublistView(x).setInt32(4, fmts[a % fmts.length]);
      return (_resign(x), true);
    case 1:
      final x = Uint8List.fromList(body);
      x[a % 4] ^= 1 << (b % 8);
      return (_resign(x), true);
    case 2:
      return (_resign(body.sublist(0, b % body.length)), true);
    case 3:
      return (Uint8List.sublistView(blob, 0, a % blob.length), true);
    case 4:
      final x = Uint8List.fromList(blob);
      x[b % x.length] ^= 1 << (a % 8);
      return (x, true);
    case 5:
      return (_resign([...body, ...List.filled(a % 7 + 1, 0)]), true);
    case 6:
      if (a % 6 == 5) {
        // The state's own beat count disagrees with its corrector's.
        final at = _indexOfSub(blob, _partBytes(_decode(blob, 'tamper'))[6]);
        final x = Uint8List.fromList(body);
        final bd = ByteData.sublistView(x);
        bd.setInt64(at, bd.getInt64(at) + 1);
        return (_resign(x), true);
      }
      return (
        _tamperRr(blob, (j) {
          final i = (j['i'] as Map).cast<String, dynamic>();
          switch (a % 6) {
            case 0:
              i['version'] = 1; // the layout-3 screen state: refused, not upgraded
            case 1:
              i['version'] = 1;
              i.remove('nIn'); // and as a version 1 really was
              i.remove('total');
            case 2:
              i['type'] = 'SomethingElse';
            case 3:
              final c = (j['c'] as Map).cast<String, dynamic>();
              c['n'] = (c['n'] as int) + 1; // the corrector disagrees about the beats
              j['c'] = c;
            default:
              (j['c'] as Map)['version'] = 99;
          }
          j['i'] = i;
        }),
        true
      );
    case 8:
      // A layout-3 blob as it was written: layout 3, the version 1 screen state.
      final old = _tamperRr(blob, (j) {
        final i = (j['i'] as Map).cast<String, dynamic>();
        i['version'] = 1;
        i.remove('nIn');
        i.remove('total');
        j['i'] = i;
      });
      final x = Uint8List.fromList(Uint8List.sublistView(old, 0, old.length - 4));
      ByteData.sublistView(x).setInt32(4, 3);
      return (_resign(x), true);
    case 10:
      // One part claims to have folded one second more than the others.
      final x = Uint8List.fromList(body);
      final bd = ByteData.sublistView(x);
      bd.setInt64(32, bd.getInt64(32) + 1);
      return (_resign(x), true);
    case 7:
      // The version 1 screen state alone under the current layout number.
      return (
        _tamperRr(blob, (j) {
          final i = (j['i'] as Map).cast<String, dynamic>();
          i['version'] = 1;
          i.remove('nIn');
          i.remove('total');
          j['i'] = i;
        }),
        true
      );
    default:
      final x = Uint8List.fromList(body);
      x[b % x.length] ^= 1 << (a % 8);
      return (_resign(x), false);
  }
}

// ── L5 configs ──────────────────────────────────────────────────────────────

/// (window minutes idx, min window beats idx, sustained fraction idx); index 0
/// of each is the production default.
typedef _RrCfg = (int, int, int);
const _wmOpts = [5.0, 1.0, 2.0, 10.0, 0.5, 0.0, -5.0];
const _mwbOpts = [40, 2, 10, 100, 1, 0, -3];
const _sfOpts = [0.5, 0.0, 1.0, 0.25, 1.5, -0.1];

bool _cfgValid(_RrCfg c) =>
    _wmOpts[c.$1] > 0 &&
    _mwbOpts[c.$2] >= 2 &&
    _sfOpts[c.$3] >= 0 &&
    _sfOpts[c.$3] <= 1;

class _RrCfgGen extends Gen<_RrCfg> {
  @override
  _RrCfg generate(Rng r, int size) {
    if (r.nextBool(.4)) return (0, 0, 0);
    return (r.nextInt(_wmOpts.length), r.nextInt(_mwbOpts.length), r.nextInt(_sfOpts.length));
  }

  @override
  Iterable<_RrCfg> shrink(_RrCfg v) sync* {
    if (v.$1 != 0) yield (0, v.$2, v.$3);
    if (v.$2 != 0) yield (v.$1, 0, v.$3);
    if (v.$3 != 0) yield (v.$1, v.$2, 0);
  }
}

/// A fresh `DayRrState` whose screen runs under [cfg]: the state keeps its
/// parameters in its checkpoint JSON, which is the only way in, so the config
/// goes through the real reader.
DayRrState _rrUnder(_RrCfg cfg) {
  final fresh = DayRrState();
  final w = ResumeWriter();
  fresh.write(w);
  final bytes = w.takeBytes();
  final head = 8 + (bytes[8] == 1 ? 9 : 1);
  final j = jsonDecode(utf8.decode(bytes.sublist(head + 4))) as Map<String, dynamic>;
  final i = (j['i'] as Map).cast<String, dynamic>();
  i['windowMinutes'] = _wmOpts[cfg.$1];
  i['minWindowBeats'] = _mwbOpts[cfg.$2];
  i['sustainedFraction'] = _sfOpts[cfg.$3];
  j['i'] = i;
  final t = utf8.encode(jsonEncode(j));
  final out = ResumeWriter()
    ..i64(0)
    ..optF64(null)
    ..i32(t.length)
    ..bytes(Uint8List.fromList(t), t.length);
  return DayRrState.read(ResumeReader(out.takeBytes()));
}

DayRrState _restartRr(DayRrState s) {
  final w = ResumeWriter();
  s.write(w);
  final r = ResumeReader(w.takeBytes());
  final back = DayRrState.read(r);
  expect(r.remaining, 0, reason: 'the reader consumed exactly what was written');
  return back;
}

/// Window sizes of the corrected series, partitioned by the contract's own
/// words (a window opens on its first clean beat and closes when a beat is a
/// full window later), independently of the streaming code.
({int total, int valid, int open, int kept}) _partition(
    List<double> nn, List<double> times, double windowMin, int minBeats) {
  final sizes = <int>[];
  double? start;
  var cur = 0, kept = 0;
  for (var i = 0; i < nn.length; i++) {
    if (!(nn[i] >= 300 && nn[i] <= 2000)) continue;
    kept++;
    start ??= times[i];
    if (times[i] - start >= windowMin * 60000) {
      sizes.add(cur);
      cur = 0;
      start = times[i];
    }
    cur++;
  }
  if (cur > 0) sizes.add(cur);
  expect(sizes.fold<int>(0, (a, b) => a + b), kept, reason: 'the windows cover the kept NN');
  return (
    total: sizes.length,
    valid: sizes.where((s) => s >= minBeats).length,
    open: sizes.isEmpty ? 0 : sizes.last,
    kept: kept,
  );
}

// ── the tail entry ──────────────────────────────────────────────────────────

const _inputs =
    WorkerInputs(nowEpochMs: _start * 1000, zoneId: 'UTC', localeTag: 'en');

List<double> _mono(List<double> ts) {
  var run = double.negativeInfinity;
  return [
    for (final t in ts) run = t > run ? t : run,
  ];
}

typedef _Tail = ({
  List<double> rr,
  List<double> ts,
  List<int> accTs,
  List<double> ax,
  List<double> ay,
  List<double> az,
});

/// The closure `DerivationEngine._foldTail` was before it became a registered
/// entry (day_tail_fold_test.dart `_inline`), run on this isolate over its own
/// decoded copy of the checkpoint.
Map<String, Object?>? _inline(
    DayRrState rr, DayCurveStates curves, _Tail t, int onset, int offset) {
  if (!curves.continuesWith(t.ts, t.accTs)) return null;
  rr.fold(t.rr, t.ts);
  if (!curves.fold(t.rr, t.ts, t.accTs, t.ax, t.ay, t.az, 1 << 60)) return null;
  return {
    'irregular': rr.irregular24hDetailedHeavy().toJson(),
    'hrv': curves.hrvCurve(),
    'resp': curves.respCurve(),
    'daytime': curves.daytimeHrv(onsetSec: onset, offsetSec: offset),
    'tailRr': t.rr,
    'tailTs': t.ts,
  };
}

Map<String, Object?> _fields(DayTailResult r) => {
      'irregular': r.irregular,
      'hrv': r.hrv,
      'resp': r.resp,
      'daytime': r.daytime,
      'tailRr': r.tailRr,
      'tailTs': r.tailTs,
    };

DayTailInput _tailInput(Uint8List cp, _Tail t, int onset, int offset) =>
    DayTailInput(
      checkpoint: cp,
      tailRr: t.rr,
      tailTs: t.ts,
      accTs: t.accTs,
      ax: t.ax,
      ay: t.ay,
      az: t.az,
      onsetSec: onset,
      offsetSec: offset,
    );

/// The persisted envelope against the batch's, leaf by leaf: exact, except the
/// four figures that come from running sums, which may differ by the rounding of
/// the six-place text.
void _sameEnvelope(Object? got, Object? want, String why, [String key = '']) {
  if (want is Map) {
    expect(got, isA<Map>(), reason: '$why $key');
    expect((got as Map).keys.toSet(), want.keys.toSet(), reason: '$why $key keys');
    for (final k in want.keys) {
      _sameEnvelope(got[k], want[k], why, '$key.$k');
    }
  } else if (want is List) {
    expect(got, isA<List>(), reason: '$why $key');
    expect((got as List).length, want.length, reason: '$why $key length');
    for (var i = 0; i < want.length; i++) {
      _sameEnvelope(got[i], want[i], why, '$key[$i]');
    }
  } else if (want is double &&
      got is double &&
      const ['.value.sd1', '.value.sd2', '.value.sd1sd2', '.confidence']
          .any(key.endsWith)) {
    if (got != want) {
      final tol = 1.000001e-6 + 1e-9 * want.abs();
      if (!((got - want).abs() <= tol)) fail('$why $key: got $got want $want');
      _oracle.boundaryDiffs++;
    }
  } else {
    expect(got, want, reason: '$why $key');
  }
}


final Map<_DayR, ana.IrregularScreenResult> _screenCache = {};
ana.IrregularScreenResult _screenOf(_Day d) =>
    _screenCache.putIfAbsent(d.r, () {
      if (_screenCache.length > 600) _screenCache.clear();
      return _batchScreen(d.rr, d.rrTs);
    });

/// The tail pass of a case, from the model alone (no fold).
({int hi, int boundary, int cpBeats, int tailBeats, bool refused}) _tailModel(_Case c) {
  final d = _dayOf(c.$1);
  final p = _planOf(c);
  final hi = p.bounds.length > 2 ? p.bounds[1] : d.n ~/ 2;
  final boundary = hi >= d.n ? d.through : d.ts[hi];
  final mono = _mono(d.rrTs);
  final edge = rrFoldEdgeMs(boundary);
  final cpBeats = mono.where((t) => t < edge).length;
  final tailBeats = d.beats - cpBeats;
  var refused = false;
  if (cpBeats == 0 && tailBeats > 0) {
    final first = mono[cpBeats] ~/ 1000;
    refused = hi >= d.n || first < d.ts[hi];
  }
  return (hi: hi, boundary: boundary, cpBeats: cpBeats, tailBeats: tailBeats, refused: refused);
}

void main() {
  group('L3 old or foreign blobs are refused whole', () {
    _lawWith<(_Case, _Mut)>(
      'L3 a mutated blob is refused whole by the codec, the fold and the tail '
      'entry',
      G.pair(G.pair(_dayGen, _chunkGen),
          G.triple(_KindGen(), G.intIn(0, 1 << 20), G.intIn(0, 1 << 20))),
      (arg) {
        final d = _dayOf(arg.$1.$1);
        final m = arg.$2;
        final tag = '${d.name} mutation=${_mutNames[m.$1]}(${m.$2},${m.$3})';
        final blob = _single(d);
        final (bad, must) = _mutate(blob, m);
        DayResumeState? got;
        try {
          got = decodeDayResumeState(bad);
        } catch (e) {
          fail('$tag: the decoder threw instead of refusing: $e');
        }
        if (!must) {
          // Not required to refuse (the checksum is valid), but never half read:
          // whatever reads, reads whole and is stable under re-encoding.
          if (got != null) {
            final again = decodeDayResumeState(encodeDayResumeState(got));
            expect(again, isNotNull, reason: '$tag: a state that read re-encodes');
            expect(_project(again!), _project(got), reason: '$tag: stable');
          }
          return;
        }
        expect(got, isNull, reason: '$tag: refused');
        expect(
            foldDayCheckpoint(
              base: bad,
              alreadyFolded: d.n,
              ts: const [],
              hr: const [],
              ax: const [],
              ay: const [],
              az: const [],
              stepCounter: const [],
              age: d.age,
              stepModulus: d.modulus,
              throughSec: d.through,
              quietCutG: d.cut,
            ),
            isNull,
            reason: '$tag: the fold writes nothing on top of it');
        expect(
            foldDayTailHeavy(
                _inputs,
                DayTailInput(
                  checkpoint: bad,
                  tailRr: const [],
                  tailTs: const [],
                  accTs: const [],
                  ax: const [],
                  ay: const [],
                  az: const [],
                  onsetSec: 0,
                  offsetSec: 0,
                )),
            isNull,
            reason: '$tag: the tail entry reads nothing from it');
      },
      examples: [
        for (var i = 0; i < _forcedCodec.length; i++)
          (_forcedCodec[i], (i % 11, 100 + 31 * i, 200 + 17 * i)),
        // Every kind on a day that has state in every part.
        for (var k = 0; k < 11; k++) (_forced[9], (k, 7 + k, 13 + 3 * k)),
        // The layout numbers: 0, 1, 2 (before RR), 3 (before the diagnostics), 5.
        for (var a = 0; a < 6; a++) (_forced[9], (0, a, 0)),
        // The RR state tampered in each of its shapes.
        for (var a = 0; a < 6; a++) (_forced[9], (6, a, 0)),
      ],
      cases: 16,
      reach: _Reach<(_Case, _Mut)>({
        for (var k = 0; k < 11; k++) 'kind: ${_mutNames[k]} $k': .02,
        'layout 3 or older': .1,
        'a day with beats': .5,
      }, (arg, bump) {
        final m = arg.$2;
        bump('kind: ${_mutNames[m.$1]} ${m.$1}');
        if ((m.$1 == 0 && m.$2 % 8 < 4) || m.$1 == 7 || m.$1 == 8) {
          bump('layout 3 or older');
        }
        if (_dayOf(arg.$1.$1).beats > 0) bump('a day with beats');
      }),
    );
  });

  group('L1 chunk invariance', () {
    _law('L1 any valid chunking gives the bytes of one fold; the documented '
        'refusal is a refusal', (c) {
      final d = _dayOf(c.$1);
      final p = _planOf(c);
      final tag = '${d.name} chunks=${p.bounds} g=${p.g} edge=${p.edgeSec}';
      // One fold of the whole day under no window; the chunks below each run
      // under their own (moving, sometimes reversed) window, so equal bytes
      // are also the proof that the window never reaches the stored state.
      final single = _single(d);
      final run = _runPlan(p);
      final model = _modelRefusal(p);
      expect(run.refusedAt, model,
          reason: '$tag: refused exactly where the contract says (-1: never)');
      if (model >= 0) return;
      final got = run.blobs.last;
      if (_bytesCanonical(p)) {
        expect(got, single, reason: '$tag: byte-identical');
        return;
      }
      // A beatless prefix chunk kept no rows (documented), so only the curve
      // state's stored rows can differ: every other part is byte-identical and
      // the curve state READS the same.
      final a = _partBytes(_decode(got, tag)), b = _partBytes(_decode(single, tag));
      for (var i = 0; i < a.length - 1; i++) {
        expect(a[i], b[i], reason: '$tag: part ${_partNames[i]} byte-identical');
      }
      final ga = _decode(got, tag).curves, gb = _decode(single, tag).curves;
      expect(ga.pending, gb.pending, reason: '$tag: pending');
      expect(curveText(ga.hrvCurve()), curveText(gb.hrvCurve()), reason: '$tag: hrv');
      expect(curveText(ga.respCurve()), curveText(gb.respCurve()), reason: '$tag: resp');
      for (final w in _projWindows) {
        expect(jsonEncode(ga.daytimeHrv(onsetSec: w.$1, offsetSec: w.$2)),
            jsonEncode(gb.daytimeHrv(onsetSec: w.$1, offsetSec: w.$2)),
            reason: '$tag: daytime $w');
      }
    }, examples: _forcedL1, drop: const {
      'beatless prefix accepted',
    }, extra: const {
      'beats pending at the end': .05,
    });
  });

  group('L1b resumed vs batch oracle', () {
    _law('L1b at a chunk seam the decoded state reads what the batch reads over '
        'the same prefix', (c) {
      final d = _dayOf(c.$1);
      final p = _planOf(c);
      final tag = '${d.name} chunks=${p.bounds} g=${p.g} edge=${p.edgeSec}';
      final run = _runPlan(p);
      expect(run.refusedAt, _modelRefusal(p), reason: tag);
      // The batch is the expensive side: the first, a pseudo-random middle and
      // the last seam (every seam is checked by the examples below).
      final k = run.blobs.length;
      final seams = <int>{
        k - 1,
        if (k > 1) Rng(c.$2.$2.abs() + 5).nextInt(k - 1),
      }..removeWhere((i) => i < 0);
      for (final i in seams) {
        _expectSeam(d, _decode(run.blobs[i], tag), p.g[i + 1], p.bounds[i + 1],
            '$tag seam $i');
      }
    }, cases: 6, examples: _forcedForOracle, drop: const {
      'beats: thin (under 60)',
    });

    test('the persisted text may differ from the batch only across a rounding '
        'boundary of its six places, and only within the tolerance', () {
      // The figures are running sums (about 1e-13 from the batch); the text is
      // round6. test/day_stream_state_test.dart header: "about one in 1e7 per
      // field". The classifier below is what _sameScreen applies.
      expect(_acrossRoundingBoundary(0.1234565 - 1e-13, 0.1234565 + 1e-13), isTrue);
      expect(_acrossRoundingBoundary(0.1234561, 0.1234569), isFalse,
          reason: 'outside the tolerance: a defect, not a boundary');
      expect(_acrossRoundingBoundary(0.12345649, 0.12345650), isFalse);
      expect(_acrossRoundingBoundary(0.5, 0.5), isFalse);
    });
  });

  group('L2 checkpoint round trip', () {
    _law('L2 write(read(b)) == b at every seam, and the decoded state reads '
        'what the live state reads', (c) {
      final d = _dayOf(c.$1);
      final p = _planOf(c);
      final tag = '${d.name} chunks=${p.bounds}';
      final run = _runPlan(p);
      expect(run.refusedAt, _modelRefusal(p), reason: tag);
      for (var i = 0; i < run.blobs.length; i++) {
        expect(encodeDayResumeState(_decode(run.blobs[i], tag)), run.blobs[i],
            reason: '$tag: canonical re-encode at seam $i');
      }
      // The live (never serialised) state against its own bytes and the fold's.
      final live = _live(d);
      final bytes = encodeDayResumeState(live);
      final back = _decode(bytes, tag);
      final want = _project(live);
      expect(_project(back), want, reason: '$tag: decoded == live on the projection');
      expect(encodeDayResumeState(back), bytes, reason: '$tag: canonical');
      expect(_project(_synced(d, live)), want,
          reason: '$tag: the sync path reads what the resume path reads');
      if (run.refusedAt < 0 && _bytesCanonical(p)) {
        expect(run.blobs.last, bytes,
            reason: '$tag: the fold path wrote the live state\'s bytes');
      }
    }, cases: 6, maxSplits: 1, examples: _forcedCodec, drop: const {
      'chunks: four or more',
      'beatless prefix accepted',
    });
  });

  group('L4 identity of an empty tail', () {
    _law('L4 an empty tail with the metadata, the bills and the watermark held '
        'fixed leaves the checkpoint unchanged', (c) {
      final d = _dayOf(c.$1);
      final p = _planOf(c);
      final tag = '${d.name} chunks=${p.bounds} g=${p.g}';
      final run = _runPlan(p);
      expect(run.refusedAt, _modelRefusal(p), reason: tag);
      // The last blob of the run, with the bills it was written with and the
      // seconds it folded.
      final k = run.blobs.length - 1;
      if (k >= 0) {
        final blob = run.blobs[k];
        Uint8List? again(Uint8List base,
                {int? through, (int, int) win = (0, 0)}) =>
            foldDayCheckpoint(
              base: base,
              alreadyFolded: p.bounds[k + 1],
              ts: const [],
              hr: const [],
              ax: const [],
              ay: const [],
              az: const [],
              stepCounter: const [],
              sleepOnsetSec: win.$1,
              sleepOffsetSec: win.$2,
              age: d.age,
              stepModulus: d.modulus,
              bills: _billsOf(p, k),
              rrMs: const [],
              rrTsMs: const [],
              throughSec: through,
              quietCutG: d.cut,
            );
        final once = again(blob, through: p.through[k], win: p.windows[k]);
        expect(once, blob, reason: '$tag seam $k: unchanged, whatever window');
        // Twice is once, and a watermark not restated changes nothing either.
        expect(again(once!, through: null, win: (_start + 9, _start - 9)), blob,
            reason: '$tag seam $k: idempotent');
      }
      // A day's first fold with nothing in it records the age and the counter
      // modulus it was asked under (so it is not the metadata-free empty
      // state); folding nothing again moves nothing.
      final empty = foldDayCheckpoint(
        base: null,
        alreadyFolded: 0,
        ts: const [],
        hr: const [],
        ax: const [],
        ay: const [],
        az: const [],
        stepCounter: const [],
        age: d.age,
        stepModulus: d.modulus,
        quietCutG: d.cut,
      );
      expect(empty, isNotNull, reason: tag);
      final emptyAgain = foldDayCheckpoint(
        base: empty,
        alreadyFolded: 0,
        ts: const [],
        hr: const [],
        ax: const [],
        ay: const [],
        az: const [],
        stepCounter: const [],
        age: d.age,
        stepModulus: d.modulus,
        quietCutG: d.cut,
      );
      expect(emptyAgain, empty, reason: '$tag: an empty fold of an empty fold');
      expect(_decode(empty!, tag).folded, 0, reason: tag);
      expect(_decode(empty, tag).curves.untouched, isTrue, reason: tag);
    }, cases: 6, maxSplits: 1, examples: _forcedCodec, drop: const {
      'chunks: four or more',
      'beatless prefix accepted',
      'beats: none',
      'beats: thin (under 60)',
    });
  });

  group('L4 refusals and bills', () {
    // A refusal does not depend on the size of the state, and the config space
    // is five values: every config, on a small day, is cheaper and stronger than
    // a draw per generated case.
    for (var cfg = 0; cfg < _cfgs.length; cfg++) {
      test('config $cfg: the same empty call with one thing changed is refused, '
          'and no bills drops them', () {
        final small = _dayOf(_day(1, 300, 150, seed: 3, cfg: cfg));
        final base = _single(small);
        final folded = small.n;
        Uint8List? tweaked(
                {int? foldedClaim, int? age, int? modulus, double? cut}) =>
            foldDayCheckpoint(
              base: base,
              alreadyFolded: foldedClaim ?? folded,
              ts: const [],
              hr: const [],
              ax: const [],
              ay: const [],
              az: const [],
              stepCounter: const [],
              age: age ?? small.age,
              stepModulus: modulus ?? small.modulus,
              bills: small.bills,
              throughSec: small.through,
              quietCutG: cut ?? small.cut,
            );
        // The contrapositive of the identity: the same empty call with one
        // thing changed is a refusal (nothing written), never a fold on top of
        // a state made under other rules (documented refusals: another age,
        // counter modulus, quiet cut, or a base that did not fold exactly the
        // seconds claimed).
        expect(tweaked(), base, reason: 'the untouched call is the identity');
        expect(tweaked(foldedClaim: folded + 1), isNull, reason: 'one second more');
        expect(tweaked(foldedClaim: folded - 1), isNull, reason: 'one second less');
        expect(tweaked(age: (small.age ?? 30) + 1), isNull, reason: 'another age');
        expect(tweaked(modulus: (small.modulus ?? 1000) + 1), isNull,
            reason: 'another counter modulus');
        expect(tweaked(cut: small.cut + 0.01), isNull, reason: 'another quiet cut');
        // The bills are the one input the state does not hold: handing none
        // drops them (documented), and nothing else moves.
        if (small.bills != null) {
          final dropped = foldDayCheckpoint(
            base: base,
            alreadyFolded: folded,
            ts: const [],
            hr: const [],
            ax: const [],
            ay: const [],
            az: const [],
            stepCounter: const [],
            age: small.age,
            stepModulus: small.modulus,
            bills: null,
            throughSec: small.through,
            quietCutG: small.cut,
          );
          expect(dropped, isNotNull);
          final a = _partBytes(_decode(dropped!, 'bills')),
              b = _partBytes(_decode(base, 'bills'));
          for (var i = 0; i < a.length; i++) {
            if (i == 5) continue;
            expect(a[i], b[i], reason: '${_partNames[i]} unmoved');
          }
          expect(_decode(dropped, 'bills').bills, isNull, reason: 'bills dropped');
        }
      });
    }
  });

  group('L5 conservation in the integrated corrector + screen', () {
    _lawWith<(_Case, _RrCfg)>(
      'L5 nn_in == rr_raw - dropped; the windows cover the kept NN; flagged <= '
      'valid <= total; an invalid window config gives no window evidence',
      G.pair(G.pair(_dayGen, _chunkGen), _RrCfgGen()),
      (arg) {
        final d = _dayOf(arg.$1.$1);
        final p = _planOf(arg.$1);
        final cfg = arg.$2;
        final tag = '${d.name} beats cuts=${p.g} cfg=$cfg';
        final wm = _wmOpts[cfg.$1], mwb = _mwbOpts[cfg.$2], sf = _sfOpts[cfg.$3];
        var st = _rrUnder(cfg);
        for (var k = 0; k < p.chunks; k++) {
          st.fold(d.rr.sublist(p.g[k], p.g[k + 1]), d.rrTs.sublist(p.g[k], p.g[k + 1]));
          st = _restartRr(st);
          final g = p.g[k + 1];
          // Every seam of a short day; every other seam, and the last, of a long one.
          if (g > 1200 && k.isOdd && k != p.chunks - 1) continue;
          final why = '$tag at $g beats';
          final res = st.irregular24hDetailedHeavy();
          final dg = res.diagnostics;
          final rr = d.rr.sublist(0, g), ts = d.rrTs.sublist(0, g);
          final cor = ana.correctRr(rr, rrTsMs: g == 0 ? null : ts);
          // beats in, beats out
          expect(dg.rrRaw, g, reason: 'rr_raw $why');
          expect(dg.dropped, cor.droppedCount, reason: 'dropped $why');
          expect(dg.corrected, cor.correctedCount, reason: 'corrected $why');
          expect(dg.nnIn, g - dg.dropped!, reason: 'nn_in == rr_raw - dropped $why');
          expect(cor.nn.length, g - cor.droppedCount, reason: 'the batch conserves too $why');
          expect(dg.corrected! <= g && dg.dropped! <= g, isTrue, reason: why);
          expect(dg.nnKept <= dg.nnIn, isTrue, reason: 'kept <= in $why');
          // the artefact share is a share of something, or absent
          if (g == 0) {
            expect(dg.artifactFraction, isNull, reason: 'a share of no beats $why');
          } else {
            expect(dg.artifactFraction, (1.0 - cor.cleanFraction).clamp(0.0, 1.0),
                reason: 'artifact fraction $why');
          }
          // the verdict and its evidence agree
          final m = res.metric;
          expect(m.present, dg.abstain == null, reason: 'present <=> not abstained $why');
          if (m.present) {
            expect(m.value!.nBeats, dg.nnKept, reason: 'nBeats == nn_kept $why');
            expect(dg.nnKept >= dg.thresholds.minBeats, isTrue, reason: 'min beats $why');
          }
          if (dg.abstain == ana.IrregularAbstain.tooFewBeats) {
            expect(dg.nnKept < dg.thresholds.minBeats, isTrue, reason: why);
          }
          if (dg.abstain == ana.IrregularAbstain.artifact) {
            expect(dg.artifactFraction! > dg.thresholds.maxArtifact, isTrue, reason: why);
          }
          // windows
          final w = dg.windows;
          if (!_cfgValid(cfg)) {
            expect(w, isNull, reason: 'an invalid config gives no window evidence $why');
            if (m.present) {
              expect(m.value!.flag, isFalse, reason: 'and cannot flag $why');
            }
          } else {
            expect(w, isNotNull, reason: 'a valid config counts windows $why');
            final part = _partition(cor.nn, cor.nnTimesMs, wm, mwb);
            expect(dg.nnKept, part.kept, reason: 'kept NN $why');
            expect(w!.total, part.total, reason: 'windows total $why');
            expect(w.valid, part.valid, reason: 'windows valid $why');
            expect(w.openBeats, part.open, reason: 'open window beats $why');
            expect(w.flagged >= 0 && w.flagged <= w.valid && w.valid <= w.total, isTrue,
                reason: 'flagged <= valid <= total $why');
            expect(w.total <= dg.nnKept, isTrue, reason: 'total <= kept $why');
            expect(w.valid * mwb <= dg.nnKept, isTrue, reason: 'valid windows are full $why');
            expect(w.total == 0, dg.nnKept == 0, reason: 'no windows <=> no kept NN $why');
            expect(w.openBeats <= dg.nnKept, isTrue, reason: why);
            expect(
                w.open,
                w.openBeats == 0
                    ? ana.IrregularOpenWindow.none
                    : w.openBeats < mwb
                        ? ana.IrregularOpenWindow.thin
                        : anyOf(ana.IrregularOpenWindow.flagged,
                            ana.IrregularOpenWindow.unflagged),
                reason: 'open window label $why');
            if (m.present && m.value!.flag) {
              expect(w.valid > 0 && w.flagged >= sf * w.valid, isTrue,
                  reason: 'a flag is backed by enough flagged windows $why');
            }
          }
          // and the whole envelope is the batch's
          _sameScreen(res,
              _batchScreen(rr, ts,
                  windowMinutes: wm,
                  minWindowBeats: mwb,
                  sustainedFraction: sf,
                  corrected: cor),
              why);
        }
      },
      examples: [
        for (var i = 0; i < _forcedL5.length; i++)
          (
            _forcedL5[i],
            (
              i % 4 == 0 ? (i ~/ 4) % 7 : 0,
              i % 3 == 0 ? (i ~/ 3) % 7 : 0,
              i % 5 == 0 ? (i ~/ 5) % 6 : 0
            )
          ),
        (_forced[10], (0, 0, 0)), // the flagged day under the default config
        (_forced[10], (5, 0, 0)), // window length 0: fails closed
        (_forced[10], (0, 5, 0)), // min window beats 0
        (_forced[10], (0, 0, 4)), // sustained fraction 1.5
        (_forced[8], (4, 1, 3)), // short windows, two-beat minimum
      ],
      cases: 8,
      reach: _Reach<(_Case, _RrCfg)>({
        'config: default': .15,
        'config: valid, not default': .15,
        'config: invalid': .15,
        'beats: none': .05,
        'beats: thin (under 60)': .05,
        'beats: 1000 or more': .1,
        'screen flags': .05,
        'screen abstains': .3,
        'chunks: four or more': .25,
      }, (arg, bump) {
        final d = _dayOf(arg.$1.$1);
        final cfg = arg.$2;
        if (cfg == (0, 0, 0)) bump('config: default');
        if (cfg != (0, 0, 0) && _cfgValid(cfg)) bump('config: valid, not default');
        if (!_cfgValid(cfg)) bump('config: invalid');
        if (d.beats == 0) bump('beats: none');
        if (d.beats > 0 && d.beats < 60) bump('beats: thin (under 60)');
        if (d.beats >= 1000) bump('beats: 1000 or more');
        if (_planOf(arg.$1).chunks >= 4) bump('chunks: four or more');
        final scr = _screenOf(d).metric;
        if (scr.present && scr.value!.flag) bump('screen flags');
        if (!scr.present) bump('screen abstains');
      }),
    );
  });

  group('T the registered tail entry', () {
    _law('T foldDayTailHeavy equals the in-isolate fold and the batch over the '
        'whole day', (c) {
      final d = _dayOf(c.$1);
      final p = _planOf(c);
      final m = _tailModel(c);
      final tag = '${d.name} boundary=${m.boundary} rows=${m.hi}';
      final mono = _mono(d.rrTs); // the engine's beat axis is non-decreasing
      final edge = rrFoldEdgeMs(m.boundary);
      final cpRr = <double>[], cpTs = <double>[];
      for (var i = 0; i < d.beats; i++) {
        if (mono[i] < edge) {
          cpRr.add(d.rr[i]);
          cpTs.add(mono[i]);
        }
      }
      final cp = foldDayCheckpoint(
        base: null,
        alreadyFolded: 0,
        ts: d.ts.sublist(0, m.hi),
        hr: d.hr.sublist(0, m.hi),
        ax: d.ax.sublist(0, m.hi),
        ay: d.ay.sublist(0, m.hi),
        az: d.az.sublist(0, m.hi),
        stepCounter: d.step.sublist(0, m.hi),
        age: d.age,
        stepModulus: d.modulus,
        bills: d.bills,
        rrMs: cpRr,
        rrTsMs: cpTs,
        throughSec: m.boundary,
        quietCutG: d.cut,
      );
      expect(cp, isNotNull, reason: '$tag: the checkpoint fold');
      final resumed = _decode(cp!, tag);
      final tail = rrTailBeats(d.rr, mono, floorMs: resumed.rr.lastTsMs, edgeMs: edge);
      expect(tail.rrMs.length, m.tailBeats, reason: '$tag: each beat once');
      final from = resumed.folded;
      final t = (
        rr: tail.rrMs,
        ts: tail.rrTsMs,
        accTs: d.ts.sublist(from),
        ax: d.ax.sublist(from),
        ay: d.ay.sublist(from),
        az: d.az.sublist(from),
      );
      final (onset, offset) = p.windows[0];
      final before = Uint8List.fromList(cp);
      final input = _tailInput(cp, t, onset, offset);
      final got = foldDayTailHeavy(_inputs, input);
      final dec = _decode(cp, tag);
      final want = _inline(dec.rr, dec.curves, t, onset, offset);
      expect(got == null, want == null,
          reason: '$tag: the entry refuses exactly when the inline fold does');
      expect(got == null, m.refused,
          reason: '$tag: and exactly when the tail reaches behind rows the '
              'checkpoint never kept');
      expect(cp, before, reason: '$tag: the caller\'s bytes are untouched');
      if (got == null) return;
      expect(jsonEncode(_fields(got)), jsonEncode(want), reason: '$tag: parity');
      expect(jsonEncode(_fields(foldDayTailHeavy(_inputs, input)!)), jsonEncode(want),
          reason: '$tag: deterministic');
      // And both are the batch over the whole day.
      final sub = substrateOf(Beats(d.rr, mono), d.accel);
      expect(curveText(got.hrv), curveText(DerivationEngine.dayHrvCurve(sub)),
          reason: '$tag: hrv vs batch');
      if (d.cut == _familyCut) {
        // (A cut other than the family's has no batch to equal.)
        expect(curveText(got.resp), curveText(DerivationEngine.dayRespCurve(sub)),
            reason: '$tag: resp vs batch');
        expect(jsonEncode(got.daytime),
            jsonEncode(DerivationEngine.daytimeHrv(sub, onset, offset)),
            reason: '$tag: daytime vs batch');
      }
      _sameEnvelope(got.irregular, _batchScreen(d.rr, mono).toJson(), '$tag: screen');
      expect(got.tailRr, tail.rrMs);
      expect(got.tailTs, tail.rrTsMs);
    }, extra: const {
      'tail: refused': .05,
      'tail: beats in the tail': .4,
      'tail: beats in the checkpoint': .35,
    }, extraObserve: (c, bump) {
      final m = _tailModel(c);
      if (m.refused) bump('tail: refused');
      if (m.tailBeats > 0) bump('tail: beats in the tail');
      if (m.cpBeats > 0) bump('tail: beats in the checkpoint');
    }, cases: 8, examples: _forcedT, drop: const {
      'beats: thin (under 60)',
    });
  });

  group('L1 the one place chunking can show in the bytes', () {
    test('a beatless prefix drops rows no reader reads: the bytes differ, every '
        'other part is identical and the curve state reads the same', () {
      // The curve state keeps no rows before its first beat (a day's beatless
      // stretch costs no bytes, day_curve_states.dart `fold`). One fold keeps
      // the rows within 300 s of the newest beat, so when the beats span less
      // than that and a chunk boundary falls before them, the stored rows
      // differ. The law (L1) therefore asks for equal bytes only when the first
      // beats are in the first chunk and equal READS otherwise. If this
      // scenario stops differing, the code became canonical: ask L1 for equal
      // bytes always.
      var found = 0;
      for (var bs = 350; bs < 750 && found == 0; bs += 25) {
        for (final cutSeed in [3, 4, 5, 6]) {
          final c = (_day(1, 900, 100, beatStart: bs, seed: 7), (2, cutSeed, 0, 5));
          final p = _planOf(c);
          if (_modelRefusal(p) >= 0 || p.firstBeatChunk <= 0) continue;
          final got = _runPlan(p).blobs.last, single = _single(p.day);
          if (got.length == single.length &&
              List.generate(got.length, (i) => got[i] == single[i]).every((x) => x)) {
            continue;
          }
          found++;
          final a = _partBytes(_decode(got, 'dead rows')),
              b = _partBytes(_decode(single, 'dead rows'));
          for (var i = 0; i < a.length - 1; i++) {
            expect(a[i], b[i], reason: _partNames[i]);
          }
          expect(_project(_decode(got, 'dead rows')),
              _project(_decode(single, 'dead rows')),
              reason: 'the curve state reads the same');
          break;
        }
      }
      expect(found, greaterThan(0),
          reason: 'no chunking of a short beat span after a beatless prefix '
              'changed the stored bytes');
    });
  });

  group('the forced scenarios say what they claim', () {
    test('thin, flagged, backwards, artefact run, pending beats, a beatless '
        'prefix, the documented refusal, a reset on a seam, 23 h / 25 h days',
        () {
      bool any(bool Function(_Day d, _Plan p) f) =>
          _forced.any((c) => f(_dayOf(c.$1), _planOf(c)));
      for (final n in [0, 1, 2, 9, 10, 59, 61]) {
        expect(any((d, p) => d.beats == n), isTrue, reason: '$n beats');
      }
      expect(any((d, p) => d.beats > 0 && _screenOf(d).metric.present && _screenOf(d).metric.value!.flag),
          isTrue,
          reason: 'a day whose screen flags');
      expect(
          any((d, p) {
            if (_flavours[d.r.$1.$1] != 'backwards') return false;
            for (var i = 1; i < d.beats; i++) {
              if (d.rrTs[i] < d.rrTs[i - 1]) return true;
            }
            return false;
          }),
          isTrue,
          reason: 'beat times that step backwards');
      expect(
          any((d, p) =>
              _flavours[d.r.$1.$1] == 'artefact runs' &&
              ana.correctRr(d.rr, rrTsMs: d.rrTs).droppedCount >= 20),
          isTrue,
          reason: 'an artefact run longer than the corrector window (a run is '
              'dropped, not corrected)');
      expect(any((d, p) => d.beats > 0 && d.rrTs.last ~/ 1000 >= d.through),
          isTrue,
          reason: 'beats still waiting for the accelerometer at the end');
      expect(any((d, p) => _modelRefusal(p) >= 0), isTrue,
          reason: 'the documented refusal');
      expect(
          any((d, p) => d.beats > 0 && _modelRefusal(p) < 0 && p.firstBeatChunk > 0),
          isTrue,
          reason: 'a beatless prefix that is accepted');
      expect(
          any((d, p) =>
              p.firstBeatChunk > 0 &&
              _modelRefusal(p) < 0 &&
              d.rrTs[p.g[p.firstBeatChunk]] ~/ 1000 == d.ts[p.bounds[p.firstBeatChunk]]),
          isTrue,
          reason: 'the first beat in the very second of its chunk\'s first row');
      expect(any((d, p) => d.resetAt > 0 && p.bounds.contains(d.resetAt)), isTrue,
          reason: 'a counter reset exactly on a chunk seam');
      expect(any((d, p) => d.n > 100 && d.ts.last - d.ts.first >= 82800 - 100), isTrue,
          reason: 'a 23 h day');
      expect(any((d, p) => d.n > 100 && d.ts.last - d.ts.first >= 90000 - 100), isTrue,
          reason: 'a 25 h day');
      expect(any((d, p) => d.n == 0), isTrue, reason: 'no rows at all');
      expect(any((d, p) => d.age == null), isTrue);
      expect(any((d, p) => d.modulus == null), isTrue);
      expect(any((d, p) => d.cut != _familyCut), isTrue);
    });
  });

  group('generator reach', () {
    test('every law sees every situation in its default cases', () {
      expect(_registry, isNotEmpty);
      final weak = <String>[];
      for (final law in _registry) {
        final got = law.measure();
        if (Platform.environment.containsKey('PROPERTY_REACH_REPORT')) {
          // To retune the shares after a generator change.
          // ignore: avoid_print
          print('REACH ${law.name.split(' ').first}/${law.cases} cases: '
              '${got.entries.map((e) => "${e.key}=${e.value}").join("; ")}');
        }
        for (final e in law.shares.entries) {
          final need = math.max(1, (law.cases * e.value).floor());
          if (got[e.key]! < need) {
            weak.add('"${law.name}": ${e.key} in ${got[e.key]} of ${law.cases} '
                'cases, need $need');
          }
        }
      }
      expect(weak, isEmpty, reason: weak.join('\n'));
    });
  });
  // Exhaustive over a small grid rather than generated: the contract is a
  // single inequality, so every boundary can be visited. Without the bound a
  // corrupt count would allocate before the read fails (Sol C2 r1 P1).
  test('ResumeReader.count accepts a length exactly when it fits the unread bytes', () {
    const hostile = [-1, -0x80000000, 0x7fffffff, 1 << 20, 1 << 30];
    for (var per = 1; per <= 9; per++) {
      for (var left = 0; left <= 40; left++) {
        final fit = left ~/ per;
        for (final n in {0, fit - 1, fit, fit + 1, ...hostile}) {
          final w = ResumeWriter()..i32(n);
          w.bytes(Uint8List(left), left);
          final r = ResumeReader(w.takeBytes());
          final ok = n >= 0 && n * per <= left;
          final tag = 'per=$per left=$left n=$n';
          if (ok) {
            expect(r.count(per), n, reason: tag);
          } else {
            expect(() => r.count(per), throwsFormatException, reason: tag);
          }
        }
      }
    }
  });
  // Last in the file on purpose: it reads what every comparison above counted.
  test('persisted-text rounding-boundary cases stay rare', () {
    // Each persisted figure can differ from the batch's only across a rounding
    // boundary (about one in 1e7 per field), so over a few thousand comparisons
    // the expected count is zero; a handful would mean the text drifts for a
    // reason other than the running sums.
    expect(_oracle.boundaryDiffs, lessThanOrEqualTo(2));
  });
}
