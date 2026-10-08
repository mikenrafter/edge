// ScoreLayout.fit: a pattern's notes as a wrapped 4/4 score of music glyphs.
// One pitch, so only the note value, dots, ties, dynamics and position matter.
//
// The display overhaul (design: haptics display):
//   * three staff lines; rests are centred on the MIDDLE line, notes sit in the
//     space between the middle and the bottom line;
//   * 4/4: a bar line every 16 sixteenths, a DOUBLE bar at the start (line 1
//     only) and at the end (last line only); an entry that crosses a bar line is
//     cut there and its notes are tied;
//   * glyphs never clump (a minimum gap) and are never stretched across the
//     row: every measure is as wide as the neediest one at the minimum gap,
//     whatever the row's width is; what does not fit wraps by whole measures,
//     and later lines are indented like the first so measures align.
//
// Pure Dart: every test here gives the width.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart' show kPresets;
import 'package:openstrap_edge/haptics/score_layout.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

// "N4mf R2 N1p": the codes PatternEntry.toString writes. A length outside
// kPatternLengths (N5, N7) is built directly: the layout must still draw it.
PatternEntry _e(String code) {
  final m = RegExp(r'^([NR])(\d+)(ff|f|mf|mp|pp|p|\*)?$').firstMatch(code)!;
  final note = m[1] == 'N';
  final dyn = m[3];
  return PatternEntry(
    note: note,
    length: int.parse(m[2]!),
    dynamic: !note
        ? null
        : dyn == '*' || dyn == null
            ? PatternDynamic.any
            : PatternDynamic.values.byName(dyn),
  );
}

const _m = ScoreMetrics();
const _widths = [320.0, 360.0, 411.0, 600.0];
const _eps = 0.001;

ScoreLayout _fit(
  String codes, {
  double width = 600,
  ScoreMetrics metrics = _m,
  List<int?>? commands,
}) =>
    ScoreLayout.fit(
      [for (final c in codes.split(' ')) _e(c)],
      width: width,
      metrics: metrics,
      commands: commands,
    );

ScoreGlyph _only(String code) {
  final l = _fit(code);
  expect(l.glyphs, hasLength(1), reason: code);
  return l.glyphs.single;
}

String _preset(String key) => kPresets.firstWhere((p) => p.$1 == key).$3;

// Real and awkward patterns the layout invariants are checked on.
final Map<String, String> _patterns = {
  'one pulse': 'N4*',
  'sos': _preset('preset.sos'),
  'hip hip hooray': _preset('preset.hip_hip_hooray_x2'),
  'five pulses with dynamics': 'N4mf R4 N4f R4 N4mf R4 N4ff R4 N4mp',
  // 16 glyphs in one measure: the densest a measure gets.
  'densest measure': 'N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1',
  // The dense measure and a sparse one: widths must still be equal.
  'dense then sparse': 'N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* R1 N1* '
      'R1 N12* R4 N4* R4',
  'dotted run': 'N3* R3 N3* R3 N3* R3 N3* R3 N6* R6',
  // 29 sixteenths in one note: whole, dotted half, sixteenth, over 2 bars.
  'long tied note': 'N29*',
  'crossing rest and note': 'N12* R8 N6* N6* N6* R12',
  // Six measures of eight glyphs each (four dotted notes, four rests): too
  // wide for any phone in one line, so it wraps.
  'six measures': List.filled(6, 'N3* R1 N3* R1 N3* R1 N3* R1').join(' '),
};

