// LAWS of the sample codec and its worker entries (design 05, pilot cluster
// C1b): lib/data/sample_codec.dart (`SampleCodec.encode / decode / summary /
// restrict`) and lib/data/sample_heavy.dart (the three registered entries,
// called in-process).
//
// The laws are stated per MODE (Rev 3 section 2, refined by section 7):
//   Q   quantized: every valid slot within step/2 of the input
//   B   adaptive / staticBlocks: per-slot error <= maxAbs, aggregate rms <= maxRms
//   LQ  losslessAtQuantum: decode == round(x / q) * q, exactly
//   PO  pyramidOnly: decode is refused (asserted), the summary remains
//   G   gaps: decode is null exactly where the input is null (every mode that
//       holds samples); the valid runs are the input's runs
//   D   encode is deterministic (byte-identical)
//   S   summary: counts exact; min / max / mean are the true values rounded to
//       the summary quantum
//   Ca-Ce  carve (`restrict`): v1 refused; nothing kept -> null; slot nullness;
//       summary cells re-rounded, dropped minutes empty; samples by mode
//   W   worker entries: NaN becomes absent; the mode map decides the mode (a
//       missing mode is pyramidOnly); parts overlay at their absolute origins,
//       later parts win where both hold a sample
//
// These describe the CURRENT behaviour (edge c4a43260). A law that fails is
// first checked against the module's contract (the header of sample_codec.dart,
// the existing tests); only a violation of the intended contract is a bug, and
// a wrong oracle is fixed here, never in lib/.
//
// Signals are drawn from the real specs (hr, ax/ay/az, skin_temp_c) as a small
// RECIPE (signal, length, shape, grid, gaps, seed) that is expanded into samples
// deterministically, so a failing input shrinks to a short readable recipe and
// not to a list of thousands of doubles. Lengths are capped at 7,200 slots
// (2 h); each property also runs forced scenarios (empty, thin, flat, on-grid,
// rounding ties, extreme values, all-null, gappy) and THREE forced full-day
// series (86,400 slots). The per-property budget is the harness's 2 s.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sample_codec.dart';
import 'package:openstrap_edge/data/sample_heavy.dart';

import '../support/property.dart';
import '../support/sample_heavy_fixtures.dart' show sampleHeavyInputs;
import '../support/sample_v1_blobs.dart';

// ── the recipe of a signal ──────────────────────────────────────────────────

const _signals = ['hr', 'ax', 'ay', 'az', 'skin_temp_c'];
const _lenMult = [1, 1, 1, 2, 4];
const _shapeNames = [
  'flat',
  'smooth',
  'steps',
  'noise',
  'spike',
  'jitter',
  'extremes'
];

/// ((signal, lenBase, lenMult, shape), (grid, gapKind, gapDensity, seed)).
///  * length = lenBase * lenMult;
///  * grid: 0 raw (off-grid), 1 on the summary quantum, 2 on rounding ties
///    ((k + .5) q), 3 on the sample step (quantized grid, else the quantum);
///  * gapKind: 0 none, 1 random runs, 2 one big gap, 3 all absent, 4 whole
///    minutes absent, 5 isolated seconds absent.
typedef _Sig = ((int, int, int, int), (int, int, double, int));

/// Lengths in seconds: mostly spread over 0-1800, with the small cases that
/// matter (one slot, a few, either side of a minute) drawn on purpose.
class _LenGen extends Gen<int> {
  static const _pool = [1, 1, 2, 2, 3, 59, 60, 61, 119, 120, 121, 599, 600, 601];
  static final Gen<int> _base = G.intIn(0, 1800);
  @override
  int generate(Rng r, int size) =>
      r.nextBool(.25) ? _pool[r.nextInt(_pool.length)] : _base.generate(r, size);
  @override
  Iterable<int> shrink(int v) => _base.shrink(v);
}

final Gen<_Sig> _sigGen = G.pair(
  G.quad(G.intIn(0, 4), _LenGen(), G.elements(_lenMult), G.intIn(0, 6)),
  G.quad(G.intIn(0, 3), G.intIn(0, 5), G.doubleIn(0, 1, boundaries: const [0, 1]),
      G.intIn(0, 1 << 30)),
);

_Sig _sig(
  int signal,
  int len, {
  int shape = 1,
  int grid = 0,
  int gaps = 0,
  double density = .3,
  int seed = 1,
}) =>
    ((signal, len, 1, shape), (grid, gaps, density, seed));

/// The signal a case really uses: `quantized` needs a sample step, which the
/// accelerometer axes do not have, so they fall back to hr there.
String _signalFor(_Sig s, SampleMode mode) {
  final name = _signals[s.$1.$1];
  return mode == SampleMode.quantized && SampleCodec.specs[name]!.step == null
      ? 'hr'
      : name;
}

