// THE SHARED DAY TIMELINE (pilot: day-timeline spec §1). One widget, used by
// the sleep timeline editor and Activities. It draws what the rules in
// timeline_model.dart return and turns the finger into calls on them:
//
//  • Lanes, top to bottom: heart rate 3/6 (bpm gridlines), stages 2/6 (the
//    wave), movement 1/6. A lane without data gives its share to heart rate.
//  • Drag anywhere outside a handle: the scrub line. It STAYS where it is
//    released.
//  • Annotations: the app's own lane (glyph on top, dashed line).
//  • Zoom: every change glides 1.5-2 s (ease in-out), never under 30 min;
//    double-tap empty space zooms in 30% around the tap; reset glides home.
//  • Blocks (sleep editor): one active block with two handles, the others
//    labelled bands. Tap a band selects it; double tap selects and zooms.
//    Dragging a handle shows the magnifier: 5-minute steps, then 1-minute
//    steps after a 0.6 s hold, a haptic per minute (stronger on round ones).
//  • ⌕ zoom selection (Activities): two handles, then glide to them.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/clock_format.dart' show formatClockOf;
import '../chart_annotations.dart';
import '../charts.dart' show Hypnogram, SleepStage;
import '../theme.dart';
import 'timeline_model.dart';

/// The view, the scrub line and the ⌕ selection of one chart. Owned by the
/// screen (it outlives rebuilds and is read by the screen's readout and list).
class TimelineController extends ChangeNotifier {
  TimelineController({
    required this.domainStart,
    required this.domainEnd,
    required TimelineView home,
    double? scrub,
  })  : home = home.clampTo(domainStart, domainEnd),
        _view = home.clampTo(domainStart, domainEnd),
        _scrub = scrub;

  final double domainStart, domainEnd;

  /// The default range "Reset zoom" glides back to.
  TimelineView home;
  TimelineView _view;
  TimelineView get view => _view;
  double? _scrub;

  /// The scrub line, epoch seconds; null: none yet.
  double? get scrub => _scrub;

  /// The ⌕ selection while it is being chosen.
  ZoomSelection? zoomSelection;

  Ticker? _ticker;
  TickerProvider? _vsync;
  TimelineView? _from, _to;
  Duration _duration = Duration.zero;

  /// The duration of the last glide that was started (tests read it).
  Duration? lastGlide;
  bool get animating => _ticker?.isActive == true;
  TimelineView? get target => _to;

  /// Whether the view differs from [home] (Reset zoom is offered).
  bool get zoomed =>
      ((_to ?? _view).start - home.start).abs() > 30 ||
      ((_to ?? _view).end - home.end).abs() > 30;

  void attach(TickerProvider vsync) {
    if (identical(_vsync, vsync)) return;
    _ticker?.dispose();
    _vsync = vsync;
    _ticker = vsync.createTicker(_tick);
  }

  void detach(TickerProvider vsync) {
    if (!identical(_vsync, vsync)) return;
    _ticker?.dispose();
    _ticker = null;
    _vsync = null;
    if (_to != null) _view = _to!;
    _to = null;
  }

  void _tick(Duration elapsed) {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    final k = _duration.inMicroseconds == 0
        ? 1.0
        : elapsed.inMicroseconds / _duration.inMicroseconds;
    _view = k >= 1 ? to : from.lerp(to, easeInOut(k));
    if (k >= 1) {
      _ticker?.stop();
      _to = null;
    }
    notifyListeners();
  }

  /// Glide to [v] (made legal first) over [zoomDuration].
  void glideTo(TimelineView v) {
    final to = v.clampTo(domainStart, domainEnd);
    _ticker?.stop();
    _from = _view;
    _duration = zoomDuration(_view, to);
    lastGlide = _duration;
    if (_ticker == null) {
      _view = to;
      _to = null;
      notifyListeners();
      return;
    }
    _to = to;
    _ticker!.start();
    notifyListeners();
  }

  void reset() {
    zoomSelection = null;
    glideTo(home);
  }

  /// The double tap on empty space.
  void zoomAt(double t) => glideTo((_to ?? _view).zoomAt(t, domainStart, domainEnd));

  void setScrub(double? t) {
    _scrub = t?.clamp(domainStart, domainEnd);
    notifyListeners();
  }