void main() {

  group('a note is drawn as the value its length in sixteenths names', () {
    final cases = <String, (NoteValue, bool)>{
      'N1*': (NoteValue.sixteenth, false),
      'N2*': (NoteValue.eighth, false),
      'N3*': (NoteValue.eighth, true), // dotted eighth
      'N4*': (NoteValue.quarter, false),
      'N6*': (NoteValue.quarter, true), // dotted quarter
      'N8*': (NoteValue.half, false),
      'N12*': (NoteValue.half, true), // dotted half
      'N16*': (NoteValue.whole, false),
    };
    cases.forEach((code, want) {
      test('$code is ${want.$2 ? 'dotted ' : ''}${want.$1.name}', () {
        final g = _only(code);
        expect(g.rest, isFalse);
        expect(g.value, want.$1);
        expect(g.dotted, want.$2);
        expect(g.tiedToNext, isFalse);
        expect(g.tiedFromPrev, isFalse);
        expect(g.units, int.parse(code.substring(1, code.length - 1)));
      });
    });
  });

  group('a length that is not one note value is tied notes', () {
    test('N5 is a quarter tied to a sixteenth', () {
      final l = _fit('N5mf');
      expect(l.glyphs, hasLength(2));
      final a = l.glyphs[0], b = l.glyphs[1];
      expect((a.rest, a.value, a.dotted), (false, NoteValue.quarter, false));
      expect((b.rest, b.value, b.dotted), (false, NoteValue.sixteenth, false));
      expect(a.tiedToNext, isTrue);
      expect(a.tiedFromPrev, isFalse);
      expect(b.tiedFromPrev, isTrue);
      expect(b.tiedToNext, isFalse);
      // Both pieces came from entry 0 and add up to its length.
      expect([a.entryIndex, b.entryIndex], [0, 0]);
      expect(a.units + b.units, 5);
    });

    test('N7 is a dotted quarter tied to a sixteenth', () {
      final l = _fit('N7*');
      expect(l.glyphs, hasLength(2));
      expect(l.glyphs[0].value, NoteValue.quarter);
      expect(l.glyphs[0].dotted, isTrue);
      expect(l.glyphs[1].value, NoteValue.sixteenth);
      expect(l.glyphs[0].tiedToNext, isTrue);
      expect(l.glyphs[1].tiedFromPrev, isTrue);
    });

    test('N10 is a half tied to an eighth; N9 a half tied to a sixteenth', () {
      final ten = _fit('N10*').glyphs;
      expect([for (final g in ten) (g.value, g.dotted)],
          [(NoteValue.half, false), (NoteValue.eighth, false)]);
      final nine = _fit('N9*').glyphs;
      expect([for (final g in nine) (g.value, g.dotted)],
          [(NoteValue.half, false), (NoteValue.sixteenth, false)]);
    });

    test('a tied run is tied in a chain: only the ends have one side open', () {
      // 16 + 12 + 1 = 29: whole, dotted half, sixteenth.
      final g = _fit('N29*').glyphs;
      expect(g, hasLength(3));
      expect([for (final x in g) x.tiedFromPrev], [false, true, true]);
      expect([for (final x in g) x.tiedToNext], [true, true, false]);
    });

    test('a note next to a note is not tied: two notes stay two', () {
      final g = _fit('N4* N4*').glyphs;
      expect(g, hasLength(2));
      expect([for (final x in g) x.tiedToNext], [false, false]);
      expect([for (final x in g) x.tiedFromPrev], [false, false]);
    });
  });

  group('a rest mirrors the note of the same length, and is never tied', () {
    final cases = <int, (NoteValue, bool)>{
      1: (NoteValue.sixteenth, false),
      2: (NoteValue.eighth, false),
      3: (NoteValue.eighth, true),
      4: (NoteValue.quarter, false),
      6: (NoteValue.quarter, true),
      8: (NoteValue.half, false),
      12: (NoteValue.half, true),
    };
    cases.forEach((n, want) {
      test('R$n is a ${want.$2 ? 'dotted ' : ''}${want.$1.name} rest', () {
        final g = _only('R$n');
        expect(g.rest, isTrue);
        expect(g.value, want.$1);
        expect(g.dotted, want.$2);
        expect(g.dynamic, isNull);
        expect(g.tiedToNext, isFalse);
        expect(g.tiedFromPrev, isFalse);
      });
    });

    test('R5 is a quarter rest then a sixteenth rest, no tie', () {
      final g = _fit('R5').glyphs;
      expect(g, hasLength(2));
      expect([for (final x in g) x.rest], [true, true]);
      expect([for (final x in g) x.value],
          [NoteValue.quarter, NoteValue.sixteenth]);
      expect([for (final x in g) x.tiedToNext || x.tiedFromPrev],
          [false, false]);
    });
  });

  group('dynamics are carried', () {
    test('a note keeps its dynamic, a rest has none', () {
      final g = _fit('N2mf R2 N2ff N2p N2mp N2f N2pp').glyphs;
      expect([for (final x in g) x.dynamic], [
        PatternDynamic.mf,
        null,
        PatternDynamic.ff,
        PatternDynamic.p,
        PatternDynamic.mp,
        PatternDynamic.f,
        PatternDynamic.pp,
      ]);
    });

    test('every piece of a tied note carries the entry\'s dynamic', () {
      final g = _fit('N5f').glyphs;
      expect([for (final x in g) x.dynamic], [PatternDynamic.f, PatternDynamic.f]);
    });

    test('any loudness is carried as any, not dropped', () {
      expect(_only('N4*').dynamic, PatternDynamic.any);
    });
  });

  group('time is kept in sixteenths, not in pixels', () {
    test('a glyph starts at the sixteenth its entries add up to', () {
      final l = _fit('N2mf R2 N2mf');
      expect([for (final g in l.glyphs) g.startUnit], [0, 2, 4]);
      expect(l.totalUnits, 6);
    });

    test('the pieces of a tied note sit end to end', () {
      final l = _fit('N5* R1 N1*');
      expect([for (final g in l.glyphs) g.startUnit], [0, 4, 5, 6]);
      expect([for (final g in l.glyphs) g.entryIndex], [0, 0, 1, 2]);
      expect(l.totalUnits, 7);
    });

    test('leading and trailing rests keep their place and count', () {
      final l = _fit('R4 N4* R2');
      expect([for (final g in l.glyphs) g.startUnit], [0, 4, 8]);
      expect(l.totalUnits, 10);
    });

    test('glyphs follow each other left to right in time order', () {
      for (final e in _patterns.entries) {
        final g = _fit(e.value).glyphs;
        for (var i = 1; i < g.length; i++) {
          expect(g[i].startUnit, g[i - 1].startUnit + g[i - 1].units,
              reason: e.key);
        }
      }
    });
  });

  test('no entries gives no glyphs, no lines and no height', () {
    final l = ScoreLayout.fit(const [], width: 320);
    expect(l.glyphs, isEmpty);
    expect(l.lines, isEmpty);
    expect(l.totalUnits, 0);
    expect(l.height, 0.0);
  });

  group('4/4: measures of sixteen sixteenths', () {
    test('the measure count is the total over 16, rounded up', () {
      expect(_fit('N16*').measures, hasLength(1));
      expect(_fit('N16* N1*').measures, hasLength(2));
      expect(_fit('N12* R4 N12* R4 N12* R4').measures, hasLength(3));
    });

    test('a glyph sits in the measure its start falls in', () {
      for (final e in _patterns.entries) {
        for (final g in _fit(e.value).glyphs) {
          expect(g.measure, g.startUnit ~/ 16, reason: '${e.key} $g');
        }
      }
    });

    test('no glyph crosses a bar line', () {
      for (final e in _patterns.entries) {
        for (final g in _fit(e.value).glyphs) {
          expect((g.startUnit + g.units - 1) ~/ 16, g.startUnit ~/ 16,
              reason: '${e.key}: glyph at ${g.startUnit} spans ${g.units}');
        }
      }
    });

    test('a measure\'s glyphs add up to 16, the last one to what is left', () {
      for (final e in _patterns.entries) {
        final l = _fit(e.value);
        for (final m in l.measures) {
          final sum = m.glyphs.fold<int>(0, (n, g) => n + g.units);
          final want = m.index < l.measures.length - 1
              ? 16
              : l.totalUnits - 16 * (l.measures.length - 1);
          expect(sum, want, reason: '${e.key} measure ${m.index}');
          expect(m.startUnit, m.index * 16);
        }
      }
    });

    test('a measure holds exactly the glyphs whose measure it is', () {
      final l = _fit(_patterns['sos']!);
      expect([for (final m in l.measures) ...m.glyphs], l.glyphs);
      for (final m in l.measures) {
        for (final g in m.glyphs) {
          expect(g.measure, m.index);
        }
      }
    });

    test('a note that crosses a bar line is cut there and tied', () {
      // R12 R2 puts N6f at sixteenth 14: two sixteenths, then four.
      final l = _fit('R12 R2 N6f');
      final notes = l.glyphs.where((g) => !g.rest).toList();
      expect(notes, hasLength(2));
      final a = notes[0], b = notes[1];
      expect((a.units, a.value, a.dotted), (2, NoteValue.eighth, false));
      expect((b.units, b.value, b.dotted), (4, NoteValue.quarter, false));
      expect([a.measure, b.measure], [0, 1]);
      expect(b.startUnit, 16);
      expect(a.tiedToNext, isTrue);
      expect(a.tiedFromPrev, isFalse);
      expect(b.tiedFromPrev, isTrue);
      expect(b.tiedToNext, isFalse);
      expect([a.entryIndex, b.entryIndex], [2, 2]);
      expect([a.dynamic, b.dynamic], [PatternDynamic.f, PatternDynamic.f]);
    });

    test('a note cut by a bar line AND by its value is one tied chain', () {
      // N29 = 16 + 12 + 1 over two measures: the tie runs through the bar.
      final l = _fit('N29*');
      expect([for (final g in l.glyphs) g.units], [16, 12, 1]);
      expect([for (final g in l.glyphs) g.measure], [0, 1, 1]);
      expect([for (final g in l.glyphs) g.tiedFromPrev], [false, true, true]);
      expect([for (final g in l.glyphs) g.tiedToNext], [true, true, false]);
    });

    test('a rest that crosses a bar line is cut there and not tied', () {
      final l = _fit('N12* R8');
      final rests = l.glyphs.where((g) => g.rest).toList();
      expect([for (final r in rests) r.units], [4, 4]);
      expect([for (final r in rests) r.value],
          [NoteValue.quarter, NoteValue.quarter]);
      expect([for (final r in rests) r.measure], [0, 1]);
      expect([for (final r in rests) r.entryIndex], [1, 1]);
      expect([for (final r in rests) r.tiedToNext || r.tiedFromPrev],
          [false, false]);
    });

    test('three dotted quarters: the third is cut at the bar and tied', () {
      final l = _fit('N6* N6* N6*');
      expect([for (final g in l.glyphs) g.units], [6, 6, 4, 2]);
      expect([for (final g in l.glyphs) g.entryIndex], [0, 1, 2, 2]);
      expect([for (final g in l.glyphs) g.tiedToNext], [false, false, true, false]);
      expect(l.glyphs[3].tiedFromPrev, isTrue);
    });

    test('two notes on either side of a bar line are not tied to each other',
        () {
      final l = _fit('N12* R4 N4*');
      final notes = l.glyphs.where((g) => !g.rest).toList();
      expect([for (final g in notes) g.tiedToNext || g.tiedFromPrev],
          [false, false]);
    });
  });

  group('bars: a double bar opens the score and a double bar closes it', () {
    test('a one-line score has both on its only line', () {
      final l = _fit('N4* R4 N4*');
      expect(l.lines, hasLength(1));
      expect(l.lines.single.startDoubleBar, isTrue);
      expect(l.lines.single.endDoubleBar, isTrue);
    });

    test('the start belongs to line 1 only, the end to the last line only', () {
      final l = _fit(_patterns['six measures']!, width: 320);
      expect(l.lines.length, greaterThan(1));
      expect([for (final x in l.lines) x.startDoubleBar],
          [true, ...List.filled(l.lines.length - 1, false)]);
      expect([for (final x in l.lines) x.endDoubleBar],
          [...List.filled(l.lines.length - 1, false), true]);
    });

    test('at every width, whatever the pattern', () {
      for (final w in _widths) {
        for (final e in _patterns.entries) {
          final l = _fit(e.value, width: w);
          final why = '${e.key} @$w';
          expect(l.lines.where((x) => x.startDoubleBar), hasLength(1),
              reason: why);
          expect(l.lines.first.startDoubleBar, isTrue, reason: why);
          expect(l.lines.where((x) => x.endDoubleBar), hasLength(1),
              reason: why);
          expect(l.lines.last.endDoubleBar, isTrue, reason: why);
        }
      }
    });
  });

  group('the staff: three lines, rests on the middle one', () {
    test('three staff lines, evenly spaced, top to bottom', () {
      for (final line in _fit(_patterns['sos']!).lines) {
        expect(line.staffY, hasLength(3));
        expect(line.staffY[1] - line.staffY[0], closeTo(_m.staffSpace, _eps));
        expect(line.staffY[2] - line.staffY[1], closeTo(_m.staffSpace, _eps));
      }
    });

    test('a rest is centred on the middle line', () {
      for (final w in _widths) {
        final l = _fit(_patterns['sos']!, width: w);
        final rests = l.glyphs.where((g) => g.rest).toList();
        expect(rests, isNotEmpty);
        for (final g in rests) {
          expect(g.y, closeTo(l.lines[g.line].staffY[1], _eps), reason: '@$w');
        }
      }
    });

    test('a note head sits in the space between the middle and bottom line',
        () {
      for (final w in _widths) {
        final l = _fit(_patterns['sos']!, width: w);
        final notes = l.glyphs.where((g) => !g.rest).toList();
        expect(notes, isNotEmpty);
        for (final g in notes) {
          final y = l.lines[g.line].staffY;
          expect(g.y, greaterThan(y[1]), reason: '@$w');
          expect(g.y, lessThan(y[2]), reason: '@$w');
          expect(g.y, closeTo((y[1] + y[2]) / 2, _eps), reason: '@$w');
        }
      }
    });

    test('every note shares one pitch: one y per line', () {
      final l = _fit(_patterns['six measures']!, width: 320);
      for (final line in l.lines) {
        final ys = {
          for (final g in l.glyphs)
            if (!g.rest && g.line == line.index) g.y,
        };
        expect(ys, hasLength(1));
      }
    });

    test('a glyph stays inside its line\'s band', () {
      final l = _fit(_patterns['six measures']!, width: 320);
      for (final g in l.glyphs) {
        final line = l.lines[g.line];
        expect(g.top, greaterThanOrEqualTo(line.top - _eps));
        expect(g.bottom, lessThanOrEqualTo(line.top + _m.lineHeight + _eps));
        expect(g.top, lessThanOrEqualTo(g.y));
        expect(g.bottom, greaterThanOrEqualTo(g.y));
      }
    });

    test('lines stack without overlapping and the height holds them all', () {
      final l = _fit(_patterns['six measures']!, width: 320);
      for (var i = 1; i < l.lines.length; i++) {
        expect(l.lines[i].top,
            greaterThanOrEqualTo(l.lines[i - 1].top + _m.lineHeight - _eps));
      }
      expect(l.height,
          greaterThanOrEqualTo(l.lines.last.top + _m.lineHeight - _eps));
    });
  });

  group('spacing: no clumping, no stretching', () {
    for (final w in _widths) {
      group('at $w logical px', () {
        test('glyphs of a line keep the minimum gap', () {
          for (final e in _patterns.entries) {
            final g = _fit(e.value, width: w).glyphs;
            for (var i = 1; i < g.length; i++) {
              if (g[i].line != g[i - 1].line) continue;
              final gap = g[i].x - (g[i - 1].x + g[i - 1].width);
              expect(gap, greaterThanOrEqualTo(_m.minGap - _eps),
                  reason: '${e.key}: glyph $i');
            }
          }
        });

        test('no two glyph rectangles overlap', () {
          for (final e in _patterns.entries) {
            final g = _fit(e.value, width: w).glyphs;
            for (var i = 0; i < g.length; i++) {
              for (var j = i + 1; j < g.length; j++) {
                final a = g[i], b = g[j];
                final overlap = a.x < b.x + b.width &&
                    b.x < a.x + a.width &&
                    a.top < b.bottom &&
                    b.top < a.bottom;
                expect(overlap, isFalse, reason: '${e.key}: glyphs $i, $j');
              }
            }
          }
        });

        test('nothing is drawn beyond the width', () {
          for (final e in _patterns.entries) {
            final l = _fit(e.value, width: w);
            for (final g in l.glyphs) {
              expect(g.x, greaterThanOrEqualTo(0), reason: e.key);
              expect(g.x + g.width, lessThanOrEqualTo(w + _eps),
                  reason: e.key);
            }
            for (final line in l.lines) {
              expect(line.left, 0, reason: e.key);
              expect(line.right, lessThanOrEqualTo(w + _eps), reason: e.key);
            }
            expect(l.contentWidth, lessThanOrEqualTo(w + _eps), reason: e.key);
          }
        });

        test('a glyph keeps its bar padding inside its measure', () {
          for (final e in _patterns.entries) {
            for (final m in _fit(e.value, width: w).measures) {
              for (final g in m.glyphs) {
                expect(g.x, greaterThanOrEqualTo(m.x + _m.measurePad - _eps),
                    reason: e.key);
                expect(g.x + g.width,
                    lessThanOrEqualTo(m.x + m.width - _m.measurePad + _eps),
                    reason: e.key);
              }
            }
          }
        });

        test('every measure is the same width', () {
          for (final e in _patterns.entries) {
            final l = _fit(e.value, width: w);
            for (final m in l.measures) {
              expect(m.width, closeTo(l.measureWidth, _eps), reason: e.key);
            }
          }
        });

        test('that width is what the neediest measure needs at the minimum gap',
            () {
          for (final e in _patterns.entries) {
            final l = _fit(e.value, width: w);
            double need(ScoreMeasure m) =>
                2 * _m.measurePad +
                m.glyphs.fold<double>(0, (n, g) => n + g.width) +
                (m.glyphs.length - 1) * _m.minGap;
            final most = l.measures.map(need).reduce((a, b) => a > b ? a : b);
            expect(l.measureWidth, closeTo(most, _eps), reason: e.key);
          }
        });
      });
    }

    test('a glyph is at least the head width, wider with a dot', () {
      final l = _fit('N4* R4 N6* R6');
      for (final g in l.glyphs) {
        expect(g.width, greaterThanOrEqualTo(_m.glyphWidth - _eps));
      }
      final plain = l.glyphs.first.width;
      final dotted = l.glyphs.firstWhere((g) => g.dotted).width;
      expect(dotted, greaterThan(plain));
    });

    test('a written dynamic gets room for its label', () {
      final l = _fit('N4mf R4 N4*');
      expect(l.glyphs.first.width,
          greaterThanOrEqualTo(_m.dynamicWidth - _eps));
    });

    test('the measure width does not depend on the row\'s width', () {
      for (final e in _patterns.entries) {
        final widths = {
          for (final w in _widths) _fit(e.value, width: w).measureWidth,
        };
        expect(widths, hasLength(1), reason: e.key);
      }
    });

    test('a short pattern is not stretched across a wide row', () {
      final l = _fit('N4* R4 N4*', width: 600);
      expect(l.lines, hasLength(1));
      expect(l.contentWidth, lessThan(600 / 2));
      final narrow = _fit('N4* R4 N4*', width: 320);
      expect([for (final g in l.glyphs) g.x],
          [for (final g in narrow.glyphs) g.x],
          reason: 'where a glyph sits does not follow the row width');
    });

    test('the neediest measure sets every measure, sparse ones included', () {
      final l = _fit(_patterns['dense then sparse']!, width: 600);
      final dense = l.measures.first;
      expect(dense.glyphs, hasLength(16));
      expect(l.measures.last.glyphs.length, lessThan(dense.glyphs.length));
      expect(l.measures.last.width, closeTo(dense.width, _eps));
    });

    test('the same input always gives the same layout (pure)', () {
      for (final w in _widths) {
        final a = _fit(_patterns['sos']!, width: w);
        final b = _fit(_patterns['sos']!, width: w);
        expect([for (final g in a.glyphs) (g.x, g.y, g.line)],
            [for (final g in b.glyphs) (g.x, g.y, g.line)]);
      }
    });
  });

  group('wrapping: by whole measures, at bar lines only', () {
    test('every line begins on a bar line and the lines follow on', () {
      for (final w in _widths) {
        for (final e in _patterns.entries) {
          final l = _fit(e.value, width: w);
          expect(l.lines, isNotEmpty, reason: '${e.key} @$w');
          var next = 0;
          for (final line in l.lines) {
            expect(line.measures, isNotEmpty, reason: '${e.key} @$w');
            expect(line.measures.first.index, next, reason: '${e.key} @$w');
            expect(line.measures.first.startUnit % 16, 0);
            next = line.measures.last.index + 1;
          }
          expect(next, l.measures.length, reason: '${e.key} @$w');
        }
      }
    });

    test('every line but the last holds the same number of measures', () {
      for (final w in _widths) {
        for (final e in _patterns.entries) {
          final lines = _fit(e.value, width: w).lines;
          final per = lines.first.measures.length;
          for (final line in lines.take(lines.length - 1)) {
            expect(line.measures, hasLength(per), reason: '${e.key} @$w');
          }
          expect(lines.last.measures.length, lessThanOrEqualTo(per));
        }
      }
    });

    test('a line wraps only when the next measure would not fit', () {
      for (final w in _widths) {
        for (final e in _patterns.entries) {
          final l = _fit(e.value, width: w);
          for (final line in l.lines.take(l.lines.length - 1)) {
            final last = line.measures.last;
            final nextIsLast = last.index + 1 == l.measures.length - 1;
            final end = last.x +
                2 * l.measureWidth +
                (nextIsLast ? _m.doubleBarWidth : 0);
            // Less than a bar of slack at most: the end bar is only owed to
            // the last measure, an implementation may keep room for it.
            expect(end, greaterThan(w - _m.doubleBarWidth - _eps),
                reason: '${e.key} @$w: wrapped with room to spare');
          }
        }
      }
    });

    test('a wider row never needs more lines', () {
      for (final e in _patterns.entries) {
        final counts = [
          for (final w in _widths) _fit(e.value, width: w).lines.length,
        ];
        for (var i = 1; i < counts.length; i++) {
          expect(counts[i], lessThanOrEqualTo(counts[i - 1]),
              reason: '${e.key}: $counts');
        }
      }
    });

    test('six measures overflow a phone and wrap', () {
      expect(_fit(_patterns['six measures']!, width: 320).lines.length,
          greaterThan(1));
    });

    test('a short pattern stays on one line at any of the widths', () {
      for (final w in _widths) {
        expect(_fit('N4* R4 N4*', width: w).lines, hasLength(1));
      }
    });

    test('the lead leaves room on line 1 and later lines indent the same',
        () {
      final l = _fit(_patterns['six measures']!, width: 320);
      expect(l.lines.length, greaterThan(1));
      expect(l.lines.first.measures.first.x,
          greaterThanOrEqualTo(_m.leadWidth + _m.doubleBarWidth - _eps));
      for (final line in l.lines) {
        expect(line.measures.first.x, closeTo(l.lines.first.measures.first.x, _eps));
        for (var i = 0; i < line.measures.length; i++) {
          expect(line.measures[i].x,
              closeTo(l.lines.first.measures[i].x, _eps),
              reason: 'measure $i of line ${line.index} lines up with line 1');
        }
      }
    });

    test('a wider lead moves every line in step', () {
      const wide = ScoreMetrics(leadWidth: 80);
      final a = _fit(_patterns['six measures']!, width: 411);
      final b = _fit(_patterns['six measures']!, width: 411, metrics: wide);
      expect(b.lines.first.measures.first.x,
          closeTo(a.lines.first.measures.first.x + 36, _eps));
      for (final line in b.lines) {
        expect(line.measures.first.x,
            closeTo(b.lines.first.measures.first.x, _eps));
      }
    });

    test('measures sit side by side: one bar line between neighbours', () {
      final l = _fit(_patterns['six measures']!, width: 600);
      for (final line in l.lines) {
        for (var i = 1; i < line.measures.length; i++) {
          expect(line.measures[i].x,
              closeTo(line.measures[i - 1].x + l.measureWidth, _eps));
        }
      }
    });

    test('a tie across a wrap keeps both pieces and their flags', () {
      // A dense first measure, then a dotted quarter at sixteenth 14 that
      // crosses the bar: at 320 each measure has a line to itself, so the tie
      // runs from the end of line 1 to the start of line 2.
      final l = _fit('N3* R1 N3* R1 N3* R1 N2* N6*', width: 320);
      expect(l.lines, hasLength(2));
      final pieces = l.glyphs.where((g) => g.entryIndex == 7).toList();
      expect(pieces, hasLength(2));
      expect([for (final g in pieces) g.line], [0, 1]);
      expect(pieces[0].tiedToNext, isTrue);
      expect(pieces[1].tiedFromPrev, isTrue);
      expect(pieces[1].startUnit, 16);
      expect(pieces[1].x, closeTo(l.lines[1].measures.first.x + _m.measurePad, _eps),
          reason: 'the second piece opens line 2');
    });
  });

  group('commands: the colour of a note is the command that plays it', () {
    test('a note carries the command of its entry', () {
      final l = _fit('N4* R4 N4* R4 N4*', commands: [0, null, 1, null, 2]);
      expect([for (final g in l.glyphs.where((g) => !g.rest)) g.command],
          [0, 1, 2]);
    });

    test('a rest never carries one, whatever the list says', () {
      final l = _fit('N4* R4 N4*', commands: [0, 7, 1]);
      expect([for (final g in l.glyphs.where((g) => g.rest)) g.command],
          [null]);
    });

    test('every piece of a split or tied note carries the entry\'s command',
        () {
      final l = _fit('R12 R2 N6f N29*', commands: [null, null, 3, 5]);
      final pieces3 = l.glyphs.where((g) => g.entryIndex == 2);
      final pieces5 = l.glyphs.where((g) => g.entryIndex == 3);
      expect(pieces3.length, greaterThan(1));
      expect(pieces5.length, greaterThan(1));
      expect([for (final g in pieces3) g.command], everyElement(3));
      expect([for (final g in pieces5) g.command], everyElement(5));
    });

    test('no commands given: no note has one', () {
      final l = _fit('N4* R4 N4*');
      expect([for (final g in l.glyphs) g.command], everyElement(isNull));
    });

    test('a note its command list leaves null stays null', () {
      final l = _fit('N4* R4 N4*', commands: [0, null, null]);
      expect([for (final g in l.glyphs.where((g) => !g.rest)) g.command],
          [0, null]);
    });

    test('commands change nothing about the geometry', () {
      final a = _fit(_patterns['sos']!, width: 360);
      final b = _fit(_patterns['sos']!,
          width: 360, commands: List.generate(17, (i) => i.isEven ? i ~/ 2 : null));
      expect([for (final g in a.glyphs) (g.x, g.y, g.line)],
          [for (final g in b.glyphs) (g.x, g.y, g.line)]);
    });
  });

  group('scoreEntriesOf', () {
    test('a pattern with notes is read from its notes code', () {
      final s = BuzzSequence(const [0],
          durationsMs: const [125], notes: 'N4mf R2 N1p');
      expect([for (final e in scoreEntriesOf(s)) e.toString()],
          ['N4mf', 'R2', 'N1p']);
    });

    test('a tapped rhythm is its presses as any-loudness notes, gaps as rests',
        () {
      // Two 125 ms presses 500 ms apart: N1, a 375 ms gap = R3, N1.
      final s = BuzzSequence(const [0, 500], durationsMs: const [125, 125]);
      expect([for (final e in scoreEntriesOf(s)) e.toString()],
          ['N1*', 'R3', 'N1*']);
    });
  });
}
