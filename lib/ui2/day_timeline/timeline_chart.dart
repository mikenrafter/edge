import '../../pilot/sync_strip_overlay.dart';
// Shared chart presentation; TimelineController owns all mutable time state.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:intl/intl.dart' show NumberFormat;
import '../../l10n/app_localizations.dart';
import 'day_graph.dart';
import '../chart_annotations.dart';
import '../charts.dart' show SleepStage, Hypnogram, AxisSpec, axisInt;
import '../skeleton/guide_plot.dart';
import '../grammar.dart'
    show
        ChartKeyReadout,
        ChartCell,
        NerdStatsListener,
        Scrubber,
        ScrubGestureDelegate;
import '../theme.dart';
import '../../state/clock_format.dart' show formatClockOf;
import 'timeline_controller.dart';
export 'timeline_controller.dart';

String _clock(double sec) =>
    formatClockOf(DateTime.fromMillisecondsSinceEpoch(sec.round() * 1000));

Widget timelineChart({
  required TimelineController controller,
  required DayGraph graph,
  required List<ChartAnnotation> annotations,
  required ValueChanged<String> onAnnotationSelected,
}) => SharedTimelineChart(
  controller: controller,
  graph: graph,
  annotations: annotations,
  onAnnotationSelected: onAnnotationSelected,
);

class SharedTimelineChart extends StatefulWidget {
  const SharedTimelineChart({
    super.key,
    required this.controller,
    required this.graph,
    this.annotations = const [],
    required this.onAnnotationSelected,
    this.onScrub,
    this.scrubColor,
    this.stages,
    this.fine,
    this.fineStartSec,
    this.emphasis,
    this.nerdStats,
    this.syncStrip = false,
  });
  final bool syncStrip;
  final TimelineController controller;
  final DayGraph graph;
  final List<ChartAnnotation> annotations;
  final ValueChanged<String> onAnnotationSelected;
  final ValueChanged<double>? onScrub;
  final Color? scrubColor;
  final List<SleepStage?>? stages;
  final List<double?>? fine;
  final int? fineStartSec;
  final Set<String>? emphasis;
  final NerdStatsListener? nerdStats;
  @override
  State<SharedTimelineChart> createState() => _ChartState();
}

