// SKELETON OVERLAY (phase 1)
//
// Turns the real, laid-out screen into skeleton except the guide's target,
// without touching any screen: everything is derived from the element and
// render tree after layout.
//
// CARD RULE. A "section" is the OUTERMOST `Surface` or `Section` element under
// the root, found by widget type:
//   - `Surface` (grammar.dart:225) builds every card: a Container with
//     `color: p.card`, `borderRadius: R.rLg`, `boxShadow: p.el(..)`. A
//     decoration test would miss `Surface(color: ...)` and would find the tab
//     bar's plain Container, so the TYPE is the rule.
//   - `Section` (grammar.dart:264) is a title row + child; its heading and its
//     ACTION sit outside the card, in no decorated box, so the unit is the
//     whole Section, not just its Surface.
//   - AppShell's tab bar (app_shell.dart:215 `_TabBar`) is a plain Container,
//     not a card: it is chrome, found by [defaultSkeletonChrome].
// Text outside any section is its own unit (one paragraph), on the scaffold.
//
// Mating parts: [GuideTarget] (../guides/guide_target.dart) resolves the rects
// that [skeletonPlan] keeps; [Skeletonize] owns the live loop between them;
// The guide run draws it live; the review views (test/support/guide_view.dart)
// draw it on demo data.

import 'dart:math' as math;
import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show NavBar, Pressable, ScreenTitle, Section, Surface;
import '../guides/guide_target.dart';
import '../guides/tree_geometry.dart';
import '../theme.dart';

enum SkeletonKind {
  /// A card rect repainted in its own surface colour ([SkeletonShape.color]).
  surface,

  /// One per text line box.
  bar,

  /// One per chart / image / custom paint.
  block,

  /// An OPAQUE fill in the scaffold background colour, painted before the bar
  /// of loose text and of Section headings/actions (text that sits on the
  /// scaffold, not on a card), so no glyph pixel survives at a bar's rounded
  /// corners. Carries [SkeletonShape.color].
  erase,

  /// ONE translucent layer ([SkeletonShape.color], alpha included) over a whole
  /// component's box: the r2 dim look. Never an erase patch.
  dim,

  /// A skeleton card's heading (its Section title, else its first text line): the
  /// text itself stays, drawn DIMMED at the unit's top-left, while the body lines
  /// are [bar]s. The rect is the heading line's box; [SkeletonShape.color] is the
  /// veil that dims the real text.
  heading,
}

@immutable
class SkeletonShape {
  final SkeletonKind kind;

  /// In paint coordinates of the plan's root (origin = root's top-left).
  final Rect rect;

  /// Set for [SkeletonKind.surface] (the card's own colour) and
  /// [SkeletonKind.erase] (the background colour) only.
  final Color? color;

  /// 0-based index of the skeletonized unit (a card / `Section`, or one loose
  /// text paragraph) this shape belongs to. Ascends with the plan order and is
  /// contiguous: a plan with N units uses 0..N-1.
  final int section;

  const SkeletonShape({
    required this.kind,
    required this.rect,
    required this.section,
    this.color,
  });
}

/// How strongly the r2 dim look veils a component (the scaffold colour at this
/// opacity). Owner decision (pilot APK e828832b): there is NO contrast floor;
/// dimmed text is not meant to be read closely, and its contrast ratio is at most
/// half of its original in light and dark [guide_r2_contrast].
const kDimOpacity = .72;

/// Words too common to make two labels look alike (r2 D-S2). Words shorter
/// than three letters are ignored as well.
const _kStopwords = {
  'the', 'and', 'for', 'you', 'your', 'are', 'how', 'these', 'this', 'that', 'with',
  'from', 'tap', 'not', 'any', 'can', 'its', 'his', 'her', 'our', 'out', 'but',
};

/// The content words of [text]: lower case, >= 3 letters, no stopwords.
Set<String> contentWords(String text) => {
  for (final w in text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)))
    if (w.length >= 3 && !_kStopwords.contains(w)) w,
};

/// True for a widget with tap semantics (a control the user can press).
bool isGuideControl(Widget w) => w is Pressable && w.onTap != null ||
    w is GestureDetector && (w.onTap != null || w.onLongPress != null) ||
    w is InkResponse && w.onTap != null || w is ButtonStyleButton && w.onPressed != null ||
    w is Semantics && (w.properties.onTap != null || w.properties.button == true) ||
    w is TextField || w is Switch || w is Checkbox || w is Radio;

/// The r2 dim look's rule for which non-kept units stay skeleton: look-alikes of
/// the target (a CONTROL inside the target's [group] box, or any unit sharing a
/// content word with the target's label). Every other unit gets one dim layer.
/// All rects are in the page root's coordinates.
/// How near a control must be to the target to stay skeleton (owner, pilot APK
/// feedback B): the gap between its ink and the target's ink is at most this many
/// logical px (about one row: the 8-12 px gaps of a card list plus a small
/// margin). Reach uses visible ink, excluding hit padding. Controls beyond it
/// are dimmed with the rest of their component.
/// Applies to content inside the visible scroll area only; P6 scroll-through
/// content is skeleton at any distance ([DimPolicy.skeletonAll]).
const kSkeletonReach = 56.0;

