// LIVE GUIDE OVERLAY (live mode): draws a [GuideRun] over the user's own
// screens. It is one entry in the app's ROOT Overlay, above every route.
//
// After frames that change the page, layout, scroll or content it
//   1. finds the top PAGE route's subtree (null while a dialog,
//      sheet or picker is on top),
//   2. lets the run match a step by anchor ([GuideRun.observe]),
//   3. plans the skeleton over that subtree (the same [skeletonPlan] as
//      PR 1: keep = the step's target + alsoKeep + chrome) and paints it in the
//      overlay's own coordinates, progressively: whole sections fade to
//      skeleton from the top over [kGuideRevealDuration], then the outline and
//      the pill appear,
//   4. scrolls a lazy target into view ([revealTarget]) and shows the scroll
//      marker on `scrollThenTap` steps.
//
// Input: a tap on the target goes THROUGH to the real control (it does exactly
// what it always does, confirmation dialogs included); every other tap on the
// page is absorbed; the card's buttons work; Android system Back and the
// NavBar arrow work. Accepted limitation (S6): on step pages the shield absorbs
// the iOS edge-swipe Back gesture. Use the NavBar arrow to leave those pages.
// While a dialog / sheet / picker is on top the overlay is inert and draws nothing, so
// the app's own dialog is fully usable.
//
// Semantics: the step card's caption is a live region; the target gets a proxy
// node "Guide target: <caption>" that performs the tap; covered content stays
// in the semantics tree (foreign semantics cannot be excluded).
//
// CLAIM(overlay-pass-through): the target's tap reaches the real control; other
// taps on the page do not [live_guide_overlay_test 'pointer rules'].
// CLAIM(overlay-yields-to-dialogs): with a dialog on top the overlay neither
// absorbs taps nor changes the run's state
// [live_guide_overlay_test 'a dialog on top is not leaving the path'].
// CLAIM(overlay-reveal): progress goes 0 -> 1 over [kGuideRevealDuration] per
// step; the outline and pill show only at 1
// [live_guide_overlay_test 'the reveal is progressive'].
//
// Mating parts: [GuideRunner] inserts/removes it; [GuideStepCard] is its card;
// guide_markers.dart holds the pill/outline rules shared with the review views.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/app_localizations.dart';
import '../grammar.dart' show NavBar, Pressable;
import '../theme.dart';
import 'guide.dart';
import 'guide_markers.dart';
import 'guide_step_card.dart';
import 'guide_target.dart';
import 'tree_geometry.dart';

import '../skeleton/skeleton.dart';
import 'guide_run.dart';
import 'guide_routes.dart';

/// How long one step's skeleton takes to fade in, top to bottom.
const kGuideRevealDuration = Motion.reveal;

class LiveGuideOverlay extends StatefulWidget {
  final GuideRun run;

  /// The app's root Navigator: where the top page is looked for.
  final GlobalKey<NavigatorState> navigatorKey;
  final GuideRouteObserver routes;

  /// "Exit" on the card.
  final VoidCallback onExit;

  /// "Back to the guide" on the off-path card.
  final VoidCallback onBackToGuide;

  const LiveGuideOverlay({
    super.key,
    required this.run,
    required this.navigatorKey,
    required this.routes,
    required this.onExit,
    required this.onBackToGuide,
  });

  static const skeletonKey = ValueKey('guide-live-skeleton');
  static const outlineKey = ValueKey('guide-live-outline');
  static const tapPillKey = ValueKey('guide-live-tap-pill');
  static const scrollMarkerKey = ValueKey('guide-live-scroll-marker');
  static const targetProxyKey = ValueKey('guide-live-target-proxy');

  @override
  State<LiveGuideOverlay> createState() => LiveGuideOverlayState();
}

class LiveGuideOverlayState extends State<LiveGuideOverlay> with SingleTickerProviderStateMixin {
  final _layerKey = GlobalKey();
  late final AnimationController _reveal;
  List<SkeletonShape> _shapes = const [];
  Rect? _target;
  RenderBox? _targetObject;
  List<Rect> _chrome = const [], _legible = const [];
  /// The control that leads back to the guide (off path) or to the step's tab: focused like a target.
  Rect? _route;
  bool _yielding = true;
  Element? _page;
  GuideStep? _step;
  Object? _revealedPage;
  GuideStep? _revealedStep;
  Object? _searchSignature;
  Element? _searchingPage;
  Object? _searchToken;
  Rect? _lastRevealRect;
  final Map<int, Offset> _downs = {};
  Object? _plannedSignature;
  Duration? _lastPlanTime;
  int _planningCount = 0;

