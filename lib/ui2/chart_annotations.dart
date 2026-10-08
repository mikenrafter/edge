// CHART ANNOTATIONS — journal items and provenance marks drawn on a chart.
//
// RED-PHASE STUB. Every behavioural function throws; the data classes and the
// public names are the contract the tests in test/chart_annotation_*_test.dart
// pin. The implementation phase replaces the throwing bodies.
//
// The idea: one pure layout function turns "things that happened" plus "how
// many pixels the chart has" plus "what the finger is on" into placed icons,
// "+n" clusters, shaded ranges and ONE static label. The widgets only draw it.

import 'package:flutter/material.dart';

/// What an annotation is. One icon and one colour per kind.
enum AnnotationKind {
  water,
  assumedWater,
  moment,
  symptom,
  workout,
  nap,
  review,
  journal,
  algoVersion,
}

/// The glyph for [k]. Unique per kind.
IconData annotationIcon(AnnotationKind k) =>
    throw UnimplementedError('annotationIcon');

/// The pigment for [k]. Unique per kind; a range's shade is this at low alpha.
Color annotationColor(AnnotationKind k) =>
    throw UnimplementedError('annotationColor');

/// One thing to mark. [at] is in the chart's own x domain (epoch seconds on an
/// intraday chart, slot index on a daily one) — the layout never assumes a
/// day is 86400 s. A non-null [until] greater than [at] makes it a RANGE (a
/// linked start/end pair); anything else is a point.
@immutable
class ChartAnnotation {
  const ChartAnnotation({
    required this.id,
    required this.kind,
    required this.at,
    required this.label,
    this.until,
  });
  final String id;
  final AnnotationKind kind;
  final double at;
  final double? until;
  final String label;
}

/// Domain-to-pixel scale of one chart plus the footprint of one icon.
@immutable
class AnnotationScale {
  const AnnotationScale({
    required this.domainStart,
    required this.domainEnd,
    required this.width,
    this.iconWidth = 24,
    this.badgeWidth = 22,
  });
  final double domainStart;
  final double domainEnd;

  /// Plot width in logical pixels.
  final double width;
  final double iconWidth;

  /// Extra footprint the "+n" badge takes right after a cluster's icon.
  final double badgeWidth;

  /// Pixel x of domain value [at] (not clamped).
  double xOf(double at) => throw UnimplementedError('AnnotationScale.xOf');
}

/// Where the one label goes. Static: it never follows the finger.
enum AnnotationLabelSlot { topStart }

/// One icon on the lane.
@immutable
class PlacedAnnotation {
  const PlacedAnnotation({
    required this.id,
    required this.kind,
    required this.label,
    required this.x,
    required this.iconLeft,
    required this.iconWidth,
    required this.badgeWidth,
    required this.memberIds,
    required this.focused,
    required this.isRange,
  });

  /// The annotation this icon shows (the focused one, else the oldest).
  final String id;
  final AnnotationKind kind;
  final String label;

  /// Where the dashed line is: the displayed item's true position.
  final double x;

  /// Left edge of the icon box after collision nudging. The line stays at [x].
  final double iconLeft;
  final double iconWidth;
  final double badgeWidth;

  /// Every annotation this icon stands for, OLDEST FIRST. One for a lone item.
  final List<String> memberIds;
  final bool focused;
  final bool isRange;

  /// The "+n": members not shown. Zero means no badge.
  int get more => memberIds.length - 1;

  /// Right edge of everything this icon takes (icon plus badge).
  double get footprintRight => iconLeft + iconWidth + (more > 0 ? badgeWidth : 0);

  /// The member after [current] in this icon, wrapping; the first member if
  /// [current] is not one of them.
  String next(String? current) => throw UnimplementedError('PlacedAnnotation.next');
}

/// The shaded area of a range, clipped to the plot.
@immutable
class ShadedRange {
  const ShadedRange({
    required this.id,
    required this.kind,
    required this.left,
    required this.right,
    required this.focused,
  });
  final String id;
  final AnnotationKind kind;
  final double left;
  final double right;
  final bool focused;
}

@immutable
class AnnotationLayout {
  const AnnotationLayout({
    required this.items,
    required this.shades,
    required this.unplaced,
    required this.focusedId,
    required this.labelText,
    this.labelSlot = AnnotationLabelSlot.topStart,
  });

  /// Icons, left to right. Their footprints never overlap and stay in bounds.
  final List<PlacedAnnotation> items;

  /// One per range that is visible at all, whether or not it got an icon.
  final List<ShadedRange> shades;

  /// Ids that are in the plot but could not get any icon (the chart is too
  /// narrow). Never silently dropped.
  final List<String> unplaced;

  /// The annotation that is focused, or null.
  final String? focusedId;

  /// The static label's text — the focused annotation's label, else null.
  final String? labelText;
  final AnnotationLabelSlot labelSlot;
}