List<double?> _samples(String signal, _Sig s) {
  final ((_, base, mult, shape), (grid, gapKind, dens, seed)) = s;
  final n = base * mult;
  final spec = SampleCodec.specs[signal]!;
  final q = spec.quantum;
  final r = Rng(seed);
  final (lvl, amp) = switch (signal) {
    'hr' => (60 + r.nextDouble() * 60, 15.0),
    'skin_temp_c' => (30 + r.nextDouble() * 6, .6),
    _ => (r.nextDouble() * 2 - 1, .3),
  };
  final period = 120 + r.nextInt(3000);
  final phase = r.nextDouble() * 6.28;
  final spikeAt = n == 0 ? 0 : r.nextInt(n);
  var stepLevel = 0.0;
  var stepLeft = 0;
  final v = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    double x;
    switch (shape) {
      case 0:
        x = lvl;
      case 2:
        if (stepLeft-- <= 0) {
          stepLevel = amp * (r.nextDouble() * 2 - 1) * 3;
          stepLeft = 200 + r.nextInt(700);
        }
        x = lvl + stepLevel;
      case 3:
        x = lvl + amp * (r.nextDouble() * 2 - 1) * 2;
      case 5:
        x = lvl + (r.nextDouble() * 2 - 1) * q * 3;
      case 6:
        final hi = (i ~/ 7).isEven;
        x = switch (signal) {
          'hr' => hi ? 255.0 : 0.0,
          'skin_temp_c' => hi ? 60.0 : 0.0,
          _ => hi ? 16.0 : -16.0,
        };
      default: // 1 smooth, 4 spike
        x = lvl + amp * math.sin(2 * math.pi * i / period + phase);
        if (shape == 4 && i == spikeAt) x += amp * 10;
    }
    final step = spec.step ?? q;
    v[i] = switch (grid) {
      1 => (x / q).round() * q,
      2 => ((x / q).round() + .5) * q,
      3 => (x / step).round() * step,
      _ => x,
    };
  }
  final out = List<double?>.of(v);
  final g = Rng(seed ^ 0x5bd1e995);
  switch (gapKind) {
    case 1:
      for (var i = 0; i < n;) {
        if (g.nextBool(dens * .02)) {
          final len = 1 + g.nextInt(120);
          for (var j = i; j < math.min(n, i + len); j++) {
            out[j] = null;
          }
          i += len;
        } else {
          i++;
        }
      }
    case 2:
      final a = (n * (.5 - dens / 4)).floor(), b = (n * (.5 + dens / 4)).ceil();
      for (var i = a; i < math.min(n, b); i++) {
        out[i] = null;
      }
    case 3:
      for (var i = 0; i < n; i++) {
        out[i] = null;
      }
    case 4:
      for (var m = 0; m * 60 < n; m++) {
        if (g.nextBool(dens)) {
          for (var i = m * 60; i < math.min(n, m * 60 + 60); i++) {
            out[i] = null;
          }
        }
      }
    case 5:
      for (var i = 0; i < n; i++) {
        if (g.nextBool(dens * .3)) out[i] = null;
      }
  }
  return out;
}

/// Which minutes a carve keeps: (kind, seed). 0 none, 1 all, 2 about half,
/// 3 even minutes, 4 the first minute only, 5 about a seventh.
typedef _Keep = (int, int);

final Gen<_Keep> _keepGen = G.pair(G.intIn(0, 5), G.intIn(0, 1 << 30));

bool Function(int) _keepFn(_Keep k) {
  final (kind, seed) = k;
  return switch (kind) {
    0 => (_) => false,
    1 => (_) => true,
    2 => (j) => Rng(caseSeed(seed, j)).nextBool(.5),
    3 => (j) => j.isEven,
    4 => (j) => j == 0,
    _ => (j) => Rng(caseSeed(seed, j)).nextBool(.15),
  };
}

/// The FormatException the carve raises for a version-1 part (not a parse error).
final Matcher _refusesV1 = throwsA(isA<FormatException>().having(
    (e) => e.message, 'message', contains('read, never re-encoded')));

/// [blob] as a version-1 part: version byte 1 and no `step` field (v1 headers
/// have none), which is exactly how the frozen v1 fixtures are laid out.
Uint8List _asVersion1(Uint8List blob) {
  var pos = 4 + 1 + 1; // magic, version, mode
  pos += 1 + blob[pos]; // signal id
  while (blob[pos++] >= 0x80) {} // blockSeconds varint
  pos += 8; // quantum
  final out = [...blob.sublist(0, pos), ...blob.sublist(pos + 8)];
  out[4] = 1;
  return Uint8List.fromList(out);
}

/// One generated situation, expanded lazily: encode and decode only run for
/// the laws that ask.
class _Case {
  _Case(this.sig, this.mode, [this.keep = (1, 0)])
      : signal = _signalFor(sig, mode) {
    x = _samples(signal, sig);
  }
  final _Sig sig;
  final SampleMode mode;
  final _Keep keep;
  final String signal;
  late final List<double?> x;

  SampleSignalSpec get spec => SampleCodec.specs[signal]!;
  int get n => x.length;
  int get nValid => x.where((v) => v != null).length;
  bool get reconstructable => mode != SampleMode.pyramidOnly;

  late final SampleEncoding enc = SampleCodec.encode(signal, x, mode: mode);
  Uint8List get blob => enc.blob;
  late final List<double?> dec = SampleCodec.decode(blob);
  late final List<SampleLevel> summary = SampleCodec.summary(blob);

  /// Minutes (60 s cells) a carve keeps: they hold a sample AND the keep rule
  /// says so.
  late final Set<int> kept = () {
    final f = _keepFn(keep);
    final cells = summary.first.cells;
    return {
      for (var j = 0; j < cells.length; j++)
        if (cells[j].count > 0 && f(j)) j
    };
  }();
  late final SampleEncoding? carved =
      SampleCodec.restrict(blob, _keepFn(keep));
  late final List<double?> carvedDec = SampleCodec.decode(carved!.blob);
  late final List<SampleLevel> carvedSummary = SampleCodec.summary(carved!.blob);
}

String _show(_Case c) =>
    '${c.signal}/${c.mode.name} n=${c.n} shape=${_shapeNames[c.sig.$1.$4]} '
    'grid=${c.sig.$2.$1} gaps=${c.sig.$2.$2}';

void _ok(bool cond, String Function() why) {
  if (!cond) fail(why());
}

// ── the registry and reach (as in annotation_layout_laws_test.dart) ─────────

/// What a law's generator must reach, as SHARES of its default case count, and
/// the observer that recognises each situation in one generated input.
class _Reach<T> {
  const _Reach(this.shares, this.observe);
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
    {required _Reach<T> reach, List<T> examples = const [], int cases = 200}) {
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
  forAll<T>(name, gen, body, examples: examples, cases: cases);
}

// ── scenarios that always run ───────────────────────────────────────────────