class _ChartState extends State<SharedTimelineChart>
    with TickerProviderStateMixin
    implements AnnotationListener, ScrubGestureDelegate {
  Offset? _doubleAt;
  bool? _firstHandle;
  double _width = 0;
  TimelineController get c => widget.controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    c.attach(this, reducedMotion: !Motion.enabled(context));
  }

  @override
  void didUpdateWidget(SharedTimelineChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.detach(this);
      c.attach(this, reducedMotion: !Motion.enabled(context));
    }
  }

  @override
  void dispose() {
    c.detach(this);
    super.dispose();
  }

  @override
  void annotationTapped(String id) {
    widget.onAnnotationSelected(id);
  }

  double _time(double x, double width) =>
      c.view.at(((x - 44) / math.max(1, width - 52)).clamp(0.0, 1.0));
  void _scrub(double time) {
    c.setScrub(time);
    widget.onScrub?.call(time);
  }

  @override
  void scrubTapped(TapUpDetails d) => _scrub(_time(d.localPosition.dx, _width));
  @override
  void scrubDoubleTapDown(TapDownDetails d) => _doubleAt = d.localPosition;
  @override
  void scrubDoubleTapped() => c.zoomAt(_time(_doubleAt!.dx, _width));
  @override
  void scrubDragStarted(DragStartDetails d) {
    final time = _time(d.localPosition.dx, _width), s = c.selection;
    _firstHandle = s == null
        ? null
        : (time - s.start).abs() <= (time - s.end).abs();
    if (s == null) _scrub(time);
  }

  @override
  void scrubDragUpdated(DragUpdateDetails d) {
    final time = _time(d.localPosition.dx, _width);
    if (_firstHandle case final first?) {
      c.moveZoomHandle(first, time);
    } else {
      _scrub(time);
    }
  }

  @override
  void scrubDragEnded() => _firstHandle = null;

  @override
  Widget build(BuildContext context) {
    final visibleGraph=syncStripVisibleGraph(context,widget.graph,enabled:widget.syncStrip);
    final visibleFine=syncStripVisibleCurve(context,widget.fine,widget.fineStartSec??widget.graph.dayStart,enabled:widget.syncStrip);
    final l =
        (AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en')));
    final p = P.of(context);
    String fullClock(double sec) {
      final at = DateTime.fromMillisecondsSinceEpoch(sec.round() * 1000);
      return '${MaterialLocalizations.of(context).formatFullDate(at)}, ${_clock(sec)}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.dayTimelineHeartRateTitle, style: F.head.copyWith(color: p.ink)),
        RepaintBoundary(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              c.range,
              c.scrubChanges,
              c.zoomChanges,
            ]),
            builder: (context, _) => LayoutBuilder(
              builder: (context, box) {
                _width = box.maxWidth;
                final header =
                    ChartAnnotationLane.headerFor(
                      MediaQuery.textScalerOf(context),
                      Directionality.of(context),
                    ) +
                    24;
                const height = 180.0;
                final view = c.view;
                return Semantics(
                  label: c.scrub == null
                      ? l.timelineSemanticsRange(
                          fullClock(view.start),
                          fullClock(view.end),
                        )
                      : l.timelineSemanticsScrub(
                          fullClock(view.start),
                          fullClock(view.end),
                          fullClock(c.scrub!),
                        ),
                  customSemanticsActions: {
                    for (final annotation in widget.annotations)
                      CustomSemanticsAction(
                        label:
                            '${annotation.label}, ${fullClock(annotation.at)}${annotation.until == null ? '' : ' – ${fullClock(annotation.until!)}'}',
                      ): () =>
                          annotationTapped(annotation.id),
                  },
                  child: Scrubber(
                    key: const ValueKey('shared-timeline-plot'),
                    label: l.dayTimelineHeartRateTitle,
                    value: c.scrub == null
                        ? null
                        : view.fraction(c.scrub!).clamp(0.0, 1.0),
                    describe: (fraction) => fullClock(view.at(fraction)),
                    step: 60 / view.span,
                    onChanged: (fraction) => _scrub(view.at(fraction)),
                    gestureDelegate: this,
                    child: SizedBox(
                      height: header + height + 24,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: TimelinePainter(
                                p: p,
                                view: view,
                                graph: visibleGraph,
                                stages: widget.stages,
                                header: header,
                                height: height,
                                fine: visibleFine,
                                fineStartSec: widget.fineStartSec,
                                scaler: MediaQuery.textScalerOf(context),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _PositionPainter(
                                  p: p,
                                  view: view,
                                  scrub: c.scrub,
                                  scrubColor: widget.scrubColor,
                                  selection: c.selection,
                                  header: header,
                                  height: height,
                                ),
                              ),
                            ),
                          ),
                          if (visibleGraph.dayStart != null &&
                              widget.annotations.isNotEmpty)
                            Positioned(
                              left: 44,
                              right: 8,
                              top: 0,
                              child: ChartAnnotationLane(
                                set: AnnotationSet(
                                  items: widget.annotations,
                                  domainStart: view.start,
                                  domainEnd: view.end,
                                  reach: 48,
                                  listener: this,
                                ),
                                tapTargetSize: 48,
                                plotHeight: height,
                                emphasis: widget.emphasis,
                                cursor: c.scrub == null
                                    ? null
                                    : view.fraction(c.scrub!),
                              ),
                            ),
                          if (widget.syncStrip) Positioned.fill(child: SyncStripOverlay(view:view,left:44,right:8,top:header,bottom:24)),
                          if (c.selection case final s?) ...[
                            for (final first in [true, false])
                              Positioned(
                                left:
                                    (44 +
                                            view.fraction(
                                                  first ? s.start : s.end,
                                                ) *
                                                math.max(1, box.maxWidth - 52) -
                                            24)
                                        .clamp(
                                          0.0,
                                          math.max(0, box.maxWidth - 48),
                                        ),
                                top: header + height - 48,
                                width: 48,
                                height: 48,
                                child: Semantics(
                                  slider: true,
                                  label: l.timelineChooseRange,
                                  value: _clock(first ? s.start : s.end),
                                  increasedValue: _clock(
                                    (first ? s.start : s.end) + 60,
                                  ),
                                  decreasedValue: _clock(
                                    (first ? s.start : s.end) - 60,
                                  ),
                                  onIncrease: () => c.moveZoomHandle(
                                    first,
                                    (first ? s.start : s.end) + 60,
                                  ),
                                  onDecrease: () => c.moveZoomHandle(
                                    first,
                                    (first ? s.start : s.end) - 60,
                                  ),
                                  child: const IgnorePointer(
                                    child: SizedBox.expand(),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // Only actual scrub changes rebuild these Text widgets; range frames do not.
        ListenableBuilder(
          listenable: c.scrubChanges,
          builder: (context, _) {
            var latest = 0;
            for (var i = 0; i < visibleGraph.slots; i++) {
              if ((i < visibleGraph.hr.length && visibleGraph.hr[i] != null) ||
                  (i < visibleGraph.movement.length &&
                      visibleGraph.movement[i] != null)) {
                latest = i;
              }
            }
            final time =
                c.scrub ??
                ((visibleGraph.dayStart ?? c.home.start) + latest * 60);
            final minute =
                ((time - (visibleGraph.dayStart ?? c.home.start)) / 60).floor();
            final fine = visibleFine;
            final second = (time - (widget.fineStartSec ?? 0)).floor();
            final hr = fine != null && second >= 0 && second < fine.length
                ? fine[second]
                : minute >= 0 && minute < visibleGraph.hr.length
                ? visibleGraph.hr[minute]
                : null;
            final move = minute >= 0 && minute < visibleGraph.movement.length
                ? visibleGraph.movement[minute]
                : null;
            final unrecorded = visibleGraph.unmeasured.any(
              (gap) => minute >= gap.$1 && minute < gap.$2,
            );
            return Semantics(
              key: const ValueKey('timeline-readout'),
              label: c.scrub == null
                  ? null
                  : '${l.dayTimelineHeartRateTitle}: ${hr == null ? '—' : '${NumberFormat.decimalPattern(l.localeName).format(hr.round())} bpm'}, ${l.homeMovement}: ${move == null ? '—' : NumberFormat.percentPattern(l.localeName).format(move)}',
              child: ChartKeyReadout(
                time: _clock(time),
                scrubbed: c.scrub != null,
                stableCells: true,
                announceLatest: true,
                nerdStats: widget.nerdStats,
                cells: [
                  ChartCell(
                    '${l.dayTimelineHeartRateTitle} (bpm)',
                    p.on(C.red),
                    value: hr == null
                        ? null
                        : '${NumberFormat.decimalPattern(l.localeName).format(hr.round())} bpm',
                  ),
                  ChartCell(
                    l.timelineMovementShare,
                    p.on(C.domMove),
                    value: move == null
                        ? null
                        : NumberFormat.percentPattern(
                            l.localeName,
                          ).format(move),
                  ),
                  if (visibleGraph.work.isNotEmpty)
                    ChartCell(
                      l.dayTimelineWorkout,
                      p.on(C.orange),
                      value:
                          visibleGraph.work.any(
                            (span) => minute >= span.$1 && minute < span.$2,
                          )
                          ? l.activityTrackYes
                          : l.activityTrackNo,
                    ),
                  if (visibleGraph.unmeasured.isNotEmpty)
                    ChartCell(
                      l.dayTimelineNotRecorded,
                      null,
                      value: unrecorded && c.scrub != null
                          ? l.timelineHere
                          : null,
                      hasValue: unrecorded && c.scrub != null,
                    ),
                ],
              ),
            );
          },
        ),
        if (visibleGraph.movement.any((v) => v != null))
          Text(l.timelineMovementNote, style: F.cap.copyWith(color: p.ink3)),
      ],
    );
  }
}

class TimelineZoomControls extends StatelessWidget {
  const TimelineZoomControls({super.key, required this.controller});
  final TimelineController controller;
  @override
  Widget build(BuildContext context) {
    final l =
        (AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en')));
    return ListenableBuilder(
      listenable: controller.zoomChanges,
      builder: (context, _) {
        final selecting = controller.selection != null;
        final label = controller.zoomed
            ? l.timelineResetZoom
            : l.timelineZoomIn;
        return Semantics(
          key: const ValueKey('timeline-zoom'),
          selected: selecting,
          label: label,
          button: true,
          excludeSemantics: true,
          value: selecting ? l.timelineChooseRange : null,
          onTap: controller.toggleZoomSelection,
          child: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: controller.toggleZoomSelection,
            child: Text(label),
          ),
        );
      },
    );
  }
}

// CLAIM(timeline-trace-gaps): a null slot breaks the trace; absent stages stay
// absent [spec §4.1/§4.3; sleep_shared_timeline_test].
class TimelinePainter extends CustomPainter implements GuidePlot {
  TimelinePainter({
    required this.p,
    required this.view,
    required this.graph,
    required this.header,
    required this.height,
    required this.scaler,
    this.stages,
    this.fine,
    this.fineStartSec,
  });
  final P p;
  final TimelineView view;
  final DayGraph graph;
  final double header, height;
  final TextScaler scaler;
  final List<SleepStage?>? stages;
  final List<double?>? fine;
  final int? fineStartSec;
  @override
  Color get guideLineColor => p.on(C.red);
  @override
  void paint(Canvas canvas, Size size) {
    final width = math.max(1.0, size.width - 52);
    double x(double t) => 44 + view.fraction(t) * width;
    final hrHeight = height * (stages == null ? 5 : 3) / 6;
    final stageHeight = stages == null ? 0.0 : height * 2 / 6;
    final moveTop = header + hrHeight + stageHeight;
    void text(
      String content,
      double anchor,
      double top, {
      TextAlign align = TextAlign.left,
      double? maxWidth,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: content,
          style: F.over.copyWith(color: p.ink3),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final factor = maxWidth == null || painter.width <= maxWidth
          ? 1.0
          : maxWidth / painter.width;
      final renderedWidth = painter.width * factor;
      final left = switch (align) {
        TextAlign.right => anchor - renderedWidth,
        TextAlign.center => anchor - renderedWidth / 2,
        _ => anchor,
      };
      canvas.save();
      canvas.translate(left, top);
      canvas.scale(factor);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
      painter.dispose();
    }

    final curve = fine ?? graph.hr;
    final axis = AxisSpec.of(
      curve.whereType<double>().where((v) => v.isFinite && v > 0),
      ticks: 3,
    );
    final lo = axis?.min ?? 0, hi = axis?.max ?? 1;
    double y(double value) =>
        header + 6 + (1 - (value - lo) / (hi - lo)) * (hrHeight - 12);
    text('bpm', 0, math.max(0, header - 20), maxWidth: 40);
    // CLAIM(timeline-clock-labels): keep interior time references on full days
    // at the current text scale [pilot time axis; day_timeline_test; review S1].
    double widthOf(String label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: F.over.copyWith(color: p.ink3)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      return measured;
    }
    final widest = [
      for (var i = 0; i <= 4; i++) widthOf(_clock(view.at(i / 4))),
    ].reduce(math.max);
    final steps = view.span <= 1800 ? 1 : widest * 4 + 40 <= width ? 4 : 2;
    for (var i = 0; i <= steps; i++) {
      final time = view.at(i / steps);
      text(
        _clock(time),
        x(time),
        header + height + 3,
        align: i == 0 ? TextAlign.left
            : i == steps ? TextAlign.right : TextAlign.center,
        maxWidth: width / 2 - 8,
      );
    }
    if (axis != null) {
      for (final tick in axis.tickValues) {
        text(
          axisInt(tick),
          40,
          y(tick) - 5,
          align: TextAlign.right,
          maxWidth: 40,
        );
      }
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(44, header, width, height));
    final base = (graph.dayStart ?? view.start).toDouble();
    for (final (a, b) in graph.unmeasured) {
      canvas.drawRect(
        Rect.fromLTRB(
          x(base + a * 60),
          header,
          x(base + b * 60),
          header + height,
        ),
        Paint()..color = p.card2,
      );
    }
    for (final (a, b, _) in graph.work) {
      canvas.drawRect(
        Rect.fromLTRB(x(base + a * 60), header, x(base + b * 60), header + 5),
        Paint()..color = p.on(C.orange),
      );
    }
    final paint = Paint()
      ..color = p.line
      ..strokeWidth = 1;
    if (axis != null) {
      for (final tick in axis.tickValues) {
        canvas.drawLine(
          Offset(44, y(tick)),
          Offset(size.width - 8, y(tick)),
          paint,
        );
      }
    }
    final start =
        (fine == null ? graph.dayStart : fineStartSec)?.toDouble() ??
        view.start;
    final step = fine == null ? 60.0 : 1.0;
    final path = Path();
    bool run = false;
    for (
      var i = math.max(0, ((view.start - start) / step).floor() - 1);
      i < curve.length && start + i * step <= view.end + step;
      i++
    ) {
      final v = curve[i];
      if (v == null || !v.isFinite || v <= 0) {
        run = false;
        continue;
      }
      final point = Offset(x(start + i * step), y(v));
      if (run) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        canvas.drawCircle(point, 1.2, Paint()..color = p.on(C.red));
      }
      run = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p.on(C.red)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    final movement = graph.movement;
    for (
      var i = math.max(0, ((view.start - base) / 60).floor());
      i < movement.length && base + i * 60 < view.end;
      i++
    ) {
      final v = movement[i];
      if (v == null || !v.isFinite) continue;
      canvas.drawRect(
        Rect.fromLTRB(
          x(base + i * 60),
          header + height - 1,
          x(base + (i + 1) * 60),
          header + height,
        ),
        Paint()..color = p.on(C.domMove).withValues(alpha: .4),
      );
      final left = x(base + i * 60), right = x(base + (i + 1) * 60);
      canvas.drawRect(
        Rect.fromLTRB(
          left,
          moveTop + (1 - v.clamp(0, 1)) * height / 6,
          right,
          header + height,
        ),
        Paint()..color = p.on(C.domMove),
      );
    }
    final stage = stages;
    if (stage != null) {
      final colors = Hypnogram.cols(p);
      for (final run in stageWave(stage)) {
        for (var i = 0; i < run.length; i++) {
          final point = run[i];
          final y = header + hrHeight + 4 + point.depth * (stageHeight - 8) / 3;
          final left = x(base + point.index * 300);
          final right = x(base + (point.index + 1) * 300);
          final paint = Paint()
            ..color = colors[point.stage]!
            ..strokeWidth = 3;
          canvas.drawLine(Offset(left, y), Offset(right, y), paint);
          if (i + 1 < run.length) {
            final next = run[i + 1];
            final nextY =
                header + hrHeight + 4 + next.depth * (stageHeight - 8) / 3;
            canvas.drawLine(Offset(right, y), Offset(right, nextY), paint);
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(TimelinePainter old) => true;
}

class _PositionPainter extends CustomPainter implements GuidePlotOverlay {
  _PositionPainter({
    required this.p,
    required this.view,
    required this.scrub,
    required this.scrubColor,
    required this.selection,
    required this.header,
    required this.height,
  });
  final P p;
  final TimelineView view;
  final double? scrub;
  final Color? scrubColor;
  final TimelineView? selection;
  final double header, height;
  @override
  void paint(Canvas canvas, Size size) {
    double x(double t) => 44 + view.fraction(t) * (size.width - 52);
    final paint = Paint()
      ..color = p.ink2
      ..strokeWidth = 1;
    if (scrub case final t?) {
      if (t >= view.start && t <= view.end) {
        canvas.drawLine(
          Offset(x(t), header),
          Offset(x(t), header + height),
          Paint()..color = (scrubColor == null ? p.ink2 : p.on(scrubColor!))..strokeWidth = 1,
        );
      }
    }
    if (selection case final s?) {
      canvas.drawRect(
        Rect.fromLTRB(x(s.start), header, x(s.end), header + height),
        Paint()..color = p.wash(C.blue),
      );
      for (final t in [s.start, s.end]) {
        canvas.drawLine(
          Offset(x(t), header),
          Offset(x(t), header + height),
          paint..strokeWidth = 3,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PositionPainter old) =>
      old.view != view || old.scrub != scrub || old.scrubColor != scrubColor ||
      old.selection != selection;
}
