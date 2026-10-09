// LAWS of the annotation layout (design 05, pilot cluster C1a).
//
// `layoutAnnotations`, `pickAnnotationFocus` and `stepAnnotationFocus` are pure
// arithmetic on layout coordinates (not painted pixels), so the rules that make
// the chart honest can be stated once and checked on hundreds of generated
// charts: widths 0-1200 px (including < one icon and invalid scales), up to 60
// items of mixed kinds, points and ranges, in and out of the domain, with
// random focus.
//
// These laws describe the CURRENT behaviour (edge 1043fd6f). A law that fails
// is first checked against the module's documented contract
// (lib/ui2/chart_annotations.dart header, the existing example tests); only a
// violation of the intended contract is a bug.
//
// PRECONDITION: annotation ids are unique (the layout indexes by id; duplicate
// ids are out of contract and pinned by ONE explicit example at the bottom).
//
// Replay a failure with the command in its report, e.g.
//   PROPERTY_SEED=<s> PROPERTY_CASE=<n> flutter test \
//     test/properties/annotation_layout_laws_test.dart --plain-name '<name>'

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/chart_annotations.dart';

import '../support/property.dart';

// ── the oracle: what is visible, in the words of the contract ───────────────

const double _eps = 1e-6;

bool _usable(AnnotationScale s) =>
    s.width > 0 &&
    s.width.isFinite &&
    s.domainStart.isFinite &&
    s.domainEnd.isFinite &&
    s.domainEnd > s.domainStart;

/// A RANGE needs a finite end after its start; anything else is a point.
bool _validRange(ChartAnnotation a) {
  final u = a.until;
  return u != null && u.isFinite && u > a.at;
}

int _cmpTime(ChartAnnotation a, ChartAnnotation b) {
  final c = a.at.compareTo(b.at);
  return c != 0 ? c : a.id.compareTo(b.id);
}

class _V {
  _V(this.a, this.x, this.right, this.startsInside, this.endsInside);
  final ChartAnnotation a;
  final double x;
  final double? right;
  final bool startsInside, endsInside;
  bool get isRange => right != null;
  bool get isNight => a.kind == AnnotationKind.mainSleep;

  /// An ordinary point: the only thing a "+n" cluster may hold.
  bool get ordinary =>
      !isRange && a.kind != AnnotationKind.algoVersion && !isNight;
}

int _cmpX(_V a, _V b) {
  final c = a.x.compareTo(b.x);
  return c != 0 ? c : _cmpTime(a.a, b.a);
}

/// The occurrences the contract says are on the plot: finite, in the domain,
/// valid. Pixel x is the scale's own `xOf` (linearity is pinned elsewhere).
List<_V> _visible(List<ChartAnnotation> items, AnnotationScale s) {
  if (!_usable(s)) return const [];
  final out = <_V>[];
  for (final a in items) {
    if (!a.at.isFinite) continue;
    if (_validRange(a)) {
      final u = a.until!;
      if (u < s.domainStart || a.at > s.domainEnd) continue;
      out.add(_V(
          a,
          s.xOf(math.max(a.at, s.domainStart)),
          s.xOf(math.min(u, s.domainEnd)),
          a.at >= s.domainStart,
          u <= s.domainEnd));
    } else if (a.at >= s.domainStart && a.at <= s.domainEnd) {
      out.add(_V(a, s.xOf(a.at), null, true, true));
    }
  }
  return out;
}

// ── generators ──────────────────────────────────────────────────────────────

/// (domainStart, span, width, mode). Mode 0 makes one domain unit one pixel,
/// where exact-threshold ties live; mode 1 squeezes the width to 8% (narrow
/// plots, where icons are given up); 2 and 3 leave it. An invalid span or width
/// gives an invalid scale on purpose.
typedef _Scale = (double, double, double, int);

/// (kind, at, length, mode). `length` null: a point; <= 0 / NaN / inf: a
/// "range" the layout must treat as a point. `mode` pins an edge: 0 starts at
/// the domain start, 1 at its end, 2 ends at its end, 3 spans the whole domain,
/// else the absolute values stand.
typedef _Item = (AnnotationKind, double, double?, int);

/// (mode, index): 0 no focus; 1 a visible item, 2 a visible ordinary point
/// (where a hidden cluster member can be focused), 3 any item (maybe off the
/// plot), each `index % count`; 4 an id that does not exist; 5 and 6 repeat
/// 2 and 1.
typedef _Focus = (int, int);

typedef _Spec = (_Scale, List<_Item>, _Focus);

const _kindPool = [
  AnnotationKind.moment,
  AnnotationKind.moment,
  AnnotationKind.water,
  AnnotationKind.symptom,
  AnnotationKind.workout,
  AnnotationKind.nap,
  AnnotationKind.journal,
  AnnotationKind.review,
  AnnotationKind.assumedWater,
  AnnotationKind.algoVersion,
  AnnotationKind.mainSleep,
];

final Gen<_Scale> _scaleGen = G.quad(
  G.doubleIn(-300, 300, integerBias: .8),
  G.doubleIn(-50, 1300,
      boundaries: const [0, 1, 24, 300, 1200],
      specials: const [double.nan, double.infinity],
      integerBias: .9),
  G.doubleIn(0, 1200,
      boundaries: const [0, 1, 23, 24, 25, 47, 48, 70, 1200],
      specials: const [-1, double.nan, double.infinity],
      integerBias: .8),
  G.intIn(0, 3),
);

final Gen<_Item> _itemGen = G.quad(
  G.elements(_kindPool),
  G.doubleIn(-100, 1400,
      boundaries: const [0, 300, 1200], integerBias: .6),
  G.nullable(
      G.doubleIn(-20, 400,
          boundaries: const [0, 1, 24],
          specials: const [double.nan, double.infinity, double.negativeInfinity],
          integerBias: .6),
      nullProbability: .7),
  G.intIn(0, 19),
);

final Gen<_Focus> _focusGen = G.pair(G.intIn(0, 6), G.intIn(0, 99));

final Gen<_Spec> _specGen =
    G.triple(_scaleGen, G.listOf(_itemGen, maxLen: 60), _focusGen);

// ── building a chart from a spec ────────────────────────────────────────────

class _Chart {
  _Chart(this.scale, this.items, this.focus);
  final AnnotationScale scale;
  final List<ChartAnnotation> items;
  final String? focus;

  late final AnnotationLayout layout =
      layoutAnnotations(annotations: items, scale: scale, focusId: focus);
  late final List<_V> vis = _visible(items, scale);
  late final Map<String, _V> visById = {for (final v in vis) v.a.id: v};
  late final Map<String, ChartAnnotation> byId = {
    for (final a in items) a.id: a
  };

  AnnotationLayout layoutWith(String? f, {List<ChartAnnotation>? order}) =>
      layoutAnnotations(
          annotations: order ?? items, scale: scale, focusId: f);

