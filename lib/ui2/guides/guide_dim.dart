// GUIDE DIM SCOPE (RED STUB, structural r2): the seam through which a guide run
// tells the app's own components how to draw themselves, so the dim and the
// skeleton are part of the SAME widget subtree as the content. That way they
// scroll, fling and overscroll-stretch with it, in every frame.
//
// RED: only the types exist. Nothing reads [GuideDimScope] yet (green: the shared
// grammar components Surface, Section and Pressable, plus a page-level fallback
// for loose text, ask [GuideUnitLooks.lookOf] and paint their own foreground; the
// overlay computes the plan and writes it here).

import 'package:flutter/widgets.dart';

/// How a guide run wants one component drawn. A component absent from the plan
/// (the target, caption-named content, chrome, the route-back control) is drawn
/// as usual and has no look.
enum GuideUnitLook {
  /// One translucent whole-component layer (kDimOpacity of the scaffold colour).
  dim,

  /// Placeholders for the component's content (bars and blocks), with the heading
  /// drawn dimmed at the top-left.
  skeleton,
}

/// The plan, as the components see it. An interface, not a function type, so the
/// heavy-calc guard can resolve the call. Identity is the component's own
/// element ([unit] is the BuildContext of the Surface / Section / Pressable).
abstract interface class GuideUnitLooks {
  /// The look for [unit], or null when the component stays as it is.
  GuideUnitLook? lookOf(BuildContext unit);
}

/// Holds the current [GuideUnitLooks] and tells the components when it changes.
class GuideDimController extends ChangeNotifier {
  GuideUnitLooks? _looks;

  /// The plan in force; null when no guide is dimming anything.
  GuideUnitLooks? get looks => _looks;

  /// Replaces the plan and repaints the components that read it.
  void setLooks(GuideUnitLooks? looks) {
    if (identical(_looks, looks)) return;
    _looks = looks;
    notifyListeners();
  }

  /// Removes the plan: every component draws as usual.
  void clear() => setLooks(null);
}

/// Provided once at the app root (above the Navigator). Components inside read
/// the plan from here.
class GuideDimScope extends InheritedNotifier<GuideDimController> {
  const GuideDimScope({super.key, required GuideDimController controller, required super.child})
      : super(notifier: controller);

  /// The controller of the nearest scope, or null outside one.
  static GuideDimController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuideDimScope>()?.notifier;
}
