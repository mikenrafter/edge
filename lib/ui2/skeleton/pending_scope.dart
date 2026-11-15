import 'package:flutter/widgets.dart';

/// Content knowable before the new read: labels, units, dates and controls.
/// Guide dimming has its own policy and deliberately ignores this marker.
class PendingStatic extends StatelessWidget {
  const PendingStatic({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// A remembered text tail paints its filler through the same debounced data
/// layer as paragraphs, so reserved geometry never flashes early ink.
abstract interface class PendingFillRender {
  void paintPendingFill(PaintingContext context, Offset offset, double pulse);
}