/// A unit (Surface, Section or control box) taller than this many logical px is
/// LARGE: near the target it is dimmed whole, never skeleton (owner: the Start
/// session card on Activity > History became a grey block). 120 keeps one-row
/// controls (44-76 px, sub-tabs, list rows) skeleton and turns the 190 px Start
/// card and the 132 px "Did something the band missed?" card into dim. Width is not
/// a criterion: full-width one-row controls are the look-alikes the rule is for.
const kLargeUnitHeight = 120.0;

/// True for a unit whose [box] is strictly taller than [kLargeUnitHeight].
bool isLargeUnit(Rect box) => box.height > kLargeUnitHeight;

/// Gap between two boxes: 0 when they overlap, else the distance between their edges.
double rectGap(Rect a, Rect b) {
  final dx = math.max(0.0, math.max(a.left - b.right, b.left - a.right));
  final dy = math.max(0.0, math.max(a.top - b.bottom, b.top - a.bottom));
  return math.sqrt(dx * dx + dy * dy);
}

/// The visible text/icon/image/chart ink under [box], excluding layout and hit padding.
/// Null means there is no visible ink to compare, not an invented fallback box.
Rect? _visibleInk(RenderBox box, RenderBox root) {
  Rect? ink;
  void add(RenderBox object, Rect local) {
    final visible = rectInRoot(object, root, local).intersect(visibleBoundsInRoot(object, root));
    if (!visible.isEmpty) ink = ink?.expandToInclude(visible) ?? visible;
  }
  void visit(RenderObject object) {
    if (object is RenderParagraph && object.hasSize) {
      final length = object.text.toPlainText().length;
      for (final glyphs in object.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length))) {
        add(object, glyphs.toRect());
      }
    } else if (object is RenderImage || object is RenderCustomPaint &&
        (object.painter != null || object.foregroundPainter != null)) {
      if (object is RenderBox && object.hasSize) add(object, Offset.zero & object.size);
    } else {
      object.visitChildren(visit);
    }
  }
  visit(box);
  return ink;
}

class DimPolicy {
  final Rect? targetRect;
  final Set<String> targetWords;
  final List<Rect> controls;

  /// P6: the target is off screen, so everything on screen collapses to
  /// skeleton (the user scrolls through it toward the marker).
  final bool skeletonAll;
  const DimPolicy({this.targetRect, this.targetWords = const {}, this.controls = const [], this.skeletonAll = false});

  /// Reads the policy for [target] from the laid-out [page]: the controls and
  /// the words of the target's label. A control is a look-alike when it is within
  /// [kSkeletonReach] of the target.
  static DimPolicy of(Element page, TargetFound target) {
    final root = laidOutBox(page);
    if (root == null) return const DimPolicy();
    final controls = <Rect>[];
    final words = <String>{};
    for (final e in onstageElements(page)) {
      final box = laidOutBox(e);
      if (box == null) continue;
      final w = e.widget;
      if (isGuideControl(w)) {
        final ink = _visibleInk(box, root);
        if (ink != null) controls.add(ink);
      }
      final ro = e is RenderObjectElement ? e.renderObject : null;
      if (ro is RenderParagraph && ro.hasSize && target.rect.contains(rectInRoot(ro, root).center)) {
        words.addAll(contentWords(ro.text.toPlainText()));
      }
      // An icon-only control (a bin) is named by its semantics label.
      final label = w is Pressable ? w.semanticLabel : w is Semantics ? w.properties.label : null;
      if (label != null && target.rect.contains(rectInRoot(box, root).center)) words.addAll(contentWords(label));
    }
    return DimPolicy(targetRect: _visibleInk(target.renderObject, root), targetWords: words, controls: controls);
  }

  // CLAIM(skeleton-visible-reach): distance and size gate every look-alike,
  // including shared words. Only P6 bypasses them [guide_r2_review_test R3].
  bool lookalike(Rect bounds, Set<String> words, {Rect? inkBounds}) {
    if (skeletonAll) return true;
    final target = targetRect;
    final ink = inkBounds;
    if (target == null || ink == null || isLargeUnit(bounds) || rectGap(ink, target) > kSkeletonReach) return false;
    return controls.any((control) => control.overlaps(ink)) || words.any(targetWords.contains);
  }
}

/// A shape before its unit has a number.
class _Draft {
  final SkeletonKind kind;
  final Rect rect;
  final Color? color;
  const _Draft(this.kind, this.rect, [this.color]);
}

/// Shapes that belong together in the plan order: an erase and the bar it
/// precedes, or one block.
class _Item {
  final Rect sortRect;

