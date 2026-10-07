// ScoreLayout.of: a pattern's notes as music glyphs. One pitch, so only the
// note value, dots, ties, dynamics and x position matter.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
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

ScoreLayout _layout(String codes, {double unitWidth = 8}) => ScoreLayout.of(
      [for (final c in codes.split(' ')) _e(c)],
      unitWidth: unitWidth,
    );

ScoreGlyph _only(String code) {
  final l = _layout(code);
  expect(l.glyphs, hasLength(1), reason: code);
  return l.glyphs.single;
}

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
      final l = _layout('N5mf');
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
      final l = _layout('N7*');
      expect(l.glyphs, hasLength(2));
      expect(l.glyphs[0].value, NoteValue.quarter);
      expect(l.glyphs[0].dotted, isTrue);
      expect(l.glyphs[1].value, NoteValue.sixteenth);
      expect(l.glyphs[0].tiedToNext, isTrue);
      expect(l.glyphs[1].tiedFromPrev, isTrue);
    });

    test('N10 is a half tied to an eighth; N9 a half tied to a sixteenth', () {
      final ten = _layout('N10*').glyphs;
      expect([for (final g in ten) (g.value, g.dotted)],
          [(NoteValue.half, false), (NoteValue.eighth, false)]);
      final nine = _layout('N9*').glyphs;
      expect([for (final g in nine) (g.value, g.dotted)],
          [(NoteValue.half, false), (NoteValue.sixteenth, false)]);
    });

    test('a tied run is tied in a chain: only the ends have one side open', () {
      // 16 + 12 + 1 = 29: whole, dotted half, sixteenth.
      final g = _layout('N29*').glyphs;
      expect(g, hasLength(3));
      expect([for (final x in g) x.tiedFromPrev], [false, true, true]);
      expect([for (final x in g) x.tiedToNext], [true, true, false]);
    });

    test('a note next to a note is not tied: two notes stay two', () {
      final g = _layout('N4* N4*').glyphs;
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
      final g = _layout('R5').glyphs;
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
      final g = _layout('N2mf R2 N2ff N2p N2mp N2f N2pp').glyphs;
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
      final g = _layout('N5f').glyphs;
      expect([for (final x in g) x.dynamic], [PatternDynamic.f, PatternDynamic.f]);
    });

    test('any loudness is carried as any, not dropped', () {
      expect(_only('N4*').dynamic, PatternDynamic.any);
    });
  });

  group('x positions follow the time', () {
    test('a glyph sits at its start in sixteenths times the unit width', () {
      final l = _layout('N2mf R2 N2mf', unitWidth: 10);
      expect([for (final g in l.glyphs) g.startUnit], [0, 2, 4]);
      expect([for (final g in l.glyphs) g.x], [0.0, 20.0, 40.0]);
      expect(l.totalUnits, 6);
      expect(l.width, 60.0);
    });

    test('the pieces of a tied note sit end to end', () {
      final l = _layout('N5* R1 N1*', unitWidth: 10);
      expect([for (final g in l.glyphs) g.startUnit], [0, 4, 5, 6]);
      expect([for (final g in l.glyphs) g.x], [0.0, 40.0, 50.0, 60.0]);
      expect([for (final g in l.glyphs) g.entryIndex], [0, 0, 1, 2]);
      expect(l.totalUnits, 7);
    });

    test('leading and trailing rests keep their place and count', () {
      final l = _layout('R4 N4* R2', unitWidth: 8);
      expect(l.glyphs.map((g) => g.x), [0.0, 32.0, 64.0]);
      expect(l.totalUnits, 10);
      expect(l.width, 80.0);
    });

    test('the default unit width is positive', () {
      final l = ScoreLayout.of([_e('N4*'), _e('R4')]);
      expect(l.unitWidth, greaterThan(0));
      expect(l.glyphs[1].x, 4 * l.unitWidth);
    });
  });

  test('no entries gives no glyphs and no width', () {
    final l = ScoreLayout.of(const []);
    expect(l.glyphs, isEmpty);
    expect(l.totalUnits, 0);
    expect(l.width, 0.0);
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
