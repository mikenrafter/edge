// THE UX GRAMMAR
//
// Every card has a job. Cards are not decoration, and a screen that reaches
// for a card without being able to name which of the seven it is has not
// finished thinking.
//
//   A · Signal      one number, glanceable, lives in grids
//   B · Progress    something moving toward a goal
//   C · Trend       something changing over time
//   D · Insight     something the system noticed
//   E · Action      something the user should do
//   F · Status      something absent or uncertain
//   G · Deep dive   a gateway into serious data
//
// Plus the non-card primitives (rows, inline metrics, sections) and the
// widgets that encode the behavioural rules — Recommendation, GoalTrajectory,
// Observation, Consistency.
//
// Two rules the components enforce so screens cannot break them:
//
//   • ABSENCE IS A STATUS, NOT A DASH. There is no "empty" variant of Signal
//     or Trend. A metric with no value renders `StatusCard(what, why, fix:)`.
//     The audit found 102 bare `—` with no reason attached; the fix is that
//     the component that would draw one does not exist.
//   • EVERY TAP TARGET IS ≥ 44 pt. Not by convention — `Pressable` is the only
//     gesture primitive in lib/ui2 and `Scrubber` the only drag (the tokens
//     test enforces both, `Listener` included), and `Pressable` applies the
//     minimum itself. There is no longer an `expand: false` to opt out with,
//     and the golden sweep measures every Pressable in every case rather than
//     the five tabs of the shell.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/journal_fields.dart' show formatMinuteOfDay;
import '../models/metric.dart';
import 'charts.dart';
import 'scroll_hint.dart';
import 'theme.dart';

/// ── PRESSABLE ── the only gesture primitive in lib/ui2 ────────────────────
///
/// Guarantees a 44 pt minimum hit area regardless of how small the visual is,
/// and gates its own press feedback through [motion]. Everything tappable in
/// this library — cards, links, tabs, buttons — is built on it.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// Optional measured presses; onTap remains the accessibility action.
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;
  final VoidCallback? onPressCancel;

  /// Screen-reader label. Required for anything whose child is not plain text
  /// (an icon-only control), optional otherwise.
  final String? semanticLabel;

  /// Announce as a link rather than a button — for text that opens a web page.
  final bool link;

  // There is no `expand: false`. It used to exist, documented as "the hit area
  // is still expanded via the parent's slop" — no such mechanism was ever in
  // this codebase, so what it actually did was drop the 44 pt minimum at seven
  // call sites: an 18 × 18 destructive delete, two 20-22 pt closes and a
  // screen's primary action among them. An opt-out nobody can audit is not a
  // guarantee, so the opt-out is gone and the seven visuals are unchanged —
  // only their hit boxes grew.

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onPressStart,
    this.onPressEnd,
    this.onPressCancel,
    this.semanticLabel,
    this.link = false,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  int? _pointer;

  @override
  Widget build(BuildContext c) {
    Widget out = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: S.tap, minHeight: S.tap),
      // widthFactor/heightFactor pin the Align to its child's size. Without
      // them Align fills every pixel it is offered, which turned each card
      // into a greedy box that ate the whole scroll view — caught by the
      // first golden, and invisible in any layout with a bounded parent.
      child: Align(
        alignment: Alignment.center,
        widthFactor: 1,
        heightFactor: 1,
        child: widget.child,
      ),
    );
    if (widget.onPressStart != null || widget.onPressEnd != null ||
        widget.onPressCancel != null) {
      // Raw contact timing belongs at the token boundary, so callers can
      // record a hold without tap-recognition delays or duplicate onTap calls.
      return Semantics(
        button: true,
        label: widget.semanticLabel,
        onTap: widget.onTap,
        excludeSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointer != null) return;
            _pointer = event.pointer;
            setState(() => _down = true);
            widget.onPressStart?.call();
          },
          onPointerUp: (event) {
            if (_pointer != event.pointer) return;
            _pointer = null;
            setState(() => _down = false);
            widget.onPressEnd?.call();
          },
          onPointerCancel: (event) {
            if (_pointer != event.pointer) return;
            _pointer = null;
            setState(() => _down = false);
            widget.onPressCancel?.call();
          },
          child: AnimatedScale(
            scale: _down ? .975 : 1,
            duration: motion(c, Motion.fast),
            child: out,
          ),
        ),
      );
    }
    if (widget.onTap == null) {
      return widget.semanticLabel == null
          ? out
          : Semantics(label: widget.semanticLabel, child: out);
    }
    return Semantics(
      button: !widget.link,
      link: widget.link,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedScale(
          scale: _down ? .975 : 1,
          duration: motion(c, Motion.fast),
          child: out,
        ),
      ),
    );
  }
}

/// A [Pressable] line that keeps its 44 pt hit target without its 44 pt of
/// layout. [child] is laid out at its natural height (a [Pressable] makes that
/// at least [S.tap]); when it is no taller than that, this box reports only
/// [visual] and centres the child, so the target overhangs the lines above and
/// below instead of pushing them apart. A tap anywhere on the whole child lands.
///
/// It must be a direct child of the Column/ListView that stacks the lines: an
/// ancestor that is only [visual] tall would reject a tap on the overhang
/// before it got here. Taller content (wrapped at large text) is left alone.
class HitOverhang extends SingleChildRenderObjectWidget {
  final double visual;
  const HitOverhang({super.key, required this.visual, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHitOverhang(visual);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderHitOverhang).visual = visual;
}

class _RenderHitOverhang extends RenderShiftedBox {
  _RenderHitOverhang(this._visual) : super(null);

  double _visual;
  set visual(double v) {
    if (v == _visual) return;
    _visual = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(constraints.loosen(), parentUsesSize: true);
    final h = c.size.height <= S.tap ? math.min(_visual, c.size.height) : c.size.height;
    size = constraints.constrain(Size(c.size.width, h));
    (c.parentData! as BoxParentData).offset = Offset(0, (size.height - c.size.height) / 2);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    if (c == null) return false;
    final off = (c.parentData! as BoxParentData).offset;
    // The child's own box, not this one's: that is the overhang.
    if (!(off & c.size).contains(position)) return false;
    return hitTestChildren(result, position: position);
  }
}

/// ── SCRUBBER ── the only continuous drag in lib/ui2 ───────────────────────
///
/// It lives here for the same reason [Pressable] does: a drag is a gesture, and
/// a gesture nobody can audit is a control somebody cannot reach. The hypnogram
/// scrub used to be a bare `Listener` on a screen — a precise drag along a
/// 110 pt strip, over a silent painter, with no discrete alternative at all, so
/// per-stage timing was unreachable without a pointer.
///
/// What this adds over the `Listener` it replaces: the slider role, so VoiceOver
/// and Switch Control expose increase/decrease and can walk it a step at a time;
/// [describe], so the position is spoken rather than only drawn; and a tap
/// anywhere on the strip that jumps straight there, which is the whole gesture
/// for anyone who cannot hold a drag steady.
class Scrubber extends StatelessWidget {
  /// 0…1 along the strip. Null means nothing has been placed yet.
  final double? value;
  final ValueChanged<double> onChanged;

  /// What the control IS — 'Hypnogram'.
  final String label;

  /// What the current position READS as — '03:12, light sleep'. This is the
  /// entire readout for a screen-reader user, so it says the value, not the
  /// fraction.
  final String Function(double) describe;

  /// One increase/decrease step. The default walks the strip in twenty moves,
  /// which is about a twenty-minute resolution on a night.
  final double step;

  final Widget child;

  const Scrubber({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    required this.describe,
    required this.child,
    this.step = .05,
  });

  @override
  Widget build(BuildContext c) {
    final v = value;
    // From nothing, increase enters at the start and decrease at the end —
    // either direction places the cursor rather than doing nothing.
    final up = ((v ?? -step) + step).clamp(0.0, 1.0);
    final down = ((v ?? 1 + step) - step).clamp(0.0, 1.0);
    return Semantics(
      label: label,
      slider: true,
      value: v == null ? 'Nothing selected' : describe(v),
      // Flutter requires both neighbours alongside a value, and it is right to:
      // they are what a screen reader reads as you step, so a slider that only
      // states where it IS gives no feedback for the action it just performed.
      increasedValue: describe(up),
      decreasedValue: describe(down),
      onIncrease: () => onChanged(up),
      onDecrease: () => onChanged(down),
      child: LayoutBuilder(
        builder: (_, box) {
          final w = box.maxWidth;
          void set(Offset o) =>
              onChanged(w <= 0 ? 0 : (o.dx / w).clamp(0.0, 1.0));
          return Listener(
            // Opaque, like Pressable. A `Listener` defers to its child by
            // default, so the strip was only touchable where the painter
            // happened to claim a hit — which is a coincidence, not a target.
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => set(e.localPosition),
            onPointerMove: (e) => set(e.localPosition),
            child: child,
          );
        },
      ),
    );
  }
}

/// ── CHARTSCRUB ── every chart is scrubbable ──────────────────────────────
///
/// One wrapper over any chart painter: a tap or a drag places a cursor that
/// follows the finger, and the values at that point appear in a row UNDER the
/// chart ([ChartKeyReadout]) — not in a pill over it. A pill sits under the
/// thumb that placed it, and on a phone the finger is the one thing that
/// always covers the number it is asking for.
///
/// It is a [Scrubber] underneath, so the slider role and [Scrubber.describe]
/// come with it; the spoken value is the same time-and-values the row shows.
///
/// [keys] is one [ChartKey] per series: its colour, its label (units in it) and
/// what it reads at a position 0…1 across the chart, or null where it has
/// nothing. A null reads "—" in the row — a gap is never the value of a
/// neighbour, never interpolated and never a 0. [time] names the position (a
/// clock, a day); it is still said over a gap, because the finger is there
/// even when the data is not.
///
/// Nothing is placed until the first touch, and then the row has nothing to
/// follow: it shows the LATEST point's values and time, and "—" where the chart
/// has no data at all. The row's height does not depend on what it says.
///
/// Inside a [ChartFrame] the row is the frame's key: each value sits directly
/// under the legend entry of the same label, in that entry's column. Outside a
/// frame the scrub draws its own key row under the chart.
///
/// [gaps] adds a "Not recorded" entry — pass `hasChartGaps(series)` (or the
/// chart's own gap list) so it appears only when the window really has a hole.
///
/// [ChartScrubMode.nearest] is for scatter and grid charts (Poincaré, heat map,
/// month grid): the row alone, no line through the picture.
enum ChartScrubMode { line, nearest }

/// Whether any of [series] has a stretch with nothing recorded that its chart
/// draws as a gap. Pure; the one rule behind every "Not recorded" key.
///
/// A slot is absent when it is null or not finite. A series with no reading at
/// all is NO DATA, not a gap (the frame says so in words). Leading and interior
/// holes are gaps; trailing ones are only gaps when [trailing] is set, because a
/// window that runs to "now" has no recorded future to be missing.
bool hasChartGaps(Iterable<List<double?>> series, {bool trailing = false}) {
  bool ok(double? v) => v != null && v.isFinite;
  for (final d in series) {
    final first = d.indexWhere(ok);
    if (first < 0) continue;
    if (first > 0) return true;
    final last = d.lastIndexWhere(ok);
    for (var i = first; i <= last; i++) {
      if (!ok(d[i])) return true;
    }
    if (trailing && last < d.length - 1) return true;
  }
  return false;
}

/// One series in a chart's key: what it is called, what colour draws it, and
/// what it reads at a position along the chart.
@immutable
class ChartKey {
  final String label;
  final Color color;

