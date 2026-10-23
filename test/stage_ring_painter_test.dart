// StageRing: the sleep dial's painter. The track first, then each segment as a
// filled band laid end to end clockwise from 12 o'clock in its own colour; a
// round disc at each segment's clockwise end sits over the next segment's
// start, so segments are painted last-to-first.
//
// Drawn onto a recording canvas, so the geometry is asserted, not eyeballed.

import 'dart:math';
import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';

class _Disc {
  final Offset c;
  final double r;
  final int color;
  _Disc(this.c, this.r, this.color);
}

class _Rec implements Canvas {
  final fills = <int>[]; // colour of every filled band, in paint order
  final discs = <_Disc>[];
  final circles = <int>[]; // every drawCircle colour, in order
  final order = <String>[];

  @override
  void drawPath(Path path, Paint paint) {
    if (paint.style == PaintingStyle.fill) {
      order.add('path');
      fills.add(paint.color.toARGB32());
    }
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    order.add('circle');
    circles.add(paint.color.toARGB32());
    if (paint.style == PaintingStyle.fill) {
      discs.add(_Disc(c, radius, paint.color.toARGB32()));
    }
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

Offset _at(double u, double radius) => Offset(50 + radius * sin(2 * pi * u),
    50 - radius * cos(2 * pi * u));

void main() {
  test('the track is drawn first, once, in the track colour', () {
    final rec = _paint(StageRing(const [RingArc(_a, .5)], _track));
    expect(rec.order.first, 'circle');
    expect(rec.circles.first, _track.toARGB32());
    expect(rec.circles.where((c) => c == _track.toARGB32()), hasLength(1));
  });

  test('segments start at 12 o\'clock and run end to end, each in its colour',
      () {
    final r = StageRing(
      const [RingArc(_a, .2), RingArc(_b, .3), RingArc(_c, .4), RingArc(_d, .05)],
      _track,
      stroke: 7,
    );
    // Every segment starts exactly where its neighbour ends.
    final bySeg = {for (final p in r.pieces) p.seg: p};
    expect(bySeg[0]!.from, closeTo(0, 1e-9));
    for (var i = 0; i < 3; i++) {
      expect(bySeg[i + 1]!.from, closeTo(bySeg[i]!.to, 1e-9),
          reason: 'segment ${i + 1} starts where segment $i ends');
    }
    expect(bySeg[0]!.to - bySeg[0]!.from, closeTo(.2, 1e-9));
    expect(bySeg[2]!.to - bySeg[2]!.from, closeTo(.4, 1e-9));
    // Painted last-to-first so each sits on top of its clockwise neighbour.
    final rec = _paint(r);
    expect(rec.fills,
        [_d, _c, _b, _a].map((c) => c.toARGB32()).toList());
    // Each segment's round end disc is centred on where it ends.
    const r0 = 50 - 3.5;
    for (final (colour, end) in [(_a, .2), (_b, .5), (_c, .9), (_d, .95)]) {
      final d = rec.discs.where((x) => x.color == colour.toARGB32() &&
          (x.c - _at(end, r0)).distance < .05);
      expect(d, hasLength(1), reason: 'end disc of $colour at $end');
      expect(d.single.r, closeTo(3.5, 1e-9));
    }
  });

  test('clockwise segment ends are round', () {
    final rec = _paint(
        StageRing(const [RingArc(_a, .2), RingArc(_b, .3)], _track));
    expect(rec.discs.where((d) => d.color == _a.toARGB32()), isNotEmpty);
    expect(rec.discs.where((d) => d.color == _b.toARGB32()), isNotEmpty);
  });

  test('a zero-length arc draws nothing', () {
    final rec = _paint(
        StageRing(const [RingArc(_a, .3), RingArc(_b, 0), RingArc(_c, .2)], _track));
    expect(rec.fills, [_c.toARGB32(), _a.toARGB32()]);
  });

  test('arcs past a full circle continue onto a second lap', () {
    final r = StageRing(const [RingArc(_a, .7), RingArc(_b, .5)], _track);
    final total = r.pieces.fold<double>(0, (s, p) => s + p.to - p.from);
    expect(total, closeTo(1.2, 1e-9));
    expect(r.pieces.map((p) => p.lap).toSet(), {0, 1});
    final rec = _paint(r);
    expect(rec.fills, containsAll([_a.toARGB32(), _b.toARGB32()]));
  });

  test('the draw-in progress t scales every sweep', () {
    final r = StageRing(
        const [RingArc(_a, .4), RingArc(_b, .4)], _track, t: .5);
    final total = r.pieces.fold<double>(0, (s, p) => s + p.to - p.from);
    expect(total, closeTo(.4, 1e-9));
  });

  test('no arcs is the bare track', () {
    final rec = _paint(StageRing(const [], _track));
    expect(rec.fills, isEmpty);
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
    expect(StageRing(const [RingArc(_a, .5)], _track, background: _b)
        .shouldRepaint(one), isTrue);
  });
}