  /// Blocks sort before bars that tie with them (a bar can sit on a block).
  final int tie;
  final List<_Draft> drafts;

  /// A text line (its bar): the heading of a skeleton card is the first of these.
  final bool text;
  const _Item(this.sortRect, this.tie, this.drafts, {this.text = false});
}

/// One skeletonized unit: its visible bounds (what "kept" is decided on) and
/// its shapes, in paint order.
class _Unit {
  final Rect bounds;
  final List<_Draft> drafts;
  final Set<String> words;

  /// The Surface / Section / control element the unit is; null for a loose paragraph.
  final Element? component;

  /// The paragraph of a loose unit.
  final RenderParagraph? paragraph;
  final RenderBox? visual;
  final Rect? fullBounds;

  Rect? get inkBounds {
    Rect? ink;
    for (final draft in drafts) {
      if (draft.kind != SkeletonKind.bar && draft.kind != SkeletonKind.heading && draft.kind != SkeletonKind.block) continue;
      ink = ink?.expandToInclude(draft.rect) ?? draft.rect;
    }
    return ink;
  }

  const _Unit(this.bounds, this.drafts, [this.words = const {}, this.component, this.paragraph, this.visual, this.fullBounds]);
}

/// How far an erase reaches past its text line, so glyph overhang (descenders,
/// italics) does not survive it.
const _kEraseGrow = 1.0;

/// True for a widget that paints something no text line describes (a chart, a
/// ring, an image). The single definition: the plan covers these with `block`s
/// and the guide view keeps its tap pill off the ones that stay legible.
bool paintsVisual(Widget w, RenderObject ro) =>
    (w is CustomPaint && (w.painter != null || w.foregroundPainter != null)) || ro is RenderImage;

/// The theme at [e], read without registering a dependency (tree inspection must
/// not rebuild the inspected elements, which may themselves be inherited).
ThemeData _themeAt(Element e) => (e.widget is Theme ? e.widget as Theme :
    e.findAncestorWidgetOfExactType<Theme>())?.data ?? ThemeData.fallback();

/// The scaffold colour a component dims toward.
Color scaffoldOf(Element e) => _themeAt(e).scaffoldBackgroundColor;

/// The palette of the theme at [e] (no dependency registered).
P paletteOf(Element e) => P(_themeAt(e).brightness == Brightness.dark);

/// Everything that turns laid-out elements into [_Unit]s, in the coordinates of
/// [rootBox]. One planner serves the whole page (the overlay's plan, in page
/// coordinates) and one component (what a Surface paints for itself, in its own).
class _Planner {
  final RenderBox rootBox;
  final Color scaffold;
  final List<Rect> legible;

  /// Skeleton cards keep their first text line, dimmed (r2 item F).
  final bool heading;
  _Planner(this.rootBox, this.scaffold, this.legible, {required this.heading});

  Color get _veil => scaffold.withValues(alpha: kDimOpacity);

  Rect visibleOf(RenderBox box, [Rect? local]) =>
      rectInRoot(box, rootBox, local).intersect(visibleBoundsInRoot(box, rootBox));