  /// The value at 0…1 across the chart, already worded with its unit, or null
  /// where the series has nothing.
  final String? Function(double at) value;

  /// Where the latest reading sits, 0…1 — what the row shows when nothing is
  /// scrubbed. Null means this series never has one.
  final double? latest;

  /// Whether the finger is on this entry's own mark (a stacked bar's band).
  final bool Function(double at)? active;

  /// What to say when nothing is scrubbed, for a chart whose "latest" is not a
  /// place along the x axis (a scatter's last point). Wins over [value] at rest.
  final String? Function()? atRest;

  /// Whether this entry is a recording. False for one that only names a shaded
  /// stretch (asleep, a workout): it says yes or no, and neither means the band
  /// was there, so it takes no part in deciding that a point is a gap.
  final bool data;

  const ChartKey(this.label, this.color, this.value,
      {this.latest = 1.0, this.active, this.atRest, this.data = true});

  /// A dense series — one entry per slot, `null` in the holes, the same list
  /// the painter draws. Lines read the slot nearest the finger; with [bars] the
  /// finger reads the bar it is over. A hole or a non-finite sample reads null.
  factory ChartKey.slots(
    String label,
    Color color,
    List<double?> d,
    String Function(int i, double v) say, {
    bool bars = false,
  }) {
    bool ok(double? v) => v != null && v.isFinite;
    final last = d.lastIndexWhere(ok);
    return ChartKey(
      label,
      color,
      (at) {
        if (d.isEmpty) return null;
        final i = ChartScrub.slotAt(d.length, at, bars: bars);
        final v = d[i];
        return ok(v) ? say(i, v!) : null;
      },
      latest: last < 0
          ? null
          : bars
              ? (last + .5) / d.length
              : d.length < 2
                  ? 0.0
                  : last / (d.length - 1),
    );
  }

  /// A value that does not depend on where the finger is — a zone's minutes in
  /// a stacked bar. [active] marks the entry the finger is on.
  factory ChartKey.fixed(String label, Color color, String? value,
          {bool Function(double at)? active}) =>
      ChartKey(label, color, (_) => value,
          latest: null, active: active, atRest: () => value);
}

/// One cell of the key row. A null [color] is the "Not recorded" entry.
@immutable
class ChartCell {
  final String label;
  final Color? color;

  /// Null with [hasValue] reads "—" (the series has nothing here). A cell with
  /// no [hasValue] is a plain key entry with no series behind it.
  final String? value;
  final bool hasValue;
  final bool active;
  const ChartCell(this.label, this.color,
      {this.value, this.hasValue = true, this.active = false});
}

/// What the row says at one position: the time, then a cell per series.
@immutable
class ChartReadout {
  /// Null when the chart has no time axis to name.
  final String? time;
  final bool scrubbed;
  final List<ChartCell> cells;
  const ChartReadout(
      {required this.time, required this.scrubbed, required this.cells});

  /// Everything the row would draw, as one string — compared to decide whether
  /// a frame's key is stale.
  String get signature => [
        time,
        scrubbed,
        for (final c in cells) '${c.label}|${c.value}|${c.hasValue}|${c.active}',
      ].join('\u0001');
}

class ChartScrub extends StatefulWidget {
  final String label;
  final List<ChartKey> keys;
  final String? Function(double at)? time;
  final bool gaps;
  final Widget child;
  final ChartScrubMode mode;
  final double step;

  static const cursorKey = ValueKey('chart-scrub-cursor');
  static const noData = 'No data here';

  /// The slot a position reads: the nearest sample for a line, the bar under
  /// the finger for [bars]. Clamped, so either edge is a real slot.
  static int slotAt(int length, double at, {bool bars = false}) {
    if (length <= 0) return 0;
    final i = bars ? (at * length).floor() : (at * (length - 1)).round();
    return i.clamp(0, length - 1);
  }

  /// What the row says at [at] (null: nothing scrubbed — the latest point).
  static ChartReadout resolve({
    required List<ChartKey> keys,
    String? Function(double at)? time,
    bool gaps = false,
    double? at,
  }) {
    double? latest;
    for (final k in keys) {
      final l = k.latest;
      if (l != null && (latest == null || l > latest)) latest = l;
    }
    final pos = at ?? latest;
    final cells = <ChartCell>[
      for (final k in keys)
        ChartCell(k.label, k.color,
            value: at == null && k.atRest != null
                ? k.atRest!()
                : pos == null
                    ? null
                    : k.value(pos),
            active: pos != null && (k.active?.call(pos) ?? false)),
    ];
    if (gaps) {
      // "Here" only while the finger is on a hole in every recorded series.
      final onGap = at != null &&
          keys.any((k) => k.data) &&
          [for (var i = 0; i < keys.length; i++) if (keys[i].data) cells[i]]
              .every((c) => c.value == null);
      cells.add(ChartCell(ChartKeyReadout.notRecorded, null,
          value: onGap ? ChartKeyReadout.here : null, hasValue: onGap));
    }
    return ChartReadout(
      time: time == null
          ? null
          : pos == null
              ? ChartKeyReadout.absent
              : (time(pos) ?? ChartKeyReadout.absent),
      scrubbed: at != null,
      cells: cells,
    );
  }

  /// Local minutes past midnight as "7:05 AM" — the time half of a readout.
  static String clock(int minuteOfDay) => formatMinuteOfDay(minuteOfDay);

  /// The local calendar day [ago] days before today — "Today", "Yesterday",
  /// then "Mon 5 Oct". Built from the calendar fields rather than by
  /// subtracting 24 h, so a DST change cannot move it a day.
  static String dayBack(int ago) {
    if (ago <= 0) return 'Today';
    if (ago == 1) return 'Yesterday';
    final n = DateTime.now();
    return day(DateTime(n.year, n.month, n.day - ago));
  }

  /// A calendar day as "Mon 5 Oct".
  static String day(DateTime d) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]}';
  }

  /// One [ChartKey] per band of a stacked bar ([ZoneBar]), laid out the way the
  /// painter lays them out (running total of [fracs]). Each band's value is its
  /// own, wherever the finger is; the band under the finger is [active]. A band
  /// with no width cannot be hit, and neither can a non-finite one.
  static List<ChartKey> bandKeys(
    List<String> labels,
    List<Color> colors,
    List<double> fracs,
    List<String?> values,
  ) {
    bool live(double f) => f.isFinite && f > 0;
    bool hit(int i, double at) {
      var lo = 0.0;
      for (var k = 0; k < fracs.length; k++) {
        final f = fracs[k];
        if (!live(f)) continue;
        if (at >= lo && at < lo + f) return k == i;
        lo += f;
      }
      return false;
    }

    return [
      for (var i = 0; i < labels.length; i++)
        ChartKey.fixed(
            labels[i], colors[i % colors.length], i < values.length ? values[i] : null,
            active: (at) => hit(i, at)),
    ];
  }

  /// [bandKeys] over five zones of minutes, named Z1…Z5 and coloured the way
  /// [ZoneBar] draws them. Each reads its own minutes and share of the total;
  /// a zone with no minutes reads "0 min", a measured nothing. No minutes at all
  /// draws no bar and reads "—" everywhere.
  static List<ChartKey> zoneKeys(P p, List<num> minutes) {
    final total = minutes.fold<double>(0, (a, b) => a + b);
    final has = total > 0;
    final fracs = [for (final m in minutes) has ? m / total : 0.0];
    return bandKeys(
      [for (var i = 0; i < minutes.length; i++) 'Z${i + 1}'],
      ZoneBar.cols(p),
      fracs,
      [
        for (var i = 0; i < minutes.length; i++)
          has ? '${minutes[i].round()} min · ${(fracs[i] * 100).round()}%' : null,
      ],
    );
  }

  const ChartScrub({
    super.key,
    required this.label,
    required this.keys,
    required this.child,
    this.time,
    this.gaps = false,
    this.mode = ChartScrubMode.line,
    this.step = .05,
  });

  @override
  State<ChartScrub> createState() => _ChartScrubState();
}

class _ChartScrubState extends State<ChartScrub> {
  double? _at;
  _ChartHub? _hub;

  ChartReadout _resolve(double? at) => ChartScrub.resolve(
      keys: widget.keys, time: widget.time, gaps: widget.gaps, at: at);

  /// The same time-and-values the row shows, as a sentence.
  String _spoken(double at) {
    final r = _resolve(at);
    final vals = [
      for (final c in r.cells)
        if (c.color != null && c.value != null) '${c.label} ${c.value}',
    ];
    return [
      if (r.time != null && r.time != ChartKeyReadout.absent) r.time!,
      if (vals.isEmpty) ChartScrub.noData else ...vals,
    ].join(', ');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final h = _ChartHubScope.maybeOf(context);
    if (!identical(h, _hub)) {
      _hub?.detach(this);
      _hub = h;
    }
  }

  @override
  void dispose() {
    _hub?.detach(this);
    super.dispose();
  }