/// THE LAYOUT. Pure. See the tests for the rules.
AnnotationLayout layoutAnnotations({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  String? focusId,
}) =>
    throw UnimplementedError('layoutAnnotations');

/// The annotation a scrub at [cursorPx] is ON or NEAREST to, or null (no
/// cursor, nothing to pick, or farther than [reach] px when given).
String? pickAnnotationFocus({
  required List<ChartAnnotation> annotations,
  required AnnotationScale scale,
  required double? cursorPx,
  double? reach,
}) =>
    throw UnimplementedError('pickAnnotationFocus');

/// Steps the focus [delta] places through every annotation in layout order
/// (icons left to right, a cluster's members oldest to newest). Clamped at the
/// ends; an unknown [current] counts as no focus.
String? stepAnnotationFocus(
  AnnotationLayout layout,
  String? current,
  int delta,
) =>
    throw UnimplementedError('stepAnnotationFocus');

/// An algorithm-version change as annotations, in the daily slot domain
/// (slot i is at i, the last slot is today). [breakDaysBehind] is each break's
/// stamp as "days behind today" — the first day computed the new way. The mark
/// sits half a slot LEFT of it, and a break at slot 0 (nothing before it in
/// the window) or outside the window is dropped.
List<ChartAnnotation> algoBreakAnnotations({
  required List<int> breakDaysBehind,
  required int seriesLength,
  required String label,
}) =>
    throw UnimplementedError('algoBreakAnnotations');

/// Intraday annotations (domain: epoch seconds) onto a daily chart whose slots
/// are the local day [dayLabels] ('YYYY-MM-DD', oldest first). Slot i is at
/// domain i. A point lands on its LOCAL day; a range inside one day is that
/// day's point; a range across days spans its first to its last day's slot.
/// Anything outside the labels is dropped. Never invents an item.
List<ChartAnnotation> dailyAnnotations(
  List<ChartAnnotation> timed,
  List<String> dayLabels,
) =>
    throw UnimplementedError('dailyAnnotations');

/// What a chart is annotated with.
@immutable
class AnnotationSet {
  const AnnotationSet({
    required this.items,
    required this.domainStart,
    required this.domainEnd,
  });
  final List<ChartAnnotation> items;
  final double domainStart;
  final double domainEnd;
}

/// One dashed line, as the painter draws it.
@immutable
class AnnotationLine {
  const AnnotationLine({
    required this.id,
    required this.x,
    required this.color,
    required this.bold,
    required this.strokeWidth,
    this.dashed = true,
  });
  final String id;
  final double x;
  final Color color;
  final bool bold;
  final double strokeWidth;
  final bool dashed;
}

/// Paints the dashed lines. Public so tests can read what it will draw.
class AnnotationLinesPainter extends CustomPainter {
  const AnnotationLinesPainter({required this.lines});
  final List<AnnotationLine> lines;

  @override
  void paint(Canvas canvas, Size size) =>
      throw UnimplementedError('AnnotationLinesPainter.paint');

  @override
  bool shouldRepaint(covariant AnnotationLinesPainter old) => true;
}

/// One kind's glyph at the lane's icon size. [bold] is the focused look.
class AnnotationIcon extends StatelessWidget {
  const AnnotationIcon({super.key, required this.kind, required this.bold});
  final AnnotationKind kind;
  final bool bold;

  @override
  Widget build(BuildContext context) =>
      throw UnimplementedError('AnnotationIcon.build');
}

/// The annotation lane: icons (and "+n"), the static label, the shaded ranges
/// and the dashed lines running [plotHeight] down through the plot. Width is
/// whatever it is given; the layout is computed from it.
///
/// [cursor] is the scrub position 0…1 (null: none). A tap on an icon or its
/// "+n" steps to the next member of that icon, and a moved [cursor] clears
/// that pin.
class ChartAnnotationLane extends StatefulWidget {
  const ChartAnnotationLane({
    super.key,
    required this.set,
    required this.cursor,
    required this.plotHeight,
  });
  final AnnotationSet set;
  final double? cursor;
  final double plotHeight;

  static const laneKey = ValueKey('annotation-lane');
  static const linesKey = ValueKey('annotation-lines');
  static const boundaryKey = ValueKey('annotation-boundary');
  static const labelKey = ValueKey('annotation-label');
  static ValueKey<String> iconKey(String id) => ValueKey('annotation-icon:$id');
  static ValueKey<String> moreKey(String id) => ValueKey('annotation-more:$id');
  static ValueKey<String> shadeKey(String id) => ValueKey('annotation-shade:$id');

  @override
  State<ChartAnnotationLane> createState() => _ChartAnnotationLaneState();
}

class _ChartAnnotationLaneState extends State<ChartAnnotationLane> {
  @override
  Widget build(BuildContext context) =>
      throw UnimplementedError('ChartAnnotationLane.build');
}
