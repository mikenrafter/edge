// Widget-test probe: snapshots the render tree into the layout shift model.
//
// Only elements whose widget has a `ValueKey<String>` are tracked; the key's
// value is the element id. Role is inferred from the keyed widget and its
// subtree: Text/RichText => paragraph, EditableText => input, Semantics
// button or Focus with canRequestFocus => control, otherwise other. Colour is
// the nearest ColoredBox/DecoratedBox colour at or below the keyed element
// (0x00000000 when none). focusable/focused come from the Focus in the
// subtree. Times are explicit ms offsets: the probe never reads a clock.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

class ShiftProbe {
  final List<Frame> frames = [];
  final List<Interaction> interactions = [];
  final List<FocusEvent> focus = [];
  final List<AnimationSpan> animations = [];

  /// Walks the current tree, records and returns a Frame stamped [atMs].
  Frame capture(WidgetTester tester, {required int atMs}) =>
      throw UnimplementedError();

  /// Everything captured so far as a scorable scenario.
  Scenario scenario(ShiftRect viewport) => throw UnimplementedError();
}