  void _place(double x) {
    setState(() => _at = x);
    _hub?.setAt(x);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final v = _at;
    final hub = _hub;
    hub?.attach(this, _resolve, v);
    final plot = Scrubber(
      value: v,
      onChanged: _place,
      label: widget.label,
      describe: _spoken,
      step: widget.step,
      // Passthrough: the chart keeps the size it always had; the cursor is a
      // positioned overlay and adds nothing to the layout.
      child: Stack(fit: StackFit.passthrough, children: [
        widget.child,
        if (v != null && widget.mode == ChartScrubMode.line)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (_, box) => Stack(children: [
                  Positioned(
                    left: v * box.maxWidth - 1,
                    top: 0,
                    bottom: 0,
                    width: 2,
                    child: ColoredBox(key: ChartScrub.cursorKey, color: p.ink),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
    // In a frame the frame draws the row, under its own x labels. Bare, the row
    // goes directly under the chart.
    if (hub != null) return plot;
    final row = ChartKeyReadout.of(_resolve(v));
    return LayoutBuilder(
      builder: (_, box) => Column(
        mainAxisSize:
            box.hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (box.hasBoundedHeight) Expanded(child: plot) else plot,
          const SizedBox(height: S.x2),
          ExcludeSemantics(child: row),
        ],
      ),
    );
  }
}

/// ── CHARTKEYREADOUT ── the key row, with the values in it ───────────────────
///
/// The time first (a "Latest" or "Selected" caption over the clock or day),
/// then one cell per series: colour swatch, label, and the value under them. A
/// value is always one line — it shrinks to fit before it wraps — and the row
/// is as tall for "—" as for a number, so scrubbing never moves what is below
/// it. Cells share the width equally and wrap to further rows when the text
/// scale leaves no room for them side by side.
class ChartKeyReadout extends StatelessWidget {
  final String? time;
  final bool scrubbed;
  final List<ChartCell> cells;

  const ChartKeyReadout(
      {super.key, required this.cells, this.time, this.scrubbed = false});

  factory ChartKeyReadout.of(ChartReadout r) =>
      ChartKeyReadout(cells: r.cells, time: r.time, scrubbed: r.scrubbed);

  static const timeKey = ValueKey('chart-key-time');
  static const latest = 'Latest';
  static const selected = 'Selected';
  static const absent = '—';
  static const notRecorded = 'Not recorded';
  static const here = 'Here';

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final scale = MediaQuery.textScalerOf(c).scale(1).clamp(1.0, 1.8);
    final items = <Widget>[
      if (time != null) _time(p),
      for (final cell in cells) _cell(p, cell),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    const gap = S.x3;
    final minW = 92.0 * scale;
    return LayoutBuilder(
      builder: (_, box) {
        final w = box.maxWidth;
        final cols = w.isFinite
            ? ((w + gap) / (minW + gap)).floor().clamp(1, items.length)
            : items.length;
        final cellW =
            w.isFinite ? ((w - gap * (cols - 1)) / cols) - .01 : minW;
        // Rows of equal cells. Within a row every cell is as tall as the
        // tallest, with its value pinned to the foot, so the values line up
        // along one baseline however many lines a label wrapped to.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r * cols < items.length; r++) ...[
              if (r > 0) const SizedBox(height: S.x2),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var k = 0; k < cols; k++) ...[
                      if (k > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: cellW,
                        child: r * cols + k < items.length
                            ? items[r * cols + k]
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _time(P p) => Column(
        key: timeKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(scrubbed ? selected : latest,
              style: F.over.copyWith(color: p.ink3),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(time!,
                  maxLines: 1,
                  style: F.cap.copyWith(
                      color: time == absent ? p.ink3 : p.ink,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      );

  Widget _cell(P p, ChartCell cell) {
    final gapKey = cell.color == null;
    final shown = cell.hasValue ? (cell.value ?? absent) : ' ';
    final present = cell.hasValue && cell.value != null;
    return Column(
      key: ValueKey('chart-key-cell:${cell.label}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2.5),
              child: Container(
                key: ValueKey('chart-key-swatch:${cell.label}'),
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // The swatch is the mark's real colour so the two match, and
                  // a pale mark still needs an edge to be findable. A gap has
                  // no colour of its own: it is the ground, outlined.
                  color: gapKey ? p.card2 : cell.color,
                  border: Border.all(
                      color: gapKey ? p.ink3 : p.line, width: gapKey ? 1 : .5),
                ),
              ),
            ),
            const SizedBox(width: S.x1),
            Expanded(
              // Never truncated: a label is a constant, so letting it wrap
              // costs nothing in stability and a clipped key names nothing.
              child: Text(cell.label,
                  style: F.over.copyWith(
                      color: cell.active ? p.ink : p.ink3,
                      fontWeight:
                          cell.active ? FontWeight.w700 : FontWeight.w600)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: FittedBox(
            key: ValueKey('chart-key-value:${cell.label}'),
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(shown,
                maxLines: 1,
                style: F.cap.copyWith(
                    color: present ? p.ink : p.ink3,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
      ],
    );
  }
}

/// ── the frame ↔ scrub hand-off ─────────────────────────────────────────────
///
/// The scrub lives inside the plot and the key row lives under the x axis, so
/// they have to share a position. [ChartFrame] hosts a hub; a [ChartScrub]
/// below it attaches what it reads and where the finger is. Attaching during
/// build is synchronous — the key row is built after the plot, so it sees the
/// scrub on the first frame; a scrub that builds later (inside a LayoutBuilder)
/// or changes under a still frame is caught by comparing what the row last drew
/// with what it would draw now.
class _ChartHub extends ChangeNotifier {
  Object? _owner;
  ChartReadout Function(double? at)? _resolve;
  double? at;
  String? rendered;
  bool _pending = false;
  bool _dead = false;

  ChartReadout? read() => _resolve?.call(at);

  void attach(Object owner, ChartReadout Function(double? at) resolve,
      double? position) {
    _owner = owner;
    _resolve = resolve;
    at = position;
    _check();
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _resolve = null;
    at = null;
    _check();
  }

  void setAt(double? x) {
    at = x;
    if (!_dead) notifyListeners();
  }

  void _check() {
    if (_pending || _dead) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (_dead) return;
      if (rendered != (read()?.signature ?? '')) notifyListeners();
    });
  }

  @override
  void dispose() {
    _dead = true;
    super.dispose();
  }
}

class _ChartHubScope extends InheritedWidget {
  final _ChartHub hub;
  const _ChartHubScope({required this.hub, required super.child});

  static _ChartHub? maybeOf(BuildContext c) =>
      c.getInheritedWidgetOfExactType<_ChartHubScope>()?.hub;

  @override
  bool updateShouldNotify(_ChartHubScope old) => !identical(hub, old.hub);
}

class _ChartHubHost extends StatefulWidget {
  final Widget Function(_ChartHub hub) builder;
  const _ChartHubHost({required this.builder});

  @override
  State<_ChartHubHost> createState() => _ChartHubHostState();
}

class _ChartHubHostState extends State<_ChartHubHost> {
  final _hub = _ChartHub();

  @override
  void dispose() {
    _hub.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) =>
      _ChartHubScope(hub: _hub, child: widget.builder(_hub));
}

/// The base card surface. Elevation, not outline.
class Surface extends StatelessWidget {
  final Widget child;
  final EdgeInsets pad;
  final VoidCallback? onTap;
  final Color? color;
  final int elevation;
  final String? semanticLabel;

  const Surface({
    super.key,
    required this.child,
    this.pad = const EdgeInsets.all(S.x4),
    this.onTap,
    this.color,
    this.elevation = 1,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Container(
        width: double.infinity,
        padding: pad,
        decoration: BoxDecoration(
          color: color ?? p.card,
          borderRadius: R.rLg,
          boxShadow: p.el(elevation),
        ),
        child: child,
      ),
    );
  }
}

/// Full-width section. Whitespace separates concepts, not borders.
class Section extends StatelessWidget {
  final String title;
  final String? action;
  final Widget child;
  final VoidCallback? onAction;

  const Section(
    this.title,
    this.child, {
    super.key,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(S.x1, S.x5, S.x1, S.x2),
          child: Row(
            // spaceBetween owns the gap, so the action sits on the right edge
            // however short the title is. Previously the title was Expanded
            // and the action Flexible — both default to flex: 1, so they split
            // the row 50/50 and the action started at the midpoint instead of
            // being anchored. Making the action a plain child fixes the anchor
            // but overflows on a long title, so the TITLE is the half that
            // gives: Flexible, two lines, ellipsised.
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: F.head.copyWith(color: p.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (action != null)
                Flexible(
                  child: Pressable(
                    onTap: onAction,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: S.x2),
                      child: Text(
                        action!,
                        style: F.cap.copyWith(
                          color: p.on(C.blue),
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

// ══════════════════ A · SIGNAL ══════════════════
/// One number. Glanceable. Lives in grids.
class SignalCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label, value, unit, sub;

  final VoidCallback? onTap;

  /// A small dial in the header row's slack — steps is the only caller today,
  /// showing progress toward its goal without a second card.
  final Widget? trailing;

  const SignalCard(
    this.icon,
    this.color,
    this.label,
    this.value, {
    super.key,
    this.unit = '',
    this.sub = '',
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      onTap: onTap,
      semanticLabel: '$label, $value $unit'.trim(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: p.on(color)),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  label,
                  style: F.cap.copyWith(color: p.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: S.x3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: F.n24.copyWith(color: p.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: S.x1),
                Text(unit, style: F.cap.copyWith(color: p.ink3)),
              ],
            ],
          ),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: S.x1),
            Text(
              sub,
              style: F.over.copyWith(color: p.ink3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════ B · PROGRESS ══════════════════
/// Something moving toward a goal. Current → target.
class ProgressCard extends StatelessWidget {
  final String label, value, target;
  final double frac;
  final Color color;
  final IconData? icon;

  const ProgressCard(
    this.label,
    this.value,
    this.target,
    this.frac,
    this.color, {
    super.key,
    this.icon,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final amount = Wrap(
      spacing: S.x2,
      children: [
        Text(
          value,
          style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600),
        ),
        Text(target, style: F.cap.copyWith(color: p.ink3)),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label and amount share a line until the text scale makes that a choice
        // between truncating a measurement and growing the card. `1h 38m / of
        // 2h 00m` overflowed by 262 px at 3× — and by 105 px with the golden's
        // own two-character fixture, which is how it shipped.
        if (bigText(c))
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: p.on(color)),
                    const SizedBox(width: S.x2),
                  ],
                  Expanded(
                    child: Text(label, style: F.cap.copyWith(color: p.ink2)),
                  ),
                ],
              ),
              const SizedBox(height: S.x1),
              amount,
            ],
          )
        else
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: p.on(color)),
                const SizedBox(width: S.x2),
              ],
              Expanded(
                child: Text(label, style: F.cap.copyWith(color: p.ink2)),
              ),
              amount,
            ],
          ),
        const SizedBox(height: S.x2),
        _Bar(frac: frac, color: color),
      ],
    );
  }
}

/// The one progress bar. Everything with a fraction uses it.
class _Bar extends StatelessWidget {
  final double frac;
  final Color color;
  const _Bar({required this.frac, required this.color});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ClipRRect(
      borderRadius: R.rPill,
      child: LinearProgressIndicator(
        value: frac.clamp(0, 1),
        minHeight: 8,
        backgroundColor: p.track,
        valueColor: AlwaysStoppedAnimation(p.on(color)),
      ),
    );
  }
}

// ══════════════════ C · TREND ══════════════════
/// Something changing. Value → context → direction.
class TrendCard extends StatelessWidget {
  final String label, value, unit, delta, window;
  final bool up;

  /// Whether the move is good news — or NULL when there is nothing to compare
  /// against. Null draws no arrow and passes no judgement: the card states
  /// [delta] as the caller wrote it ("no baseline") and stops there.
  final bool? good;

  /// DENSE — see [MetricRow.series].
  final List<double?> series;
  final Color color;
  final VoidCallback? onTap;

  const TrendCard(
    this.label,
    this.value,
    this.unit,
    this.delta,
    this.window,
    this.series,
    this.color, {
    super.key,
    this.up = false,
    this.good = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final j = good;
    // The arrow says which WAY, the colour says whether that is good news, and
    // those are independent: "HRV down" and "resting heart rate down" draw the
    // same arrow in different hues. Hue alone is not a channel, so the reading
    // goes in the label too.
    //
    // With no baseline there is no way and no news — an arrow and a hue would
    // both be inventions, so neither is drawn and the label says nothing about
    // better or worse.
    final dir = j == null ? p.ink3 : p.on(j ? C.green : C.orange);
    final judgement = j == null ? '' : (j ? 'an improvement' : 'worse than usual');
    final change = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (j != null) ...[
          Icon(
            up ? LucideIcons.arrowUpRight : LucideIcons.arrowDownRight,
            size: 14,
            color: dir,
          ),
          const SizedBox(width: S.x1),
        ],
        Text(
          delta,
          style: F.cap.copyWith(color: dir, fontWeight: FontWeight.w600),
        ),
      ],
    );
    // Whether value, a sliver of caption and the change share one line. When
    // they do not, the change restacks (the Wrap below) rather than the value
    // giving way: the hero number is never the part that is cut.
    final scaler = MediaQuery.textScalerOf(c);
    double width(String t, TextStyle st) => (TextPainter(
            text: TextSpan(text: t, style: st),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1)
          ..layout())
        .width;
    final changeStyle = F.cap.copyWith(fontWeight: FontWeight.w600);
    bool oneRow(double room) =>
        width(value, F.n34) +
            S.x1 +
            math.min(width(unit, F.cap), 72) +
            S.x2 +
            (j == null ? 0 : 14 + S.x1) +
            width(delta, changeStyle) <=
        room;
    return Surface(
      onTap: onTap,
      semanticLabel:
          '$label, $value $unit, $delta $window${judgement.isEmpty ? '' : ', $judgement'}'
              .trim(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: F.cap.copyWith(color: p.ink2)),
          const SizedBox(height: S.x2),
          // A realistic value — `7h 42m`, not the two characters the golden used
          // to pass on — pushed the delta and its arrow clean off the card: 202 px
          // at 2×, 458 at 3×. Above the restack point the change moves to its own
          // run rather than off the edge.
          LayoutBuilder(
            builder: (lc, box) => bigText(c) || !oneRow(box.maxWidth)
            ? Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: S.x2,
              runSpacing: S.x1,
              children: [
                Text(value, style: F.n34.copyWith(color: p.ink)),
                Text(unit, style: F.cap.copyWith(color: p.ink3)),
                change,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // The value and the change take the room they need and the
                // caption takes what is left, so on a narrow card it is the
                // caption that wraps or shortens. The value used to be the
                // flexible one: "Time asleep" beside "4h 22m" and a delta cut
                // the hero to "4h 2…" at 360 pt.
                Text(
                  value,
                  style: F.n34.copyWith(color: p.ink),
                  maxLines: 1,
                  softWrap: false,
                ),
                const SizedBox(width: S.x1),
                // `unit` takes the remainder and left-aligns in it, which is
                // also what keeps the change flush right (a Spacer next to a
                // flexible unit split the row 50/50 and shortened a long
                // reading with empty space beside it).
                Expanded(
                  child: Text(
                    unit,
                    style: F.cap.copyWith(color: p.ink3),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: S.x2),
                if (j != null) ...[
                  Icon(
                    up ? LucideIcons.arrowUpRight : LucideIcons.arrowDownRight,
                    size: 14,
                    color: dir,
                  ),
                  const SizedBox(width: S.x1),
                ],
                Text(
                  delta,
                  style: F.cap.copyWith(
                    color: dir,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: S.x1),
          Text(window, style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x4),
          SizedBox(
            height: 64,
            child: CustomPaint(
              size: Size.infinite,
              // No `dotInk`: `dots` is off here, and the knockout colour is
              // only ever read inside the head-dot branch.
              painter: LineChart(series, p.on(color)),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════ D · INSIGHT ══════════════════
/// Something the system noticed. Recommendation → reason → action.
class InsightCard extends StatelessWidget {
  final String headline, reason, action;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const InsightCard(
    this.headline,
    this.reason, {
    super.key,
    this.action = '',
    this.icon = LucideIcons.sparkles,
    this.color = C.blue,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = p.on(color);
    return Surface(
      onTap: onTap,
      color: p.wash(color, strength: .65),
      elevation: 0,
      semanticLabel: '$headline. $reason',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.wash(color),
                  borderRadius: R.rSm,
                ),
                child: Icon(icon, size: 16, color: ink),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style: F.body.copyWith(
                        color: p.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: S.x1),
                    Text(
                      reason,
                      style: F.cap.copyWith(color: p.ink2, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (action.isNotEmpty) ...[
            const SizedBox(height: S.x2),
            Padding(
              padding: const EdgeInsets.only(left: S.x10 + S.x1),
              child: _Cta(action, ink),
            ),
          ],
        ],
      ),
    );
  }
}

/// The "do the thing →" affordance. Always a label plus an arrow, never an
/// arrow alone.
class _Cta extends StatelessWidget {
  final String label;
  final Color color;

  /// The arrow is the promise that this goes somewhere. A `StatusCard` whose
  /// fix is advice ("Wear the band overnight") has nothing to tap, so it gets
  /// the emphasis without the arrow — 60% of cards were drawing a dead link.
  final bool arrow;
  const _Cta(this.label, this.color, {this.arrow = true});

  @override
  Widget build(BuildContext c) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(
          label,
          style: F.cap.copyWith(color: color, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (arrow) ...[
        const SizedBox(width: S.x1),
        Icon(LucideIcons.arrowRight, size: 13, color: color),
      ],
    ],
  );
}

// ══════════════════ E · ACTION ══════════════════
/// Something the user should do.
class ActionCard extends StatelessWidget {
  final String title, meta, cta;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const ActionCard(
    this.title,
    this.meta,
    this.cta,
    this.icon,
    this.color, {
    super.key,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final wide = bigText(c);
    // The CTA is never Flexible: it is a button label, and a clipped one reads
    // as a different word. Below the restack point it wins the row against the
    // title, which is the right loser; above it, it takes its own line.
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x2),
      decoration: BoxDecoration(color: p.fill(color), borderRadius: R.rSm),
      child: Text(
        cta,
        style: F.cap.copyWith(color: p.inkOnFill, fontWeight: FontWeight.w600),
      ),
    );
    final head = Row(
      children: [
        Container(
          width: S.tap,
          height: S.tap,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.wash(color), borderRadius: R.rMd),
          child: Icon(icon, size: 20, color: p.on(color)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: F.body.copyWith(
                  color: p.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(meta, style: F.cap.copyWith(color: p.ink3)),
            ],
          ),
        ),
        if (!wide) ...[const SizedBox(width: S.x3), badge],
      ],
    );
    return Surface(
      onTap: onTap,
      semanticLabel: '$title. $meta. $cta',
      child: !wide
          ? head
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                head,
                const SizedBox(height: S.x3),
                Align(alignment: Alignment.centerLeft, child: badge),
              ],
            ),
    );
  }
}

// ══════════════════ F · STATUS ══════════════════

/// How much of the window a gap has to swallow before it is allowed to be the
/// reason. An hour: a radio hiccup or a shower is not why a night went
/// unscored, and offering one as the cause is the false diagnosis with an
/// unactionable fix that costs more trust than the bare absence did.
///
/// The WINDOW does the rest of the work — it decides WHERE a gap has to fall,
/// which is the part that separates "on the charger all night" from "took it
/// off at lunch". A proportional gate on top of it reads well and is wrong:
/// the night window is deliberately wide enough to hold any bedtime, so a
/// third of it is nearly five hours, and the ordinary three-hour charge that
/// really did cost the night would be thrown away for being too short.
const int _kGapMinSec = 60 * 60;

/// THE MEASURED REASON A METRIC IS MISSING, when the wear record holds one.
///
/// [wear] is one or two `getDayWear` maps — two when the window crosses
/// midnight, because a night's gap starts on the evening BEFORE the day it is
/// filed under. Touching off-stretches are joined across that seam first, or a
/// band off from 11:20 PM to 2:14 AM would be two sub-threshold gaps meeting at
/// midnight instead of the one three-hour hole it was.
///
/// Each map's `segments` are `{on, start, end, len_min}`
/// over the OBSERVABLE day, so the leading and trailing holes are on the list
/// too — a night whose records begin at 9 am really does carry its 00:00–09:00
/// gap. Reads as a wear MEASUREMENT only when the key is there: an ABSENT
/// `segments` is "we never looked", and `[]` from an older bundle is not
/// "the band was never off your wrist" either, so both return null.
///
/// [fromSec]/[toSec] are the window the missing metric was read from. The gap
/// has to be the one that plausibly explains THAT window — a hole at 3 pm says
/// nothing about a night — and when none does, this returns null and the caller
/// says nothing extra rather than reaching for the nearest gap it can find.
String? wearGapWhy(
  List<Map<String, dynamic>?> wear, {
  required int fromSec,
  required int toSec,
}) {
  if (toSec <= fromSec) return null;
  final off = <List<int>>[];
  for (final w in wear) {
    final segs = w?['segments'];
    if (segs is! List) continue;
    for (final s in segs) {
      if (s is! Map || s['on'] != false) continue;
      final a = (s['start'] as num?)?.toInt(), b = (s['end'] as num?)?.toInt();
      if (a != null && b != null && b > a) off.add([a, b]);
    }
  }
  if (off.isEmpty) return null;
  off.sort((x, y) => x[0].compareTo(y[0]));
  final joined = <List<int>>[off.first];
  for (final o in off.skip(1)) {
    if (o[0] <= joined.last[1]) {
      joined.last[1] = math.max(joined.last[1], o[1]);
    } else {
      joined.add(o);
    }
  }
  int? bestStart, bestEnd;
  var best = 0;
  for (final o in joined) {
    final overlap = math.min<int>(o[1], toSec) - math.max<int>(o[0], fromSec);
    if (overlap < _kGapMinSec || overlap <= best) continue;
    best = overlap;
    bestStart = o[0];
    bestEnd = o[1];
  }
  if (bestStart == null || bestEnd == null) return null;
  // The stretch's OWN bounds, not the part of it inside the window: the gap is
  // a thing that happened, and clipping it to the question would report a
  // shorter absence than the one that was measured.
  return 'Your band was off your wrist from ${_clock(bestStart)} to '
         '${_clock(bestEnd)}.';
}

String _clock(int epochSec) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  return formatMinuteOfDay(d.hour * 60 + d.minute);
}

/// Something unavailable or uncertain. WHAT is missing → WHY → WHAT FIXES IT.
///
/// This is the only correct rendering of an absent metric anywhere in the app.
/// Never an error, never a bare dash, never a zero.
class StatusCard extends StatelessWidget {
  final String what, why, fix;
  final IconData icon;
  final VoidCallback? onFix;

  /// Replaces the [icon] glyph — a small spinner in place of a static icon is
  /// the whole difference between "this is missing" and "this is happening",
  /// and the rest of the card (title, body, fix) is identical either way.
  final Widget? leading;

  const StatusCard(
    this.what,
    this.why, {
    super.key,
    this.fix = '',
    this.icon = LucideIcons.circleHelp,
    this.onFix,
    this.leading,
  });

  /// Build straight from an abstention — turns the metric's own note into the
  /// honest three-part copy instead of a dash. Returns null when [m] actually
  /// has a value.
  ///
  /// THE PIPELINE'S REASON OUTRANKS THE SCREEN'S. [why] is a sentence written
  /// into a widget by someone who never saw the day, so it is the FALLBACK, not
  /// the answer: whenever the metric came back carrying a reason of its own,
  /// that reason is what renders. And when there is neither — no note, no
  /// [why] — the card says it does not know. It used to say "No measurement
  /// covering this period", which is a cause, and it was printed on days with
  /// 89 % wear and a scored night.
  /// [gap] is a MEASURED reason from the wear record — see [wearGapWhy]. It
  /// ranks between the two existing sources, which is the only place it can
  /// honestly sit: the pipeline saw the day and keeps the first sentence, so a
  /// gap is ADDED to it, while a [why] written into a widget by someone who
  /// never saw the day is replaced by the thing that was measured. Null gap
  /// leaves every existing card byte-identical.
  static StatusCard? forMetric(
    String what,
    Metric? m, {
    String unit = 'nights',
    String why = '',
    String? gap,
    VoidCallback? onFix,
  }) {
    if (m != null && !m.isEmpty) return null;
    final need = needMessageFromNote(m?.note, unit: unit);
    // A need_baseline note is rendered as the FIX ("Need 3 more nights"), so
    // its why stays the generic one — every other note is the why itself.
    final told = need == null ? whyFromNote(m?.note) : null;
    return StatusCard(
      what,
      told != null
          ? (gap == null ? told : '$told $gap')
          : gap ??
              (why.isNotEmpty
                  ? why
                  : need != null
                      ? 'Not enough history to set your baseline yet.'
                      : 'The app has no record of why this is missing.'),
      fix: need ?? '',
      onFix: onFix,
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      elevation: 0,
      color: p.card2,
      onTap: onFix,
      semanticLabel: [what, why, fix].where((s) => s.isNotEmpty).join('. '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              leading ?? Icon(icon, size: 16, color: p.ink3),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  what,
                  style: F.body.copyWith(
                    color: p.ink2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          // A card may be a title and an action with no body. That is the
          // minimal-text ideal, not a broken card — what it must never be is a
          // title alone, which is why `fix` and `why` cannot both be empty at
          // the call sites that matter.
          if (why.isNotEmpty) ...[
            const SizedBox(height: S.x2),
            Text(why, style: F.cap.copyWith(color: p.ink3, height: 1.5)),
          ],
          if (fix.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            _Cta(fix, p.on(C.blue), arrow: onFix != null),
          ],
        ],
      ),
    );
  }
}

// ══════════════════ G · DEEP DIVE ══════════════════
/// A gateway into serious data.
class DeepDiveCard extends StatelessWidget {
  final String label, value, unit, cta;
  final Widget? preview;
  final Color color;
  final VoidCallback? onTap;

  const DeepDiveCard(
    this.label,
    this.value,
    this.unit,
    this.cta,
    this.color, {
    super.key,
    this.preview,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final semantic = '$label, $value $unit. $cta';
    // A card with a preview chart holds a scrubber, and a scrubber owns the tap.
    // The card then opens through its header and its call to action
    // instead of as a whole, so one tap never both scrubs and navigates.
    final whole = preview == null;
    Widget tappable(Widget child) => whole
        ? child
        : Pressable(onTap: onTap, semanticLabel: semantic, child: child);
    final header = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Same restack as TrendCard, for the same reason: `7h 42m` beside a
          // full-width label overflowed by 184 px at 3×.
          if (bigText(c))
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: F.cap.copyWith(color: p.ink2)),
                const SizedBox(height: S.x1),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: S.x1,
                  children: [
                    Text(value, style: F.n24.copyWith(color: p.ink)),
                    Text(unit, style: F.cap.copyWith(color: p.ink3)),
                  ],
                ),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Same 50/50 split as above: Expanded and Flexible are both
                // flex: 1, so the reading started at the midpoint. Both
                // shrinkable with spaceBetween owning the gap anchors it.
                Flexible(
                  child: Text(
                    label,
                    style: F.cap.copyWith(color: p.ink2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: S.x2),
                Flexible(
                  child: Text(
                    value,
                    style: F.n24.copyWith(color: p.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: S.x1),
                Text(unit, style: F.cap.copyWith(color: p.ink3)),
              ],
            ),
        ]);
    return Surface(
      onTap: whole ? onTap : null,
      semanticLabel: whole ? semantic : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tappable(header),
          if (preview != null) ...[const SizedBox(height: S.x3), preview!],
          const SizedBox(height: S.x3),
          tappable(_Cta(cta, p.on(color))),
        ],
      ),
    );
  }
}

// ══════════════════ ROWS — for lists, not cards ══════════════════

/// Which way is good news for THIS metric.
///
/// Resting heart rate falling is good, HRV rising is good, and skin
/// temperature moving is neither — it is a deviation signal, and calling a
/// rise "worse" would be a claim this project does not make. Metrics with no
/// settled direction get [neither] and an arrow with no hue: the direction is
/// still stated, the judgement is not invented.
enum Rising { good, bad, neither }

/// Which way a series is going, or null when there is no basis for saying.
enum Trend { rising, falling, steady }

/// The direction of the newest few days against the ones before them.
///
/// THE RULE, so it is one rule and not a feeling: the mean of the newest 3
/// recorded values against the mean of up to 14 before them, and the move
/// only counts as a direction if it clears HALF A STANDARD DEVIATION of that
/// baseline (Cohen's small effect, 1988). Inside that, a day-to-day wobble
/// and a trend look identical, and an arrow would be pointing at a coin flip
/// — so it reads [Trend.steady].
///
/// Null is a different answer from steady: fewer than 3 + 4 recorded values
/// is not a weak comparison, it is no comparison, and the row draws nothing
/// rather than a flat arrow that would read as a measured "no change".
///
/// A baseline with zero spread (a quantized series that really did sit still)
/// does NOT abstain — any move off it is a real move. Abstaining on a zero
/// spread is the readiness bug this codebase has already paid for once.
Trend? trendOf(List<double?> series) {
  final v = [
    for (final x in series)
      if (x != null && x.isFinite) x,
  ];
  const recentN = 3, baseMax = 14, baseMin = 4;
  if (v.length < recentN + baseMin) return null;
  double mean(Iterable<double> l) =>
      l.fold<double>(0, (a, b) => a + b) / l.length;
  final recent = v.sublist(v.length - recentN);
  final base = v.sublist(
      math.max(0, v.length - recentN - baseMax), v.length - recentN);
  final mb = mean(base);
  final delta = mean(recent) - mb;
  final sd = math.sqrt(
      base.map((x) => (x - mb) * (x - mb)).fold<double>(0, (a, b) => a + b) /
          (base.length - 1));
  if (delta.abs() <= 0.5 * sd) return Trend.steady;
  return delta > 0 ? Trend.rising : Trend.falling;
}

/// Whether this move is good news — hue only, never direction.
///
/// Steady is not good or bad news, and a metric with no settled direction has
/// no news at all: both draw in ink.
Color _trendHue(P p, Trend trend, Rising rising) {
  if (trend == Trend.steady || rising == Rising.neither) return p.ink3;
  final good = (trend == Trend.rising) == (rising == Rising.good);
  return good ? p.on(C.green) : p.on(C.orange);
}

/// What the arrow says, in words, for the screen reader — including the case
/// where there is no arrow, so an empty slot is not a silent hole.
String _trendWord(Trend? t) => switch (t) {
      Trend.rising => 'trending up',
      Trend.falling => 'trending down',
      Trend.steady => 'steady',
      null => 'no trend yet, not enough days recorded',
    };

/// A metric in a list: name → value → trend.
class MetricRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String name, sub, value, unit;

  /// DENSE — one slot per calendar day, `null` for a day with no record. A
  /// compacted list draws a gap as continuity.
  ///
  /// Read for a DIRECTION, not drawn: the trailing slot used to hold a 52 pt
  /// sparkline, which at that size showed a shape nobody could read a number
  /// off. See [trendOf] for what counts as a direction.
  final List<double?> series;

  /// Which way is good news here. Defaults to [Rising.neither] — a caller that
  /// has not said gets a direction and no judgement, never a guess.
  final Rising rising;

  final String? status;
  final VoidCallback? onTap;

  const MetricRow(
    this.icon,
    this.color,
    this.name,
    this.value, {
    super.key,
    this.sub = '',
    this.unit = '',
    this.series = const [],
    this.rising = Rising.neither,
    this.status,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: F.body.copyWith(color: p.ink),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (sub.isNotEmpty) Text(sub, style: F.over.copyWith(color: p.ink3)),
      ],
    );
    final amount = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        // NOT Flexible. Sharing the row's flex with the name gave the value
        // a quarter of the width and no more, so 'Respiratory rate' shipped
        // reading `1… br/min` — a truncated measurement, which this row is
        // supposed to never do. It is the name that gives way now.
        Text(
          value,
          style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (unit.isNotEmpty) ...[
          const SizedBox(width: 2),
          Text(unit, style: F.over.copyWith(color: p.ink3)),
        ],
      ],
    );
    // `status` is a word — 'ON TRACK' needs 92 pt at 1.0× and was being
    // silently clipped inside a 52 pt box before any scaling at all — so it
    // gets measured space rather than the arrow's fixed slot.
    final trend = trendOf(series);
    // NO ARROW AND NO EXPLANATION IN THE ROW: a metric with too little history
    // has nothing to say here, and a horizontal arrow would say "no change",
    // which is a measurement it has not made. The reason goes to the screen
    // reader and the row stays quiet — see [_trendWord].
    final trailing = status != null
        ? Text(
            status!,
            style: F.over.copyWith(color: p.on(C.green)),
            textAlign: TextAlign.end,
          )
        : trend == null
        ? const SizedBox.shrink()
        : Icon(
            switch (trend) {
              Trend.rising => LucideIcons.arrowUpRight,
              Trend.falling => LucideIcons.arrowDownRight,
              Trend.steady => LucideIcons.arrowRight,
            },
            size: 18,
            // THE GLYPH CARRIES THE DIRECTION and the hue only carries the
            // judgement, because roughly one man in twelve cannot read the
            // hue at all. Green/orange is the pair TrendCard already spends on
            // this judgement — red in this system is the heart's category
            // colour, not a verdict.
            color: _trendHue(p, trend, rising),
          );
    return Pressable(
      onTap: onTap,
      // WHAT THE ROW SHOWS IS WHAT IT SAYS. `status` REPLACES the arrow in the
      // trailing slot, so announcing the trend under it described a glyph that
      // is not on screen — a row reading 'ON TRACK' told a screen reader
      // 'trending up'.
      semanticLabel: '$name, $value $unit ${status ?? _trendWord(trend)}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: bigText(c)
            // A dense row cannot stay one line at accessibility sizes without
            // truncating the measurement, and a truncated measurement is worse
            // than a taller row.
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: p.on(color)),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title,
                        const SizedBox(height: S.x1),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: S.x3,
                          runSpacing: S.x1,
                          children: [amount, trailing],
                        ),
                      ],
                    ),
                  ),
                ],
              )
            // THE ROW RULE, and it holds for every label→value row in the app:
            // the name is the only flexible part, so the measurement keeps its
            // natural width and every row in a list ends on one right edge.
            // Two flex children split the width by ratio instead, which left
            // each value block starting and ending at its own x — a column of
            // readings that did not read as a column.
            : Row(
                children: [
                  Icon(icon, size: 18, color: p.on(color)),
                  const SizedBox(width: S.x3),
                  Expanded(child: title),
                  const SizedBox(width: S.x2),
                  amount,
                  const SizedBox(width: S.x3),
                  trailing,
                ],
              ),
      ),
    );
  }
}