/// Thin, flat, present, on-grid / off-grid, ties, boundary, all-absent, gappy.
final List<_Sig> _forced = [
  _sig(0, 0), // empty
  _sig(0, 1, shape: 0), // thin: one slot
  _sig(4, 2, shape: 0), // thin: two slots
  _sig(0, 59, shape: 0), // flat, under a minute
  _sig(0, 600, shape: 0), // flat
  _sig(0, 900, shape: 1, grid: 1), // on the summary quantum
  _sig(1, 900, shape: 1), // off-grid accelerometer
  _sig(0, 300, shape: 3, grid: 2), // rounding ties
  _sig(4, 300, shape: 6), // boundary values
  _sig(2, 300, shape: 6, grid: 3), // boundary on the sample grid
  _sig(0, 300, shape: 1, gaps: 3), // everything absent
  _sig(3, 1800, shape: 5, gaps: 4, density: .4), // whole minutes absent
  _sig(0, 1200, shape: 4, gaps: 5), // a spike, isolated gaps
  _sig(4, 3000, shape: 2, gaps: 1, density: .6), // steps, random gaps
  _sig(1, 721, shape: 3, grid: 3, gaps: 2, density: .5), // odd length, big gap
];

/// Three full local days (86,400 slots) per property.
final List<_Sig> _fullDays = [
  ((0, 21600, 4, 1), (0, 0, .3, 11)), // hr, smooth
  ((1, 21600, 4, 5), (1, 1, .5, 12)), // ax, jitter, random gaps
  ((4, 21600, 4, 2), (3, 4, .3, 13)), // skin, steps on the step grid, minutes absent
];

/// The forced scenarios, each in one of [modes] (rotating) so that over the
/// list every mode meets thin, flat, boundary and gappy inputs.
List<(_Sig, SampleMode)> _forcedIn(List<SampleMode> modes) => [
      for (var i = 0; i < _forced.length; i++)
        (_forced[i], modes[i % modes.length]),
      for (var i = 0; i < _fullDays.length; i++)
        (_fullDays[i], modes[i % modes.length]),
    ];

const _reconstructable = [
  SampleMode.adaptive,
  SampleMode.staticBlocks,
  SampleMode.losslessAtQuantum,
  SampleMode.quantized,
];

// ── reach ───────────────────────────────────────────────────────────────────

void _observeCase(_Case c, void Function(String) bump) {
  bump('mode:${c.mode.name}');
  bump('signal:${c.signal}');
  bump(c.n == 0
      ? 'length: empty'
      : c.n <= 2
          ? 'length: thin (1-2)'
          : c.n < 60
              ? 'length: under a minute'
              : c.n < 1800
                  ? 'length: a minute to half an hour'
                  : 'length: half an hour or more');
  final valid = c.nValid;
  if (c.n > 0 && valid == 0) {
    bump('gaps: all absent');
  } else if (valid < c.n) {
    bump('gaps: some absent');
  } else if (c.n > 0) {
    bump('gaps: none');
  }
  bump('shape: ${_shapeNames[c.sig.$1.$4]}');
  bump(switch (c.sig.$2.$1) {
    0 => 'grid: off-grid',
    2 => 'grid: rounding ties',
    _ => 'grid: on-grid',
  });
}

/// Shares of a law's default cases that must show each situation: about 60% of
/// the smallest share measured across the laws (the table is the measurement,
/// not a wish). A single-mode `quantized` law only meets the signals with a
/// sample step.
Map<String, double> _codecShares(List<SampleMode> modes,
    {bool stepSignalsOnly = false}) {
  final stepOnly = stepSignalsOnly ||
      (modes.length == 1 && modes.first == SampleMode.quantized);
  const modeShare = {
    SampleMode.adaptive: .07,
    SampleMode.staticBlocks: .09,
    SampleMode.losslessAtQuantum: .11,
    SampleMode.pyramidOnly: .07,
    SampleMode.quantized: .09,
  };
  return {
    if (modes.length > 1)
      for (final m in modes) 'mode:${m.name}': modeShare[m]!,
    if (stepOnly) ...{'signal:hr': .4, 'signal:skin_temp_c': .12} else ...{
      'signal:hr': .15,
      'signal:ax': .04,
      'signal:ay': .04,
      'signal:az': .04,
      'signal:skin_temp_c': .1,
    },
    'length: empty': .02,
    'length: thin (1-2)': .01,
    'length: under a minute': .01,
    'length: a minute to half an hour': .28,
    'length: half an hour or more': .1,
    'gaps: all absent': .06,
    'gaps: some absent': .19,
    'gaps: none': .18,
    'shape: flat': .11,
    'shape: smooth': .03,
    'shape: steps': .04,
    'shape: noise': .04,
    'shape: spike': .03,
    'shape: jitter': .03,
    'shape: extremes': .08,
    'grid: off-grid': .14,
    'grid: on-grid': .22,
    'grid: rounding ties': .07,
  };
}

/// A law over one generated signal in one of [modes].
void _codecLaw(String name, List<SampleMode> modes, void Function(_Case) body,
    {int cases = 200,
    bool stepSignalsOnly = false,
    Map<String, double> extraShares = const {},
    void Function(_Case, void Function(String))? extraObserve}) {
  _lawWith<(_Sig, SampleMode)>(
    name,
    G.pair(_sigGen, G.elements(modes)),
    (arg) => body(_Case(arg.$1, arg.$2)),
    cases: cases,
    examples: _forcedIn(modes),
    reach: _Reach<(_Sig, SampleMode)>({
      ..._codecShares(modes, stepSignalsOnly: stepSignalsOnly),
      ...extraShares
    }, (arg, bump) {
      final c = _Case(arg.$1, arg.$2);
      _observeCase(c, bump);
      extraObserve?.call(c, bump);
    }),
  );
}

/// A carve law: signal, mode and the minutes to keep.
void _carveLaw(String name, List<SampleMode> modes, void Function(_Case) body,
    {int cases = 200,
    Map<String, double> extraShares = const {},
    void Function(_Case, void Function(String))? extraObserve}) {
  final forced = _forcedIn(modes);
  _lawWith<(_Sig, SampleMode, _Keep)>(
    name,
    G.triple(_sigGen, G.elements(modes), _keepGen),
    (arg) => body(_Case(arg.$1, arg.$2, arg.$3)),
    cases: cases,
    examples: [
      for (var i = 0; i < forced.length; i++)
        // every keep rule meets the forced scenarios in turn
        (forced[i].$1, forced[i].$2, (i % 6, 100 + i)),
    ],
    reach: _Reach<(_Sig, SampleMode, _Keep)>({
      ..._codecShares(modes),
      'keep: nothing': .24,
      'keep: everything': .07,
      'keep: some minutes': .17,
      ...extraShares
    }, (arg, bump) {
      final c = _Case(arg.$1, arg.$2, arg.$3);
      _observeCase(c, bump);
      final total = c.summary.first.cells.where((m) => m.count > 0).length;
      bump(c.kept.isEmpty
          ? 'keep: nothing'
          : c.kept.length == total
              ? 'keep: everything'
              : 'keep: some minutes');
      extraObserve?.call(c, bump);
    }),
  );
}