  /// The focus id if it names a visible item, else null.
  String? get visibleFocus => focus != null && visById.containsKey(focus) ? focus : null;
}

/// Builds the chart. [map] is applied to every domain coordinate (domain ends,
/// `at`, `until`); [snap] first rounds them to a quarter grid so that a
/// power-of-two scaling plus an on-grid shift is EXACT in floating point.
_Chart _build(_Spec s,
    {double Function(double)? map, bool snap = false}) {
  final (sc, its, fo) = s;
  final dS0 = sc.$1;
  final dE0 = sc.$1 + sc.$2;
  final width = (sc.$4 == 0 && sc.$2.isFinite && sc.$2 > 0 && sc.$2 <= 1200)
      ? sc.$2
      : sc.$4 == 1
          ? sc.$3 * .08
          : sc.$3;
  double q(double v) => snap && v.isFinite ? (v * 4).round() / 4 : v;
  double t(double v) => map == null ? q(v) : map(q(v));
  final items = <ChartAnnotation>[];
  for (var i = 0; i < its.length; i++) {
    final (kind, a0, len, mode) = its[i];
    var at = a0;
    double? until = len == null ? null : a0 + len;
    switch (mode) {
      case 0:
        at = dS0;
        until = len == null ? null : dS0 + len;
      case 1:
        at = dE0;
        until = len == null ? null : dE0 + len;
      case 2:
        until = dE0;
      case 3:
        at = dS0;
        until = dE0;
    }
    items.add(ChartAnnotation(
      id: 'a$i',
      kind: kind,
      at: t(at),
      until: until == null ? null : t(until),
      label: 'L-a$i',
    ));
  }
  final scale =
      AnnotationScale(domainStart: t(dS0), domainEnd: t(dE0), width: width);
  final vis = _visible(items, scale);
  final ordinary = [for (final v in vis) if (v.ordinary) v];
  final String? focus = switch (fo.$1) {
    1 || 6 when vis.isNotEmpty => vis[fo.$2 % vis.length].a.id,
    2 || 5 when ordinary.isNotEmpty => ordinary[fo.$2 % ordinary.length].a.id,
    1 || 2 || 3 || 5 || 6 => items.isEmpty ? null : 'a${fo.$2 % items.length}',
    4 => 'ghost',
    _ => null,
  };
  return _Chart(scale, items, focus);
}

_Spec _spec(
  List<_Item> items, {
  double dS = 0,
  double span = 300,
  double width = 300,
  _Focus focus = (0, 0),
}) =>
    ((dS, span, width, 2), items, focus);

_Item _pt(double at, [AnnotationKind k = AnnotationKind.moment]) =>
    (k, at, null, 9);
_Item _rg(double at, double len, [AnnotationKind k = AnnotationKind.workout]) =>
    (k, at, len, 9);

/// Scenarios that must always run: thin, present, crowded, exact thresholds,
/// too narrow, invalid scale, range edges, priority.
final List<_Spec> _forced = [
  // thin
  _spec(const []),
  _spec([_pt(150)]),
  // crowd: one cluster, focus on a hidden member
  _spec([for (var i = 0; i < 20; i++) _pt(i.toDouble())], focus: (1, 7)),
  // exactly one icon width apart (two icons) and just under (one)
  _spec([_pt(100), _pt(124), _pt(148), _pt(171.5)]),
  // priority: night between crowded points on a chart too narrow for all
  _spec([
    _pt(40),
    _pt(50),
    _rg(60, 80, AnnotationKind.mainSleep),
    _pt(200),
    _pt(210, AnnotationKind.algoVersion),
  ], width: 60, span: 300, focus: (1, 0)),
  // a night as a point, a chart barely wider than one icon
  _spec([_pt(150, AnnotationKind.mainSleep), _pt(10), _pt(290)],
      width: 24, focus: (1, 1)),
  // too narrow for any icon
  _spec([_pt(10), _rg(20, 50)], width: 23.999),
  // invalid scales
  _spec([_pt(10), _pt(20)], span: double.nan),
  _spec([_pt(10), _pt(20)], width: double.nan),
  _spec([_pt(10), _pt(20)], width: 0),
  _spec([_pt(10), _pt(20)], span: -5),
  // range edges: before, over, ending at the start, starting at the end
  _spec([
    _rg(-50, 100),
    _rg(250, 200),
    _rg(-30, 30),
    _rg(300, 10),
    _rg(-10, 400, AnnotationKind.mainSleep),
    _rg(10, 0),
    _rg(20, double.nan),
  ], focus: (2, 4)),
];

// ── small helpers ───────────────────────────────────────────────────────────

void _ok(bool cond, String Function() why) {
  if (!cond) fail(why());
}

String _dump(AnnotationLayout l) {
  final b = StringBuffer();
  for (final i in l.items) {
    b.writeln('  icon ${i.id} members=${i.memberIds} x=${i.x} '
        'left=${i.iconLeft} right=${i.footprintRight} '
        '${i.focused ? "FOCUSED " : ""}${i.isRange ? "range" : ""}');
  }
  for (final s in l.shades) {
    b.writeln('  shade ${s.id} [${s.left}, ${s.right}] '
        'start=${s.startsInside} end=${s.endsInside}');
  }
  b.writeln('  unplaced=${l.unplaced} focused=${l.focusedId} '
      'label=${l.labelText}');
  return b.toString();
}

/// null when [a] and [b] are the same layout (pixel values within [tol]),
/// else what differs.
String? _diff(AnnotationLayout a, AnnotationLayout b, double tol) {
  bool near(double x, double y) => (x - y).abs() <= tol;
  bool same(List<String> x, List<String> y) =>
      x.length == y.length && [for (var i = 0; i < x.length; i++) x[i] == y[i]].every((e) => e);
  if (a.items.length != b.items.length) return 'icon count';
  for (var i = 0; i < a.items.length; i++) {
    final p = a.items[i], q = b.items[i];
    if (p.id != q.id ||
        p.kind != q.kind ||
        p.focused != q.focused ||
        p.isRange != q.isRange ||
        !same(p.memberIds, q.memberIds)) {
      return 'icon $i: ${p.id}/${q.id} ${p.memberIds}/${q.memberIds}';
    }
    if (!near(p.x, q.x) || !near(p.iconLeft, q.iconLeft)) {
      return 'icon $i position: x ${p.x}/${q.x} left ${p.iconLeft}/${q.iconLeft}';
    }
  }
  if (a.shades.length != b.shades.length) return 'shade count';
  for (var i = 0; i < a.shades.length; i++) {
    final p = a.shades[i], q = b.shades[i];
    if (p.id != q.id ||
        p.kind != q.kind ||
        p.focused != q.focused ||
        p.startsInside != q.startsInside ||
        p.endsInside != q.endsInside ||
        !near(p.left, q.left) ||
        !near(p.right, q.right)) {
      return 'shade $i: ${p.id}/${q.id}';
    }
  }
  if (!same(a.unplaced, b.unplaced)) return 'unplaced ${a.unplaced}/${b.unplaced}';
  if (a.focusedId != b.focusedId) return 'focusedId';
  if (a.labelText != b.labelText) return 'labelText';
  return null;
}