  /// Move the line to [t] smoothly (a tapped list item). When [t] is outside
  /// the view, the view pans to put it in the middle at the same scale.
  void glideScrub(double t) {
    _scrubFrom = _scrub ?? t;
    _scrubTo = t;
    _scrubStarted = null;
    final v = _to ?? _view;
    if (t < v.start || t > v.end) {
      glideTo(TimelineView(t - v.span / 2, t + v.span / 2));
    }
    if (_vsync == null) {
      setScrub(t);
      return;
    }
    _scrubTicker ??= _vsync!.createTicker(_scrubTick);
    _scrubTicker!
      ..stop()
      ..start();
  }

  Ticker? _scrubTicker;
  double? _scrubFrom, _scrubTo;
  Duration? _scrubStarted;
  static const scrubGlide = Duration(milliseconds: 450);
  void _scrubTick(Duration elapsed) {
    _scrubStarted ??= elapsed;
    final k = (elapsed - _scrubStarted!).inMicroseconds / scrubGlide.inMicroseconds;
    final from = _scrubFrom!, to = _scrubTo!;
    _scrub = k >= 1 ? to : from + (to - from) * easeInOut(k);
    if (k >= 1) _scrubTicker?.stop();
    notifyListeners();
  }

  /// ⌕ pressed: start choosing, or glide to what was chosen.
  void toggleZoomSelection() {
    final z = zoomSelection;
    if (z == null) {
      zoomSelection = ZoomSelection.around(_view, _scrub ?? _view.center);
      notifyListeners();
    } else {
      zoomSelection = null;
      glideTo(TimelineView(z.a, z.b));
    }
  }

  void moveZoomHandle(double t) {
    final z = zoomSelection;
    if (z == null) return;
    zoomSelection = z.move(z.nearerA(t), t);
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scrubTicker?.dispose();
    super.dispose();
  }
}

/// How a time on the chart reads. The default is the app's clock setting.
abstract interface class ClockText {
  String of(int epochSec);
}

class AppClockText implements ClockText {
  const AppClockText();
  @override
  String of(int epochSec) =>
      formatClockOf(DateTime.fromMillisecondsSinceEpoch(epochSec * 1000));
}

/// Where the haptics of a handle drag go. The default plays the phone's own
/// feedback; tests record the tiers.
abstract interface class TimelineHaptics {
  void tick(HapticTier tier);
  void fineMode();
}

class PhoneTimelineHaptics implements TimelineHaptics {
  const PhoneTimelineHaptics();
  @override
  void tick(HapticTier tier) {
    switch (tier) {
      case HapticTier.minute: HapticFeedback.selectionClick();
      case HapticTier.five: HapticFeedback.lightImpact();
      case HapticTier.ten: HapticFeedback.mediumImpact();
      case HapticTier.thirty || HapticTier.hour: HapticFeedback.heavyImpact();
    }
  }
  @override
  void fineMode() => HapticFeedback.mediumImpact();
}

/// Told when the person changes the blocks or the scrub.
abstract interface class TimelineListener {
  /// Blocks after a handle drag, already clamped (no overlaps).
  void blocksChanged(List<SleepBlock> blocks);

  /// A band was tapped ([zoom] false) or double-tapped ([zoom] true).
  void blockSelected(String id, {required bool zoom});

  /// The person moved the scrub line to [t] (a drag or a tap).
  void scrubbed(double t);

  /// A handle drag ended.
  void dragEnded();
}

class DayTimelineChart extends StatefulWidget {
  const DayTimelineChart({
    super.key,
    required this.controller,
    required this.hr,
    required this.movement,
    this.stages,
    this.stagesArePreview = false,
    this.annotations = const [],
    this.emphasis,
    this.annotationListener,
    this.blocks = const [],
    this.activeBlock,
    this.blockLabels = const {},
    this.listener,
    this.haptics = const PhoneTimelineHaptics(),
    this.plotHeight = 156,
    this.clock = const AppClockText(),
  });

  final TimelineController controller;

  /// Per minute from `controller.domainStart`. Null: not measured.
  final List<double?> hr, movement;