// ── oracles ─────────────────────────────────────────────────────────────────

/// Runs of present (non-null) slots, as [start, end).
List<(int, int)> _runs(List<double?> x) {
  final out = <(int, int)>[];
  for (var i = 0; i < x.length;) {
    if (x[i] == null) {
      i++;
      continue;
    }
    var j = i;
    while (j < x.length && x[j] != null) {
      j++;
    }
    out.add((i, j));
    i = j;
  }
  return out;
}

String _runsText(List<(int, int)> r) => r.take(6).join(',');

/// The summary the contract promises for [x] at [q]: per level, per cell, the
/// count and the true extremes rounded to the quantum.
void _expectSummary(List<double?> x, double q, List<SampleLevel> got,
    String label) {
  final len = x.length;
  expect([for (final l in got) l.cellSeconds], [60, 900, 3600, len],
      reason: '$label: levels');
  for (final lvl in got) {
    final cs = lvl.cellSeconds;
    final nCells = cs == len ? 1 : (len + cs - 1) ~/ cs;
    expect(lvl.cells.length, nCells, reason: '$label: cells at $cs s');
    for (var i = 0; i < nCells; i++) {
      final from = cs == len ? 0 : i * cs;
      final to = cs == len ? len : math.min(len, from + cs);
      var count = 0;
      var sum = 0.0;
      double? lo, hi;
      for (var k = from; k < to; k++) {
        final v = x[k];
        if (v == null) continue;
        count++;
        sum += v;
        if (lo == null || v < lo) lo = v;
        if (hi == null || v > hi) hi = v;
      }
      final cell = lvl.cells[i];
      final where = '$label: cell $i of $cs s [$from,$to)';
      expect(cell.count, count, reason: '$where count');
      if (count == 0) {
        expect((cell.min, cell.mean, cell.max), (null, null, null),
            reason: '$where: an empty cell has no numbers');
        continue;
      }
      expect(cell.min, (lo! / q).round() * q, reason: '$where min');
      expect(cell.max, (hi! / q).round() * q, reason: '$where max');
      final mean = sum / count;
      final m = cell.mean!;
      _ok((m - mean).abs() <= q / 2 + 1e-9,
          () => '$where: mean $m is not within q/2 of the true $mean');
      _ok((m / q - (m / q).roundToDouble()).abs() < 1e-6,
          () => '$where: mean $m is not a multiple of the quantum');
      _ok(m >= cell.min! && m <= cell.max!,
          () => '$where: mean $m outside [${cell.min}, ${cell.max}]');
    }
  }
}