/// An icon as the layout builds it at some cluster threshold.
class _Ic {
  _Ic(this.ids, this.night, this.focus);
  final List<String> ids;
  final bool night, focus;
}

/// The icons the layout builds at the FIRST cluster threshold
/// `iconWidth + k * badgeWidth` under which every footprint fits the plot, or,
/// when none does, at the last threshold it tries (all points in one cluster
/// reach it). Icons come out left to right.
({bool fits, double t, List<_Ic> icons}) _fitting(_Chart c) {
  final iw = c.scale.iconWidth, bw = c.scale.badgeWidth;
  final ordinary = [
    for (final v in c.vis)
      if (v.ordinary) v
  ]..sort(_cmpX);
  final solos = [
    for (final v in c.vis)
      if (!v.ordinary) v
  ];
  final f = c.visibleFocus;
  var t = iw;
  for (;; t += bw) {
    final groups = <List<_V>>[];
    var anchor = 0.0;
    for (final p in ordinary) {
      if (groups.isEmpty || p.x - anchor >= t) {
        groups.add([p]);
        anchor = p.x;
      } else {
        groups.last.add(p);
      }
    }
    final need = solos.length * iw +
        [for (final g in groups) iw + (g.length > 1 ? bw : 0)]
            .fold<double>(0, (a, b) => a + b);
    // The footprints are whole pixels, so an exact fit is exact on both sides.
    final fits = need <= c.scale.width + 1e-9;
    if (fits || t > c.scale.width + iw) {
      final shown = <(_V, _Ic)>[];
      for (final g in [...groups, for (final v in solos) [v]]) {
        final members = [...g]..sort((a, b) => _cmpTime(a.a, b.a));
        final head = f != null && members.any((m) => m.a.id == f)
            ? c.visById[f]!
            : members.first;
        shown.add((
          head,
          _Ic([for (final m in members) m.a.id], members.any((m) => m.isNight),
              f != null && members.any((m) => m.a.id == f))
        ));
      }
      shown.sort((a, b) => _cmpX(a.$1, b.$1));
      return (fits: fits, t: t, icons: [for (final e in shown) e.$2]);
    }
  }
}

/// What a law's generator must reach for the law to mean anything: minimum
/// counts of situations over the law's default cases, and the observer that
/// recognises them in one generated input.
class _Reach<T> {
  const _Reach(this.needs, this.observe);
  final Map<String, int> needs;
  final void Function(T arg, void Function(String) bump) observe;
}

class _Registered {
  _Registered(this.name, this.needs, this.measure);
  final String name;
  final Map<String, int> needs;
  final Map<String, int> Function() measure;
}

/// Every law in this file is registered here (through [_law] or [_lawWith]), so
/// the generator-reach test can ask whether each law's OWN generator really
/// produces the situations the law talks about.
final List<_Registered> _registry = [];

void _lawWith<T>(String name, Gen<T> gen, void Function(T) body,
    {required _Reach<T> reach, List<T> examples = const [], int? cases}) {
  _registry.add(_Registered(name, reach.needs, () {
    final got = <String, int>{for (final k in reach.needs.keys) k: 0};
    final r = runProperty<T>(
      name: name,
      gen: gen,
      config: PropertyConfig(
          cases: cases ?? 200, budget: const Duration(seconds: 30)),
      body: (v) => reach.observe(v, (k) => got[k] = (got[k] ?? 0) + 1),
    );
    if (!r.passed) fail(r.failure!.report);
    return got;
  }));
  forAll<T>(name, gen, body, examples: examples, cases: cases);
}

void _law(String name, void Function(_Spec) body,
    {List<_Spec> examples = const [], int? cases}) =>
    _lawWith<_Spec>(name, _specGen, body,
        reach: _specReach, examples: examples, cases: cases);

/// The situations a plain chart law must meet (counted on usable charts).
void _observeChart(_Chart c, void Function(String) bump) {
  if (!_usable(c.scale)) {
    bump('unusable scale');
    return;
  }
  final l = c.layout;
  if (c.scale.width < c.scale.iconWidth) {
    bump('usable plot narrower than one icon');
  }
  _observeShape(c, bump);
  if (l.items.any((i) => i.focused)) bump('focused icon placed');
  if (l.items.any((i) =>
      i.focused && i.memberIds.length > 1 && i.memberIds.first != i.id)) {
    bump('focus on a non-oldest member (shown in place of the oldest)');
  }
  if (c.vis.any((v) => v.isRange && !v.startsInside)) {
    bump('range clipped on the left');
  }
  if (c.vis.any((v) => v.isRange && !v.endsInside)) {
    bump('range clipped on the right');
  }
  final nights = {
    for (final v in c.vis)
      if (v.isNight) v.a.id
  };
  if (nights.isNotEmpty) bump('main sleep visible');
  if (l.unplaced.any(nights.contains)) bump('main sleep given up');
  if (c.vis.any((v) => v.a.kind == AnnotationKind.algoVersion)) {
    bump('algorithm-version mark visible');
  }
  if (c.vis.isNotEmpty) {
    bump(_fitting(c).fits
        ? 'L9 sweep: everything fits'
        : 'L9 sweep: nothing fits, icons dropped');
  }
}

/// Clusters and drops: the two things layout does beyond placing icons.
void _observeShape(_Chart c, void Function(String) bump) {
  if (!_usable(c.scale)) return;
  final l = c.layout;
  if (l.items.any((i) => i.memberIds.length > 1)) bump('multi-member cluster');
  if (l.unplaced.isNotEmpty) bump('icon given up (unplaced)');
}

final _specReach = _Reach<_Spec>(const {
  'multi-member cluster': 40,
  'icon given up (unplaced)': 25,
  'focused icon placed': 35,
  'focus on a non-oldest member (shown in place of the oldest)': 8,
  'range clipped on the left': 22,
  'range clipped on the right': 35,
  'main sleep visible': 45,
  'main sleep given up': 5,
  'algorithm-version mark visible': 40,
  'usable plot narrower than one icon': 6,
  'unusable scale': 20,
  'L9 sweep: everything fits': 45,
  'L9 sweep: nothing fits, icons dropped': 22,
}, (spec, bump) => _observeChart(_build(spec), bump));

final _reachL7 = _Reach<(_Spec, (int, int))>(const {
  'scaled by a power of two other than 1': 100,
  'shifted by a non-zero offset': 110,
  'scaled and shifted together': 95,
  'multi-member cluster': 35,
  'icon given up (unplaced)': 28,
}, (arg, bump) {
  final (spec, (k, m)) = arg;
  if (k != 0) bump('scaled by a power of two other than 1');
  if (m != 0) bump('shifted by a non-zero offset');
  if (k != 0 && m != 0) bump('scaled and shifted together');
  _observeShape(_build(spec, snap: true), bump);
});