  /// One bar (and its erase when the text sits on the scaffold) per line.
  List<_Item> linesOf(RenderParagraph paragraph, {required bool onCard}) {
    final length = paragraph.text.toPlainText().length;
    if (length == 0) return const [];
    final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length));
    // One rect per LINE: boxes of mixed runs (bold, other sizes) share a line
    // when they overlap vertically by more than half of the shorter one.
    final lines = <Rect>[];
    for (final b in boxes) {
      // Not clipped to the paragraph: a glyph box can be taller than its line
      // (F.t2 draws 30 px in a 28 px line) and the bar must cover all of it.
      final r = Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
      if (r.isEmpty) continue;
      final at = lines.indexWhere((line) {
        final overlap = math.min(line.bottom, r.bottom) - math.max(line.top, r.top);
        return overlap > .5 * math.min(line.height, r.height);
      });
      if (at < 0) {
        lines.add(r);
      } else {
        lines[at] = lines[at].expandToInclude(r);
      }
    }
    final visible = visibleBoundsInRoot(paragraph, rootBox);
    final items = <_Item>[];
    for (final local in lines) {
      final line = rectInRoot(paragraph, rootBox, local);
      final bar = line.intersect(visible);
      if (bar.isEmpty) continue;
      final drafts = <_Draft>[];
      if (!onCard) {
        // Scaffold text: erase first (see SkeletonKind.erase). The grown rect
        // is dropped back to the bar when it would touch a legible rect.
        final grown = line.inflate(_kEraseGrow).intersect(visible);
        drafts.add(_Draft(
          SkeletonKind.erase,
          legible.any((k) => k.overlaps(grown)) ? bar : grown,
          scaffold,
        ));
      }
      drafts.add(_Draft(SkeletonKind.bar, bar));
      items.add(_Item(bar, 1, drafts, text: true));
    }
    return items;
  }

  /// [items] sorted into plan order, the first text line turned into the dimmed
  /// heading when there are two or more text lines and headings are on.
  List<_Draft> orderedDrafts(List<_Item> items, [List<_Draft> leading = const []]) {
    items.sort((a, b) {
      final byTop = a.sortRect.top.compareTo(b.sortRect.top);
      if (byTop != 0) return byTop;
      final byLeft = a.sortRect.left.compareTo(b.sortRect.left);
      return byLeft != 0 ? byLeft : a.tie.compareTo(b.tie);
    });
    final firstText = items.indexWhere((i) => i.text);
    final headed = heading && firstText >= 0 && items.where((i) => i.text).length >= 2 ? firstText : -1;
    return [
      ...leading,
      for (var i = 0; i < items.length; i++)
        if (i == headed) _Draft(SkeletonKind.heading, items[i].sortRect, _veil) else ...items[i].drafts,
    ];
  }

  /// The unit a Surface / Section / control opens: its nested surfaces, then its
  /// lines and visuals.
  _Unit? cardUnit(Element card) {
    final box = laidOutBox(card);
    if (box == null) return null;
    final bounds = visibleOf(box);
    if (bounds.isEmpty) return null;
    final surfaces = <_Draft>[];
    final items = <_Item>[];
    final words = <String>{};

    void inner(Element e, bool onCard) {
      final w = e.widget;
      // Icons are not planned, except where headings are on (the dim look): there an
      // icon is a line like any other, the heading when it comes first, a bar after.
      if ((w is Icon || w is ImageIcon) && !heading) return;
      final label = w is Pressable ? w.semanticLabel : w is Semantics ? w.properties.label : null;
      if (label != null) words.addAll(contentWords(label));
      var here = onCard;
      if (w is Surface) {
        final surfaceBox = laidOutBox(e);
        if (surfaceBox != null) {
          final rect = visibleOf(surfaceBox);
          if (!rect.isEmpty) surfaces.add(_Draft(SkeletonKind.surface, rect, w.color ?? P(_themeAt(e).brightness == Brightness.dark).card));
        }
        here = true;
      }
      final ro = e is RenderObjectElement ? e.renderObject : null;
      if (ro is RenderParagraph && ro.hasSize) {
        words.addAll(contentWords(ro.text.toPlainText()));
        items.addAll(linesOf(ro, onCard: here));
      } else if (ro is RenderBox && ro.hasSize && paintsVisual(w, ro)) {
        final rect = visibleOf(ro);
        if (!rect.isEmpty) items.add(_Item(rect, 0, [_Draft(SkeletonKind.block, rect)]));
      }
      e.debugVisitOnstageChildren((c) => inner(c, here));
    }

    inner(card, false);
    final drafts = orderedDrafts(items, surfaces);
    return drafts.isEmpty ? null : _Unit(bounds, drafts, words, card, null, null, rectInRoot(box, rootBox));
  }

  /// A loose paragraph as a unit (the dim look boxes the whole paragraph).
  _Unit? looseUnit(RenderParagraph ro, {required bool dimLook}) {
    final items = linesOf(ro, onCard: false);
    if (items.isEmpty) return null;
    return _Unit(
      dimLook ? visibleOf(ro) : items.map((i) => i.sortRect).reduce((a, b) => a.expandToInclude(b)),
      orderedDrafts(items),
      contentWords(ro.text.toPlainText()),
      null,
      ro,
    );
  }
}

/// One unit of a [SkeletonPlan] as the components need it: which component (or
/// loose paragraph) it is and how it is drawn.
class PlannedUnit {
  /// The Surface / Section / control element; null for a loose paragraph.
  final Element? component;

  /// The loose paragraph; null for a component.
  final RenderParagraph? paragraph;

  /// True: placeholders (heading dimmed, body bars). False: one whole-box dim.
  final bool skeleton;

  /// A loose chart/image, whose live box supplies its input geometry.
  final RenderBox? visual;

  /// The unit's [SkeletonShape.section].
  final int section;
  const PlannedUnit({this.component, this.paragraph, this.visual, required this.skeleton, required this.section});
}

/// What [planSkeleton] decided: the shapes (the plan as rectangles) and the same
/// decisions per component, for the components that paint themselves.
class SkeletonPlan {
  final List<SkeletonShape> shapes;

  /// One per skeletonized or dimmed unit; kept units are absent.
  final List<PlannedUnit> units;

  /// Every Surface / Section / control element the plan has seen (kept, nested or
  /// planned): a component that is NOT in here was built after the plan.
  final Set<Element> seen;

  /// Every loose paragraph the plan has seen, kept or not.
  final Set<RenderParagraph> seenLoose;
  const SkeletonPlan(this.shapes, this.units, this.seen, this.seenLoose);
}

