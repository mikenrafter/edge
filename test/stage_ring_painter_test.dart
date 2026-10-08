// StageRing: the sleep dial's painter. The track first, then each arc laid end
// to end clockwise from 12 o'clock in its own colour, butt-capped so one
// stage's end is the next stage's start with no overlap and no gap.
//
// Drawn onto a recording canvas, so the geometry is asserted, not eyeballed.

import 'dart:math';
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';

class _Arc {
  final double start, sweep, stroke;
  final int color;
  final StrokeCap cap;
  _Arc(this.start, this.sweep, this.stroke, this.color, this.cap);
}

class _Rec implements Canvas {
  final arcs = <_Arc>[];
  final circles = <int>[];
  final order = <String>[];

  @override
  void drawArc(
      Rect rect, double start, double sweep, bool useCenter, Paint paint) {
    order.add('arc');
    arcs.add(_Arc(start, sweep, paint.strokeWidth, paint.color.toARGB32(),
        paint.strokeCap));
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    order.add('circle');
    circles.add(paint.color.toARGB32());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _track = Color(0xFF202020);
const _a = Color(0xFF0000FF);
const _b = Color(0xFF00FFFF);
const _c = Color(0xFF88CCFF);
const _d = Color(0xFFFF8800);

_Rec _paint(StageRing r) {
  final rec = _Rec();
  r.paint(rec, const Size(100, 100));
  return rec;
}

void main() {
  test('the track is drawn first, once, in the track colour', () {
    final rec = _paint(StageRing(const [RingArc(_a, .5)], _track));
    expect(rec.order.first, 'circle');
    expect(rec.circles, [_track.toARGB32()]);
  });

  test('arcs start at 12 o\'clock and run end to end, each in its colour', () {
    final rec = _paint(StageRing(
      const [RingArc(_a, .2), RingArc(_b, .3), RingArc(_c, .4), RingArc(_d, .05)],
      _track,
      stroke: 7,
    ));
    expect(rec.arcs, hasLength(4));
    expect(rec.arcs.first.start, closeTo(-pi / 2, 1e-9));
    for (var i = 0; i < rec.arcs.length - 1; i++) {
      expect(rec.arcs[i + 1].start,
          closeTo(rec.arcs[i].start + rec.arcs[i].sweep, 1e-9),
          reason: 'arc ${i + 1} starts where arc $i ends');
    }
    expect([for (final a in rec.arcs) a.color],
        [_a, _b, _c, _d].map((c) => c.toARGB32()).toList());
    expect(rec.arcs[0].sweep, closeTo(2 * pi * .2, 1e-9));
    expect(rec.arcs[2].sweep, closeTo(2 * pi * .4, 1e-9));
    expect(rec.arcs.every((a) => a.stroke == 7), isTrue);
  });

  test('butt caps — a round cap would overlap the neighbouring stage', () {
    final rec = _paint(
        StageRing(const [RingArc(_a, .2), RingArc(_b, .3)], _track));
    expect(rec.arcs, hasLength(2));
    expect(rec.arcs.every((a) => a.cap == StrokeCap.butt), isTrue);
  });

  test('a zero-length arc draws nothing', () {
    final rec = _paint(
        StageRing(const [RingArc(_a, .3), RingArc(_b, 0), RingArc(_c, .2)], _track));
    expect(rec.arcs.map((a) => a.color), [_a.toARGB32(), _c.toARGB32()]);
  });

  test('arcs past a full circle are clipped to it, never wrapped', () {
    final rec = _paint(
        StageRing(const [RingArc(_a, .7), RingArc(_b, .5)], _track));
    final total = rec.arcs.fold<double>(0, (s, a) => s + a.sweep);
    expect(total, closeTo(2 * pi, 1e-9));
    expect(rec.arcs[1].sweep, closeTo(2 * pi * .3, 1e-9));
  });

  test('the draw-in progress t scales every sweep', () {
    final rec = _paint(StageRing(
        const [RingArc(_a, .4), RingArc(_b, .4)], _track, t: .5));
    final total = rec.arcs.fold<double>(0, (s, a) => s + a.sweep);
    expect(total, closeTo(2 * pi * .4, 1e-9));
  });

  test('no arcs is the bare track', () {
    final rec = _paint(StageRing(const [], _track));
    expect(rec.arcs, isEmpty);
    expect(rec.circles, [_track.toARGB32()]);
  });

  test('shouldRepaint: same arcs no, different arcs yes', () {
    final one = StageRing(const [RingArc(_a, .5)], _track);
    final same = StageRing(const [RingArc(_a, .5)], _track);
    final other = StageRing(const [RingArc(_a, .6)], _track);
    final recolour = StageRing(const [RingArc(_b, .5)], _track);
    expect(same.shouldRepaint(one), isFalse);
    expect(other.shouldRepaint(one), isTrue);
    expect(recolour.shouldRepaint(one), isTrue);
  });
}