final _reachL7g = _Reach<(_Spec, (double, double))>(const {
  'transform is not the identity': 120,
  'chart in generic position (compared)': 85,
  'multi-member cluster': 21,
  'icon given up (unplaced)': 17,
}, (arg, bump) {
  final (spec, (a, b)) = arg;
  if (a != 1 || b != 0) bump('transform is not the identity');
  final c = _build(spec);
  if (!_usable(c.scale)) return;
  if (_generic(c)) {
    bump('chart in generic position (compared)');
    _observeShape(c, bump);
  }
});

final _reachL8 = _Reach<(_Spec, (double?, double?))>(const {
  'cursor missing or non-finite': 18,
  'nearest within reach (pick returned)': 38,
  'nearest out of reach (pick is null)': 20,
  'tie at the nearest distance': 40,
  'tie between a point and a range': 22,
  'cursor inside a range': 12,
  'inclusive reach boundary checked (reach == distance)': 38,
}, (arg, bump) {
  final (spec, (cursor, reach)) = arg;
  final c = _build(spec);
  if (cursor == null || !cursor.isFinite) {
    bump('cursor missing or non-finite');
    return;
  }
  if (c.vis.isEmpty) return;
  final n = _nearest(c, cursor);
  if (reach == null || n.d <= reach) {
    bump('nearest within reach (pick returned)');
  } else {
    bump('nearest out of reach (pick is null)');
  }
  if (n.tie) bump('tie at the nearest distance');
  if (n.mixedTie) bump('tie between a point and a range');
  if (n.best.isRange && n.d == 0) bump('cursor inside a range');
  // The body re-runs the pick with reach == distance on every such case.
  if (reach == null || n.d <= reach) {
    bump('inclusive reach boundary checked (reach == distance)');
  }
});

final _reachL12 = _Reach<(_Spec, double?)>(const {
  'null cursor': 27,
  'NaN cursor': 27,
  'positive infinity cursor': 27,
  'negative infinity cursor': 27,
  'annotations are visible (so null means something)': 80,
}, (arg, bump) {
  final (spec, cursor) = arg;
  if (cursor == null) bump('null cursor');
  if (cursor != null && cursor.isNaN) bump('NaN cursor');
  if (cursor == double.infinity) bump('positive infinity cursor');
  if (cursor == double.negativeInfinity) bump('negative infinity cursor');
  if (_build(spec).vis.isNotEmpty) {
    bump('annotations are visible (so null means something)');
  }
});

final _reachL8s = _Reach<(_Spec, ((int, bool), (int, int)))>(const {
  'nothing to step through': 19,
  'step within a multi-member cluster': 12,
  'step across icons': 20,
  'clamped at the last stop': 8,
  'clamped at the first stop': 7,
  'forward from no focus': 12,
  'back from no focus': 17,
}, (arg, bump) {
  final (spec, ((size, forward), (curMode, curIdx))) = arg;
  final c = _build(spec);
  if (!_usable(c.scale)) return;
  final l = c.layout;
  final seq = [for (final i in l.items) ...i.memberIds];
  if (seq.isEmpty) {
    bump('nothing to step through');
    return;
  }
  final owner = <String, int>{
    for (var k = 0; k < l.items.length; k++)
      for (final m in l.items[k].memberIds) m: k
  };
  final delta = forward ? size : -size;
  final cur = _stepCurrent(l, curMode, curIdx);
  final at = cur == null ? -1 : seq.indexOf(cur);
  final int target;
  if (at >= 0) {
    target = at + delta;
  } else {
    target = delta > 0 ? delta - 1 : seq.length + delta;
    bump(delta > 0 ? 'forward from no focus' : 'back from no focus');
  }
  if (target > seq.length - 1) bump('clamped at the last stop');
  if (target < 0) bump('clamped at the first stop');
  if (at >= 0) {
    final j = target.clamp(0, seq.length - 1);
    if (j != at) {
      if (owner[seq[at]] == owner[seq[j]]) {
        bump('step within a multi-member cluster');
      } else {
        bump('step across icons');
      }
    }
  }
});

/// The current focus of a stepping case: 0 none, 1 any stop, 2 an id that is
/// on no icon, 3-4 a stop inside a multi-member cluster (any stop when the
/// chart has none), so steps within a cluster are common.
String? _stepCurrent(AnnotationLayout l, int mode, int idx) {
  final seq = [for (final i in l.items) ...i.memberIds];
  if (seq.isEmpty) return mode == 2 ? 'ghost' : null;
  switch (mode) {
    case 1:
      return seq[idx % seq.length];
    case 2:
      return 'ghost';
    case 3 || 4:
      final inCluster = [
        for (final i in l.items)
          if (i.memberIds.length > 1) ...i.memberIds
      ];
      final pool = inCluster.isEmpty ? seq : inCluster;
      return pool[idx % pool.length];
    default:
      return null;
  }
}

/// The annotation a scrub at [cursor] px is ON or NEAREST to: distance 0 on a
/// range, otherwise to its nearest edge (a point: to its x); at equal distance a
/// point beats a range, then the older. [tie]: another annotation is equally
/// near; [mixedTie]: one of them is a range where the winner is a point.
({_V best, double d, bool tie, bool mixedTie}) _nearest(
    _Chart c, double cursor) {
  double dist(_V v) => v.isRange
      ? (cursor < v.x ? v.x - cursor : cursor > v.right! ? cursor - v.right! : 0)
      : (v.x - cursor).abs();
  bool before(_V a, _V b) {
    if (a.isRange != b.isRange) return !a.isRange;
    return _cmpTime(a.a, b.a) < 0;
  }

  var best = c.vis.first;
  for (final v in c.vis) {
    final dv = dist(v), db = dist(best);
    if (dv < db || (dv == db && before(v, best))) best = v;
  }
  final d = dist(best);
  final tied = [
    for (final v in c.vis)
      if (!identical(v, best) && dist(v) == d) v
  ];
  return (
    best: best,
    d: d,
    tie: tied.isNotEmpty,
    mixedTie: tied.any((v) => v.isRange != best.isRange)
  );
}