  /// Per 5-minute epoch from `controller.domainStart`, null outside sleep.
  /// Null: no stage lane (its share goes to heart rate).
  final List<SleepStage?>? stages;
  final bool stagesArePreview;
  final List<ChartAnnotation> annotations;
  final Set<String>? emphasis;
  final AnnotationListener? annotationListener;
  final List<SleepBlock> blocks;
  final String? activeBlock;

  /// A band's label per block id ("Main sleep ✎").
  final Map<String, String> blockLabels;
  final TimelineListener? listener;
  final TimelineHaptics haptics;
  final double plotHeight;
  final ClockText clock;

  static const double gutter = 44, rightPad = 8, axisHeight = 20;
  static const handleReach = 22.0;
  static const chartKey = ValueKey('day-timeline-chart');
  static const magnifierKey = ValueKey('day-timeline-magnifier');

  @override
  State<DayTimelineChart> createState() => _DayTimelineChartState();
}

enum _DragMode { scrub, handle, zoomHandle }

class _DayTimelineChartState extends State<DayTimelineChart>
    with TickerProviderStateMixin {
  _DragMode? _mode;
  MagnifierDrag? _drag;
  BlockEnd? _dragEnd;
  Timer? _hold;
  int? _lastMinute;
  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    widget.controller.attach(this);
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(DayTimelineChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      old.controller.detach(this);
      widget.controller.attach(this);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    widget.controller.removeListener(_changed);
    widget.controller.detach(this);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  double _plotWidth(double w) =>
      math.max(1, w - DayTimelineChart.gutter - DayTimelineChart.rightPad);

  double _tAt(double localX, double width) {
    final v = widget.controller.view;
    final f = (localX - DayTimelineChart.gutter) / _plotWidth(width);
    return v.at(f.clamp(0.0, 1.0));
  }

  double _xOf(double t, double width) =>
      DayTimelineChart.gutter + widget.controller.view.fraction(t) * _plotWidth(width);

  SleepBlock? get _active =>
      widget.blocks.where((b) => b.id == widget.activeBlock).firstOrNull;

  SleepBlock? _bandAt(double t) => widget.blocks.where((b) => b.contains(t)).firstOrNull;

  void _tapUp(TapUpDetails d, double width) {
    final t = _tAt(d.localPosition.dx, width);
    final band = _bandAt(t);
    if (band != null && band.id != widget.activeBlock && widget.listener != null) {
      widget.listener!.blockSelected(band.id, zoom: false);
      return;
    }
    widget.controller.setScrub(t);
    widget.listener?.scrubbed(t);
  }

  void _doubleTap(double width) {
    final at = _doubleTapAt;
    if (at == null) return;
    final t = _tAt(at.dx, width);
    final band = _bandAt(t);
    final c = widget.controller;
    if (band != null && widget.listener != null) {
      widget.listener!.blockSelected(band.id, zoom: true);
      c.glideTo(framing(band.start, band.end, c.domainStart, c.domainEnd));
      return;
    }
    c.zoomAt(t);
  }

  void _dragStart(DragStartDetails d, double width) {
    final c = widget.controller;
    final x = d.localPosition.dx;
    if (c.zoomSelection != null) {
      _mode = _DragMode.zoomHandle;
      c.moveZoomHandle(_tAt(x, width));
      return;
    }
    final a = _active;
    if (a != null) {
      final ds = (x - _xOf(a.start.toDouble(), width)).abs();
      final de = (x - _xOf(a.end.toDouble(), width)).abs();
      if (math.min(ds, de) <= DayTimelineChart.handleReach) {
        _mode = _DragMode.handle;
        _dragEnd = ds <= de ? BlockEnd.start : BlockEnd.end;
        _drag = MagnifierDrag(_dragEnd == BlockEnd.start ? a.start : a.end);
        _lastMinute = _drag!.value ~/ 60;
        _armHold();
        setState(() {});
        return;
      }
    }
    _mode = _DragMode.scrub;
    final t = _tAt(x, width);
    c.setScrub(t);
    widget.listener?.scrubbed(t);
  }

  void _armHold() {
    _hold?.cancel();
    _hold = Timer(kFineHold, () {
      if (!mounted || _drag == null) return;
      if (_drag!.hold()) {
        widget.haptics.fineMode();
        setState(() {});
      }
    });
  }

  void _dragUpdate(DragUpdateDetails d, double width) {
    final c = widget.controller;
    final x = d.localPosition.dx;
    switch (_mode) {
      case _DragMode.zoomHandle:
        c.moveZoomHandle(_tAt(x, width));
      case _DragMode.scrub:
        final t = _tAt(x, width);
        c.setScrub(t);
        widget.listener?.scrubbed(t);
      case _DragMode.handle:
        final drag = _drag!, a = _active;
        if (a == null) return;
        if (d.delta.dx.abs() > .5) _armHold();
        final secPerPx = c.view.span / _plotWidth(width);
        final want = drag.update(x, _tAt(x, width), secPerPx);
        final next = moveBlockEnd(widget.blocks, a.id, _dragEnd!, want,
            domainStart: c.domainStart.round(), domainEnd: c.domainEnd.round());
        final moved = next.firstWhere((b) => b.id == a.id);
        final value = _dragEnd == BlockEnd.start ? moved.start : moved.end;
        final minute = value ~/ 60;
        if (minute != _lastMinute) {
          final local = DateTime.fromMillisecondsSinceEpoch(value * 1000);
          widget.haptics.tick(hapticTier(local.hour * 60 + local.minute));
          _lastMinute = minute;
        }
        if (moved != a) widget.listener?.blocksChanged(next);
      case null:
        break;
    }
  }

  void _dragDone() {
    _hold?.cancel();
    final wasHandle = _mode == _DragMode.handle;
    _mode = null;
    _drag = null;
    _dragEnd = null;
    if (wasHandle) widget.listener?.dragEnded();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final c = widget.controller;
    final scaler = MediaQuery.textScalerOf(context);
    final header = ChartAnnotationLane.headerFor(scaler, Directionality.of(context));
    final lanes = {
      TimelineLane.heartRate,
      if (widget.stages != null) TimelineLane.stages,
      TimelineLane.movement,
    };
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 360.0;
      final plotW = _plotWidth(width);
      final v = c.view;
      final cursor = c.scrub == null ? null : v.fraction(c.scrub!);
      final a = _active;
      final dragValue = _drag?.value;
      return Semantics(
        container: true,
        label: 'Timeline ${widget.clock.of(v.start.round())} to ${widget.clock.of(v.end.round())}'
            '${c.scrub == null ? '' : ', line at ${widget.clock.of(c.scrub!.round())}'}',
        child: GestureDetector(
          key: DayTimelineChart.chartKey,
          behavior: HitTestBehavior.opaque,
          // The handle under the finger is the one it went DOWN on.
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: (d) => _tapUp(d, width),
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () => _doubleTap(width),
          onHorizontalDragStart: (d) => _dragStart(d, width),
          onHorizontalDragUpdate: (d) => _dragUpdate(d, width),
          onHorizontalDragEnd: (_) => _dragDone(),
          onHorizontalDragCancel: _dragDone,
          child: SizedBox(
            height: header + widget.plotHeight + DayTimelineChart.axisHeight,
            child: Stack(clipBehavior: Clip.hardEdge, children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: TimelinePainter(
                    p: p,
                    view: v,
                    domainStart: c.domainStart,
                    header: header,
                    plotHeight: widget.plotHeight,
                    lanes: laneLayout(widget.plotHeight, lanes),
                    hr: widget.hr,
                    movement: widget.movement,
                    stages: widget.stages,
                    stagesArePreview: widget.stagesArePreview,
                    blocks: widget.blocks,
                    active: widget.activeBlock,
                    blockLabels: widget.blockLabels,
                    scrub: c.scrub,
                    zoom: c.zoomSelection,
                    clock: widget.clock,
                    textScaler: scaler,
                  ),
                ),
              ),
              Positioned(
                left: DayTimelineChart.gutter,
                width: plotW,
                top: 0,
                child: ChartAnnotationLane(
                  set: AnnotationSet(
                    items: widget.annotations,
                    domainStart: v.start,
                    domainEnd: v.end,
                    listener: widget.annotationListener,
                  ),
                  cursor: cursor == null || cursor < 0 || cursor > 1 ? null : cursor,
                  plotHeight: widget.plotHeight,
                  emphasis: widget.emphasis,
                ),
              ),
              if (_drag != null && a != null && dragValue != null)
                Positioned(
                  key: DayTimelineChart.magnifierKey,
                  left: (_xOf(dragValue.toDouble(), width) - 80)
                      .clamp(DayTimelineChart.gutter, math.max(DayTimelineChart.gutter, width - 168)),
                  top: header + 2,
                  child: IgnorePointer(
                    child: _Magnifier(
                      value: dragValue,
                      fine: _drag!.fine,
                      clock: widget.clock,
                      color: a.kind == BlockKind.main ? C.blue : C.orange,
                    ),
                  ),
                ),
            ]),
          ),
        ),
      );
    });
  }
}

