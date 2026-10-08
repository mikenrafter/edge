// When one measure cannot fit the row the score is scaled down, and EVERYTHING
// drawn scales with it: staff spacing (so the row is shorter), stems, flags,
// ties, rests, dots, bars and stroke widths, not only the horizontal geometry
// and the heads. Painted through a recording canvas, the same pattern at scale
// 1 and at scale k gives the same operations, each k times the size.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/score_layout.dart';
import 'package:openstrap_edge/ui2/haptic_score.dart';

const _m = ScoreMetrics();

List<PatternEntry> _notes(String code) =>
    PatternTranscript.parseCode(code).entries;

// One op the painter drew, reduced to sizes (no positions: those carry the
// indent, which does not scale).
class _Op {
  _Op(this.kind, this.sizes, this.stroke, this.color);
  final String kind;
  final List<double> sizes;
  final double stroke;
  final Color color;
  @override
  String toString() => '$kind $sizes w=$stroke $color';
}

class _Rec implements Canvas {
  final ops = <_Op>[];
  void _add(String k, List<double> sizes, Paint p) =>
      ops.add(_Op(k, sizes, p.strokeWidth, p.color));

  @override
  void drawLine(Offset a, Offset b, Paint p) =>
      _add('line', [(b - a).dx.abs(), (b - a).dy.abs()], p);
  @override
  void drawOval(Rect r, Paint p) => _add('oval', [r.width, r.height], p);
  @override
  void drawRect(Rect r, Paint p) => _add('rect', [r.width, r.height], p);
  @override
  void drawCircle(Offset c, double r, Paint p) => _add('circle', [r], p);
  @override
  void drawPath(Path path, Paint p) {
    final b = path.getBounds();
    _add('path', [b.width, b.height], p);
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

const _ink = Color(0xFF111111);
const _red = Color(0xFFCC0000);

// The ops painting [code] in [width] px, and its layout.
(ScoreLayout, List<_Op>) _paint(String code, double width) {
  final layout = ScoreLayout.fit(_notes(code),
      width: width,
      commands: [for (final _ in _notes(code)) 0]);
  final rec = _Rec();
  HapticScorePainter(layout, ink: _ink, commandColor: (_) => _red)
      .paint(rec, ui.Size(width, layout.height));
  return (layout, rec.ops);
}

// The width that makes one measure of [code] fit at exactly [scale].
double _widthFor(String code, double scale) {
  final natural = ScoreLayout.fit(_notes(code), width: 2000);
  expect(natural.scale, 1);
  final room = natural.measureWidth * scale;
  return _m.leadWidth + 2 * _m.doubleBarWidth + room;
}

// One measure each: flags, dots, rests of every shape.
const _patterns = <String, String>{
  'dotted note, flags, rests': 'N6mf R1 N2ff R4 N1mf R2',
  'half and dotted-half rests, open head, dotted note':
      'N4mf R8 N2ff R2',
  'a half note and a quarter rest': 'N8mf R4 N4ff',
};

void main() {
  for (final e in _patterns.entries) {
    for (final k in const [0.5, 0.2]) {
      test('${e.key} at scale $k: every drawn size is $k x its full size', () {
        final (full, fullOps) = _paint(e.value, 2000);
        final (small, ops) = _paint(e.value, _widthFor(e.value, k));
        expect(full.scale, 1);
        expect(small.scale, closeTo(k, 1e-6));
        expect(small.lines.length, full.lines.length,
            reason: 'one measure either way, so one line');
        expect(ops.length, fullOps.length);
        for (var i = 0; i < ops.length; i++) {
          final a = fullOps[i], b = ops[i];
          expect(b.kind, a.kind, reason: 'op $i');
          for (var j = 0; j < a.sizes.length; j++) {
            expect(b.sizes[j], closeTo(a.sizes[j] * k, 1e-4),
                reason: 'op $i ($a -> $b), size $j');
          }
          expect(b.stroke, closeTo(a.stroke * k, 1e-6),
              reason: 'op $i stroke ($a -> $b)');
        }
      });
    }
  }

  test('staff spacing, stem length and the row height are scale x full', () {
    const code = 'N6mf R1 N2ff R4 N1mf R2';
    final (full, fullOps) = _paint(code, 2000);
    final (small, ops) = _paint(code, _widthFor(code, 0.5));
    // Staff lines: the first three horizontal lines painted.
    double spacing(ScoreLayout l) => l.lines.first.staffY[1] - l.lines.first.staffY[0];
    expect(spacing(full), closeTo(_m.staffSpace, 1e-6));
    expect(spacing(small), closeTo(_m.staffSpace * 0.5, 1e-6));
    expect(small.lines.first.staffY[2] - small.lines.first.staffY[1],
        closeTo(_m.staffSpace * 0.5, 1e-6));
    expect(small.height, closeTo(full.height * 0.5, 1e-6));
    // A stem is the coloured vertical line: 3.5 staff spaces, drawn at the
    // stroke width of the command colour.
    List<double> stems(List<_Op> o) => [
          for (final x in o)
            if (x.kind == 'line' &&
                x.color.toARGB32() == _red.toARGB32() &&
                x.sizes[0] == 0 &&
                x.sizes[1] > 0)
              x.sizes[1],
        ];
    expect(stems(fullOps), isNotEmpty);
    for (final s in stems(fullOps)) {
      expect(s, closeTo(3.5 * _m.staffSpace, 1e-6));
    }
    for (final s in stems(ops)) {
      expect(s, closeTo(3.5 * _m.staffSpace * 0.5, 1e-6));
    }
    final stroke = ops
        .firstWhere((o) =>
            o.kind == 'line' && o.color.toARGB32() == _red.toARGB32())
        .stroke;
    expect(stroke, closeTo(1.2 * 0.5, 1e-6));
  });

  test('a tie bows by two head radii, at every scale', () {
    // A note that crosses the bar line is cut and tied.
    const code = 'R12 N8mf R4';
    for (final k in const [1.0, 0.5, 0.2]) {
      final w = k == 1.0 ? 2000.0 : _widthFor('R12 N4mf', k);
      final (l, ops) = _paint(code, w);
      final ties = [
        for (final o in ops)
          if (o.kind == 'path' && o.color.toARGB32() == _red.toARGB32()) o,
      ];
      expect(ties, isNotEmpty, reason: 'k=$k');
      for (final t in ties) {
        // The control point sits 2 r under the heads; getBounds includes it.
        expect(t.sizes[1], closeTo(2 * _m.staffSpace * .55 * l.scale, 1e-4),
            reason: 'k=$k');
        expect(t.stroke, closeTo(1.2 * l.scale, 1e-6), reason: 'k=$k');
      }
    }
  });

  test('at 0.2 and 0.5 nothing is clipped: glyphs sit inside their line band',
      () {
    for (final k in const [1.0, 0.5, 0.2]) {
      const code = 'N6mf R1 N2ff R4 N1mf R2 N4mf R8 N2ff R2';
      final w = k == 1.0 ? 2000.0 : _widthFor(code, k);
      final l = ScoreLayout.fit(_notes(code), width: w);
      for (final g in l.glyphs) {
        final line = l.lines[g.line];
        expect(g.top, greaterThanOrEqualTo(line.top - 1e-9), reason: 'k=$k');
        expect(g.bottom, lessThanOrEqualTo(line.top + l.height / l.lines.length + 1e-9),
            reason: 'k=$k');
        expect(g.bottom, lessThanOrEqualTo(l.height + 1e-9));
      }
      for (final line in l.lines) {
        expect(line.right, lessThanOrEqualTo(w + 1e-6), reason: 'k=$k');
      }
    }
  });
}