/// PURE over an already laid-out subtree. Output order: unit by unit,
/// top-to-bottom; inside a unit, containers before what they contain (an erase
/// before its bar), then by (top, left). Shapes are in the root's local space,
/// after applying every ancestor clip (viewports, ClipRect, the root bounds)
/// and transform between the root and the shape's render object; a shape whose
/// clipped rect is empty is dropped.
///
/// A unit is kept (no shapes) when its visible bounds overlap any [keep] or
/// [chrome] rect: the section holding a target stays whole; a target outside
/// every card keeps only its own paragraph.
///
/// ↳ CLAIM(kept-untouched): no returned shape overlaps a [keep]/[chrome] rect
/// [skeleton_plan_test 'what stays legible'].
List<SkeletonShape> skeletonPlan(
  Element root, {
  required List<Rect> keep,
  List<Rect> chrome = const [],
  DimPolicy? dim,
}) => planSkeleton(root, keep: keep, chrome: chrome, dim: dim).shapes;

/// [skeletonPlan] and, for the same units, which component each one is.
SkeletonPlan planSkeleton(
  Element root, {
  required List<Rect> keep,
  List<Rect> chrome = const [],
  DimPolicy? dim,
}) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const SkeletonPlan([], [], {}, {});
  final legible = [...keep, ...chrome];
  final scaffold = scaffoldOf(root);
  final planner = _Planner(rootBox, scaffold, legible, heading: dim != null);
  final seen = <Element>{};
  final seenLoose = <RenderParagraph>{};

  /// Marks [e] and every component below it as seen.
  void see(Element e) {
    seen.add(e);
    for (final c in onstageElements(e)) {
      final w = c.widget;
      if (w is Surface || w is Section || w is Pressable) seen.add(c);
    }
  }

  final units = <_Unit>[];
  void find(Element e) {
    final w = e.widget;
    // The dim look treats the OUTERMOST control as one component too (its whole
    // box, padding and background included), not just the text inside it.
    if (w is Surface || w is Section || (dim != null && isGuideControl(w) && laidOutBox(e) != null)) {
      see(e);
      final unit = planner.cardUnit(e);
      if (unit != null) units.add(unit);
      return; // everything inside belongs to this unit
    }
    // A loose icon is its own unit in the dim look (dimmed whole); not otherwise.
    if ((w is Icon || w is ImageIcon) && dim == null) return;
    final ro = e is RenderObjectElement ? e.renderObject : null;
    if (ro is RenderParagraph && ro.hasSize) {
      seenLoose.add(ro);
      final unit = planner.looseUnit(ro, dimLook: dim != null);
      if (unit != null) units.add(unit);
    } else if (ro is RenderBox && ro.hasSize && paintsVisual(w, ro)) {
      final rect = planner.visibleOf(ro);
      if (!rect.isEmpty) units.add(_Unit(rect, [_Draft(SkeletonKind.block, rect)], const {}, null, null, ro));
    }
    e.debugVisitOnstageChildren(find);
  }

  find(root);

  final skeletonized = [
    for (final u in units)
      if (!legible.any((k) => k.overlaps(u.bounds))) u,
  ]..sort((a, b) {
      final byTop = a.bounds.top.compareTo(b.bounds.top);
      return byTop != 0 ? byTop : a.bounds.left.compareTo(b.bounds.left);
    });
  final shapes = <SkeletonShape>[];
  final planned = <PlannedUnit>[];
  final veil = scaffold.withValues(alpha: kDimOpacity);
  for (var i = 0; i < skeletonized.length; i++) {
    final u = skeletonized[i];
    final skeleton = dim == null || dim.lookalike(u.fullBounds ?? u.bounds, u.words, inkBounds: u.inkBounds);
    if (skeleton) {
      for (final d in u.drafts) {
        shapes.add(SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: i));
      }
    } else {
      shapes.add(SkeletonShape(kind: SkeletonKind.dim, rect: u.bounds, color: veil, section: i));
    }
    if (u.component != null || u.paragraph != null || u.visual != null) {
      planned.add(PlannedUnit(component: u.component, paragraph: u.paragraph, visual: u.visual, skeleton: skeleton, section: i));
    }
  }
  return SkeletonPlan(shapes, planned, seen, seenLoose);
}

/// What one component paints over itself when its look is skeleton: its shapes in
/// ITS OWN coordinates (origin = the component's top-left), with the heading
/// dimmed. Empty when it has nothing to show.
List<SkeletonShape> skeletonOfComponent(Element component, RenderBox box) {
  final planner = _Planner(box, scaffoldOf(component), const [], heading: true);
  final unit = planner.cardUnit(component);
  if (unit == null) return const [];
  return [for (final d in unit.drafts) SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: 0)];
}