/// The magnifier over a dragged end: the time, a ruler of minutes around it
/// (taller ticks on 5, 10, 30 and 60) and the step mode.
class _Magnifier extends StatelessWidget {
  const _Magnifier({required this.value, required this.fine,
      required this.clock, required this.color});
  final int value;
  final bool fine;
  final ClockText clock;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Container(
      width: 160,
      padding: const EdgeInsets.fromLTRB(S.x2, S.x1, S.x2, S.x1),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: R.rMd,
        border: Border.all(color: p.on(color), width: 1.2),
        boxShadow: p.el(2),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(clock.of(value),
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w700, height: 1.2)),
        Text(fine ? '1-minute steps' : '5-minute steps · hold for minutes',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: F.over.copyWith(color: fine ? p.on(C.green) : p.ink3, height: 1.2)),
        const SizedBox(height: 2),
        SizedBox(
          height: 14,
          width: double.infinity,
          child: CustomPaint(painter: _RulerPainter(value, p, p.on(color))),
        ),
      ]),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.value, this.p, this.accent);
  final int value;
  final P p;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final local = DateTime.fromMillisecondsSinceEpoch(value * 1000);
    final m0 = local.hour * 60 + local.minute;
    const n = 20;
    final step = size.width / (2 * n);
    for (var d = -n; d <= n; d++) {
      final tier = hapticTier(m0 + d);
      final h = switch (tier) {
        HapticTier.hour => 14.0,
        HapticTier.thirty => 12.0,
        HapticTier.ten => 10.0,
        HapticTier.five => 7.0,
        HapticTier.minute => 4.0,
      };
      final x = size.width / 2 + d * step;
      canvas.drawLine(
          Offset(x, size.height - h),
          Offset(x, size.height),
          Paint()
            ..color = d == 0 ? accent : tier == HapticTier.minute ? p.line : p.ink3
            ..strokeWidth = d == 0 ? 2 : tier.index >= HapticTier.ten.index ? 1.5 : 1);
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.value != value;
}

