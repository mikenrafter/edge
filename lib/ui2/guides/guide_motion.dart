// One clock per overlay supplies all placeholder painters.
import 'dart:math' as math;

const kGuidePulseDuration = Duration(milliseconds: 1600);
double guidePulseValue(double phase) => 1 - .08 * math.cos(phase * 2 * math.pi);

/// Owns the instruction card's position for one step. Time is supplied by its
/// overlay's ticker; it never creates timers or writes app state.
class GuideCardMotion {
  double? top;
  double opacity = 1;
  void reset() { top = null; opacity = 1; }
  void place(double desired, {required bool scrolling, required bool collision, required Duration elapsed}) {
    top = desired;
  }
}