/// What a loose paragraph paints over itself when its look is skeleton, in the
/// PARAGRAPH's own coordinates.
List<SkeletonShape> skeletonOfParagraph(RenderParagraph paragraph, Color scaffold) {
  final unit = _Planner(paragraph, scaffold, const [], heading: true).looseUnit(paragraph, dimLook: true);
  if (unit == null) return const [];
  return [for (final d in unit.drafts) SkeletonShape(kind: d.kind, rect: d.rect, color: d.color, section: 0)];
}

/// Paints [shapes] with [palette]: the single painter of placeholders, shared by
/// the review overlay ([Skeletonize]) and the components that paint themselves.
/// A heading is the REAL text: the surface fills leave a hole at its line and a
/// veil dims it.
void paintSkeletonShapes(Canvas canvas, Iterable<SkeletonShape> shapes, P palette) {
  final holes = [for (final s in shapes) if (s.kind == SkeletonKind.heading) s.rect];
  for (final s in shapes) {
    switch (s.kind) {
      case SkeletonKind.surface:
        if (holes.isEmpty) {
          canvas.drawRRect(R.rLg.toRRect(s.rect), Paint()..color = s.color!);
        } else {
          canvas.save();
          for (final h in holes) { canvas.clipRect(h, clipOp: ClipOp.difference); }
          canvas.drawRRect(R.rLg.toRRect(s.rect), Paint()..color = s.color!);
          canvas.restore();
        }
      case SkeletonKind.erase:
        canvas.drawRect(s.rect, Paint()..color = s.color!);
      case SkeletonKind.bar:
        // The shape is the whole line box; the drawn bar is a slimmer pill
        // centred in it, as in the mock-up.
        final h = math.min(s.rect.height, math.max(8.0, s.rect.height * .55));
        final pill = Rect.fromCenter(center: s.rect.center, width: s.rect.width, height: h);
        canvas.drawRRect(RRect.fromRectAndRadius(pill, Radius.circular(h / 2)), Paint()..color = palette.line);
      case SkeletonKind.block:
        canvas.drawRRect(R.rMd.toRRect(s.rect), Paint()..color = palette.line);
      case SkeletonKind.dim:
      case SkeletonKind.heading:
        canvas.drawRect(s.rect, Paint()..color = s.color!);
    }
  }
}

/// The shapes `progress` (0..1, clamped) reveals: WHOLE units only,
/// `floor(progress * unitCount)` of them, from the top.
List<SkeletonShape> revealedShapes(List<SkeletonShape> plan, double progress) {
  if (plan.isEmpty) return plan;
  final units = plan.last.section + 1; // contiguous 0..N-1, ascending
  final shown = (progress.clamp(0.0, 1.0) * units).floor();
  if (shown >= units) return plan;
  return [for (final s in plan) if (s.section < shown) s];
}

/// A rounded placeholder line. Reusable for loading states. No animation.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) => _Placeholder(
        width: width,
        height: height,
        radius: BorderRadius.circular(height / 2),
      );
}

/// A rounded placeholder block (chart / image). No animation.
class SkeletonBlock extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBlock({super.key, this.width, required this.height});

  @override
  Widget build(BuildContext context) => _Placeholder(width: width, height: height, radius: R.rMd);
}

class _Placeholder extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius radius;
  const _Placeholder({required this.width, required this.height, required this.radius});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(decoration: BoxDecoration(color: P.of(context).line, borderRadius: radius)),
      );
}

/// Resolver for the regions that must stay legible and interactive. Rects in
/// the root element's local space. An interface, not a function type, so the
/// heavy-calc guard (test/guards) can resolve the call.
abstract interface class SkeletonChrome {
  List<Rect> of(Element root);
}

/// [defaultSkeletonChrome] as a [SkeletonChrome].
class DefaultSkeletonChrome implements SkeletonChrome {
  const DefaultSkeletonChrome();

  @override
  List<Rect> of(Element root) => defaultSkeletonChrome(root);
}

/// The default: finds `ScreenTitle` and `NavBar` by widget type, and AppShell's
/// private tab bar by its runtime type (app_shell.dart:215), without editing
/// app_shell.dart. The tab bar's name is a string match on purpose: the class
/// is private, and the test 'finds AppShell's tab bar by type' fails if it is
/// ever renamed.
List<Rect> defaultSkeletonChrome(Element root) {
  final rootBox = laidOutBox(root);
  if (rootBox == null) return const [];
  final out = <Rect>[];
  void find(Element e) {
    final w = e.widget;
    if (w is ScreenTitle || w is NavBar || w.runtimeType.toString() == '_TabBar') {
      final box = laidOutBox(e);
      if (box != null) out.add(rectInRoot(box, rootBox));
      return;
    }
    e.debugVisitOnstageChildren(find);
  }

  find(root);
  return out;
}

/// What a screen reader gets for something that stays readable while the rest
/// of the screen is excluded: its words, whether it is a button, and what a
/// double-tap does.
class _SemanticProxy {
  final Rect rect;
  final String label;
  final bool button;
  final VoidCallback? onTap;
  const _SemanticProxy(this.rect, this.label, this.button, this.onTap);