  @visibleForTesting
  int get planningCount => _planningCount;

  @visibleForTesting
  List<SkeletonShape> get paintedShapes => _yielding ? const [] : _collapsed ? _shapes : revealedShapes(_shapes, revealProgress);

  /// P6 (dim look): the target is off screen or not built, so the way to it
  /// shows at once (no progressive reveal) with the scroll marker.
  bool get _collapsed {
    final t = _target;
    return widget.run.guide.look == GuideLook.dim && _step != null &&
      (t == null || !(Offset.zero & _viewport).contains(t.topLeft) || !(Offset.zero & _viewport).contains(t.bottomRight));
  }
  Size _viewport = Size.zero;
  @visibleForTesting
  Rect? get targetRect => _target;
  @visibleForTesting
  double get revealProgress => _reveal.value;
  @visibleForTesting
  bool get isYielding => _yielding;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: kGuideRevealDuration)..addListener(_changed);
    widget.run.addListener(_changed);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    _watch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reveal.duration = motion(context, kGuideRevealDuration);
  }

  @override
  void didUpdateWidget(LiveGuideOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.run != widget.run) {
      oldWidget.run.removeListener(_changed);
      widget.run.addListener(_changed);
      _revealedPage = null;
      _revealedStep = null;
      _cardFraction = null;
    }
  }

  void _changed() { if (mounted) setState(() {}); }

  // CLAIM(overlay-hit-target): geometry alone cannot prove a tap reaches a
  // control hidden under chrome [occluded target regressions in overlay tests].
  bool _hitsTarget(Offset position) {
    final target = _targetObject;
    if (target == null || !target.attached) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
    return result.path.any((entry) => identical(entry.target, target));
  }

  void _pointer(PointerEvent event) {
    final layer = _layerKey.currentContext?.findRenderObject();
    if (layer is! RenderBox || !layer.hasSize || !layer.attached || _yielding) return;
    final point = layer.globalToLocal(event.position);
    if (event is PointerDownEvent && (_target?.contains(point) ?? false) && _hitsTarget(event.position)) _downs[event.pointer] = point;
    if (event is PointerCancelEvent) _downs.remove(event.pointer);
    if (event is PointerMoveEvent) {
      final down = _downs[event.pointer];
      if (down != null && (point - down).distance > kTouchSlop) _downs.remove(event.pointer);
    }
    if (event is PointerUpEvent) {
      final down = _downs.remove(event.pointer);
      if (down != null && (point - down).distance <= kTouchSlop && (_target?.contains(point) ?? false) && _hitsTarget(event.position)) {
        // Let the real gesture recognizer handle the tap before completing the run.
        scheduleMicrotask(() { if (mounted) widget.run.targetTapped(); });
      }
    }
  }

  Drag? _pageDrag;

  /// Dim plan for an off-path page, in the page's coordinates: whole components
  /// (tabs included) except the route-back control, which stays full colour.
  /// [tabOnly]: the route is the guide's start tab (never the NavBar back arrow); used
  /// when the step's target is on a tab the user is not on. Returns the plan and the
  /// route control's rect (page coordinates), which gets the target's outline and pill.
  (List<SkeletonShape>, Rect?) _offPathPlan(Element page, {bool tabOnly = false}) {
    final root = laidOutBox(page);
    if (root == null) return (const [], null);
    Rect rectOf(Element e) { final b = laidOutBox(e)!; return rectInRoot(b, root); }
    final tabs = <Rect>[];
    Rect? tabBar, back;
    Element? navBar;
    for (final e in onstageElements(page)) {
      if (laidOutBox(e) == null) continue;
      if (e.widget.runtimeType.toString() == '_TabBar') {
        tabBar = rectOf(e);
        for (final c in onstageElements(e)) {
          if (c.widget is Pressable && laidOutBox(c) != null) tabs.add(rectOf(c));
        }
      } else if (e.widget is NavBar && navBar == null) {
        navBar = e;
      }
    }
    if (navBar != null && !tabOnly) {
      for (final c in onstageElements(navBar)) {
        if (c.widget is Pressable && laidOutBox(c) != null) { back = rectOf(c); break; }
      }
    }
    final startTab = switch (widget.run.guide.start) {
      GuideStart.today => 0, GuideStart.sleep => 1, GuideStart.activity => 2, GuideStart.health => 3,
      GuideStart.settings => -1,
    };
    if (back == null && startTab >= 0 && startTab < tabs.length) back = tabs[startTab];
    final route = back;
    final keepers = [?back];
    final plan = skeletonPlan(page, keep: keepers, chrome: [?tabBar], dim: const DimPolicy());
    final scaffold = (page.findAncestorWidgetOfExactType<Theme>()?.data ?? ThemeData.fallback()).scaffoldBackgroundColor;
    final veil = scaffold.withValues(alpha: kDimOpacity);
    final out = <SkeletonShape>[...plan];
    var section = plan.isEmpty ? 0 : plan.last.section + 1;
    for (final tab in tabs) {
      if (back != null && tab.overlaps(back)) continue;
      out.add(SkeletonShape(kind: SkeletonKind.dim, rect: tab, color: veil, section: section++));
    }
    return (out, route);
  }

  // The user's card height for THIS run, as a fraction of the travel available
  // between the bounds' edges (survives rotation and keyboard). The overlay is
  // created per run, so a new run starts without one. null = automatic.
  double? _cardFraction;
  final _cardGeometry = _CardGeometry();

  void _moveCard(double dy) {
    final g = _cardGeometry;
    if (g.upper <= g.lower) return;
    setState(() => _cardFraction = ((g.top + dy - g.lower) / (g.upper - g.lower)).clamp(0.0, 1.0));
  }

  // The card follows the finger exactly. A gesture recognizer would eat the touch
  // slop (and apply only the last update per frame), so the drag reads raw pointer
  // events: once the finger has moved a slop vertically, the card sits at
  // (its top when the finger went down) + (finger travel), clamped to its bounds.
  int? _cardPointer;
  double _cardDownY = 0, _cardDownTop = 0;
  bool _cardDragging = false;

  void _cardDown(PointerDownEvent e) {
    if (_cardPointer != null) return;
    _cardPointer = e.pointer;
    _cardDownY = e.position.dy;
    _cardDownTop = _cardGeometry.top;
    _cardDragging = false;
  }

  void _cardMove(PointerMoveEvent e) {
    if (e.pointer != _cardPointer) return;
    final travel = e.position.dy - _cardDownY;
    if (!_cardDragging && travel.abs() < kTouchSlop) return;
    _cardDragging = true;
    final g = _cardGeometry;
    if (g.upper <= g.lower) return;
    final top = (_cardDownTop + travel).clamp(g.lower, g.upper);
    setState(() => _cardFraction = (top - g.lower) / (g.upper - g.lower));
  }

  void _cardEnd(PointerEvent e) {
    if (e.pointer == _cardPointer) _cardPointer = null;
  }

  /// The card, draggable by its blank space (buttons keep their taps) and a
  /// sink for every other pointer: nothing on the card reaches the page below.
  Widget _cardMover(Widget card) => Semantics(
    customSemanticsActions: {
      const CustomSemanticsAction(label: 'Move card up'): () => _moveCard(-_cardGeometry.step),
      const CustomSemanticsAction(label: 'Move card down'): () => _moveCard(_cardGeometry.step),
    },
    child: Listener(
      onPointerDown: _cardDown, onPointerMove: _cardMove,
      onPointerUp: _cardEnd, onPointerCancel: _cardEnd,
      // The card is hit-testable, so the page below is never in the hit path; the
      // no-op tap/long-press sink taps on blank card space. No double-tap: it delays buttons' taps.
      child: GestureDetector(onTap: () {}, onLongPress: () {}, child: card),
    ),
  );

  /// Starts a drag on the page's own innermost vertical scrollable under
  /// [details], so a drag that begins on skeleton ink scrolls the real page.
  void _dragStart(DragStartDetails details) {
    final page = _page;
    if (page == null) return;
    ScrollableState? hit;
    for (final e in builtElements(page)) {
      if (e is! StatefulElement) continue;
      final state = e.state;
      if (state is! ScrollableState || !state.position.hasPixels || state.position.axis != Axis.vertical) continue;
      final box = e.renderObject;
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(details.globalPosition)) hit = state;
    }
    _pageDrag = hit?.position.drag(details, () => _pageDrag = null);
  }

  void _activateTarget() {
    final target = _target;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (target == null || layer is! RenderBox || !layer.attached) return;
    final position = layer.localToGlobal(target.center);
    if (!_hitsTarget(position)) return;
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: -1, position: position));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: -1, position: position));
  }

  void _watch() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _plan();
      _watch(); // Observes frames; does not request one when geometry is unchanged.
    });
  }

  bool _sameShapes(List<SkeletonShape> a, List<SkeletonShape> b) => a.length == b.length &&
    List.generate(a.length, (i) => a[i].kind == b[i].kind && a[i].rect == b[i].rect &&
      a[i].section == b[i].section && a[i].color == b[i].color).every((same) => same);

  void _plan() {
    final nav = widget.navigatorKey.currentState;
    final layer = _layerKey.currentContext?.findRenderObject();
    if (nav == null || layer is! RenderBox || !layer.hasSize || !layer.attached) return;
    final page = widget.routes.page;
    final l = AppLocalizations.of(context)!;
    widget.run.observe(null, l); // Prune disposed pages even when the plan is cached.
    // One traversal replaces repeated anchor, target, chrome, legibility and
    // skeleton walks on idle/reveal frames. Widget identity catches replacement
    // structure (including same-text controls). Transforms catch controls moving
    // without resizing; sliver geometry and counts catch newly built lazy content.
    // See the late-content, real Sleep and History integration regressions.
    final content = <Object?>[];
    final discoveryContent = <Object?>[];
    var builtCount = 0;
    if (page != null) {
      for (final e in builtElements(page)) {
        builtCount++;
        final w = e.widget;
        content.add(e);
        content.add(w);
        final object = e is RenderObjectElement ? e.renderObject : null;
        if (object != null && object.attached) {
          content.add(object);
          if (object is RenderBox && object.hasSize) {
            content.add(object.size);
            content.add(Object.hashAll(object.getTransformTo(layer).storage));
          }
          if (object is RenderSliver && object.geometry != null) {
            content.add(object.constraints);
            content.add(object.geometry);
            content.add(Object.hashAll(object.getTransformTo(layer).storage));
          }
        }
        if (w is Text) discoveryContent.add(w.data ?? w.textSpan?.toPlainText());
        if (e is StatefulElement && e.state is ScrollableState) {
          final position = (e.state as ScrollableState).position;
          if (position.hasPixels) content.add(position.pixels);
          if (position.hasContentDimensions) {
            content.add(position.minScrollExtent);
            content.add(position.maxScrollExtent);
            content.add(position.viewportDimension);
            discoveryContent.add(position.minScrollExtent);
            discoveryContent.add(position.maxScrollExtent);
            discoveryContent.add(position.viewportDimension);
          }
        }
      }
    }
    // Discovery retries use stable text/extents: rebuilding cached list
    // children during an unsuccessful search must not restart that search.
    final signature = Object.hashAll(discoveryContent);
    final planSignature = (page, layer.size, builtCount, Object.hashAll(content), widget.run,
      widget.run.state, l, _searchingPage, _revealedPage, _revealedStep);
    if (_plannedSignature == planSignature) return;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    // Avoid full-tree planning at animation cadence. Request a trailing frame
    // so even the last throttled layout is eventually measured. New pages,
    // popups and completed animations are always reflected immediately.
    final animating = SchedulerBinding.instance.transientCallbackCount >
        (_reveal.isAnimating ? 1 : 0);
    if (page != null && identical(page, _page) && animating &&
        _lastPlanTime != null && now - _lastPlanTime! < motion(context, Motion.guidePlanInterval)) {
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    _plannedSignature = planSignature;
    _lastPlanTime = now;
    _planningCount++;
    if (page == null || !identical(page, _searchingPage)) widget.run.observe(page, l);
    final step = widget.run.currentStep;
    final newStep = _revealedPage != page || _revealedStep != step;
    if (page != null && step == null) {
      _revealedPage = null;
      _revealedStep = null;
      _reveal.stop();
    }
    final box = page == null ? null : laidOutBox(page);
    final resolution = page == null || step == null ? null : step.target.resolve(page, l);
    final targetNow = box != null && resolution is TargetFound
        ? MatrixUtils.transformRect(box.getTransformTo(layer), resolution.rect) : null;
    final viewport = Offset.zero & layer.size;
    _viewport = layer.size;
    final outside = targetNow != null &&
        !(viewport.contains(targetNow.topLeft) && viewport.contains(targetNow.bottomRight));
    // Async screen reads can move a previously revealed target out of view.
    // Retry when that geometry changes, without repeatedly probing a fixed,
    // unscrollable target. See the dynamic-layout overlay regression.
    // Use THIS layout's resolution: a late insert can unbuild a previously
    // visible target. Waiting for _target to become null would need another
    // full plan, but the next frame may reuse this plan's unchanged signature.
    // The dim look reveals once per step: after that the user scrolls (the marker
    // shows the way) and the overlay must not scroll the page back under them.
    final retry = widget.run.guide.look != GuideLook.dim && _searchingPage == null &&
        ((targetNow == null && _searchSignature != signature) ||
         (outside && _lastRevealRect != targetNow));
    if (page != null && step != null && (newStep || retry)) {
      _revealedPage = page;
      _revealedStep = step;
      _searchSignature = signature;
      _lastRevealRect = targetNow;
      // Also reveal plain-tap targets built just beyond the viewport: a target
      // must be visible before the card asks the user to press it.
      final token = Object();
      _searchToken = token;
      _searchingPage = page;
      unawaited(revealTarget(page, step.target, l, isCurrent: _StepGate(this, token, page, step)).whenComplete(() {
          if (mounted && identical(_searchToken, token)) {
            _searchingPage = null;
            _searchToken = null;
            // The search can build children or move the target after this
            // frame's snapshot. Always measure its settled result once.
            _plannedSignature = null;
            if (!identical(widget.routes.page, page)) _revealedPage = null;
            setState(() {});
          }
        }));
      if (newStep) _reveal.forward(from: 0);
    }
    Rect? target;
    var shapes = <SkeletonShape>[];
    var chrome = <Rect>[];
    var legible = <Rect>[];
    if (page != null && box != null && step != null) {
      final transform = box.getTransformTo(layer);
      Rect intoOverlay(Rect r) => MatrixUtils.transformRect(transform, r);
      if (resolution case TargetFound(:final rect)) {
        target = intoOverlay(rect);
        final keep = <Rect>[rect];
        for (final extra in step.alsoKeep) {
          if (extra.resolve(page, l) case TargetFound(:final rect)) keep.add(rect);
        }
        final dimLook = widget.run.guide.look == GuideLook.dim;
        // P7/P8: caption-offered controls and caption-named details stay full colour.
        if (dimLook) {
          for (final content in [...step.alsoTap, ...step.alsoRead]) {
            for (final found in content.resolve(page, l)) { keep.add(found.rect); }
          }
        }
        // Live status (title row, running timer) stays readable and clear of the card.
        final status = dimLook ? liveStatusRects(page) : const <Rect>[];
        keep.addAll(status);
        final localChrome = defaultSkeletonChrome(page);
        chrome = localChrome.map(intoOverlay).toList();
        legible = [...legibleContent(page, keep: keep), ...status].map(intoOverlay).toList();
        DimPolicy? policy;
        if (dimLook) {
          // P6: target (partly) off screen -> the content on screen collapses to skeleton.
          policy = outside ? const DimPolicy(skeletonAll: true)
              : DimPolicy.of(page, resolution);
        }
        shapes = [for (final shape in skeletonPlan(page, keep: keep, chrome: localChrome, dim: policy))
          SkeletonShape(kind: shape.kind, rect: intoOverlay(shape.rect), section: shape.section, color: shape.color)];
      }
    }
    Rect? route;
    if (page != null && box != null && step != null && resolution is! TargetFound &&
        widget.run.guide.look == GuideLook.dim) {
      final transform = box.getTransformTo(layer);
      final localChrome = defaultSkeletonChrome(page);
      chrome = [for (final r in localChrome) MatrixUtils.transformRect(transform, r)];
      final (tabPlan, tab) = resolution is TargetAbsent ? _offPathPlan(page, tabOnly: true) : (const <SkeletonShape>[], null);
      if (tab != null) {
        // The step's target is on a tab the user is not on: that tab is the route
        // (outline and pill like a target; it passes taps), the rest is dimmed.
        route = MatrixUtils.transformRect(transform, tab);
        shapes = [for (final shape in tabPlan)
          SkeletonShape(kind: shape.kind, rect: MatrixUtils.transformRect(transform, shape.rect),
            section: shape.section, color: shape.color)];
      } else {
        // P6: the target is not built yet; everything on screen is the way to it.
        shapes = [for (final shape in skeletonPlan(page, keep: const [], chrome: localChrome, dim: const DimPolicy(skeletonAll: true)))
          SkeletonShape(kind: shape.kind, rect: MatrixUtils.transformRect(transform, shape.rect),
            section: shape.section, color: shape.color)];
      }
    }
    if (page != null && box != null && step == null && widget.run.state is GuideOffPath &&
        widget.run.guide.look == GuideLook.dim) {
      // Off path (dim look): everything dims except the one control one step
      // closer to the guide (NavBar back arrow, or the start tab); it is focused
      // like a target.
      final transform = box.getTransformTo(layer);
      final (plan, back) = _offPathPlan(page);
      if (back != null) route = MatrixUtils.transformRect(transform, back);
      shapes = [for (final shape in plan)
        SkeletonShape(kind: shape.kind, rect: MatrixUtils.transformRect(transform, shape.rect),
          section: shape.section, color: shape.color)];
    }
    final changed = _page != page || _step != step || _target != target || _yielding != (page == null) ||
      !_sameShapes(_shapes, shapes) || !listEquals(_chrome, chrome) || !listEquals(_legible, legible) || _route != route;
    _page = page;
    _step = step;
    _target = target;
    _targetObject = resolution is TargetFound ? resolution.renderObject : null;
    _shapes = shapes;
    _chrome = chrome;
    _legible = legible;
    _route = route;
    _yielding = page == null;
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    widget.run.removeListener(_changed);
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final p = P.of(context);
    final run = widget.run;
    final state = run.state;
    final step = run.currentStep;
    final target = _target;
    final model = switch (state) {
      GuideAtStep(:final index) => GuideCardOnStep(number: index + 1, total: run.variant.steps.length,
        caption: run.variant.steps[index].caption.of(l), missingHelp: run.guide.missingTargetHelp),
      GuideOffPath() => const GuideCardOffPath(),
      GuideFinished() => GuideCardDone(run.guide.doneFooters),
    };
    final show = !_yielding && !run.isExited;
    // The root overlay sits above every route's Material, so text here would
    // fall back to the yellow-underlined debug style. A theme text style fixes
    // that without a Material, which would take part in hit testing.
    return DefaultTextStyle(
        style: Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
        child: SizedBox.expand(key: _layerKey, child: LayoutBuilder(builder: (context, constraints) {
      final screen = Offset.zero & constraints.biggest;
      final outline = target?.inflate(kGuideOutlineGap).intersect(screen);
      final marked = show && target != null && step != null && revealProgress == 1 &&
          outline != null && !outline.isEmpty;
      final dimLook = run.guide.look == GuideLook.dim;
      final routeOutline = target == null && show ? _route?.inflate(kGuideOutlineGap).intersect(screen) : null;
      final routeMarked = routeOutline != null && !routeOutline.isEmpty;
      // The target is hidden: scrolled off (resolved, outline empty) or, in the
      // dim look, not built yet (then the way to it lies below).
      final offscreen = show && step != null && step.action == GuideAction.scrollThenTap &&
          (target == null ? dimLook : revealProgress == 1 && (outline == null || outline.isEmpty));
      final padding = MediaQuery.paddingOf(context);
      var bounds = Rect.fromLTRB(screen.left, padding.top, screen.right,
        screen.bottom - math.max(padding.bottom, MediaQuery.viewInsetsOf(context).bottom));
      for (final r in _chrome) {
        if (r.top > screen.height / 2 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, bounds.top, bounds.right, math.min(bounds.bottom, r.top));
        if (r.top < screen.height / 4 && r.width > screen.width / 2) bounds = Rect.fromLTRB(bounds.left, math.max(bounds.top, r.bottom), bounds.right, bounds.bottom);
      }
      return Stack(children: [
        if (show && target != null && step != null && run.guide.look == GuideLook.skeleton)
          Positioned.fill(child: _GuideShield(
            holes: [target, ..._chrome],
            child: CustomPaint(key: LiveGuideOverlay.skeletonKey, painter: _GuidePainter(paintedShapes, p)),
          )),
        if (show && run.guide.look == GuideLook.dim && (target != null && step != null || state is GuideOffPath))
          Positioned.fill(child: ExcludeSemantics(child: GestureDetector(
            // Skeleton ink swallows activation (tap, long press, double tap); the
            // page itself is not in the hit path there. A vertical drag is handed
            // to the page's own scrollable so P6 scroll-through still works.
            onTap: () {}, onLongPress: () {}, onDoubleTap: () {},
            onVerticalDragStart: _dragStart, onVerticalDragUpdate: (d) => _pageDrag?.update(d),
            onVerticalDragEnd: (d) { _pageDrag?.end(d); _pageDrag = null; },
            onVerticalDragCancel: () { _pageDrag?.cancel(); _pageDrag = null; },
            child: CustomPaint(key: LiveGuideOverlay.skeletonKey,
              painter: _GuidePainter(paintedShapes, p, [?target, ?_route, ..._chrome])),
          ))),
        if (marked || routeMarked) Positioned.fromRect(rect: (marked ? outline : routeOutline)!, child: ExcludeSemantics(child: IgnorePointer(child: DecoratedBox(
          key: LiveGuideOverlay.outlineKey,
          decoration: BoxDecoration(border: Border.all(color: kGuideMarkerColor, width: 2.5), borderRadius: R.rMd),
        )))),
        if (marked) Positioned.fromRect(rect: target, child: Semantics(
          key: LiveGuideOverlay.targetProxyKey, container: true, button: true,
          label: l.guideTargetProxy(step.caption.of(l).replaceAll('**', '')), onTap: _activateTarget,
          child: const SizedBox.expand(),
        )),
        if (show) Positioned.fill(child: CustomMultiChildLayout(
          delegate: _GuideLayout(bounds, marked ? outline : routeMarked ? routeOutline : target ?? (offscreen ? Rect.fromLTWH(bounds.center.dx, bounds.bottom + 10, 1, 1) : null),
            _legible, _cardFraction, _cardGeometry, widget.run.guide.look == GuideLook.dim),
          children: [
            LayoutId(id: 'card', child: _cardMover(GuideStepCard(model: model, onExit: widget.onExit,
              onBackToGuide: state is GuideOffPath && state.lastIndex != null ? widget.onBackToGuide : null))),
            if (marked || routeMarked) LayoutId(id: 'pill', child: ExcludeSemantics(child: IgnorePointer(
              child: GuideMarkerPill(l.guideTapMarker, key: LiveGuideOverlay.tapPillKey)))),
            if ((marked || offscreen) && step!.action == GuideAction.scrollThenTap) LayoutId(id: 'scroll', child: ExcludeSemantics(child: IgnorePointer(
              child: RotatedBox(key: LiveGuideOverlay.scrollMarkerKey, quarterTurns: offscreen && target != null && target.bottom <= 0 ? 3 : 1,
                child: GuideMarkerPill(l.guideScrollMarker, arrow: true))))),
          ],
        )),
      ]);
    })));
  }
}

