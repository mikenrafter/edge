// Widget-test probe: snapshots the render tree into the layout shift model.
//
// Only elements whose widget has a `ValueKey<String>` are tracked; the key's
// value is the element id. Role is inferred from the keyed widget and its
// subtree: Text/RichText => paragraph, EditableText => input, Semantics
// button or Focus with canRequestFocus => control, otherwise other. Colour is
// the nearest ColoredBox/DecoratedBox colour at or below the keyed element
// (0x00000000 when none). focusable/focused come from the Focus in the
// subtree. Times are explicit ms offsets: the probe never reads a clock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

class ShiftProbe {
  final List<Frame> frames = [];
  final List<Interaction> interactions = [];
  final List<FocusEvent> focus = [];
  final List<AnimationSpan> animations = [];

  /// Walks the current tree, records and returns a Frame stamped [atMs].
  Frame capture(WidgetTester tester, {required int atMs}) {
    final out = <ElementSnapshot>[];
    for (final e in tester.allElements) {
      final k = e.widget.key;
      if (k is! ValueKey<String>) continue;
      final box = _box(e);
      if (box == null || !box.hasSize) continue;
      final o = box.localToGlobal(Offset.zero);
      final sub = _subtree(e);
      final focusEl = sub.where((x) => x.widget is Focus).firstOrNull;
      final node = focusEl == null ? null : _nodeOf(focusEl);
      final canFocus = node?.canRequestFocus ?? false;
      out.add(ElementSnapshot(
        id: k.value,
        rect: ShiftRect(o.dx, o.dy, box.size.width, box.size.height),
        role: _role(e.widget, sub, canFocus),
        colorArgb: _color(sub),
        focusable: canFocus,
        focused: node?.hasFocus ?? false,
      ));
    }
    final f = Frame(atMs, out);
    frames.add(f);
    return f;
  }

  /// Everything captured so far as a scorable scenario.
  Scenario scenario(ShiftRect viewport) => Scenario(
        viewport: viewport,
        frames: List.of(frames),
        interactions: List.of(interactions),
        focus: List.of(focus),
        animations: List.of(animations),
      );

  static RenderBox? _box(Element e) {
    RenderBox? found;
    void visit(Element x) {
      if (found != null) return;
      final r = x.renderObject;
      if (r is RenderBox) {
        found = r;
        return;
      }
      x.visitChildren(visit);
    }

    visit(e);
    return found;
  }

  /// [e] and every descendant, depth first.
  static List<Element> _subtree(Element e) {
    final l = <Element>[];
    void visit(Element x) {
      l.add(x);
      x.visitChildren(visit);
    }

    visit(e);
    return l;
  }

  static FocusNode? _nodeOf(Element focusEl) {
    // Focus.maybeOf looks upward, so ask from the Focus's own child.
    FocusNode? n;
    focusEl.visitChildren((c) => n ??= Focus.maybeOf(c, scopeOk: false));
    return n;
  }

  static ElementRole _role(Widget w, List<Element> sub, bool canFocus) {
    if (w is Text || w is RichText) return ElementRole.paragraph;
    if (sub.any((x) => x.widget is EditableText)) return ElementRole.input;
    if (sub.any((x) {
      final y = x.widget;
      return y is Semantics && (y.properties.button ?? false);
    })) {
      return ElementRole.control;
    }
    if (canFocus) return ElementRole.control;
    if (sub.any((x) => x.widget is Text || x.widget is RichText)) {
      return ElementRole.paragraph;
    }
    return ElementRole.other;
  }

  static int _color(List<Element> sub) {
    for (final x in sub) {
      final w = x.widget;
      if (w is ColoredBox) return w.color.toARGB32();
      if (w is DecoratedBox) {
        final d = w.decoration;
        if (d is BoxDecoration && d.color != null) return d.color!.toARGB32();
      }
    }
    return 0x00000000;
  }
}
