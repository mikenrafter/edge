import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

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

/// Shared card/section titles also name their pending semantics. A null name
/// lets an unnamed surface inherit its enclosing section's title.
abstract interface class PendingSectionLabel {
  String? get pendingSectionName;
}

/// A screen title supplies the name for pending regions without a nearer
/// card or section title; it never changes their layout or paint.
class PendingSectionScope extends InheritedWidget
    implements PendingSectionLabel {
  const PendingSectionScope({
    super.key,
    required this.pendingSectionName,
    required super.child,
  });
  @override
  final String? pendingSectionName;
  @override
  bool updateShouldNotify(PendingSectionScope old) =>
      pendingSectionName != old.pendingSectionName;
}

/// Owner: this module tracks the current user action through its first build.
/// A pending region captures that intent when it starts, never at completion.
/// CLAIM(pending-semantics): background reads outside an action frame are quiet
/// [pending_semantics_test]. No elapsed-time guess or last-action timer.
class PendingUserAction {
  static bool _active = false;
  static int _generation = 0;
  static bool get active => _active;
  static T run<T>(T Function() action) {
    _active = true;
    final generation = ++_generation;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_generation == generation) _active = false;
    });
    // Accessibility activation can be a no-op with no rebuild to clear intent.
    SchedulerBinding.instance.scheduleFrame();
    return action();
  }
}
