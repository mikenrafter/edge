import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

// Owner: each boundary animates its own height changes. Movement contributed
// by nested boundaries flows through it during layout.
class SettlingHeight extends StatefulWidget {
  const SettlingHeight({super.key, required this.child});
  final Widget child;
  static const duration = Duration(milliseconds: 200);
  @override
  State<SettlingHeight> createState() => _SettlingHeightState();
}

class _SettlingHeightState extends State<SettlingHeight>
    with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? widget.child
      : _FlowSize(vsync: this, child: widget.child);
}

class _FlowSize extends SingleChildRenderObjectWidget {
  const _FlowSize({required this.vsync, required super.child});
  final TickerProvider vsync;
  @override
  RenderSettlingHeight createRenderObject(BuildContext context) =>
      RenderSettlingHeight(vsync: vsync);
  @override
  void updateRenderObject(
    BuildContext context,
    RenderSettlingHeight renderObject,
  ) {
    renderObject.vsync = vsync;
  }
}

// CLAIM(settling-height-independent): independently changing parent content
// retains its own tween while nested vertical sections flow without another
// tween [pending_height_transition_test]. No widget rebuilds on animation ticks.
// CLAIM(settling-height-layout-contribution): flowing motion follows Column's
// sum and Row's maximum; tight children contribute no flowing height
// [settling_height_row_test; pending_height_transition_test].
class RenderSettlingHeight extends RenderProxyBox {
  // Debug-only observer for layout-work measurements in widget tests.
  static void Function(int flowNodes, int sizeReads)? debugOnFlow;
  int _flowNodes = 0, _sizeReads = 0;
  RenderSettlingHeight({required TickerProvider vsync}) : _vsync = vsync {
    _controller = AnimationController(
      vsync: vsync,
      duration: SettlingHeight.duration,
    )..addListener(_tick);
  }

  late final AnimationController _controller;
  TickerProvider _vsync;
  final _descendants = <RenderSettlingHeight, double>{};
  RenderSettlingHeight? _ancestor;
  double? _target;
  double _begin = 0;
  double _laidOutHeight = 0;
  double _lastFlow = 0;
  // Cache topology, not sizes: constraints and sibling maxima can change on
  // every layout even when registration is unchanged.
  final _paths = <RenderSettlingHeight, List<RenderBox>>{};
  final _routes = <RenderBox, Set<RenderBox>>{};
  bool _routesDirty = false;
  bool _registered = false;
  bool _layingOut = false;

  void _tick() {
    // Restarting the controller during layout consumes value zero in that same
    // pass. Only later ticks need to schedule another layout.
    if (!_layingOut) markNeedsLayout();
  }

  bool get isAnimating => _controller.isAnimating;
  set vsync(TickerProvider value) {
    if (identical(value, _vsync)) return;
    _vsync = value;
    _controller.resync(value);
  }

  double get _height =>
      _begin +
      ((_target ?? _begin) - _begin) *
          Curves.easeOutCubic.transform(_controller.value);

  void _register() {
    if (_registered) return;
    final path = <RenderBox>[this];
    RenderObject? next = parent;
    while (next != null && next is! RenderSettlingHeight) {
      if (next is RenderBox) path.add(next);
      next = next.parent;
    }
    _registered = true;
    _ancestor = next as RenderSettlingHeight?;
    // Insertion/removal belongs to the parent; subsequent height movement
    // belongs to this boundary. Reparenting detaches and registers a new path.
    _ancestor?._descendants[this] = _laidOutHeight;
    _ancestor?._paths[this] = path;
    _ancestor?._routesDirty = true;
  }

  void _updateRoutes() {
    if (!_routesDirty) return;
    _routes.clear();
    for (final path in _paths.values) {
      for (var i = 1; i < path.length; i++) {
        (_routes[path[i]] ??= <RenderBox>{}).add(path[i - 1]);
      }
    }
    _routesDirty = false;
  }

  @override
  void performLayout() {
    _layingOut = true;
    try {
      _layout();
    } finally {
      _layingOut = false;
    }
  }