  @override
  bool operator ==(Object other) =>
      other is _SemanticProxy &&
      other.rect == rect &&
      other.label == label &&
      other.button == button &&
      other.onTap == onTap;

  @override
  int get hashCode => Object.hash(rect, label, button, onTap);
}

/// Wraps [child]; after every layout it re-resolves [keep] / [alsoKeep] against
/// the LIVE tree and recomputes the plan; paints [revealedShapes]. Revealed
/// units absorb pointer events and are excluded from semantics; kept targets
/// and chrome stay tappable and keep their semantics.
///
/// A [keep] target that does not resolve (absent / ambiguous / not built)
/// yields an EMPTY plan - never cover a screen whose target cannot be found -
/// and the reason is in [SkeletonizeState.resolutions]. An unresolved
/// [alsoKeep] target is skipped.
///
/// SEMANTICS. Flutter cannot exclude individual descendants of a foreign
/// subtree from the semantics tree, so while any unit is painted over, the
/// whole child is excluded and every label OUTSIDE the covered units is
/// re-published by a transparent proxy at its rect (Text, Semantics labels and
/// Pressables, with their tap handler). Known limit for phase 4: a proxy does
/// not carry scroll actions.
///
/// WHEN THE PLAN RUNS. In this overlay's `paint` (so the painted shapes always
/// match the frame), and again at the end of every frame that happens
/// afterwards, to catch changes that repaint only below an inner repaint
/// boundary (a scroll is caught immediately through its notifications).
class Skeletonize extends StatefulWidget {
  final Widget child;

  /// The targets the guide points at.
  final List<GuideTarget> keep;

  /// Extra units to leave readable (e.g. "Your zones" in step 3).
  final List<GuideTarget> alsoKeep;
  final SkeletonChrome chrome;
  final double progress;

  const Skeletonize({
    super.key,
    required this.child,
    required this.keep,
    this.alsoKeep = const [],
    this.chrome = const DefaultSkeletonChrome(),
    this.progress = 1,
  });

  @override
  State<Skeletonize> createState() => SkeletonizeState();
}

class SkeletonizeState extends State<Skeletonize> {
  final _layerKey = GlobalKey();
  _RenderSkeleton? _render;

  List<SkeletonShape> _shapes = const [];
  List<TargetResolution> _resolutions = const [];

  /// keep + alsoKeep + chrome, root space: hit-testing never absorbs here.
  List<Rect> _legible = const [];

  /// Bounds of each painted unit, root space: what pointer events are absorbed in.
  List<Rect> _absorbing = const [];
  List<_SemanticProxy> _proxies = const [];

  /// What the last build used, to know when semantics must rebuild.
  List<_SemanticProxy> _builtProxies = const [];
  bool _builtExcluding = false;
  bool _watching = false;
  bool _semanticsStale = false;

  P _palette = const P(false);

  /// The full plan as of the last layout (valid after the first frame).
  List<SkeletonShape> get shapes => _shapes;

  /// The subset actually painted at the current `progress`.
  List<SkeletonShape> get paintedShapes => revealedShapes(_shapes, widget.progress);

  /// One resolution per [Skeletonize.keep] target, same order, as of the last
  /// layout.
  List<TargetResolution> get resolutions => _resolutions;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(Skeletonize oldWidget) {
    super.didUpdateWidget(oldWidget);
    _render?.markNeedsPaint();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _render?.markNeedsPaint();
  }

