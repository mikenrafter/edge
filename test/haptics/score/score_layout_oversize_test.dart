// A measure that cannot fit the row at its minimum gaps (sixteen sixteenth
// notes that all write a dynamic need 343 px of glyphs and gaps with the sizes
// in ScoreMetrics; eight notes with a dynamic between eight rests, 295) does
// not overflow the row and is not clipped: the whole score is
// scaled down uniformly, glyphs, gaps, padding and dynamics together, until one
// measure fits per line. Proportions, and the equal width of every measure,
// are kept. A score that fits is not touched.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/score_layout.dart';

const _m = ScoreMetrics();
const _eps = 0.001;

List<PatternEntry> _notes(String codes) =>
    PatternTranscript.parseCode(codes).entries;

ScoreLayout _fit(String codes, double width) =>
    ScoreLayout.fit(_notes(codes), width: width);

// Sixteen sixteenth notes in a measure, each writing a dynamic (two measures).
final _sixteen = List.filled(32, 'N1mf').join(' ');
// Eight sixteenth notes with a dynamic, each followed by a sixteenth rest.
final _pairs = List.filled(16, 'N1mf R1').join(' ');

// What does not fit, and the widths at which it does not.
final _cases = <String, (String, List<double>)>{
  'sixteen notes': (_sixteen, const [320.0, 360.0]),
  'notes and rests': (_pairs, const [320.0]),
};

double _scaleOf(ScoreLayout l) => (l as dynamic).scale as double;

void main() {
  for (final c in _cases.entries) {
    for (final w in c.value.$2) {
      group('${c.key} at $w px', () {
        final e = MapEntry(c.key, c.value.$1);
        test('${e.key}: nothing is beyond the width', () {
          final l = _fit(e.value, w);
          expect(l.contentWidth, lessThanOrEqualTo(w + _eps));
          for (final g in l.glyphs) {
            expect(g.x, greaterThanOrEqualTo(0));
            expect(g.x + g.width, lessThanOrEqualTo(w + _eps));
          }
          for (final line in l.lines) {
            expect(line.right, lessThanOrEqualTo(w + _eps));
          }
        });

        test('${e.key}: every measure is the same width, one fits a line', () {
          final l = _fit(e.value, w);
          expect(l.measures.length, greaterThan(1));
          for (final m in l.measures) {
            expect(m.width, closeTo(l.measureWidth, _eps));
          }
          for (final line in l.lines) {
            expect(line.measures, hasLength(1));
          }
          final firstX = _m.leadWidth + _m.doubleBarWidth;
          expect(firstX + l.measureWidth + _m.doubleBarWidth,
              lessThanOrEqualTo(w + _eps));
        });

        test('${e.key}: glyphs still clear each other and stay in their '
            'measure', () {
          final l = _fit(e.value, w);
          final g = l.glyphs;
          for (var i = 1; i < g.length; i++) {
            if (g[i].line != g[i - 1].line) continue;
            expect(g[i].x - (g[i - 1].x + g[i - 1].width), greaterThan(0));
          }
          for (var i = 0; i < g.length; i++) {
            for (var j = i + 1; j < g.length; j++) {
              final a = g[i], b = g[j];
              expect(
                  a.x < b.x + b.width &&
                      b.x < a.x + a.width &&
                      a.top < b.bottom &&
                      b.top < a.bottom,
                  isFalse,
                  reason: 'glyphs $i and $j');
            }
          }
          for (final m in l.measures) {
            for (final x in m.glyphs) {
              expect(x.x, greaterThanOrEqualTo(m.x - _eps));
              expect(x.x + x.width, lessThanOrEqualTo(m.x + m.width + _eps));
            }
          }
        });

        test('${e.key}: the same picture as the roomy one, only smaller', () {
          final roomy = _fit(e.value, 4000);
          final tight = _fit(e.value, w);
          expect(_scaleOf(roomy), 1.0);
          final k = _scaleOf(tight);
          expect(k, lessThan(1.0));
          expect(k, greaterThan(0.2));
          expect(tight.measureWidth, closeTo(roomy.measureWidth * k, 0.01));
          for (var i = 0; i < roomy.glyphs.length; i++) {
            final r = roomy.glyphs[i], t = tight.glyphs[i];
            final rm = roomy.measures[r.measure], tm = tight.measures[t.measure];
            expect((t.x - tm.x) / tm.width,
                closeTo((r.x - rm.x) / rm.width, 1e-6),
                reason: 'glyph $i keeps its place in the measure');
            expect(t.width / tm.width, closeTo(r.width / rm.width, 1e-6),
                reason: 'glyph $i keeps its share of the measure');
          }
        });
      });
    }
  }

  test('a score that fits is not scaled', () {
    for (final codes in ['N4* R4 N4*', 'N4mf R4 N4f R4 N4mf R4 N4ff R4 N4mp']) {
      for (final w in const [320.0, 600.0]) {
        expect(_scaleOf(_fit(codes, w)), 1.0, reason: '$codes @ $w');
      }
    }
  });

  test('the scale is the room over the need: the measure just fits', () {
    final l = _fit(_pairs, 320);
    final firstX = _m.leadWidth + _m.doubleBarWidth;
    expect(l.measureWidth,
        closeTo(320 - firstX - _m.doubleBarWidth, 0.01));
  });

  test('a wider row scales it less', () {
    final k = [
      for (final w in const [320.0, 360.0, 411.0]) _scaleOf(_fit(_sixteen, w)),
    ];
    expect(k[0], lessThan(k[1]));
    expect(k[1], lessThan(1.0));
    expect(k[2], 1.0, reason: '343 px fit a 411 px row');
  });

  test('time order and ties survive scaling', () {
    final entries = [
      ..._notes(List.filled(15, 'N1ff').join(' ')),
      // Crosses the bar line, so it is two tied glyphs.
      const PatternEntry(note: true, length: 5, dynamic: PatternDynamic.mf),
      ..._notes(List.filled(6, 'N1p').join(' ')),
    ];
    final l = ScoreLayout.fit(entries, width: 320);
    expect(_scaleOf(l), lessThan(1.0));
    expect([for (final g in l.glyphs) g.startUnit],
        [...List.of(l.glyphs.map((g) => g.startUnit))..sort()]);
    expect(l.glyphs.where((g) => g.tiedToNext), isNotEmpty);
  });
}