/// Everything under the annotation lane. Public so tests can read its inputs.
class TimelinePainter extends CustomPainter {
  TimelinePainter({
    required this.p,
    required this.view,
    required this.domainStart,
    required this.header,
    required this.plotHeight,
    required this.lanes,
    required this.hr,
    required this.movement,
    required this.stages,
    required this.stagesArePreview,
    required this.blocks,
    required this.active,
    required this.blockLabels,
    required this.scrub,
    required this.zoom,
    required this.clock,
    required this.textScaler,
  });

  final P p;
  final TimelineView view;
  final double domainStart, header, plotHeight;
  final List<({TimelineLane lane, double top, double height})> lanes;
  final List<double?> hr, movement;
  final List<SleepStage?>? stages;
  final bool stagesArePreview;
  final List<SleepBlock> blocks;
  final String? active;
  final Map<String, String> blockLabels;
  final double? scrub;
  final ZoomSelection? zoom;
  final ClockText clock;
  final TextScaler textScaler;

  static const double _l = DayTimelineChart.gutter, _r = DayTimelineChart.rightPad;

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {TextAlign align = TextAlign.left, double? maxWidth}) {
    final tp = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
        ellipsis: '…')
      ..layout(maxWidth: maxWidth ?? double.infinity);
    final dx = switch (align) {
      TextAlign.right || TextAlign.end => at.dx - tp.width,
      TextAlign.center => at.dx - tp.width / 2,
      _ => at.dx,
    };
    tp.paint(canvas, Offset(dx, at.dy));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - _l - _r;
    if (w <= 0) return;
    double x(double t) => _l + view.fraction(t) * w;
    final top = header, bottom = header + plotHeight;
    final label = F.over.copyWith(color: p.ink3, height: 1);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width, size.height));

    final mStart = ((view.start - domainStart) / 60).floor().clamp(0, 1 << 30);
    final mEnd = ((view.end - domainStart) / 60).ceil();

    for (final lane in lanes) {
      final y0 = top + lane.top, h = lane.height;
      switch (lane.lane) {
        case TimelineLane.heartRate:
          // bpm gridlines with units, from the whole night's range so the
          // grid does not jump while zooming.
          double? lo, hi;
          for (final v in hr) {
            if (v == null) continue;
            lo = lo == null ? v : math.min(lo, v);
            hi = hi == null ? v : math.max(hi, v);
          }
          if (lo == null || hi == null) {
            _text(canvas, 'bpm', Offset(0, y0 + 2), label.copyWith(color: p.on(C.red)));
            break;
          }
          final gLo = ((lo - 5) / 10).floor() * 10.0, gHi = ((hi + 5) / 10).ceil() * 10.0;
          double y(double v) => y0 + 6 + (1 - (v - gLo) / math.max(1, gHi - gLo)) * (h - 12);
          final stepBpm = ((gHi - gLo) / 3 / 10).ceil() * 10.0;
          final grid = Paint()..color = p.line..strokeWidth = 1;
          for (var g = gLo + stepBpm; g < gHi; g += stepBpm) {
            canvas.drawLine(Offset(_l, y(g)), Offset(size.width - _r, y(g)), grid);
            _text(canvas, g.round().toString(), Offset(_l - 4, y(g) - 5), label,
                align: TextAlign.right);
          }
          _text(canvas, 'bpm', Offset(0, y0 + 2),
              label.copyWith(color: p.on(C.red), fontWeight: FontWeight.w700));
          // Gaps of up to 5 minutes are bridged; a lone reading is a dot,
          // never a line invented across a longer gap.
          final path = Path();
          final hrInk = p.on(C.red);
          int? last;
          var run = 0;
          void dotIfLone() {
            if (run == 1 && last != null) {
              canvas.drawCircle(Offset(x(domainStart + last * 60 + 30), y(hr[last]!)), 1.6,
                  Paint()..color = hrInk);
            }
          }
          for (var m = math.max(0, mStart - 5); m <= mEnd + 5 && m < hr.length; m++) {
            final v = hr[m];
            if (v == null) continue;
            final px = x(domainStart + m * 60 + 30);
            if (last != null && m - last <= 5) {
              path.lineTo(px, y(v));
              run++;
            } else {
              dotIfLone();
              path.moveTo(px, y(v));
              run = 1;
            }
            last = m;
          }
          dotIfLone();
          canvas.drawPath(
              path,
              Paint()
                ..color = hrInk
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..strokeJoin = StrokeJoin.round);
        case TimelineLane.stages:
          final s = stages;
          if (s == null) break;
          _text(canvas, 'Stages', Offset(0, y0 + 2),
              label.copyWith(color: p.ink2, fontWeight: FontWeight.w700));
          if (stagesArePreview) {
            _text(canvas, 'PREVIEW', Offset(0, y0 + 14),
                label.copyWith(color: p.on(C.orange), fontWeight: FontWeight.w700, fontSize: 9));
          }
          final cols = Hypnogram.cols(p);
          final e0 = ((view.start - domainStart) / 300).floor() - 1;
          final e1 = ((view.end - domainStart) / 300).ceil() + 1;
          final sub = [for (var e = math.max(0, e0); e < math.min(s.length, e1); e++) s[e]];
          final offset = math.max(0, e0);
          double y(double depth) => y0 + 4 + depth / 3 * (h - 8);
          for (final run in stageWave(sub)) {
            for (var i = 0; i < run.length; i++) {
              final pt = run[i];
              final px = x(domainStart + (offset + pt.index) * 300 + 150);
              final paint = Paint()
                ..color = cols[pt.stage]!
                ..strokeWidth = 3
                ..strokeCap = StrokeCap.round;
              if (i == 0) {
                canvas.drawCircle(Offset(px, y(pt.depth)), 1.5, paint);
                continue;
              }
              final q = run[i - 1];
              canvas.drawLine(
                  Offset(x(domainStart + (offset + q.index) * 300 + 150), y(q.depth)),
                  Offset(px, y(pt.depth)),
                  paint);
            }
          }
        case TimelineLane.movement:
          _text(canvas, 'Move', Offset(0, y0 + 2),
              label.copyWith(color: p.on(C.purple), fontWeight: FontWeight.w700));
          final bar = Paint()..color = p.on(C.purple).withValues(alpha: .75);
          final pxPerMin = w * 60 / view.span;
          for (var m = mStart; m <= mEnd && m < movement.length; m++) {
            final v = movement[m];
            if (v == null || v <= 0) continue;
            final bh = v.clamp(0.0, 1.0) * (h - 2);
            canvas.drawRect(
                Rect.fromLTWH(x(domainStart + m * 60), y0 + h - bh,
                    math.max(.6, pxPerMin - (pxPerMin > 2 ? .3 : 0)), bh),
                bar);
          }
      }
    }

    // Blocks: everything outside them dimmed; the inactive ones labelled
    // bands; the active one carries the only handles.
    if (blocks.isNotEmpty) {
      final sorted = [...blocks]..sort((a, b) => a.start.compareTo(b.start));
      final shade = Paint()..color = p.bg.withValues(alpha: .62);
      var cursor = view.start;
      for (final b in sorted) {
        if (b.start > cursor) {
          canvas.drawRect(Rect.fromLTRB(x(cursor), top, x(math.min(b.start.toDouble(), view.end)), bottom), shade);
        }
        cursor = math.max(cursor, b.end.toDouble());
      }
      if (cursor < view.end) {
        canvas.drawRect(Rect.fromLTRB(x(cursor), top, x(view.end), bottom), shade);
      }
      for (final b in sorted) {
        if (b.id == active || b.end < view.start || b.start > view.end) continue;
        final accent = b.kind == BlockKind.main ? C.blue : C.orange;
        final x0 = math.max(_l, x(b.start.toDouble())), x1 = math.min(size.width - _r, x(b.end.toDouble()));
        final rect = Rect.fromLTRB(x0, top, x1, bottom);
        canvas.drawRect(rect, Paint()..color = p.on(accent).withValues(alpha: .08));
        _dashedRect(canvas, rect, Paint()
          ..color = p.on(accent).withValues(alpha: .5)
          ..style = PaintingStyle.stroke);
        final text = blockLabels[b.id] ?? (b.kind == BlockKind.main ? 'Main sleep' : 'Nap');
        final style = F.over.copyWith(color: p.on(accent), fontWeight: FontWeight.w700, height: 1);
        // "✎" is the Lucide pencil: the text fonts have no such glyph.
        final pen = LucideIcons.pencil;
        final tp = TextPainter(text: TextSpan(text: '$text ', style: style, children: [
              TextSpan(text: String.fromCharCode(pen.codePoint),
                  style: style.copyWith(fontFamily: pen.fontFamily, package: pen.fontPackage)),
            ]),
            textDirection: TextDirection.ltr, textScaler: textScaler, maxLines: 1, ellipsis: '…')
          ..layout(maxWidth: w - 14);
        final pw = tp.width + 14;
        final cx = ((x0 + x1) / 2).clamp(_l + pw / 2, size.width - _r - pw / 2);
        final pill = Rect.fromCenter(center: Offset(cx, top + 10),
            width: pw, height: tp.height + 6);
        canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(99)),
            Paint()..color = p.bg);
        canvas.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(99)),
            Paint()..color = p.on(accent).withValues(alpha: .7)..style = PaintingStyle.stroke);
        tp.paint(canvas, Offset(pill.left + 7, pill.top + 3));
      }
      final a = blocks.where((b) => b.id == active).firstOrNull;
      if (a != null) {
        final accent = p.on(a.kind == BlockKind.main ? C.blue : C.orange);
        for (final t in [a.start, a.end]) {
          if (t < view.start || t > view.end) continue;
          final hx = x(t.toDouble());
          canvas.drawLine(Offset(hx, top), Offset(hx, bottom), Paint()..color = accent..strokeWidth = 2);
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  Rect.fromCenter(center: Offset(hx, top + plotHeight / 2), width: 14, height: 28),
                  const Radius.circular(7)),
              Paint()..color = accent);
        }
      }
    }

    // The ⌕ selection: dimmed outside, two handles.
    final z = zoom;
    if (z != null) {
      final shade = Paint()..color = p.bg.withValues(alpha: .6);
      canvas.drawRect(Rect.fromLTRB(_l, top, x(z.a), bottom), shade);
      canvas.drawRect(Rect.fromLTRB(x(z.b), top, size.width - _r, bottom), shade);
      final accent = p.on(C.blue);
      for (final t in [z.a, z.b]) {
        final hx = x(t);
        canvas.drawLine(Offset(hx, top), Offset(hx, bottom), Paint()..color = accent..strokeWidth = 2);
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset(hx, top + plotHeight / 2), width: 14, height: 28),
                const Radius.circular(7)),
            Paint()..color = accent);
      }
    }

    // The scrub line, where it was left.
    final s = scrub;
    if (s != null && s >= view.start && s <= view.end) {
      canvas.drawLine(Offset(x(s), top), Offset(x(s), bottom),
          Paint()..color = p.ink..strokeWidth = 1.4);
    }

    // The time axis: five clock labels across the view, or three when five
    // would touch.
    final axis = label.copyWith(color: p.ink2);
    double widthOf(String s) => (TextPainter(text: TextSpan(text: s, style: axis),
            textDirection: TextDirection.ltr, textScaler: textScaler, maxLines: 1)
          ..layout())
        .width;
    final widest = [for (var i = 0; i <= 4; i++) widthOf(clock.of(view.at(i / 4).round()))]
        .reduce(math.max);
    final steps = widest * 4 + 4 * 10 <= w ? 4 : 2;
    for (var i = 0; i <= steps; i++) {
      final t = view.at(i / steps);
      _text(canvas, clock.of(t.round()), Offset(x(t), bottom + 5), axis,
          align: i == 0 ? TextAlign.left : i == steps ? TextAlign.right : TextAlign.center);
    }
    canvas.restore();
  }

  void _dashedRect(Canvas canvas, Rect r, Paint paint) {
    void dashed(Offset a, Offset b) {
      final len = (b - a).distance;
      if (len <= 0) return;
      final dir = (b - a) / len;
      for (var d = 0.0; d < len; d += 6) {
        canvas.drawLine(a + dir * d, a + dir * math.min(d + 3, len), paint);
      }
    }
    dashed(r.topLeft, r.topRight);
    dashed(r.bottomLeft, r.bottomRight);
    dashed(r.topLeft, r.bottomLeft);
    dashed(r.topRight, r.bottomRight);
  }

  @override
  bool shouldRepaint(TimelinePainter old) => true;
}