/// Where the card last landed, written by layout and read by drag handling.
class _CardGeometry {
  double top = 0, lower = 0, upper = 0, step = 80;
}

class _GuideLayout extends MultiChildLayoutDelegate {
  final Rect bounds;
  final Rect? target;
  final List<Rect> avoid;
  final double? fraction;
  final _CardGeometry geometry;
  final bool seekGap;
  _GuideLayout(this.bounds, this.target, this.avoid, this.fraction, this.geometry, this.seekGap);
  @override
  void performLayout(Size size) {
    Rect? pill;
    if (hasChild('pill')) {
      final pillSize = layoutChild('pill', BoxConstraints.loose(bounds.size));
      pill = GuidePillLayout(target!, bounds, avoid).place(pillSize);
      positionChild('pill', pill.topLeft);
    }
    final maxWidth = math.max(0.0, bounds.width - 2 * kGuideCardGap);
    final keep = [?target, ?pill];
    // A card taller than the room beside the target caps its height (its text
    // scrolls) instead of covering the target. Laid out once: the delegate
    // asserts on a second layoutChild.
    var maxHeight = bounds.height;
    if (keep.isNotEmpty) {
      final union = keep.reduce((a, b) => a.expandToInclude(b));
      final room = math.max(union.top - bounds.top, bounds.bottom - union.bottom) - 2 * kGuideCardGap;
      if (room > 80) maxHeight = math.min(maxHeight, room);
    }
    final cardSize = layoutChild('card', BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight));
    final lower = bounds.top + kGuideCardGap;
    final upper = math.max(lower, bounds.bottom - kGuideCardGap - cardSize.height);
    final card = placeGuideCard(bounds: bounds, cardSize: cardSize, keepClear: keep, avoid: avoid, seekGap: seekGap,
      preferredTop: fraction == null ? null : lower + fraction! * (upper - lower));
    positionChild('card', card.topLeft);
    geometry..top = card.top..lower = lower..upper = upper..step = math.max(40, (upper - lower) / 5);
    if (hasChild('scroll')) {
      final markerSize = layoutChild('scroll', BoxConstraints.loose(bounds.size));
      final marker = GuidePillLayout(target!, bounds, [...avoid, card, ?pill]).place(markerSize);
      positionChild('scroll', marker.topLeft);
    }
  }
  @override
  bool shouldRelayout(_GuideLayout old) => bounds != old.bounds || target != old.target ||
      !listEquals(avoid, old.avoid) || fraction != old.fraction;
}