void main() {
  group('layout laws', () {
    _law('L1 placed icons never overlap and stay inside the plot', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final iw = c.scale.iconWidth, bw = c.scale.badgeWidth;
      for (final i in l.items) {
        final right = i.iconLeft + iw + (i.memberIds.length > 1 ? bw : 0);
        _ok(i.iconLeft >= -_eps, () => '${i.id} starts left of the plot\n${_dump(l)}');
        _ok(right <= c.scale.width + _eps,
            () => '${i.id} ends right of the plot (${c.scale.width})\n${_dump(l)}');
        _ok((i.footprintRight - right).abs() <= _eps,
            () => '${i.id} footprintRight disagrees with icon + badge');
      }
      for (var k = 1; k < l.items.length; k++) {
        final a = l.items[k - 1], b = l.items[k];
        final aRight = a.iconLeft + iw + (a.memberIds.length > 1 ? bw : 0);
        _ok(aRight <= b.iconLeft + _eps,
            () => '${a.id} overlaps ${b.id}\n${_dump(l)}');
      }
    }, examples: _forced);

    _law('L2 every visible occurrence is in exactly one icon or unplaced', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final visIds = [for (final v in c.vis) v.a.id]..sort();
      final flat = [for (final i in l.items) ...i.memberIds, ...l.unplaced]
        ..sort();
      expect(flat, visIds, reason: 'partition of the visible set\n${_dump(l)}');
      for (final i in l.items) {
        _ok(i.memberIds.contains(i.id),
            () => 'icon ${i.id} is not one of its own members');
      }
      // Shades are a representation, not partition members: exactly one per
      // visible valid range, none for anything else.
      final rangeIds = {
        for (final v in c.vis)
          if (v.isRange) v.a.id
      };
      expect(l.shades.map((s) => s.id).toList()..sort(), rangeIds.toList()..sort());
    }, examples: _forced);

    _law('L3 a point is drawn at its true x, a range at its clipped ends', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final s = c.scale;
      for (final i in l.items) {
        final v = c.visById[i.id];
        _ok(v != null, () => 'icon ${i.id} is not a visible annotation');
        final a = v!.a;
        _ok(i.isRange == v.isRange, () => '${i.id} range flag');
        final shownAt = v.isRange ? math.max(a.at, s.domainStart) : a.at;
        final truth = (shownAt - s.domainStart) * s.width / (s.domainEnd - s.domainStart);
        _ok((i.x - truth).abs() <= _eps && (i.x - v.x).abs() <= 1e-9,
            () => '${i.id}: line at ${i.x}, true x $truth\n${_dump(l)}');
        _ok(i.x >= -_eps && i.x <= s.width + _eps,
            () => '${i.id}: line ${i.x} off the plot');
      }
      for (final sh in l.shades) {
        final a = c.byId[sh.id]!;
        _ok(sh.startsInside == (a.at >= s.domainStart),
            () => '${sh.id}: start line must exist iff the range begins on the plot');
        _ok(sh.endsInside == (a.until! <= s.domainEnd),
            () => '${sh.id}: end line must exist iff the range ends on the plot');
        final span = s.domainEnd - s.domainStart;
        final l0 = (math.max(a.at, s.domainStart) - s.domainStart) * s.width / span;
        final r0 = (math.min(a.until!, s.domainEnd) - s.domainStart) * s.width / span;
        _ok((sh.left - l0).abs() <= _eps && (sh.right - r0).abs() <= _eps,
            () => '${sh.id}: ends [${sh.left}, ${sh.right}] != clipped [$l0, $r0]');
      }
    }, examples: _forced);

    void nightLaw(_Chart c, AnnotationLayout l, String label) {
      final nights = {
        for (final v in c.vis)
          if (v.isNight) v.a.id
      };
      for (final i in l.items) {
        if (i.memberIds.any(nights.contains)) {
          _ok(i.memberIds.length == 1 && i.memberIds.single == i.id,
              () => '$label: a main sleep is in a cluster ${i.memberIds}\n${_dump(l)}');
        }
      }
      if (l.unplaced.any(nights.contains)) {
        // Given up only after EVERY other icon, the focused one included.
        _ok(l.items.every((i) => nights.contains(i.id)),
            () => '$label: a main sleep was dropped while another icon stayed\n${_dump(l)}');
      }
      if (nights.length == 1 && c.scale.width >= c.scale.iconWidth + _eps) {
        _ok(l.items.any((i) => i.id == nights.single),
            () => '$label: the only main sleep got no icon on a wide enough plot\n${_dump(l)}');
      }
    }

    _law('L4 the main sleep is never clustered, last dropped, outranks focus', (spec) {
      final c = _build(spec);
      nightLaw(c, c.layout, 'focus ${c.focus}');
      // Focus on an ordinary visible item: the night still outranks it.
      final ordinary = [
        for (final v in c.vis)
          if (!v.isNight) v.a.id
      ];
      if (ordinary.isNotEmpty) {
        final f = ordinary[spec.$3.$2 % ordinary.length];
        nightLaw(c, c.layoutWith(f), 'focus $f');
      }
    }, examples: _forced);

    _law('L5 the label is the focused one, else the main sleep, else none', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final night = ([
        for (final v in c.vis)
          if (v.isNight) v
      ]..sort(_cmpX))
          .firstOrNull;
      final f = c.visibleFocus;
      expect(l.focusedId, f, reason: 'an unknown or off-plot focus focuses nothing');
      expect(l.labelText, f != null ? c.byId[f]!.label : night?.a.label,
          reason: 'label slot\n${_dump(l)}');
      expect(l.labelSlot, AnnotationLabelSlot.topStart);
      // A label that is only a default is not a focus.
      final flagged = [for (final i in l.items) if (i.focused) i.id];
      if (f == null) {
        expect(flagged, isEmpty);
      } else {
        final holder = l.items.where((i) => i.memberIds.contains(f));
        // Focused even when its icon is unplaced: then nothing is flagged.
        expect(flagged, holder.isEmpty ? isEmpty : [f]);
      }
      for (final sh in l.shades) {
        expect(sh.focused, sh.id == f, reason: 'shade ${sh.id} focus flag');
      }
    }, examples: _forced);

    _law('L6 a valid range never clusters and keeps a shade', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final ranges = {
        for (final v in c.vis)
          if (v.isRange) v.a.id
      };
      for (final i in l.items) {
        if (ranges.contains(i.id)) {
          _ok(i.isRange && i.memberIds.length == 1,
              () => 'range ${i.id} in a cluster ${i.memberIds}\n${_dump(l)}');
        } else {
          _ok(!i.isRange, () => '${i.id} is flagged as a range but is a point');
          _ok(!i.memberIds.any(ranges.contains),
              () => 'a range is a member of ${i.id}: ${i.memberIds}');
        }
      }
      for (final id in ranges) {
        _ok(l.shades.any((s) => s.id == id),
            () => 'range $id has no shade (unplaced icon must keep it)');
      }
    }, examples: _forced);

    _law('L6b an algorithm-version mark never clusters', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final marks = {
        for (final v in c.vis)
          if (v.a.kind == AnnotationKind.algoVersion) v.a.id
      };
      for (final i in l.items) {
        if (marks.contains(i.id)) {
          _ok(i.memberIds.length == 1, () => 'mark ${i.id} owns ${i.memberIds}');
        } else {
          _ok(!i.memberIds.any(marks.contains),
              () => 'a version mark is a member of ${i.id}: ${i.memberIds}');
        }
      }
    }, examples: _forced);

    _law('L0 an unusable scale lays out nothing and does not throw', (spec) {
      final c = _build(spec);
      if (_usable(c.scale)) return;
      final l = c.layout;
      expect(l.items, isEmpty, reason: 'an unusable scale shows nothing');
      expect(l.shades, isEmpty);
      expect(l.unplaced, isEmpty);
      expect(l.focusedId, isNull);
      expect(l.labelText, isNull, reason: 'and invents nothing');
    }, examples: _forced);

    _law('L11 a range shade spans its visible clipped extent', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final s = c.scale;
      for (final v in c.vis.where((v) => v.isRange)) {
        final sh = l.shades.where((x) => x.id == v.a.id);
        _ok(sh.length == 1, () => 'range ${v.a.id}: ${sh.length} shades');
        final x = sh.single;
        _ok(x.kind == v.a.kind, () => '${x.id}: shade kind ${x.kind}');
        _ok((x.left - v.x).abs() <= 1e-9 && (x.right - v.right!).abs() <= 1e-9,
            () => '${x.id}: [${x.left}, ${x.right}] != clipped [${v.x}, ${v.right}]');
        _ok(x.left <= x.right + 1e-9, () => '${x.id}: inverted shade');
        _ok(x.left >= -_eps && x.right <= s.width + _eps,
            () => '${x.id}: shade leaves the plot');
      }
    }, examples: _forced);

    // ── L7: affine invariance ──────────────────────────────────────────────
    //
    // The layout depends on the domain only through ratios, so mapping domain
    // and items by v -> a*v + b (a > 0) leaves it equal. Two flavours, because
    // floating point can flip a DISCRETE decision (a tie at exactly one icon
    // width, a point exactly on the domain edge) when the scaling rounds:
    //  * exact: coordinates on a quarter grid, a a power of two, b on the grid
    //    -> every operation is exact, so the layouts are IDENTICAL;
    //  * generic: any positive a, any b, within a pixel tolerance, on charts
    //    where no decision sits within 0.01 px of its threshold.

    _lawWith<(_Spec, (int, int))>(
        'L7 a power-of-two scaling and on-grid shift leave the layout equal',
        G.pair(_specGen, G.pair(G.intIn(-2, 3), G.intIn(-4000, 4000))),
        (arg) {
      final (spec, (k, m)) = arg;
      final a = math.pow(2, k).toDouble(), b = m * .25;
      final base = _build(spec, snap: true);
      final moved = _build(spec, snap: true, map: (v) => a * v + b);
      final d = _diff(base.layout, moved.layout, 1e-9);
      _ok(d == null, () => 'v -> ${a}v + $b changed the layout: $d\n'
          '${_dump(base.layout)}--- moved ---\n${_dump(moved.layout)}');
      // The scrub is in pixels, so it picks the same annotation too.
      final cursor = spec.$3.$2 * 11.0;
      expect(
          pickAnnotationFocus(
              annotations: moved.items, scale: moved.scale, cursorPx: cursor),
          pickAnnotationFocus(
              annotations: base.items, scale: base.scale, cursorPx: cursor));
    }, reach: _reachL7, examples: [for (final s in _forced) (s, (1, 40))]);

    var genericChecked = 0, genericSkipped = 0;
    _lawWith<(_Spec, (double, double))>(
        'L7g a positive affine map leaves the layout equal within a pixel',
        G.pair(
          G.triple(
              _scaleGen,
              G.listOf(
                  G.quad(
                      G.elements(_kindPool),
                      G.doubleIn(-300, 1800, integerBias: 0),
                      G.nullable(G.doubleIn(-20, 400, integerBias: 0),
                          nullProbability: .5),
                      G.intIn(4, 9)),
                  maxLen: 60),
              _focusGen),
          G.pair(G.doubleIn(0.001, 1000, integerBias: .2),
              G.doubleIn(-1e6, 1e6, integerBias: .2)),
        ), (arg) {
      final (spec, (a, b)) = arg;
      final base = _build(spec);
      if (!_generic(base)) {
        genericSkipped++;
        return;
      }
      genericChecked++;
      final moved = _build(spec, map: (v) => a * v + b);
      final d = _diff(base.layout, moved.layout, 1e-3);
      _ok(d == null, () => 'v -> ${a}v + $b changed the layout: $d\n'
          '${_dump(base.layout)}--- moved ---\n${_dump(moved.layout)}');
    }, reach: _reachL7g, examples: [
      for (final s in _forced) (s, (86400.0 / 300, 1.7e9)),
    ]);

    test('L7g is not vacuous: most generated charts are in generic position',
        () {
      if (genericChecked + genericSkipped == 0) return; // run alone by name
      expect(genericChecked, greaterThan(genericSkipped),
          reason: 'the generic-position guard rejected most charts');
    });

    // ── L8: focus pick and step ─────────────────────────────────────────────

    final cursorGen = G.nullable(
        G.doubleIn(-60, 1260,
            boundaries: const [0, 300, 1200],
            specials: const [double.nan, double.infinity, double.negativeInfinity],
            integerBias: .7),
        nullProbability: .1);
    final reachGen = G.nullable(
        G.doubleIn(0, 150, boundaries: const [0, 12, 24], integerBias: .8),
        nullProbability: .4);

    _lawWith<(_Spec, (double?, double?))>(
        'L8 the focus pick is the nearest within reach, ties to a point then older',
        G.pair(_specGen, G.pair(cursorGen, reachGen)), (arg) {
      final (spec, (cursor, reach)) = arg;
      final c = _build(spec);
      String? pick(double? r) => pickAnnotationFocus(
          annotations: c.items, scale: c.scale, cursorPx: cursor, reach: r);
      final got = pick(reach);
      if (cursor == null || !cursor.isFinite || c.vis.isEmpty) {
        expect(got, isNull, reason: 'no cursor or nothing visible');
        return;
      }
      final n = _nearest(c, cursor);
      final best = n.best;
      final bd = n.d;
      if (reach != null && bd > reach) {
        expect(got, isNull, reason: 'nearest is ${best.a.id} at $bd > reach $reach');
        return;
      }
      expect(got, best.a.id, reason: 'cursor $cursor, nearest ${best.a.id} at $bd');
      // Reach is inclusive.
      expect(pick(bd), best.a.id, reason: 'reach == distance still picks');
      if (bd > 1e-3) expect(pick(bd - 1e-3), isNull, reason: 'just inside it does not');
    }, reach: _reachL8, examples: [
      for (final s in _forced) (s, (0.0, null)),
      for (final s in _forced) (s, (150.0, 12.0)),
      for (final s in _forced) (s, (double.nan, 5.0)),
    ]);

    _lawWith<(_Spec, double?)>(
        'L12 a missing or non-finite cursor focuses nothing',
        G.pair(
            _specGen,
            G.elements(const <double?>[
              null,
              double.nan,
              double.infinity,
              double.negativeInfinity
            ])), (arg) {
      final (spec, cursor) = arg;
      final c = _build(spec);
      for (final reach in <double?>[null, 0, 1e9]) {
        expect(
            pickAnnotationFocus(
                annotations: c.items,
                scale: c.scale,
                cursorPx: cursor,
                reach: reach),
            isNull);
      }
    }, reach: _reachL12, examples: [for (final s in _forced) (s, null)]);

    _lawWith<(_Spec, ((int, bool), (int, int)))>(
        'L8s stepping moves by delta through the icons and clamps at the ends',
        G.pair(_specGen, G.pair(G.pair(G.intIn(1, 3), G.boolean()), G.pair(G.intIn(0, 4), G.intIn(0, 99)))),
        (arg) {
      final (spec, ((size, forward), (curMode, curIdx))) = arg;
      final c = _build(spec);
      final l = c.layout;
      final seq = [for (final i in l.items) ...i.memberIds];
      final delta = forward ? size : -size;
      final cur = _stepCurrent(l, curMode, curIdx);
      final got = stepAnnotationFocus(l, cur, delta);
      if (seq.isEmpty) {
        expect(got, isNull, reason: 'nothing to step through');
        return;
      }
      final at = cur == null ? -1 : seq.indexOf(cur);
      final j = got == null ? -1 : seq.indexOf(got);
      _ok(j >= 0, () => 'stepped to $got, which is not on an icon: $seq');
      if (at >= 0) {
        expect(j, (at + delta).clamp(0, seq.length - 1),
            reason: 'from #$at by $delta in $seq');
      } else if (delta > 0) {
        expect(j, math.min(delta - 1, seq.length - 1),
            reason: 'forward from nothing starts at the first');
      } else {
        expect(j, math.max(seq.length + delta, 0),
            reason: 'back from nothing starts at the last');
      }
    }, reach: _reachL8s, examples: [
      for (final s in _forced) (s, ((1, true), (0, 0))),
      for (final s in _forced) (s, ((2, false), (1, 3))),
    ]);

    // ── L9: cluster formation ───────────────────────────────────────────────

    _law('L9 clusters are the greedy runs of ordinary points under the first width that fits',
        (spec) {
      final c = _build(spec);
      // Nothing is visible on an unusable scale (L0); the sweep needs a finite
      // width to terminate.
      if (!_usable(c.scale)) return;
      final l = c.layout;
      final ordinary = [
        for (final v in c.vis)
          if (v.ordinary) v
      ]..sort(_cmpX);
      final rank = {for (var i = 0; i < ordinary.length; i++) ordinary[i].a.id: i};

      // Always: a "+n" holds only ordinary points, consecutive in x order.
      for (final i in l.items.where((i) => i.memberIds.length > 1)) {
        final idx = [
          for (final m in i.memberIds) rank[m] ?? -1,
        ]..sort();
        _ok(!idx.contains(-1),
            () => 'cluster ${i.memberIds} holds something that is not an ordinary point');
        for (var k = 1; k < idx.length; k++) {
          _ok(idx[k] == idx[k - 1] + 1,
              () => 'cluster ${i.memberIds} skips a point between its members\n${_dump(l)}');
        }
      }

      String key(Iterable<String> ids) => ids.join(',');
      final fit = _fitting(c);
      final placedKeys = {for (final i in l.items) key(i.memberIds)};
      if (fit.fits) {
        // Clusters are the greedy sweep from each cluster's first point at the
        // first threshold iconWidth + k * badgeWidth under which every icon
        // fits (k = 0: nothing needed to widen). Nothing is dropped.
        final want = [for (final ic in fit.icons) key(ic.ids)]..sort();
        final got = [for (final i in l.items) key(i.memberIds)]..sort();
        expect(got, want,
            reason: 'first threshold that fits is ${fit.t} px\n${_dump(l)}');
        expect(l.unplaced, isEmpty);
        for (final i in l.items.where((i) => i.memberIds.length > 1)) {
          final xs = [for (final m in i.memberIds) c.visById[m]!.x];
          _ok(xs.reduce(math.max) - xs.reduce(math.min) < fit.t,
              () => 'cluster ${i.memberIds} is wider than ${fit.t} px');
        }
        return;
      }

      // Nothing fits even with every point in one cluster: icons are given up,
      // from the right, the focused icon only after every other, the main
      // sleep after that. Each icon is placed or unplaced whole.
      expect(l.unplaced, isNotEmpty,
          reason: 'footprints exceed ${c.scale.width} px, something must go\n${_dump(l)}');
      bool dropped(_Ic ic) {
        final inPlaced = placedKeys.contains(key(ic.ids));
        final inUnplaced = ic.ids.every(l.unplaced.contains);
        _ok(inPlaced != inUnplaced,
            () => 'icon ${ic.ids} is neither wholly placed nor wholly unplaced\n${_dump(l)}');
        return inUnplaced;
      }

      final candidates = [
        for (final ic in fit.icons)
          if (!ic.night && !ic.focus) ic
      ]; // already in left-to-right order
      final flags = [for (final ic in candidates) dropped(ic)];
      for (var k = 1; k < flags.length; k++) {
        _ok(!flags[k - 1] || flags[k],
            () => 'an icon was kept to the right of one given up: $flags\n${_dump(l)}');
      }
      final allCandidatesGone = flags.every((f) => f);
      for (final ic in fit.icons) {
        final gone = dropped(ic);
        if (ic.focus && !ic.night && gone) {
          _ok(allCandidatesGone,
              () => 'the focused icon went before the others\n${_dump(l)}');
        }
        if (ic.night && gone) {
          _ok(fit.icons.where((o) => !o.night).every(dropped),
              () => 'the main sleep went before every other icon\n${_dump(l)}');
        }
      }
    }, examples: _forced);

    // ── L10: representative and membership ─────────────────────────────────

    _law('L10 the shown member is the focused one, else the oldest; focus keeps membership', (spec) {
      final c = _build(spec);
      final l = c.layout;
      final f = c.visibleFocus;
      for (final i in l.items) {
        _ok(i.more == i.memberIds.length - 1, () => '${i.id}: +n is ${i.more}');
        for (var k = 1; k < i.memberIds.length; k++) {
          _ok(_cmpTime(c.byId[i.memberIds[k - 1]]!, c.byId[i.memberIds[k]]!) < 0,
              () => '${i.id}: members not oldest first ${i.memberIds}');
        }
        final want = f != null && i.memberIds.contains(f) ? f : i.memberIds.first;
        _ok(i.id == want, () => 'icon shows ${i.id}, expected $want of ${i.memberIds}');
      }

      // Focus never changes WHO is in which cluster: every cluster of one
      // layout is a cluster (or all unplaced) in the layout without focus.
      final none = c.layoutWith(null);
      String key(PlacedAnnotation i) => i.memberIds.join(',');
      final noneKeys = {for (final i in none.items) key(i)};
      for (final i in l.items) {
        _ok(noneKeys.contains(key(i)) || i.memberIds.every(none.unplaced.contains),
            () => 'focus $f regrouped ${i.memberIds}\n${_dump(l)}--- none ---\n${_dump(none)}');
      }
      final lKeys = {for (final i in l.items) key(i)};
      for (final i in none.items) {
        _ok(lKeys.contains(key(i)) || i.memberIds.every(l.unplaced.contains),
            () => 'focus $f regrouped ${i.memberIds}\n${_dump(none)}--- focused ---\n${_dump(l)}');
      }
    }, examples: _forced);

    // ── L13: stepping order ────────────────────────────────────────────────

    _law('L13 stepping visits icons left to right, a cluster oldest to newest', (spec) {
      final c = _build(spec);
      final l = c.layout;
      for (var k = 1; k < l.items.length; k++) {
        _ok(l.items[k - 1].x <= l.items[k].x + 1e-9 &&
                l.items[k - 1].iconLeft < l.items[k].iconLeft,
            () => 'icons out of left-to-right order\n${_dump(l)}');
      }
      final seq = [for (final i in l.items) ...i.memberIds];
      // Forward from nothing walks the whole sequence, then stays on the last.
      String? cur;
      final walked = <String>[];
      for (var k = 0; k < seq.length; k++) {
        cur = stepAnnotationFocus(l, cur, 1);
        walked.add(cur!);
      }
      expect(walked, seq);
      if (seq.isNotEmpty) {
        expect(stepAnnotationFocus(l, cur, 1), seq.last, reason: 'clamped');
      }
      // Backward from nothing is the reverse.
      cur = null;
      final back = <String>[];
      for (var k = 0; k < seq.length; k++) {
        cur = stepAnnotationFocus(l, cur, -1);
        back.add(cur!);
      }
      expect(back, seq.reversed.toList());
    }, examples: _forced);

    // ── beyond the numbered laws ────────────────────────────────────────────

    _law('L14 the order the annotations arrive in changes nothing', (spec) {
      final c = _build(spec);
      final n = c.items.length;
      final rotated = [...c.items.skip(n ~/ 2), ...c.items.take(n ~/ 2)];
      for (final order in [c.items.reversed.toList(), rotated]) {
        final d = _diff(c.layout, c.layoutWith(c.focus, order: order), 0);
        _ok(d == null, () => 'reordered input changed the layout: $d');
      }
    }, examples: _forced);
  });

  // The generators must actually REACH what the laws are about, or a law passes
  // by never being exercised. Counted per law, over exactly the 200 generated
  // cases that law runs by default (its own seed), forced scenarios excluded.
  group('generator reach', () {
    test('every law sees every situation in its default cases', () {
      expect(_registry, isNotEmpty);
      final weak = <String>[];
      for (final law in _registry) {
        final got = law.measure();
        for (final e in law.needs.entries) {
          if (got[e.key]! < e.value) {
            weak.add('"${law.name}": ${e.key} in ${got[e.key]} cases, need ${e.value}');
          }
        }
      }
      expect(weak, isEmpty, reason: weak.join('\n'));
    });
  });

  group('regressions', () {
    // layoutAnnotations used to sort a `const []` for an unusable scale and
    // threw UnsupportedError ("Cannot modify an unmodifiable list"), even with
    // no annotations. An unusable scale is absent, not an error.
    test('an unusable scale does not crash the layout (const-list sort)', () {
      final items = [
        const ChartAnnotation(
            id: 'n', kind: AnnotationKind.mainSleep, at: 5, label: 'Night'),
        const ChartAnnotation(
            id: 'm', kind: AnnotationKind.moment, at: 5, label: 'M'),
      ];
      for (final scale in const [
        AnnotationScale(domainStart: 0, domainEnd: 1, width: 0),
        AnnotationScale(domainStart: 0, domainEnd: 0, width: 100),
        AnnotationScale(domainStart: 0, domainEnd: 10, width: double.nan),
        AnnotationScale(domainStart: 0, domainEnd: double.nan, width: 100),
        AnnotationScale(domainStart: 10, domainEnd: 0, width: double.infinity),
      ]) {
        for (final list in [const <ChartAnnotation>[], items]) {
          final l = layoutAnnotations(
              annotations: list, scale: scale, focusId: 'm');
          expect(l.items, isEmpty);
          expect(l.shades, isEmpty);
          expect(l.unplaced, isEmpty);
          expect(l.focusedId, isNull);
          expect(l.labelText, isNull);
        }
      }
    });
  });

  group('known out-of-contract input', () {
    test('duplicate ids: pinned as-is, not a law (the layout indexes by id)', () {
      // Two different moments sharing one id. Both are laid out (the partition
      // counts occurrences), but anything keyed by id sees only the LAST one
      // (by x): with that id focused, BOTH icons report the same focused id,
      // and each shows the byId winner.
      const scale = AnnotationScale(domainStart: 0, domainEnd: 300, width: 300);
      final dup = [
        const ChartAnnotation(
            id: 'dup', kind: AnnotationKind.moment, at: 50, label: 'first'),
        const ChartAnnotation(
            id: 'dup', kind: AnnotationKind.moment, at: 250, label: 'second'),
      ];
      final none = layoutAnnotations(annotations: dup, scale: scale);
      expect([for (final i in none.items) i.id], ['dup', 'dup']);
      expect([for (final i in none.items) i.x], [50, 250]);
      expect(none.focusedId, isNull);
      final f = layoutAnnotations(annotations: dup, scale: scale, focusId: 'dup');
      expect(f.focusedId, 'dup');
      expect([for (final i in f.items) i.focused], [true, true]);
      expect([for (final i in f.items) i.x], [250, 250],
          reason: 'both icons show the byId winner (the later one)');
      expect(f.labelText, 'second');
    });
  });
}