/// A pill above the chart, in the chart card's title row: the app's [Pill]
/// look (a wash of the accent, pill radius, caption weight 600), pressable,
/// blue when [on].
class TimelinePill extends StatelessWidget {
  const TimelinePill(this.label, {super.key, this.onTap, this.on = false, this.icon});
  final String label;
  final VoidCallback? onTap;
  final bool on;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final accent = on ? C.blue : C.n500;
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          // The visual pill is small; the tap target is not.
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 5),
            decoration: BoxDecoration(
                color: on ? p.wash(C.blue) : p.card2, borderRadius: R.rPill),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: p.on(accent)),
                const SizedBox(width: S.x1),
              ],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: F.cap.copyWith(
                        color: on ? p.on(C.blue) : p.ink, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The chart card's title row: the title (and a small subtitle) on the left,
/// the pills right-aligned.
class TimelineTitleRow extends StatelessWidget {
  const TimelineTitleRow(this.title, {super.key, this.subtitle, this.pills = const []});
  final String title;
  final String? subtitle;
  final List<Widget> pills;
  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Flexible(
        flex: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: F.head.copyWith(color: p.ink)),
          if (subtitle != null)
            Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: F.over.copyWith(color: p.ink3)),
        ]),
      ),
      const SizedBox(width: S.x2),
      Expanded(
        flex: 3,
        child: Wrap(spacing: S.x2, alignment: WrapAlignment.end, children: pills),
      ),
    ]);
  }
}