/// Related numbers that belong on one line, not in four cards.
class InlineMetrics extends StatelessWidget {
  final List<(String, String, Color)> items;
  const InlineMetrics(this.items, {super.key});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Row(
      children: [
        for (final e in items)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.$1, style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x1),
                // scaleDown, NOT ellipsis. These are measurements sharing
                // one row, so the slot is a third of a card and a two-digit
                // fixture fits where a real one does not: at 2x text the
                // journey summary printed '+642…' and '−618…' where the
                // numbers are +642 m and −618 m. A shrunk measurement is
                // still the measurement; a truncated one is a different
                // number.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    e.$2,
                    style: F.n17.copyWith(color: p.on(e.$3)),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ══════════════════ BEHAVIOURAL RULES ══════════════════

/// Recommendation → reason → action. Never a recommendation on its own; an
/// instruction the user cannot audit is an instruction they stop trusting.
class Recommendation extends StatelessWidget {
  final String rec, reason, action;
  final Color color;
  final VoidCallback? onTap;

  const Recommendation(
    this.rec,
    this.reason,
    this.action, {
    super.key,
    this.color = C.green,
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Pressable(
      onTap: onTap,
      semanticLabel: '$rec. $reason. $action',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rec, style: F.t2.copyWith(color: p.ink)),
          const SizedBox(height: S.x2),
          Text(reason, style: F.body.copyWith(color: p.ink2, height: 1.5)),
          const SizedBox(height: S.x3),
          Row(
            children: [
              Flexible(
                child: Text(
                  action,
                  style: F.body.copyWith(
                    color: p.on(color),
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                ),
              ),
              const SizedBox(width: S.x1),
              Icon(LucideIcons.arrowRight, size: 15, color: p.on(color)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Current → target → the rate that connects them.
class GoalTrajectory extends StatelessWidget {
  final String label, current, target, rate;
  final double frac;
  final Color color;

  /// Which way the rate points. Purely presentational — the caller knows
  /// whether its own metric going down is good news.
  final bool rateDown;

  const GoalTrajectory(
    this.label,
    this.current,
    this.target,
    this.rate,
    this.frac,
    this.color, {
    super.key,
    this.rateDown = true,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = p.on(color);
    return Surface(
      semanticLabel: '$label, $current toward $target. $rate',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: F.cap.copyWith(color: p.ink2)),
          const SizedBox(height: S.x3),
          // Wrap, not Row: at large text scales the goal label drops to its own
          // line rather than pushing the number off the card. A truncated
          // measurement is worse than a taller card.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: S.x3,
            runSpacing: S.x1,
            children: [
              Text(current, style: F.n34.copyWith(color: p.ink)),
              Text('Goal $target', style: F.cap.copyWith(color: p.ink3)),
            ],
          ),
          const SizedBox(height: S.x3),
          _Bar(frac: frac, color: color),
          const SizedBox(height: S.x2),
          Row(
            children: [
              Icon(
                rateDown ? LucideIcons.trendingDown : LucideIcons.trendingUp,
                size: 14,
                color: ink,
              ),
              const SizedBox(width: S.x1),
              Flexible(
                child: Text(rate, style: F.cap.copyWith(color: ink)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A health observation that may deserve a clinician. Not gamification, not a
/// diagnosis — a statement of what was measured and what it might be worth.
class Observation extends StatelessWidget {
  final String headline, detail, advice;
  final VoidCallback? onTap;

  const Observation(
    this.headline,
    this.detail, {
    super.key,
    this.advice = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = p.on(C.orange);
    return Pressable(
      onTap: onTap,
      semanticLabel: 'Health observation. $headline. $detail. $advice'.trim(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x4),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: R.rLg,
          border: Border(left: BorderSide(color: ink, width: 3)),
          boxShadow: p.el(1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.stethoscope, size: 15, color: ink),
                const SizedBox(width: S.x2),
                Flexible(
                  child: Text(
                    'HEALTH OBSERVATION',
                    style: F.over.copyWith(color: ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: S.x3),
            Text(
              headline,
              style: F.body.copyWith(
                color: p.ink,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            const SizedBox(height: S.x2),
            Text(detail, style: F.cap.copyWith(color: p.ink2, height: 1.5)),
            if (advice.isNotEmpty) ...[
              const SizedBox(height: S.x2),
              Text(advice, style: F.cap.copyWith(color: p.ink3, height: 1.5)),
            ],
            if (onTap != null) ...[
              const SizedBox(height: S.x3),
              _Cta('View data', ink),
            ],
          ],
        ),
      ),
    );
  }
}

/// Consistency, never a streak. "18 of 24 days" cannot reset to zero, so a
/// missed day costs a day rather than costing everything.
class Consistency extends StatelessWidget {
  final int have, of;
  final String label;
  final Color color;

  /// What the segments COUNT. Days for a habit, doses for a medication — the
  /// adherence card fed this a dose count while the widget printed "of N days"
  /// and drew one segment per day, so 10 of 14 doses read as 10 of 14 days.
  final String unit;

  const Consistency(this.have, this.of, this.label, this.color,
      {super.key, this.unit = 'days'});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final n = of <= 0 ? 0 : of;
    return Semantics(
      label: '$have of $n $unit. $label',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: S.x1,
            children: [
              Text('$have', style: F.n24.copyWith(color: p.ink)),
              Text('of $n $unit', style: F.cap.copyWith(color: p.ink3)),
            ],
          ),
          const SizedBox(height: S.x2),
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Container(
                    margin: EdgeInsets.only(right: i == n - 1 ? 0 : 2),
                    height: 6,
                    decoration: BoxDecoration(
                      color: i < have ? p.on(color) : p.track,
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(label, style: F.cap.copyWith(color: p.ink3)),
        ],
      ),
    );
  }
}

// ══════════════════ FORM INPUT ══════════════════

/// What a typed number actually was. THREE answers, not two.
///
/// Every form in the app folded "nothing typed" and "cannot read that" into
/// the same null and then saved: a weight typed as "78 kg" cleared the stored
/// weight, an energy typed as "1,200" turned a costed meal into an uncosted
/// occasion, and a lab value with its unit on it dropped the whole result —
/// each of them under a screen that closed as if it had saved.
///
/// Nothing here guesses. "1,5" is 1.5 to half of Europe and 15 to the other
/// half, so it is [bad] and the user is asked, never averaged into a number
/// they did not type.
class Typed {
  const Typed._(this.value, this.bad);

  /// The parsed number, or null when the field was left blank.
  final double? value;

  /// Something was typed and it is not a number. Never save one of these.
  final bool bad;

  bool get blank => value == null && !bad;

  static Typed of(String text) {
    final s = text.trim();
    if (s.isEmpty) return const Typed._(null, false);
    final v = double.tryParse(s);
    // tryParse accepts "Infinity"/"-Infinity"/"NaN" and overflows huge
    // literals ("1e400") to infinity — none of those are a real number.
    return v == null || !v.isFinite
        ? const Typed._(null, true)
        : Typed._(v, false);
  }
}

/// Say what could not be read, naming the fields. One line, no ceremony —
/// the point is that the form stops instead of saving a hole.
void sayUnreadable(BuildContext c, List<String> fields) {
  if (fields.isEmpty) return;
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(
    content: Text(fields.length == 1
        ? '${fields.first} is not a number. Nothing was saved.'
        : '${fields.join(', ')} are not numbers. Nothing was saved.'),
  ));
}

/// The one destructive confirm. Names what goes and what stays, and there is
/// no undo behind any caller of it.
///
/// On-system rather than an `AlertDialog`: this package bans `fontSize:` and
/// `Colors.white` in its own tests and a Material dialog smuggles both in.
Future<bool> confirmRemove(
  BuildContext c, {
  required String title,
  required String body,
  String remove = 'Remove',
  String keep = 'Keep it',
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: c,
    sheetAnimationStyle: sheetMotion(c),
    backgroundColor: P.of(c).card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.xxl)),
    ),
    builder: (s) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(S.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: F.head.copyWith(color: P.of(s).ink)),
            const SizedBox(height: S.x2),
            Text(body, style: F.cap.copyWith(color: P.of(s).ink2, height: 1.5)),
            const SizedBox(height: S.x5),
            BigButton(remove,
                icon: LucideIcons.trash2,
                color: C.red,
                onTap: () => Navigator.of(s).pop(true)),
            const SizedBox(height: S.x3),
            BigButton(keep, soft: true, onTap: () => Navigator.of(s).pop(false)),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

// ══════════════════ CHROME ══════════════════

/// Contextual sub-navigation inside a domain. Never a bottom tab — the bottom
/// bar has five destinations and will not grow a sixth.
class SubTabs extends StatelessWidget {
  final List<String> items;
  final int index;
  final ValueChanged<int> onTap;
  final Color color;

  /// Indices that are shown but not tappable — a device that physically cannot
  /// supply this metric (final-plan §6.3). Drawn, because an option that
  /// silently is not there is the thing users hunt for; untappable, because
  /// there is nothing behind it.
  final Set<int> disabled;

  /// Indices drawn in the same inert `card2` look as [disabled] but still
  /// tappable: an option that is switched off yet worth opening (an alarm day
  /// that is off still has settings). A selected tab keeps the accent wash.
  final Set<int> muted;

  /// A key per tab, for tests and for finding one tab among several.
  final List<Key?>? itemKeys;

  /// What a screen reader says for each tab instead of its label.
  final List<String>? semanticLabels;

  /// Tighter padding and gaps (the 44 pt hit box stays), so a row of short
  /// labels (seven weekdays) fits a 360 pt phone in a real font. It still
  /// scrolls when a label or the text scale is wider.
  final bool dense;

  const SubTabs(
    this.items,
    this.index,
    this.onTap, {
    super.key,
    this.color = C.green,
    this.disabled = const {},
    this.muted = const {},
    this.itemKeys,
    this.semanticLabels,
    this.dense = false,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return SizedBox(
      height: MediaQuery.textScalerOf(c).scale(S.tap),
      // The fifth tab is off the edge on every phone we ship to — at 360 pt
      // it is entirely off-screen in both tab sets, and above 1.0x text every
      // set overflows even a 430 pt screen. ScrollHint draws nothing at all
      // while the row fits, and scales with how much is left to scroll.
      child: ScrollHint(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, _) => SizedBox(width: dense ? 2 : S.x2),
          itemBuilder: (_, i) {
            final off = disabled.contains(i);
            final on = i == index && !off;
            return Pressable(
              key: itemKeys?[i],
              onTap: off ? null : () => onTap(i),
              // `Pressable` drops `Semantics(button: true)` when `onTap` is
              // null, so without this a screen reader announced a disabled
              // pill exactly like a working one.
              semanticLabel: off
                  ? '${items[i]}, unavailable'
                  : semanticLabels?[i],
              child: AnimatedContainer(
                duration: motion(c, Motion.base),
                constraints: BoxConstraints(minWidth: dense ? 0 : S.tap),
                padding: EdgeInsets.symmetric(horizontal: dense ? 6 : S.x4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // THREE STATES, THREE LOOKS. A disabled pill used to compute
                  // `on == false` and render exactly like a selectable-but-
                  // unselected one — transparent, same ink — so the user
                  // tapped it and nothing happened. An inert `card2` slot
                  // reads as filled-but-dead against both the accent wash of
                  // the active pill and the empty ground of a live one, and
                  // `ink3` is solved for 4.5:1 ON `card2` (see theme.dart), so
                  // this cue costs no contrast the way dimming would.
                  color: off || (muted.contains(i) && !on)
                      ? p.card2
                      : on
                          ? p.wash(color)
                          : const Color(0x00000000),
                  borderRadius: R.rPill,
                ),
                child: Text(
                  items[i],
                  style: F.cap.copyWith(
                    color: on ? p.on(color) : p.ink3,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class ScreenTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const ScreenTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x1, S.x2, S.x1, S.x3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: F.t1.copyWith(color: p.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A small labelled chip. Status, tag, category.
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Pill(this.text, this.color, {super.key, this.icon});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = p.on(color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 5),
      decoration: BoxDecoration(color: p.wash(color), borderRadius: R.rPill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: ink),
            const SizedBox(width: S.x1),
          ],
          Flexible(
            child: Text(
              text,
              style: F.cap.copyWith(color: ink, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The primary commitment button. [soft] is the secondary form.
class BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool soft;
  final VoidCallback? onTap;
  final VoidCallback? onPressStart;
  final VoidCallback? onPressEnd;
  final VoidCallback? onPressCancel;

  const BigButton(
    this.label, {
    super.key,
    this.icon,
    this.color = C.green,
    this.soft = false,
    this.onTap,
    this.onPressStart,
    this.onPressEnd,
    this.onPressCancel,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = soft ? p.on(color) : p.inkOnFill;
    return Pressable(
      onTap: onTap,
      onPressStart: onPressStart,
      onPressEnd: onPressEnd,
      onPressCancel: onPressCancel,
      semanticLabel: label,
      child: Container(
        // A minimum, never a fixed height — at accessibility text sizes the
        // label is taller than 52 and a fixed box would clip it.
        constraints: const BoxConstraints(minHeight: 52),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: soft ? p.wash(color) : p.fill(color),
          borderRadius: R.rMd,
          boxShadow: soft ? null : p.el(2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: ink),
              const SizedBox(width: S.x2),
            ],
            Flexible(
              child: Text(
                label,
                style: F.head.copyWith(color: ink),
                textAlign: TextAlign.center,
                maxLines: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════ CHART FRAME ══════════════════
/// Everything a chart needs in order to be read: what it is, what it is
/// measured in, what the heights mean, what the colours mean, and what the
/// horizontal axis covers.
///
/// A painter draws a shape. The shape is only information once something says
/// `bpm` next to it and puts a `56` beside a gridline, and until this existed
/// lib/ui2 drew forty charts and printed neither. The rules it enforces:
///
///   • THE UNIT IS ALWAYS IN THE HEADER. Not in a caption under the card, not
///     implied by the metric name. [unit] is required, and there is no variant
///     without it.
///   • THE LABELS AND THE CURVE SHARE ONE [AxisSpec]. Pass the same instance to
///     [yAxis] and to the painter (`LineChart(d, colour, axis: spec)`). The
///     frame prints [AxisSpec.format] at each gridline and the painter maps
///     values through [AxisSpec.t], so they cannot disagree. A painter left to
///     auto-scale is a chart whose gridlines are decoration.
///   • ABSENCE IS NOT AN EMPTY AXIS. Pass [empty] — normally `const NoData()` —
///     when there is no series. The frame keeps the title and the unit and
///     drops the axis entirely, because an axis with nothing on it reads as a
///     measurement of zero.
///   • MORE THAN ONE COLOUR MEANS A [legend]. `Hypnogram.legend`,
///     `ZoneBar.legend`, `Spectrum.legend` and `IntervalLadder.legend` are
///     derived from the painters' own palettes — pass those rather than
///     retyping them, so a recolour can never orphan its key.
///
/// [xLabels] are laid out first-flush-left, last-flush-right and the rest
/// centred, on cells that line up with the data: with three labels they mark
/// the start, middle and end of what is actually drawn. They must describe the
/// range on screen — a fixed `['30 days ago', '15', 'Today']` under a
/// seven-day window is worse than no labels at all.
class ChartFrame extends StatelessWidget {
  final String title;

  /// `bpm`, `ms`, `min`, `°`. Always rendered.
  final String unit;

  /// The painter, normally a `CustomPaint(size: Size.infinite, painter: …)`.
  final Widget child;

  /// Plot height in logical pixels. Text scale does not stretch it; the tick
  /// labels thin themselves instead (see the note in `build`).
  final double height;

  final AxisSpec? yAxis;
  final List<String> xLabels;
  final List<(String, Color)> legend;
  final String? footnote;

  /// The series behind [child], for the SPOKEN version of the chart. A painter
  /// is a picture and a picture has no screen-reader form, so before this a
  /// fully-specified frame read out its title, its unit and then the three bare
  /// axis tick numbers — and not one value from the data.
  ///
  /// Pass the same list the painter draws. The frame says the latest value,
  /// the range and which way it moved; it never reads thirty numbers aloud.
  /// Empty means the chart genuinely has no series to summarise (a hypnogram,
  /// a route), and the legend and x range carry it instead.
  final List<double?> series;

  /// Non-null means THERE IS NO DATA: rendered in place of the plot, axis and
  /// x-labels. `const NoData()` is the house form.
  final Widget? empty;

  /// Vertical marks at 0…1 across the plot. NOT data — a mark says the days
  /// either side of it are not strictly comparable, and the only thing that can
  /// say WHY is [footnote], which is also the mark's only screen-reader form.
  /// Pass one without the other and the picture gains a line nobody can read.
  ///
  /// Drawn dotted, in the axis's own muted ink, so it can never be mistaken for
  /// a measured line. It does not take taps.
  final List<double> xMarks;

  const ChartFrame({
    super.key,
    required this.title,
    required this.unit,
    required this.child,
    this.height = 120,
    this.yAxis,
    this.xLabels = const [],
    this.legend = const [],
    this.footnote,
    this.empty,
    this.series = const [],
    this.xMarks = const [],
  });

  /// Width and height of [s] as it will actually be laid out — including the
  /// user's text scale. Estimating this from a character count is how axis
  /// gutters end up clipping `7h 30m` at 2× on exactly the devices whose
  /// owners chose 2× because they need it.
  static Size _measure(String s, TextStyle st, TextScaler sc, TextDirection d) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: st),
      textDirection: d,
      textScaler: sc,
      maxLines: 1,
    )..layout();
    return tp.size;
  }

  /// The chart in a sentence: what it ends on, what it spanned, and which way
  /// it went. Null when there is nothing to say.
  ///
  /// A summary, deliberately — not a reading of the series. Thirty numbers read
  /// aloud is the same non-information as a picture, and a screen reader cannot
  /// skim. The shape and the extremes are what a sighted glance takes from it,
  /// so they are what this says.
  String? _spoken() {
    // No plot, nothing to summarise. The [empty] child says why in the
    // caller's own words and is left in the tree to say it — a 'No data' here
    // would be a second, blunter announcement of the same absence.
    if (empty != null) return null;
    final v = [
      for (final x in series)
        if (x != null && x.isFinite) x,
    ];
    if (v.isEmpty) return null;
    final fmt = yAxis?.format ?? axisFixedOrInt;
    var lo = v.first, hi = v.first;
    for (final x in v) {
      if (x < lo) lo = x;
      if (x > hi) hi = x;
    }
    final last = v.last;
    // No unit here: the sentence has already said "measured in $unit", and a
    // formatter like [axisHm] writes its own — which is how this read out
    // "Latest 7h 42m min".
    final parts = ['Latest ${fmt(last)}'];
    if (v.length > 1) {
      if (hi > lo) parts.add('ranging ${fmt(lo)} to ${fmt(hi)}');
      final delta = last - v.first;
      // A move smaller than a twentieth of the range is not a direction.
      final noise = (hi - lo) / 20;
      parts.add(
        delta.abs() <= noise
            ? 'roughly level across ${v.length} readings'
            : '${delta > 0 ? 'up' : 'down'} ${fmt(delta.abs())} '
                  'across ${v.length} readings',
      );
    }
    return parts.join(', ');
  }

  Widget _header(P p, bool stacked) {
    final name = Text(
      title,
      style: F.cap.copyWith(color: p.ink, fontWeight: FontWeight.w600),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    final measure = Text(unit, style: F.over.copyWith(color: p.ink3));
    if (!stacked) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: name),
          const SizedBox(width: S.x2),
          measure,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [name, measure],
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final scaler = MediaQuery.textScalerOf(c);
    final dir = Directionality.of(c);
    // ink3 is the muted token that is *solved* to 4.5:1 on every surface — the
    // axis is the smallest type on the card, so it gets the floor, not a
    // lighter grey chosen by eye.
    final tick = F.over.copyWith(color: p.ink3);

    final a = empty == null ? yAxis : null;
    var labels = const <String>[];
    var gutter = 0.0, lineH = 0.0;
    if (a != null) {
      lineH = _measure('0', tick, scaler, dir).height;
      // At 2× text a 120 pt plot fits three labels; a 60 pt one fits two. Thin
      // the LABELS rather than the axis — min and max are unchanged, so the
      // curve keeps the exact scale the caller pinned and the remaining
      // gridlines still sit on real values.
      final fits = (height / (lineH * 1.35)).floor();
      final n = a.ticks.clamp(2, fits < 2 ? 2 : fits);
      labels = [
        for (final v in AxisSpec(
          min: a.min,
          max: a.max,
          ticks: n,
          format: a.format,
        ).tickValues)
          a.format(v),
      ];
      for (final s in labels) {
        final w = _measure(s, tick, scaler, dir).width;
        if (w > gutter) gutter = w;
      }
    }
    final inset = a == null ? 0.0 : gutter + S.x2;

    return _ChartHubHost(
      builder: (hub) => Semantics(
      container: true,
      // Keeps `child` as its own node. Without it a container merges every
      // descendant into itself, so an interactive child's label is swallowed
      // by the frame's sentence and the control is unreachable — the same
      // outcome `excludeSemantics` had, by a different route.
      explicitChildNodes: true,
      // NOT `excludeSemantics: true`. That suppressed the bare axis ticks and
      // the doubled header — which was the point — but it deletes EVERY
      // descendant semantics node, and `child` is a descendant. On the sleep
      // screen the child is the `Scrubber`, so the one interactive control in
      // the chart vanished from the accessibility tree entirely. The
      // decoration is excluded piece by piece below instead, and `child` is
      // left reachable.
      label: [
        title,
        'measured in $unit',
        ?_spoken(),
        if (xLabels.length > 1) 'from ${xLabels.first} to ${xLabels.last}',
        if (legend.isNotEmpty)
          'Key: ${[for (final (l, _) in legend) l].join(', ')}',
        ?footnote,
      ].join('. '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── header: what it is, and what it is measured in ──
          // Title and unit share a line until the text scale makes that a
          // choice between truncating the title and dropping the unit — at
          // which point the unit moves under it. Neither is ever dropped.
          ExcludeSemantics(child: _header(p, scaler.scale(1) > 1.3)),
          const SizedBox(height: S.x3),

          // ── plot, or the honest absence of one ──
          if (empty != null)
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: Center(child: empty),
            )
          else
            SizedBox(
              height: height,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (a != null) ...[
                    // Tick numbers, spoken already as part of the frame's sentence.
                    ExcludeSemantics(
                      child: SizedBox(
                        width: gutter,
                        child: Stack(
                          children: [
                            for (var i = 0; i < labels.length; i++)
                              Positioned(
                                left: 0,
                                right: 0,
                                // Centred on its gridline, then clamped inside the
                                // plot so the top and bottom labels are not half cut.
                                top:
                                    (i / (labels.length - 1) * height -
                                            lineH / 2)
                                        .clamp(
                                          0.0,
                                          (height - lineH).clamp(0.0, height),
                                        ),
                                child: Text(
                                  labels[i],
                                  style: tick,
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: S.x2),
                  ],
                  Expanded(
                    child: Stack(
                      children: [
                        if (a != null)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _Gridlines(labels.length, p.line),
                            ),
                          ),
                        Positioned.fill(child: child),
                        // Above the curve, because a fill would swallow it —
                        // and it never absorbs a pointer, so the scrub
                        // underneath still works.
                        if (xMarks.isNotEmpty)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _XMarks(xMarks, p.ink3),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // ── x axis ──
          if (empty == null && xLabels.isNotEmpty)
            ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.only(top: S.x1, left: inset),
                child: Row(
                  children: [
                    for (var i = 0; i < xLabels.length; i++)
                      Expanded(
                        child: Text(
                          xLabels[i],
                          style: tick,
                          textAlign: i == 0
                              ? TextAlign.start
                              : i == xLabels.length - 1
                              ? TextAlign.end
                              : TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),

          // ── key ──
          // The legend, and under each entry the value at the scrubbed point
          // (or the latest one). A frame with no scrub keeps the plain legend.
          _FrameKeys(hub: hub, legend: legend, tick: tick, line: p.line),

          if (footnote != null)
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(top: S.x2),
                child: Text(footnote!, style: F.cap.copyWith(color: p.ink3)),
              ),
            ),
        ],
      ),
    ));
  }
}

/// The key under a [ChartFrame]: its legend, with the scrubbed point's values
/// under each entry when a [ChartScrub] is attached.
///
/// Entries are matched to the scrub's series by label, so a legend built from a
/// painter's own palette and a scrub keyed on the same strings line up. A legend
/// entry no series answers to (a shaded stretch, say) stays a plain key; a
/// series with no legend entry is added after them, and "Not recorded" last.
class _FrameKeys extends StatelessWidget {
  final _ChartHub hub;
  final List<(String, Color)> legend;
  final TextStyle tick;
  final Color line;
  const _FrameKeys(
      {required this.hub,
      required this.legend,
      required this.tick,
      required this.line});

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: hub,
        builder: (c, _) {
          final r = hub.read();
          hub.rendered = r?.signature ?? '';
          if (r == null) return _plain(c);
          final used = <ChartCell>{};
          final cells = <ChartCell>[];
          for (final (label, colour) in legend) {
            final m = r.cells.where((x) => x.label == label).firstOrNull;
            if (m == null) {
              cells.add(ChartCell(label, colour, hasValue: false));
            } else {
              used.add(m);
              cells.add(ChartCell(label, m.color == null ? null : colour,
                  value: m.value, hasValue: m.hasValue, active: m.active));
            }
          }
          cells.addAll(r.cells.where((x) => !used.contains(x)));
          return ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: S.x3),
              child: ChartKeyReadout(
                  cells: cells, time: r.time, scrubbed: r.scrubbed),
            ),
          );
        },
      );

  Widget _plain(BuildContext c) {
    if (legend.isEmpty) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: S.x3),
        child: Wrap(
          spacing: S.x3,
          runSpacing: S.x1,
          children: [
            for (final (label, colour) in legend)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colour,
                      // The swatch is the mark's real colour so the two match,
                      // and a pale mark still needs an edge to be findable.
                      border: Border.all(color: line, width: .5),
                    ),
                  ),
                  const SizedBox(width: S.x1),
                  // Flexible, because `Wrap` hands each item the frame's full
                  // width and no more: a key like "Breathing (br/min)" is wider
                  // than a 390 pt card at 2× text and overflowed the item
                  // rather than wrapping inside it.
                  Flexible(child: Text(label, style: tick)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// The horizontal rules behind a plot, at the same fractions [ChartFrame]
/// prints its labels — one count, passed to both, so they cannot drift.
class _Gridlines extends CustomPainter {
  final int n;
  final Color color;
  const _Gridlines(this.n, this.color);

  @override
  void paint(Canvas cv, Size s) {
    if (n < 2 || s.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i < n; i++) {
      // Inset half a stroke so the first and last rules are drawn, not clipped.
      final y = (i / (n - 1) * s.height).clamp(.5, s.height - .5);
      cv.drawLine(Offset(0, y), Offset(s.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Gridlines o) => o.n != n || o.color != color;
}

/// A break in the x direction — where the days on one side were not produced
/// the same way as the days on the other. Dotted and hairline-thin: provenance
/// is worth seeing and is not worth alarming anybody about.
class _XMarks extends CustomPainter {
  final List<double> at;
  final Color color;
  const _XMarks(this.at, this.color);

  @override
  void paint(Canvas cv, Size s) {
    if (s.width <= 0 || s.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final f in at) {
      final x = (f.clamp(0.0, 1.0) * s.width).clamp(.5, s.width - .5);
      for (var y = 0.0; y < s.height; y += 6) {
        final end = y + 3 > s.height ? s.height : y + 3;
        cv.drawLine(Offset(x, y), Offset(x, end), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _XMarks o) => o.color != color || o.at != at;
}

/// The body of an empty [ChartFrame]. Says what is missing in words.
///
/// This is not a replacement for [StatusCard] — a metric that has no value
/// still renders one, with its why and its fix. This is the smaller case: the
/// number exists, the SERIES behind the picture does not.
class NoData extends StatelessWidget {
  final String message;
  const NoData({super.key, this.message = 'No data yet'});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.chartLine, size: 15, color: p.ink3),
        const SizedBox(width: S.x2),
        Flexible(
          child: Text(
            message,
            style: F.cap.copyWith(color: p.ink3),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// The pushed-screen header. Back → title → one optional action.
class NavBar extends StatelessWidget {
  final String title;
  final String sub;
  final Widget? trailing;
  final VoidCallback? onBack;

  /// Width of the trailing slot. Only [ActivitySummary] widens it, to fit a
  /// share icon beside an edit-type one — every other caller keeps the
  /// one-icon default.
  final double trailingWidth;

  const NavBar(
    this.title, {
    super.key,
    this.sub = '',
    this.trailing,
    this.onBack,
    this.trailingWidth = S.tap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: [
          Pressable(
            onTap: onBack ?? () => Navigator.maybePop(c),
            semanticLabel: 'Back',
            child: Icon(LucideIcons.chevronLeft, size: 24, color: p.ink),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: F.head.copyWith(color: p.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sub.isNotEmpty)
                  Text(
                    sub,
                    style: F.over.copyWith(color: p.ink3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          SizedBox(
            width: trailingWidth,
            child: Align(alignment: Alignment.centerRight, child: trailing),
          ),
        ],
      ),
    );
  }
}