/// True when no discrete decision of the layout sits within 0.01 px of its
/// threshold, so a rounding-sized perturbation cannot flip it: the domain
/// edges, the validity of a range, and the cluster thresholds
/// (iconWidth + k * badgeWidth).
bool _generic(_Chart c) {
  const margin = .01;
  final s = c.scale;
  final span = s.domainEnd - s.domainStart;
  double px(double v) => (v - s.domainStart) * s.width / span;
  for (final a in c.items) {
    if (!a.at.isFinite) continue;
    for (final v in [a.at, if (a.until != null && a.until!.isFinite) a.until!]) {
      final p = px(v);
      if (v != s.domainStart && p.abs() <= margin) return false;
      if (v != s.domainEnd && (p - s.width).abs() <= margin) return false;
    }
    if (_validRange(a) && px(a.until!) - px(a.at) <= margin) return false;
  }
  final xs = [for (final v in c.vis) if (v.ordinary) v.x];
  for (var i = 0; i < xs.length; i++) {
    for (var j = i + 1; j < xs.length; j++) {
      final d = (xs[i] - xs[j]).abs();
      final k = math.max(0, ((d - s.iconWidth) / s.badgeWidth).round());
      if ((d - (s.iconWidth + k * s.badgeWidth)).abs() <= margin) return false;
    }
  }
  return true;
}