  /// Re-plan at the end of every frame that happens while mounted. It never
  /// asks for a frame itself: a changed plan marks the overlay dirty, which does.
  void _watch() {
    if (_watching) return;
    _watching = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _watching = false;
      if (!mounted) return;
      if (_replan()) _render?.markNeedsPaint();
      if (_semanticsStale) {
        _semanticsStale = false;
        setState(() {});
      }
      _watch();
    });
  }

  /// Recomputes everything from the live tree. True when the plan or the
  /// legible/absorbing rects changed (so a repaint is needed).
  bool _replan() {
    final layer = _layerKey.currentContext;
    if (layer is! Element) return false;
    final l = AppLocalizations.of(layer) ?? lookupAppLocalizations(const Locale('en'));

    final resolutions = [for (final t in widget.keep) t.resolve(layer, l)];
    final keepRects = <Rect>[];
    var unresolved = false;
    for (final r in resolutions) {
      switch (r) {
        case TargetFound(:final rect):
          keepRects.add(rect);
        case TargetNotBuilt() || TargetAbsent() || TargetAmbiguous():
          unresolved = true;
      }
    }
    for (final t in widget.alsoKeep) {
      if (t.resolve(layer, l) case TargetFound(:final rect)) keepRects.add(rect);
    }
    final chrome = widget.chrome.of(layer);
    final shapes = unresolved ? const <SkeletonShape>[] : skeletonPlan(layer, keep: keepRects, chrome: chrome);

    final painted = revealedShapes(shapes, widget.progress);
    final bounds = <int, Rect>{};
    for (final s in painted) {
      bounds[s.section] = bounds[s.section]?.expandToInclude(s.rect) ?? s.rect;
    }
    final absorbing = bounds.values.toList();
    final proxies = painted.isEmpty ? const <_SemanticProxy>[] : _collectProxies(layer, absorbing);

    final changed = !_samePlan(shapes, _shapes) || !_sameRects(absorbing, _absorbing);
    _resolutions = resolutions;
    _shapes = shapes;
    _legible = [...keepRects, ...chrome];
    _absorbing = absorbing;
    _proxies = proxies;
    if (!_sameProxies(proxies, _builtProxies) || painted.isNotEmpty != _builtExcluding) {
      _semanticsStale = true;
      _watch();
    }
    return changed;
  }

  static bool _samePlan(List<SkeletonShape> a, List<SkeletonShape> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].kind != b[i].kind ||
          a[i].rect != b[i].rect ||
          a[i].color != b[i].color ||
          a[i].section != b[i].section) {
        return false;
      }
    }
    return true;
  }

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameProxies(List<_SemanticProxy> a, List<_SemanticProxy> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Every label outside the covered units, as proxies (see the class doc).
  List<_SemanticProxy> _collectProxies(Element layer, List<Rect> covered) {
    final rootBox = laidOutBox(layer);
    if (rootBox == null) return const [];
    final out = <_SemanticProxy>[];

    String textBelow(Element e) {
      final parts = <String>[];
      for (final c in onstageElements(e)) {
        final w = c.widget;
        if (w is Text) {
          final t = (w.data ?? w.textSpan?.toPlainText() ?? '').trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
      return parts.join(', ');
    }

    void take(Element e, String label, bool button, VoidCallback? onTap) {
      final box = laidOutBox(e);
      if (box == null || label.isEmpty) return;
      final rect = rectInRoot(box, rootBox).intersect(visibleBoundsInRoot(box, rootBox));
      if (rect.isEmpty || covered.any((c) => c.contains(rect.center))) return;
      out.add(_SemanticProxy(rect, label, button, onTap));
    }

    void walk(Element e) {
      final w = e.widget;
      if (w is Icon || w is ImageIcon) return;
      if (w is Pressable && (w.semanticLabel != null || w.onTap != null)) {
        take(e, w.semanticLabel ?? textBelow(e), w.onTap != null, w.onTap);
        return;
      }
      if (w is Semantics && (w.properties.label?.isNotEmpty ?? false)) {
        take(e, w.properties.label!, w.properties.button ?? false, w.properties.onTap);
        return;
      }
      if (w is Text) {
        take(e, (w.data ?? w.textSpan?.toPlainText() ?? '').trim(), false, null);
        return;
      }
      e.debugVisitOnstageChildren(walk);
    }

    layer.debugVisitOnstageChildren(walk);
    return out;
  }

  bool _absorbs(Offset position) =>
      _absorbing.any((r) => r.contains(position)) && !_legible.any((r) => r.contains(position));

  @override
  Widget build(BuildContext context) {
    _palette = P.of(context);
    _builtProxies = _proxies;
    _builtExcluding = paintedShapes.isNotEmpty;
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        ExcludeSemantics(
          excluding: _builtExcluding,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _render?.markNeedsPaint();
              return false;
            },
            child: _SkeletonLayer(key: _layerKey, skeleton: this, child: widget.child),
          ),
        ),
        for (final p in _proxies)
          Positioned.fromRect(
            rect: p.rect,
            child: IgnorePointer(
              child: Semantics(
                container: true,
                label: p.label,
                button: p.button,
                onTap: p.onTap,
                child: const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}

class _SkeletonLayer extends SingleChildRenderObjectWidget {
  final SkeletonizeState skeleton;
  const _SkeletonLayer({super.key, required this.skeleton, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSkeleton(skeleton);

  @override
  void updateRenderObject(BuildContext context, _RenderSkeleton renderObject) {
    renderObject.skeleton = skeleton;
  }
}

/// Paints the child, then the plan over it; absorbs pointer events on painted
/// units.
class _RenderSkeleton extends RenderProxyBox {
  SkeletonizeState skeleton;

  _RenderSkeleton(this.skeleton) {
    skeleton._render = this;
  }

  @override
  void detach() {
    if (identical(skeleton._render, this)) skeleton._render = null;
    super.detach();
  }

  @override
  void attach(PipelineOwner pipelineOwner) {
    super.attach(pipelineOwner);
    skeleton._render = this;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    skeleton._replan();
    final shapes = skeleton.paintedShapes;
    if (shapes.isEmpty) return;
    final p = skeleton._palette;
    final canvas = context.canvas;
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    paintSkeletonShapes(canvas, shapes, p);
    canvas.restore();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position) && skeleton._absorbs(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }
}
