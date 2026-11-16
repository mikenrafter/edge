import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

// Owner: each changing boundary owns its size animation. Ancestors flow with
// that height during layout, rather than applying a second tween to it.
class SettlingHeight extends StatefulWidget {
  const SettlingHeight({super.key, required this.child});
  final Widget child;
  static const duration = Duration(milliseconds: 200);
  @override
  State<SettlingHeight> createState() => _SettlingHeightState();
}

class _SettlingHeightState extends State<SettlingHeight>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? widget.child
      : _FlowSize(vsync: this, child: widget.child);
}

class _FlowSize extends SingleChildRenderObjectWidget {
  const _FlowSize({required this.vsync, required super.child});
  final TickerProvider vsync;
  @override
  RenderAnimatedSize createRenderObject(BuildContext context) =>
      _RenderFlowSize(vsync: vsync);
  @override
  void updateRenderObject(BuildContext context, _RenderFlowSize renderObject) {
    renderObject.vsync = vsync;
  }
}

class _RenderFlowSize extends RenderAnimatedSize {
  _RenderFlowSize({required super.vsync})
    : super(
        duration: SettlingHeight.duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
      );

  bool _descendantMoving = false;
  bool _layingOut = false;

  @override
  void markNeedsLayout() {
    // A zero-duration controller completes synchronously during super's layout.
    // Its final value is consumed in that same pass, so no re-layout is needed.
    if (!_layingOut) super.markNeedsLayout();
  }

  @override
  void performLayout() {
    final before = hasSize ? size : null;
    _descendantMoving = false;
    // Descendants report their motion during this layout, before this owner
    // chooses a duration. No post-frame rebuild or one-frame outer lag.
    child?.layout(constraints, parentUsesSize: true);
    duration = _descendantMoving ? Duration.zero : SettlingHeight.duration;
    _layingOut = true;
    try {
      super.performLayout();
    } finally {
      _layingOut = false;
    }
    // Include the last frame: the final increment must also flow immediately.
    if (isAnimating || (before != null && before != size)) {
      RenderObject? ancestor = parent;
      while (ancestor != null) {
        if (ancestor is _RenderFlowSize) ancestor._descendantMoving = true;
        ancestor = ancestor.parent;
      }
    }
  }
}