void main() {
  group('sample codec laws', () {
    // ── Q ─────────────────────────────────────────────────────────────────
    _codecLaw('Q quantized: every valid slot is within step/2 of the input',
        [SampleMode.quantized], (c) {
      final step = c.spec.step!;
      final d = c.dec;
      _ok(d.length == c.n, () => '${_show(c)}: length ${d.length} != ${c.n}');
      for (var i = 0; i < c.n; i++) {
        final v = c.x[i];
        if (v == null) continue;
        _ok((d[i]! - v).abs() <= step / 2 + 1e-9,
            () => '${_show(c)}: slot $i $v decodes to ${d[i]} (step $step)');
        _ok(d[i] == (d[i]! / step).round() * step,
            () => '${_show(c)}: slot $i ${d[i]} is not on the step grid');
      }
      expect(SampleCodec.readHeader(c.blob).step, step);
      expect(c.enc.stats.maxErr, step / 2, reason: 'the bound is exact by construction');
    }, stepSignalsOnly: true);

    // ── B ─────────────────────────────────────────────────────────────────
    _codecLaw(
        'B lossy DCT: per-slot error <= maxAbs and aggregate rms <= maxRms',
        [SampleMode.adaptive, SampleMode.staticBlocks], (c) {
      final d = c.dec;
      var sq = 0.0, nv = 0;
      for (var i = 0; i < c.n; i++) {
        final v = c.x[i];
        if (v == null) continue;
        final e = (d[i]! - v).abs();
        _ok(e <= c.spec.maxAbs + 1e-9,
            () => '${_show(c)}: slot $i error $e > maxAbs ${c.spec.maxAbs}');
        sq += e * e;
        nv++;
      }
      if (nv > 0) {
        final rms = math.sqrt(sq / nv);
        _ok(rms <= c.spec.maxRms + 1e-9,
            () => '${_show(c)}: rms $rms > maxRms ${c.spec.maxRms}');
      }
    }, cases: 80, extraShares: const {
      'segments: more than one': .34
    }, extraObserve: (c, bump) {
      if (SampleCodec.segments(c.blob).length > 1) bump('segments: more than one');
    });

    // ── LQ ────────────────────────────────────────────────────────────────
    _codecLaw('LQ lossless at the quantum: decode == round(x / q) * q exactly',
        [SampleMode.losslessAtQuantum], (c) {
      final q = c.spec.quantum;
      final d = c.dec;
      for (var i = 0; i < c.n; i++) {
        final v = c.x[i];
        if (v == null) continue;
        _ok(d[i] == (v / q).round() * q,
            () => '${_show(c)}: slot $i $v decodes to ${d[i]}, want ${(v / q).round() * q}');
        _ok((d[i]! - v).abs() <= q / 2 + 1e-9,
            () => '${_show(c)}: slot $i error beyond q/2');
      }
    });

    // ── PO ────────────────────────────────────────────────────────────────
    _codecLaw('PO pyramid only: decode is refused, the summary is kept',
        [SampleMode.pyramidOnly], (c) {
      expect(() => SampleCodec.decode(c.blob), throwsFormatException,
          reason: 'a pyramid-only blob holds no samples');
      expect(() => SampleCodec.decodeCoarse(c.blob, maxOrder: 4),
          throwsFormatException);
      expect(SampleCodec.hasSamples(c.blob), isFalse);
      expect(SampleCodec.readHeader(c.blob).mode, SampleMode.pyramidOnly);
      expect(SampleCodec.segments(c.blob), isEmpty);
      expect(SampleCodec.validRuns(c.blob), _runs(c.x),
          reason: 'the mask survives');
      _expectSummary(c.x, c.spec.quantum, c.summary, _show(c));
    });

    // ── G ─────────────────────────────────────────────────────────────────
    _codecLaw('G gaps: decode is null exactly where the input is null',
        _reconstructable, (c) {
      final d = c.dec;
      expect(d.length, c.n, reason: _show(c));
      for (var i = 0; i < c.n; i++) {
        _ok((d[i] == null) == (c.x[i] == null),
            () => '${_show(c)}: slot $i input ${c.x[i]} decoded ${d[i]}');
      }
      final runs = SampleCodec.validRuns(c.blob);
      _ok(_runsText(runs) == _runsText(_runs(c.x)) && runs.length == _runs(c.x).length,
          () => '${_show(c)}: valid runs ${_runsText(runs)} != ${_runsText(_runs(c.x))}');
      expect(SampleCodec.readHeader(c.blob).nValid, c.nValid);
      expect(c.enc.stats.nValid, c.nValid);
    });

    // ── D ─────────────────────────────────────────────────────────────────
    _codecLaw('D determinism: encoding the same input again gives the same bytes',
        SampleMode.values, (c) {
      final again =
          SampleCodec.encode(c.signal, List<double?>.of(c.x), mode: c.mode);
      expect(again.blob, c.blob, reason: _show(c));
      expect(again.stats.bytes, c.enc.stats.bytes);
      expect(again.stats.rmsErr, c.enc.stats.rmsErr);
      expect(again.stats.maxErr, c.enc.stats.maxErr);
      expect(again.stats.coefficientCount, c.enc.stats.coefficientCount);
    }, cases: 80);

    // ── S ─────────────────────────────────────────────────────────────────
    _codecLaw(
        'S summary: counts exact, min / max / mean the true values rounded to the quantum',
        SampleMode.values, (c) {
      _expectSummary(c.x, c.spec.quantum, c.summary, _show(c));
    }, cases: 120);

    // ── Ca-Ce: carve ──────────────────────────────────────────────────────
    _carveLaw('Ca a version-1 part is refused by the carve, never re-encoded',
        SampleMode.values, (c) {
      final v1 = _asVersion1(c.blob);
      expect(SampleCodec.readHeader(v1).codecVersion, 1);
      expect(SampleCodec.readHeader(v1).length, c.n, reason: 'a readable v1 part');
      expect(() => SampleCodec.restrict(v1, _keepFn(c.keep)), _refusesV1,
          reason: _show(c));
      // The same part at the current version IS carved (or has nothing to keep).
      SampleCodec.restrict(c.blob, _keepFn(c.keep));
    }, cases: 60);

    _carveLaw('Cb nothing kept gives null, anything kept gives a part',
        SampleMode.values, (c) {
      final r = SampleCodec.restrict(c.blob, _keepFn(c.keep));
      expect(r == null, c.kept.isEmpty,
          reason: '${_show(c)} keep=${c.keep} kept=${c.kept.length} minutes');
      expect(SampleCodec.restrict(c.blob, (_) => false), isNull);
      // A keep rule that only names minutes without samples keeps nothing.
      final empty = {
        for (var j = 0; j < c.summary.first.cells.length; j++)
          if (c.summary.first.cells[j].count == 0) j
      };
      expect(SampleCodec.restrict(c.blob, empty.contains), isNull);
    }, cases: 100);

    _carveLaw('Cc carve slots: present iff the input had a sample in a kept minute',
        SampleMode.values, (c) {
      final carved = c.carved;
      if (carved == null) return;
      final want = [
        for (var i = 0; i < c.n; i++) c.x[i] != null && c.kept.contains(i ~/ 60)
      ];
      final runs = SampleCodec.validRuns(carved.blob);
      final got = List<bool>.filled(c.n, false);
      for (final (a, b) in runs) {
        for (var i = a; i < b; i++) {
          got[i] = true;
        }
      }
      for (var i = 0; i < c.n; i++) {
        _ok(got[i] == want[i],
            () => '${_show(c)}: slot $i present=${got[i]}, want ${want[i]} (minute ${i ~/ 60})');
      }
      expect(carved.stats.nValid, want.where((w) => w).length);
      if (c.reconstructable) {
        final d = c.carvedDec;
        for (var i = 0; i < c.n; i++) {
          _ok((d[i] != null) == want[i],
              () => '${_show(c)}: decoded slot $i null=${d[i] == null}, want ${!want[i]}');
        }
      }
    }, cases: 100);

    _carveLaw('Cd carve summary: kept minutes keep their cell, dropped minutes are empty',
        SampleMode.values, (c) {
      final carved = c.carved;
      if (carved == null) return;
      final q = c.spec.quantum;
      final orig = c.summary, got = c.carvedSummary;
      expect([for (final l in got) l.cellSeconds],
          [for (final l in orig) l.cellSeconds]);
      final m0 = orig.first.cells, g0 = got.first.cells;
      for (var j = 0; j < m0.length; j++) {
        final want = m0[j], cell = g0[j];
        if (c.kept.contains(j)) {
          expect(cell.count, want.count, reason: '${_show(c)} minute $j count');
          expect(cell.min, (want.min! / q).round() * q, reason: 'minute $j min');
          expect(cell.mean, (want.mean! / q).round() * q, reason: 'minute $j mean');
          expect(cell.max, (want.max! / q).round() * q, reason: 'minute $j max');
        } else {
          expect((cell.count, cell.min, cell.mean, cell.max), (0, null, null, null),
              reason: '${_show(c)} minute $j was dropped');
        }
      }
      // Coarser levels: counts add, extremes are the kept minutes' extremes.
      final len = c.n;
      for (var li = 1; li < got.length; li++) {
        final cs = got[li].cellSeconds;
        for (var i = 0; i < got[li].cells.length; i++) {
          final from = cs == len ? 0 : i * cs;
          final to = cs == len ? len : math.min(len, from + cs);
          var count = 0;
          double? lo, hi;
          for (var j = from ~/ 60; j * 60 < to; j++) {
            if (!c.kept.contains(j)) continue;
            count += m0[j].count;
            if (lo == null || m0[j].min! < lo) lo = m0[j].min;
            if (hi == null || m0[j].max! > hi) hi = m0[j].max;
          }
          final cell = got[li].cells[i];
          expect(cell.count, count, reason: '${_show(c)} level $cs cell $i count');
          expect(cell.min, lo, reason: '${_show(c)} level $cs cell $i min');
          expect(cell.max, hi, reason: '${_show(c)} level $cs cell $i max');
        }
      }
    }, cases: 100);

    _carveLaw('Ce lossless carve: kept samples are exactly the decoded ones',
        [SampleMode.losslessAtQuantum], (c) {
      if (c.carved == null) return;
      final d = c.dec, k = c.carvedDec;
      for (var i = 0; i < c.n; i++) {
        if (!c.kept.contains(i ~/ 60) || d[i] == null) continue;
        _ok(k[i] == d[i], () => '${_show(c)}: slot $i ${k[i]} != ${d[i]}');
      }
    });

    _carveLaw('Ce quantized carve: within step/2 of the decode, step of the raw',
        [SampleMode.quantized], (c) {
      if (c.carved == null) return;
      final step = c.spec.step!;
      final d = c.dec, k = c.carvedDec;
      for (var i = 0; i < c.n; i++) {
        if (!c.kept.contains(i ~/ 60) || d[i] == null) continue;
        _ok((k[i]! - d[i]!).abs() <= step / 2 + 1e-9,
            () => '${_show(c)}: slot $i carved ${k[i]} vs decoded ${d[i]}');
        _ok((k[i]! - c.x[i]!).abs() <= step + 1e-9,
            () => '${_show(c)}: slot $i carved ${k[i]} vs raw ${c.x[i]}');
      }
    });

    _carveLaw(
        'Ce lossy carve: second generation within maxAbs / maxRms of the decode, 2*maxAbs of the raw',
        [SampleMode.adaptive, SampleMode.staticBlocks], (c) {
      if (c.carved == null) return;
      final d = c.dec, k = c.carvedDec;
      var sq = 0.0, nv = 0;
      for (var i = 0; i < c.n; i++) {
        if (!c.kept.contains(i ~/ 60) || d[i] == null) continue;
        final e = (k[i]! - d[i]!).abs();
        _ok(e <= c.spec.maxAbs + 1e-9,
            () => '${_show(c)}: slot $i carved vs decoded error $e > maxAbs');
        _ok((k[i]! - c.x[i]!).abs() <= 2 * c.spec.maxAbs + 1e-9,
            () => '${_show(c)}: slot $i carved vs raw error beyond 2*maxAbs');
        sq += e * e;
        nv++;
      }
      if (nv > 0) {
        _ok(math.sqrt(sq / nv) <= c.spec.maxRms + 1e-9,
            () => '${_show(c)}: carved vs decoded rms beyond maxRms');
      }
    }, cases: 60);

    _carveLaw('Ce pyramid-only carve: summary only, no samples',
        [SampleMode.pyramidOnly], (c) {
      final carved = c.carved;
      if (carved == null) return;
      expect(SampleCodec.hasSamples(carved.blob), isFalse);
      expect(SampleCodec.readHeader(carved.blob).mode, SampleMode.pyramidOnly);
      expect(() => SampleCodec.decode(carved.blob), throwsFormatException);
    });
  });

  group('v1 parts and refusals', () {
    test('Ca frozen version-1 parts are refused by the carve', () {
      for (final v in [v1HrAdaptive, v1HrStatic, v1AxLossless, v1AxPyramid]) {
        expect(SampleCodec.readHeader(v.bytes).codecVersion, 1);
        expect(() => SampleCodec.restrict(v.bytes, (_) => true), _refusesV1);
      }
    });

    test('the encoder refuses what it cannot represent', () {
      expect(() => SampleCodec.encode('hr', [1.0, double.nan]),
          throwsArgumentError,
          reason: 'NaN is not "absent"; null is');
      expect(() => SampleCodec.encode('hr', [double.infinity]),
          throwsArgumentError);
      expect(() => SampleCodec.encode('spo2', [1.0]), throwsArgumentError);
      expect(
          () => SampleCodec.encode('ax', [0.1], mode: SampleMode.quantized),
          throwsArgumentError,
          reason: 'ax has no sample step');
    });
  });

  // ── W: the worker entries, in-process ────────────────────────────────────
  group('sample worker entry laws', () {
    // (signal recipes with their mode, which signals have a mode entry)
    final slotsGen = G.pair(
        G.listOf(G.pair(_sigGen, G.elements(SampleMode.values)),
            minLen: 1, maxLen: 3),
        G.intIn(0, 7));

    ({Map<String, List<double?>> x, SampleEncodeInput input, Set<String> omitted})
        build((List<(_Sig, SampleMode)>, int) arg) {
      final (parts, omitMask) = arg;
      final x = <String, List<double?>>{};
      final modes = <String, SampleMode>{};
      final omitted = <String>{};
      for (var i = 0; i < parts.length; i++) {
        final (sig, mode) = parts[i];
        final signal = _signalFor(sig, mode);
        x[signal] = _samples(signal, sig);
        if ((omitMask >> i) & 1 == 1) {
          omitted.add(signal);
          modes.remove(signal);
        } else {
          modes[signal] = mode;
          omitted.remove(signal);
        }
      }
      return (
        x: x,
        input: SampleEncodeInput(slots: {
          for (final e in x.entries)
            e.key: Float64List.fromList(
                [for (final v in e.value) v ?? double.nan])
        }, modes: modes),
        omitted: omitted,
      );
    }

    _lawWith<(List<(_Sig, SampleMode)>, int)>(
      'W1 encode entry: NaN slots are absent, the rest is the codec\'s own encode',
      slotsGen,
      (arg) {
        final b = build(arg);
        final out = encodeSampleSignalsHeavy(sampleHeavyInputs, b.input);
        expect(out.keys.toSet(), b.input.slots.keys.toSet());
        for (final e in b.x.entries) {
          final part = out[e.key]!;
          final mode = b.input.modes[e.key] ?? SampleMode.pyramidOnly;
          final nan = [for (final v in e.value) v == null];
          expect(part.nValid, nan.where((a) => !a).length,
              reason: '${e.key}: valid count');
          expect(part.blob, SampleCodec.encode(e.key, e.value, mode: mode).blob,
              reason: '${e.key}: the entry is the codec on null-for-NaN');
          final runs = SampleCodec.validRuns(part.blob);
          expect(runs.length, _runs(e.value).length, reason: '${e.key}: runs');
          if (SampleCodec.hasSamples(part.blob)) {
            final d = SampleCodec.decode(part.blob);
            for (var i = 0; i < nan.length; i++) {
              _ok((d[i] == null) == nan[i],
                  () => '${e.key}: slot $i NaN=${nan[i]} decoded ${d[i]}');
            }
          }
        }
      },
      examples: [
        for (final s in _forced.take(10))
          ([(s, SampleMode.quantized), (s, SampleMode.losslessAtQuantum)], 0),
        ([(_fullDays[0], SampleMode.pyramidOnly)], 0),
        ([(_fullDays[1], SampleMode.losslessAtQuantum)], 0),
        ([(_fullDays[2], SampleMode.quantized)], 0),
      ],
      cases: 100,
      reach: _Reach<(List<(_Sig, SampleMode)>, int)>(const {
        'a NaN slot is present': .45,
        'every slot is NaN': .14,
        'no NaN at all': .13,
        'two or more signals': .28,
        'a reconstructable mode with NaN': .22,
      }, (arg, bump) {
        final b = build(arg);
        final any = b.x.values.any((v) => v.any((s) => s == null));
        if (any) bump('a NaN slot is present');
        if (b.x.values.any((v) => v.isNotEmpty && v.every((s) => s == null))) {
          bump('every slot is NaN');
        }
        if (!any) bump('no NaN at all');
        if (b.x.length > 1) bump('two or more signals');
        if (any &&
            b.input.modes.values.any((m) => m != SampleMode.pyramidOnly)) {
          bump('a reconstructable mode with NaN');
        }
      }),
    );

    _lawWith<(List<(_Sig, SampleMode)>, int)>(
      'W2 encode entry: the mode map decides, a signal without a mode is pyramid-only',
      slotsGen,
      (arg) {
        final b = build(arg);
        final out = encodeSampleSignalsHeavy(sampleHeavyInputs, b.input);
        for (final signal in b.x.keys) {
          final want = b.input.modes[signal] ?? SampleMode.pyramidOnly;
          expect(SampleCodec.readHeader(out[signal]!.blob).mode, want,
              reason: '$signal (omitted: ${b.omitted.contains(signal)})');
          expect(SampleCodec.readHeader(out[signal]!.blob).signal, signal);
        }
      },
      examples: [
        ([(_forced[5], SampleMode.adaptive), (_forced[6], SampleMode.staticBlocks)], 0),
        ([(_forced[5], SampleMode.adaptive), (_forced[6], SampleMode.staticBlocks)], 3),
        ([(_forced[4], SampleMode.quantized)], 1),
        ([(_forced[7], SampleMode.losslessAtQuantum)], 0),
        ([(_forced[7], SampleMode.pyramidOnly)], 1),
      ],
      cases: 100,
      reach: _Reach<(List<(_Sig, SampleMode)>, int)>(const {
        'a signal without a mode entry': .32,
        'adaptive requested': .12,
        'staticBlocks requested': .08,
        'losslessAtQuantum requested': .12,
        'quantized requested': .08,
        'pyramidOnly requested': .13,
      }, (arg, bump) {
        final b = build(arg);
        if (b.omitted.isNotEmpty) bump('a signal without a mode entry');
        for (final m in b.input.modes.values) {
          bump('${m.name} requested');
        }
      }),
    );

    test('W1 the entry refuses an infinite slot (only NaN means absent)', () {
      expect(
          () => encodeSampleSignalsHeavy(
              sampleHeavyInputs,
              SampleEncodeInput(slots: {
                'hr': Float64List.fromList([70, double.infinity])
              }, modes: const {
                'hr': SampleMode.quantized
              })),
          throwsArgumentError);
    });

    // ── W3: overlay at absolute origins ─────────────────────────────────────
    const epoch = 1790000000;
    const overlayModes = [
      SampleMode.quantized,
      SampleMode.losslessAtQuantum,
      SampleMode.adaptive
    ];
    final partGen = G.triple(
        G.quad(G.intIn(0, 600), G.intIn(0, 6), G.intIn(0, 5), G.intIn(0, 1 << 20)),
        G.intIn(0, 1500),
        G.elements(overlayModes));
    final overlayGen = G.pair(G.listOf(partGen, minLen: 1, maxLen: 4),
        G.elements(const <int?>[null, null, 0, 8]));

    (SampleReconstructInput, List<List<double?>>) overlayBuild(
        (List<((int, int, int, int), int, SampleMode)>, int?) arg) {
      final (parts, maxOrder) = arg;
      final blobs = <SampleBlobPart>[];
      final raws = <List<double?>>[];
      for (var i = 0; i < parts.length; i++) {
        final ((len, shape, gaps, seed), offset, mode) = parts[i];
        final sig = ((0, len, 1, shape), (0, gaps, .4, seed + i));
        final x = _samples('hr', sig);
        raws.add(x);
        blobs.add(SampleBlobPart(
            epoch + offset, SampleCodec.encode('hr', x, mode: mode).blob));
      }
      return (SampleReconstructInput(parts: blobs, maxOrder: maxOrder), raws);
    }

    _lawWith<(List<((int, int, int, int), int, SampleMode)>, int?)>(
      'W3 reconstruct entry: parts overlay at their absolute origins, later parts win',
      overlayGen,
      (arg) {
        final (input, _) = overlayBuild(arg);
        final out = reconstructSamplePartsHeavy(sampleHeavyInputs, input);
        final decoded = [
          for (final p in input.parts)
            input.maxOrder == null
                ? SampleCodec.decode(p.blob)
                : SampleCodec.decodeCoarse(p.blob, maxOrder: input.maxOrder!)
        ];
        var o0 = input.parts.first.originSec, end = 0;
        for (var i = 0; i < decoded.length; i++) {
          o0 = math.min(o0, input.parts[i].originSec);
          end = math.max(end, input.parts[i].originSec + decoded[i].length);
        }
        expect(out.originSec, o0, reason: 'the earliest origin');
        expect(out.samples.length, end - o0, reason: 'to the last second any part reaches');
        for (var t = 0; t < out.samples.length; t++) {
          // The LAST part (in list order) holding a sample at this absolute second.
          double? want;
          for (var p = 0; p < decoded.length; p++) {
            final at = o0 + t - input.parts[p].originSec;
            if (at < 0 || at >= decoded[p].length) continue;
            final v = decoded[p][at];
            if (v != null) want = v;
          }
          _ok(out.samples[t] == want,
              () => 'absolute second ${o0 + t}: got ${out.samples[t]}, want $want');
        }
      },
      examples: [
        // two parts overlapping by 100 s, then the same in the other order
        ([((600, 1, 0, 1), 0, SampleMode.quantized), ((600, 3, 0, 2), 500, SampleMode.quantized)], null),
        ([((600, 3, 0, 2), 500, SampleMode.quantized), ((600, 1, 0, 1), 0, SampleMode.quantized)], null),
        // a later part with gaps must not blank an earlier part's samples
        ([((400, 1, 0, 3), 100, SampleMode.losslessAtQuantum), ((400, 3, 4, 4), 0, SampleMode.losslessAtQuantum)], null),
        // a hole between two parts stays null; coarse orders
        ([((200, 1, 0, 5), 0, SampleMode.adaptive), ((200, 1, 0, 6), 900, SampleMode.adaptive)], 0),
        ([((0, 1, 0, 7), 50, SampleMode.quantized), ((120, 1, 0, 8), 10, SampleMode.quantized)], null),
      ],
      cases: 60,
      reach: _Reach<(List<((int, int, int, int), int, SampleMode)>, int?)>(const {
        'parts overlap in time': .15,
        'a later part has gaps over an earlier part\'s samples': .09,
        'a hole between parts': .25,
        'three or more parts': .15,
        'parts given out of origin order': .25,
        'a coarse order': .35,
      }, (arg, bump) {
        final (input, raws) = overlayBuild(arg);
        final ps = input.parts;
        bool overlaps = false, blanks = false, hole = false, unordered = false;
        for (var i = 0; i < ps.length; i++) {
          for (var j = i + 1; j < ps.length; j++) {
            final a0 = ps[i].originSec, a1 = a0 + raws[i].length;
            final b0 = ps[j].originSec, b1 = b0 + raws[j].length;
            if (a0 < b1 && b0 < a1) {
              overlaps = true;
              final lo = math.max(a0, b0), hi = math.min(a1, b1);
              for (var t = lo; t < hi; t++) {
                if (raws[i][t - a0] != null && raws[j][t - b0] == null) blanks = true;
              }
            } else if (raws[i].isNotEmpty && raws[j].isNotEmpty) {
              hole = true;
            }
          }
          if (i > 0 && ps[i].originSec < ps[i - 1].originSec) unordered = true;
        }
        if (overlaps) bump('parts overlap in time');
        if (blanks) bump('a later part has gaps over an earlier part\'s samples');
        if (hole) bump('a hole between parts');
        if (ps.length >= 3) bump('three or more parts');
        if (unordered) bump('parts given out of origin order');
        if (input.maxOrder != null) bump('a coarse order');
      }),
    );

    // ── W4: the carve entry is the codec's carve ───────────────────────────
    _lawWith<(_Sig, SampleMode, _Keep)>(
      'W4 carve entry: the codec\'s carve of the minutes not already covered',
      G.triple(_sigGen, G.elements(SampleMode.values), _keepGen),
      (arg) {
        final c = _Case(arg.$1, arg.$2, arg.$3);
        final minutes = c.summary.first.cells.length;
        final covered = [
          for (var j = 0; j < minutes; j++)
            if (!_keepFn(c.keep)(j)) j
        ];
        final got = carveSamplePartHeavy(
            sampleHeavyInputs,
            SampleCarveInput(
                blob: c.blob,
                coveredMinutes: covered,
                valid: c.nValid,
                rmsErr: c.enc.stats.rmsErr,
                maxErr: c.enc.stats.maxErr));
        final want = SampleCodec.restrict(c.blob, _keepFn(c.keep));
        if (want == null) {
          expect(got, isNull, reason: '${_show(c)}: nothing left to keep');
          return;
        }
        expect(got, isNotNull, reason: _show(c));
        expect(got!.blob, want.blob, reason: '${_show(c)}: byte-identical');
        expect(got.nValid, want.stats.nValid);
      },
      examples: [
        for (var i = 0; i < 12; i++)
          (_forced[i], SampleMode.values[i % 5], (i % 6, 200 + i)),
      ],
      cases: 60,
      reach: _Reach<(_Sig, SampleMode, _Keep)>(const {
        'nothing left to keep': .25,
        'something kept': .35,
        'everything kept': .09,
      }, (arg, bump) {
        final c = _Case(arg.$1, arg.$2, arg.$3);
        final total = c.summary.first.cells.where((m) => m.count > 0).length;
        if (c.kept.isEmpty) {
          bump('nothing left to keep');
        } else {
          bump('something kept');
          if (c.kept.length == total) bump('everything kept');
        }
      }),
    );
  });

  // The generators must actually REACH what the laws are about, or a law
  // passes by never being exercised. Counted per law over exactly the default
  // generated cases that law runs (its own seed), forced scenarios excluded.
  group('generator reach', () {
    test('every law sees every situation in its default cases', () {
      expect(_registry, isNotEmpty);
      final weak = <String>[];
      for (final law in _registry) {
        final got = law.measure();
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
}
