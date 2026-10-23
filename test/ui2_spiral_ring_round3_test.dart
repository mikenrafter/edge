// Round 3 on the spiral ring: the separator is a thin line, not an eraser, and
// a translucent (gradient) ring composites each coloured region once.

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/spiral_ring.dart';

const _green = Color(0xFF00AA00);
const _bg = Color(0xFFFF00FF);
const _none = Color(0x00000000);

Future<ByteData> _raster(CustomPainter p, int px) async {
  final rec = ui.PictureRecorder();
  p.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
  final img = await rec.endRecording().toImage(px, px);
  return (await img.toByteData())!;
}

List<int> _at(ByteData d, int px, double u, double r) {
  final x = (px / 2 + r * sin(2 * pi * u)).floor().clamp(0, px - 1);
  final y = (px / 2 - r * cos(2 * pi * u)).floor().clamp(0, px - 1);
  final i = (y * px + x) * 4;
  return [for (var k = 0; k < 4; k++) d.getUint8(i + k)];
}

bool _magenta(List<int> c) =>
    c[3] > 100 && c[0] > 200 && c[2] > 200 && c[1] < 80;

void main() {
  testWidgets('20 px / stroke 3 ring at 500%: no empty or background pixel '
      'between the outer edge and the innermost lap', (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(
          Ring(5.0, _green, _none, stroke: 3, solid: true, background: _bg),
          20);
      for (var k = 0; k < 12; k++) {
        final u = k / 12 + .02;
        double? inner;
        for (var r = 1.5; r < 10; r += .25) {
          if (_at(d, 20, u, r)[3] > 200) {
            inner = r;
            break;
          }
        }
        expect(inner, isNotNull, reason: 'u=$u');
        for (var r = inner! + .5; r < 9.3; r += .25) {
          final c = _at(d, 20, u, r);
          expect(c[3], greaterThan(200), reason: 'gap at u=$u r=$r $c');
          expect(_magenta(c), isFalse, reason: 'separator at u=$u r=$r');
        }
      }
    });
  });

  testWidgets('200 px / stroke 20: the separator is present and at most '
      '1.5 px wide', (tester) async {
    await tester.runAsync(() async {
      const g = SpiralGeometry(20);
      final d = await _raster(
          Ring(1.3, _green, _none, stroke: 20, solid: true, background: _bg),
          200);
      for (final u in [.15, .2, .25]) {
        final edge = 90 - g.inset(1 + u) + 10;
        var n = 0;
        for (var r = edge - 4; r < edge + 4; r += .1) {
          if (_magenta(_at(d, 200, u, r))) n++;
        }
        final w = n * .1;
        expect(w, greaterThan(.3), reason: 'u=$u: no separator');
        expect(w, lessThanOrEqualTo(1.6), reason: 'u=$u width $w');
      }
    });
  });

  test('separator width scales with stroke and vanishes on tiny rings', () {
    expect(kSpiralSeparator, 1.5);
    expect(spiralSeparatorWidth(20), closeTo(1.5, 1e-9));
    expect(spiralSeparatorWidth(40), closeTo(1.5, 1e-9));
    expect(spiralSeparatorWidth(14), closeTo(1.05, 1e-9));
    expect(spiralSeparatorWidth(10), closeTo(.75, 1e-9));
    expect(spiralSeparatorWidth(3), 0);
    expect(spiralSeparatorWidth(6), 0);
  });

  testWidgets('translucent gradient ring at 66%: caps do not double the alpha',
      (tester) async {
    await tester.runAsync(() async {
      final d = await _raster(
          Ring(.66, _green, _none, stroke: 20, background: _bg), 200);
      // Start cap: inside both the disc and the band vs band only.
      final overlap = _at(d, 200, .008, 90)[3];
      final bandOnly = _at(d, 200, .05, 90)[3];
      expect((overlap - bandOnly).abs(), lessThan(16),
          reason: 'start cap overlap $overlap vs band $bandOnly');
      // Cap-only side (before 12 o'clock) is the start colour, not full.
      final capOnly = _at(d, 200, .99, 90)[3];
      expect(capOnly, closeTo(bandOnly, 24), reason: 'cap-only $capOnly');
      // End cap.
      final endOverlap = _at(d, 200, .655, 90)[3];
      final endBand = _at(d, 200, .6, 90)[3];
      expect((endOverlap - endBand).abs(), lessThan(16),
          reason: 'end cap overlap $endOverlap vs band $endBand');
    });
  });
}
