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
class RenderSettlingHeight extends RenderProxyBox {
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
    RenderObject? next = parent;
    while (next != null && next is! RenderSettlingHeight) {
      next = next.parent;
    }
    if (identical(next, _ancestor)) return;
    _ancestor?._descendants.remove(this);
    _ancestor = next as RenderSettlingHeight?;
    // Remember the first laid-out height: later movement belongs to this
    // descendant; inserting/removing the whole section belongs to its parent.
    _ancestor?._descendants[this] = _laidOutHeight;
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
    child?.layout(constraints, parentUsesSize: true);
    final natural = child?.size ?? constraints.smallest;
    final flow = _descendants.entries.fold<double>(
      0,
      (height, entry) => height + entry.key._laidOutHeight - entry.value,
    );
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
    _ancestor = null;
    _controller.stop();
    super.detach();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