  void _layout() {
    assert(() { _flowNodes = 0; _sizeReads = 0; return true; }());
    child?.layout(constraints, parentUsesSize: true);
    final natural = child?.size ?? constraints.smallest;
    var flow = 0.0;
    final topologyChanged = _routesDirty;
    _updateRoutes();
    if (child != null && _descendants.isNotEmpty) {
      // All descendants have completed layout. A layout callback permits
      // inspecting those actual sizes (including LayoutBuilder output) without
      // speculative child layouts or another pass through the render tree.
      invokeLayoutCallback<BoxConstraints>((_) { flow = _flow(child!); });
    }
    if (topologyChanged && _target != null) {
      // Reparenting changes the baseline's coordinate system, not the visible
      // height. Rebase both tween endpoints before considering content changes.
      final shift = _lastFlow - flow;
      _begin += shift;
      _target = _target! + shift;
    }
    _lastFlow = flow;
    final target = natural.height - flow;
    if (_target == null) {
      _begin = target;
      _target = target;
      _controller.value = 1;
    } else if ((target - _target!).abs() > precisionErrorTolerance) {
      _begin = _height;
      _target = target;
      _controller.forward(from: 0);
    }
    size = constraints.constrain(
      Size(natural.width, (_height + flow).clamp(0, double.infinity)),
    );
    _laidOutHeight = size.height;
    _register();
    assert(() { debugOnFlow?.call(_flowNodes, _sizeReads); return true; }());
  }

  double _flow(RenderBox box) {
    assert(() { _flowNodes++; return true; }());
    // A stretched intrinsic row lays out both cards at the same tight height.
    // That height belongs to the row's owner, not to either card's tween.
    if (box.constraints.hasTightHeight ||
        (box is RenderOffstage && box.offstage)) {
      return 0;
    }
    if (box is RenderSettlingHeight) {
      final baseline = _descendants[box];
      return baseline == null ? 0 : box._laidOutHeight - baseline;
    }
    final routed = _routes[box];
    if (routed == null) return 0;
    double movement;
    if (box is RenderFlex) {
      if (box.direction == Axis.vertical) {
        if (box.mainAxisSize == MainAxisSize.max &&
            box.constraints.hasBoundedHeight) {
          return 0;
        }
        movement = routed.fold(0.0, (sum, child) => sum + _flow(child));
      } else {
        return _maxFlow(box, routed);
      }
    } else if (box is RenderStack) {
      return _maxFlow(box, routed, stack: true);
    } else if (box is RenderProxyBox || box is RenderShiftedBox) {
      movement = _flow(routed.single);
    } else {
      // LayoutBuilder forwards its one child's size. Other opaque multi-child
      // layouts need their own contribution policy; do not treat them as sums.
      var count = 0;
      box.visitChildren((_) => count++);
      if (count != 1) return 0;
      movement = _flow(routed.single);
    }
    return box.size.height -
        box.constraints.constrainHeight(box.size.height - movement);
  }

  double _maxFlow(RenderBox box, Set<RenderBox> routed, {bool stack = false}) {
    var baselineMax = 0.0;
    var hasBody = false;
    box.visitChildren((child) {
      final body = child as RenderBox;
      // Positioned overlays never determine Stack height.
      if (stack && (body.parentData! as StackParentData).isPositioned) return;
      hasBody = true;
      assert(() { _sizeReads++; return true; }());
      final movement = routed.contains(body) ? _flow(body) : 0.0;
      final baseline = body.size.height - movement;
      if (baseline > baselineMax) baselineMax = baseline;
    });
    return hasBody
        ? box.size.height - box.constraints.constrainHeight(baselineMax)
        : 0;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (child!.size.height > size.height) {
      context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        super.paint,
      );
    } else {
      super.paint(context, offset);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (_target != null && _controller.value < 1) _controller.forward();
  }

  @override
  void detach() {
    _ancestor?._descendants.remove(this);
    _ancestor?._paths.remove(this);
    _ancestor?._routesDirty = true;
    _ancestor = null;
    _registered = false;
    _controller.stop();
    super.detach();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