class _GuidePainter extends CustomPainter {
  final List<SkeletonShape> shapes;
  final P palette;
  final List<Rect> holes;
  _GuidePainter(this.shapes, this.palette, [this.holes = const []]);
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in shapes) {
      switch (s.kind) {
        case SkeletonKind.surface:
          canvas.drawRRect(R.rLg.toRRect(s.rect), Paint()..color = s.color!);
        case SkeletonKind.erase:
          canvas.drawRect(s.rect, Paint()..color = s.color!);
        case SkeletonKind.bar:
          final h = math.min(s.rect.height, math.max(8.0, s.rect.height * .55));
          final pill = Rect.fromCenter(center: s.rect.center, width: s.rect.width, height: h);
          canvas.drawRRect(RRect.fromRectAndRadius(pill, Radius.circular(h / 2)), Paint()..color = palette.line);
        case SkeletonKind.block:
          canvas.drawRRect(R.rMd.toRRect(s.rect), Paint()..color = palette.line);
        case SkeletonKind.dim:
          canvas.drawRect(s.rect, Paint()..color = s.color!);
        case SkeletonKind.heading:
          break; // RED stub: green draws the heading dimmed.
      }
    }
  }
  @override
  bool shouldRepaint(_GuidePainter old) => true;

  /// Input per layer (owner decision, r2): ONLY skeleton ink takes pointers; a
  /// dim layer, a hole (target, chrome) or blank scaffold lets them through to
  /// the real page. Used by the dim look; the legacy look keeps [_GuideShield].
  @override
  bool? hitTest(Offset position) {
    if (holes.any((r) => r.contains(position))) return false;
    return shapes.any((s) => s.kind != SkeletonKind.dim && s.rect.contains(position));
  }
}

/// Hit-test holes let Navigator hit the actual page, including its recognizers.
class _GuideShield extends SingleChildRenderObjectWidget {
  final List<Rect> holes;
  const _GuideShield({required this.holes, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGuideShield(holes);
  @override
  void updateRenderObject(BuildContext context, _RenderGuideShield renderObject) { renderObject.holes = holes; }
}
class _RenderGuideShield extends RenderProxyBox {
  List<Rect> holes;
  _RenderGuideShield(this.holes);
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || holes.any((r) => r.contains(position))) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

/// Whether the reveal search started for ([page], [step]) is still wanted: this
/// overlay is mounted, still on that search, the run is alive and still on that
/// page and step. A class (not a closure) so the heavy-calc guard can resolve it.
class _StepGate implements RevealGate {
  final LiveGuideOverlayState _state;
  final Object _token;
  final Element _page;
  final GuideStep _step;
  const _StepGate(this._state, this._token, this._page, this._step);

  @override
  bool get isOpen =>
      _state.mounted &&
      identical(_state._searchToken, _token) &&
      !_state.widget.run.isExited &&
      identical(_state.widget.routes.page, _page) &&
      identical(_state.widget.run.currentStep, _step);
}
