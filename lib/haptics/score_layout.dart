// A haptic pattern as a wrapped score: which note value each beat or rest is
// drawn as, and where it sits. Pure Dart, no Flutter.
//
// 4/4 on a three-line staff, one pitch: a rest sits on the middle line, a note
// in the space between the middle and the bottom line. A bar line every 16
// sixteenths, a double bar at the start and at the end. A length that is not
// one note value (5 sixteenths), or one that crosses a bar line, is split into
// the largest values that fit, greedily, and the notes are tied
// (N5 -> quarter tied to sixteenth); a rest is split the same way and never
// tied. Values by length in sixteenths: 1 sixteenth, 2 eighth, 3 dotted
// eighth, 4 quarter, 6 dotted quarter, 8 half, 12 dotted half, 16 whole.
//
// Space: glyphs keep a minimum gap and are never stretched across the row.
// Every measure is as wide as the neediest one needs at the minimum gap, so
// the width of a measure does not depend on the row; what does not fit wraps by
// whole measures onto further lines, all indented like the first so measures
// line up down the page.
//
import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';
import 'tap_notes.dart';

/// The undotted note values, by their length in sixteenths.
enum NoteValue {
  sixteenth(1),
  eighth(2),
  quarter(4),
  half(8),
  whole(16);

  const NoteValue(this.units);
  final int units;
}

/// One drawn symbol: a note head or a rest.
class ScoreGlyph {
  const ScoreGlyph({
    required this.rest,
    required this.value,
    required this.dotted,
    required this.units,
    required this.startUnit,
    required this.x,
    required this.entryIndex,
    this.dynamic,
    this.tiedFromPrev = false,
    this.tiedToNext = false,
    this.width = 0,
    this.y = 0,
    this.top = 0,
    this.bottom = 0,
    this.line = 0,
    this.measure = 0,
    this.command,
  });

  final bool rest;
  final NoteValue value;
  final bool dotted;

  /// The sixteenths this glyph covers alone (a tied note's pieces add up to
  /// the entry's length).
  final int units;

  /// Sixteenths from the start of the pattern to the start of this glyph.
  final int startUnit;

  /// Left edge.
  final double x;

  /// The index of the input entry this glyph was cut from.
  final int entryIndex;

  /// The entry's dynamic; null for a rest. Carried on every piece of a tied
  /// note ([PatternDynamic.any] is carried as is; drawing it is up to the
  /// widget).
  final PatternDynamic? dynamic;

  /// This note continues the one before it (draw no dynamic here).
  final bool tiedFromPrev;

  /// This note is tied to the one after it.
  final bool tiedToNext;

  // The fields below are what [ScoreLayout.fit] fills in (the display
  // overhaul). They are all in the layout's own coordinates: x to the right,
  // y down from the top of the first line, logical pixels.

  /// Horizontal extent of the glyph, from [x]: the head (plus its dot, plus
  /// room for a written dynamic), never less than [ScoreMetrics.glyphWidth].
  final double width;

  /// The vertical centre of the head or rest: the middle staff line for a
  /// rest, the space between the middle and the bottom line for a note.
  final double y;

  /// The vertical extent of the glyph (stem and flags included).
  final double top, bottom;

  /// The index of the staff line and of the measure (counted over the whole
  /// score, not per line) the glyph sits in.
  final int line, measure;

  /// The band command that plays this note (an index into the commands a
  /// delivery writes), or null: a rest, a note no command plays, or a layout
  /// made without commands. Every piece of a tied or bar-split note carries
  /// the entry's command.
  final int? command;
}

/// The sizes [ScoreLayout.fit] works in, in logical pixels. One place for
/// them, so the layout, the painter and the tests agree.
class ScoreMetrics {
  const ScoreMetrics({
    this.glyphWidth = 10,
    this.dotWidth = 5,
    this.dynamicWidth = 16,
    this.minGap = 5,
    this.measurePad = 6,
    this.doubleBarWidth = 6,
    this.leadWidth = 44,
    this.staffSpace = 6,
    this.lineHeight = 44,
  });

  /// Width of an undotted note head or rest.
  final double glyphWidth;

  /// What a dot adds to the glyph it follows.
  final double dotWidth;

  /// Width of a written dynamic ("mf"); a note that writes one is at least
  /// this wide, so the labels never touch.
  final double dynamicWidth;

  /// The least clear space between two glyphs of one measure.
  final double minGap;

  /// The least clear space between a bar line and its nearest glyph.
  final double measurePad;

  /// Width of a double bar (two strokes and the gap between them).
  final double doubleBarWidth;

  /// Room at the left of line 1 for the "~x.xs" text; every later line keeps
  /// the same indent so measures align down the page.
  final double leadWidth;

  /// Distance between two staff lines.
  final double staffSpace;

  /// Height of one staff line's band: the three lines, stems above, the
  /// dynamics under.
  final double lineHeight;
}

/// One measure: 16 sixteenths of 4/4 (the last may hold fewer).
class ScoreMeasure {
  const ScoreMeasure({
    required this.index,
    required this.x,
    required this.width,
    required this.startUnit,
    required this.glyphs,
  });

  /// Counted over the whole score from 0.
  final int index;

  /// The left bar line; the right one is at `x + width`.
  final double x;
  final double width;
  final int startUnit;
  final List<ScoreGlyph> glyphs;
}

/// One staff line of the wrapped score.
class ScoreLine {
  const ScoreLine({
    required this.index,
    required this.top,
    required this.staffY,
    required this.left,
    required this.right,
    required this.measures,
    required this.startDoubleBar,
    required this.endDoubleBar,
  });

  final int index;

  /// Top of the line's band; the band is `ScoreMetrics.lineHeight` tall.
  final double top;

  /// The y of the top, middle and bottom staff line.
  final List<double> staffY;

  /// Where the three staff lines start and end.
  final double left, right;
  final List<ScoreMeasure> measures;

  /// The double bar that opens the score: line 0 only.
  final bool startDoubleBar;

  /// The double bar that closes the score: the last line only.
  final bool endDoubleBar;
}

class ScoreLayout {
  const ScoreLayout._({
    required this.glyphs,
    required this.lines,
    required this.measures,
    required this.totalUnits,
    required this.measureWidth,
    required this.metrics,
    required this.width,
  });

  /// Every glyph, in time order.
  final List<ScoreGlyph> glyphs;

  /// The lines, top to bottom; none for an empty score.
  final List<ScoreLine> lines;

  /// Every measure, in order.
  final List<ScoreMeasure> measures;

  /// Every entry's length added up, leading and trailing rests included.
  final int totalUnits;

  /// The width of every measure.
  final double measureWidth;
  final ScoreMetrics metrics;

  /// The width the layout was asked to fit.
  final double width;

  /// The right edge of the furthest content; never more than [width] unless
  /// not even one measure fits.
  double get contentWidth =>
      lines.fold(0.0, (w, l) => l.right > w ? l.right : w);

  /// All the lines stacked.
  double get height => lines.length * metrics.lineHeight;

  /// The wrapped score of [notes] in [width] logical pixels. Pure: the same
  /// entries, width and metrics always give the same layout.
  ///
  /// A measure needs `2 * measurePad + sum(glyph widths) + (n - 1) * minGap`;
  /// every measure is as wide as the neediest one ([measureWidth]), whatever
  /// [width] is. A line holds as many whole measures as fit between the indent
  /// ([ScoreMetrics.leadWidth] plus the start double bar) and [width], leaving
  /// room for the end double bar (so every line but the last holds the same
  /// number), at least one. An entry that crosses a bar line is cut there, its
  /// notes tied. [commands] is the band command of each entry (see
  /// `bandCommandOfEntries`), put on the notes' glyphs.
  static ScoreLayout fit(
    List<PatternEntry> notes, {
    required double width,
    ScoreMetrics metrics = const ScoreMetrics(),
    List<int?>? commands,
  }) {
    final m = metrics;
    // 1. Cut every entry into glyphs: at bar lines first, then into values.
    final cut = <_Cut>[];
    var at = 0;
    for (var i = 0; i < notes.length; i++) {
      final e = notes[i];
      var left = e.length;
      var first = true;
      while (left > 0) {
        final room = _kMeasureUnits - at % _kMeasureUnits;
        var chunk = left < room ? left : room;
        while (chunk > 0) {
          final (units, value, dotted) =
              _shapes.firstWhere((s) => s.$1 <= chunk);
          chunk -= units;
          left -= units;
          cut.add(_Cut(
            entry: i,
            e: e,
            units: units,
            value: value,
            dotted: dotted,
            start: at,
            fromPrev: e.note && !first,
            toNext: e.note && left > 0,
          ));
          at += units;
          first = false;
        }
      }
    }
    if (cut.isEmpty) {
      return ScoreLayout._(
        glyphs: const [],
        lines: const [],
        measures: const [],
        totalUnits: 0,
        measureWidth: 0,
        metrics: m,
        width: width,
      );
    }
    // A note writes its dynamic once, under its first piece (any loudness
    // writes nothing).
    bool writes(_Cut c) =>
        c.e.note &&
        !c.fromPrev &&
        c.e.dynamic != null &&
        c.e.dynamic != PatternDynamic.any;
    double widthOf(_Cut c) {
      final base = m.glyphWidth + (c.dotted ? m.dotWidth : 0);
      return writes(c) && m.dynamicWidth > base ? m.dynamicWidth : base;
    }

    // 2. The measures, and the one width they all get.
    final byMeasure = <List<_Cut>>[];
    for (final c in cut) {
      final k = c.start ~/ _kMeasureUnits;
      if (k == byMeasure.length) byMeasure.add([]);
      byMeasure[k].add(c);
    }
    double need(List<_Cut> ms) =>
        2 * m.measurePad +
        ms.fold<double>(0, (n, c) => n + widthOf(c)) +
        (ms.length - 1) * m.minGap;
    final mw = byMeasure.map(need).reduce((a, b) => a > b ? a : b);

    // 3. Wrap by whole measures. The count is chosen so a line could also be
    // the last one, with the end double bar after it.
    final firstX = m.leadWidth + m.doubleBarWidth;
    var per = ((width - firstX - m.doubleBarWidth) / mw).floor();
    if (per < 1) per = 1;

    final glyphs = <ScoreGlyph>[];
    final measures = <ScoreMeasure>[];
    final lines = <ScoreLine>[];
    final lineCount = (byMeasure.length + per - 1) ~/ per;
    final s = m.staffSpace;
    for (var li = 0; li < lineCount; li++) {
      final top = li * m.lineHeight;
      final staffY = [top + 3.3 * s, top + 4.3 * s, top + 5.3 * s];
      final lineMeasures = <ScoreMeasure>[];
      for (var k = li * per; k < byMeasure.length && k < (li + 1) * per; k++) {
        final x0 = firstX + (k - li * per) * mw;
        final ms = byMeasure[k];
        final extra = mw - need(ms);
        final totalU = ms.fold<int>(0, (n, c) => n + c.units);
        var x = x0 + m.measurePad;
        final mGlyphs = <ScoreGlyph>[];
        for (final c in ms) {
          final w = widthOf(c);
          final note = c.e.note;
          final y = note ? staffY[1] + s / 2 : staffY[1];
          final g = ScoreGlyph(
            rest: !note,
            value: c.value,
            dotted: c.dotted,
            units: c.units,
            startUnit: c.start,
            x: x,
            entryIndex: c.entry,
            dynamic: note ? c.e.dynamic : null,
            tiedFromPrev: c.fromPrev,
            tiedToNext: c.toNext,
            width: w,
            y: y,
            top: note ? y - 3.5 * s : y - 1.6 * s,
            // Under a note: its head, or the label of its dynamic.
            bottom: note ? staffY[2] + (writes(c) ? 2 * s : s) : y + 1.6 * s,
            line: li,
            measure: k,
            command: note && commands != null && c.entry < commands.length
                ? commands[c.entry]
                : null,
          );
          mGlyphs.add(g);
          glyphs.add(g);
          // The measure's spare room goes to the glyphs by their length.
          x += w + m.minGap + extra * c.units / totalU;
        }
        lineMeasures.add(ScoreMeasure(
          index: k,
          x: x0,
          width: mw,
          startUnit: k * _kMeasureUnits,
          glyphs: mGlyphs,
        ));
      }
      measures.addAll(lineMeasures);
      final last = li == lineCount - 1;
      lines.add(ScoreLine(
        index: li,
        top: top,
        staffY: staffY,
        left: 0,
        right: lineMeasures.last.x +
            mw +
            (last ? m.doubleBarWidth : 0),
        measures: lineMeasures,
        startDoubleBar: li == 0,
        endDoubleBar: last,
      ));
    }
    return ScoreLayout._(
      glyphs: glyphs,
      lines: lines,
      measures: measures,
      totalUnits: at,
      measureWidth: mw,
      metrics: m,
      width: width,
    );
  }
}

/// Sixteenths in a 4/4 measure.
const int _kMeasureUnits = 16;

// One glyph before it has a place.
class _Cut {
  const _Cut({
    required this.entry,
    required this.e,
    required this.units,
    required this.value,
    required this.dotted,
    required this.start,
    required this.fromPrev,
    required this.toNext,
  });
  final int entry;
  final PatternEntry e;
  final int units;
  final NoteValue value;
  final bool dotted;
  final int start;
  final bool fromPrev;
  final bool toNext;
}

// Length, value and dot, largest first: what an entry is cut into.
const List<(int, NoteValue, bool)> _shapes = [
  (16, NoteValue.whole, false),
  (12, NoteValue.half, true),
  (8, NoteValue.half, false),
  (6, NoteValue.quarter, true),
  (4, NoteValue.quarter, false),
  (3, NoteValue.eighth, true),
  (2, NoteValue.eighth, false),
  (1, NoteValue.sixteenth, false),
];

/// The notes and rests that draw [s]: its `notes` code when it has one, else
/// the taps as notes (any loudness, [unitMs] per sixteenth).
List<PatternEntry> scoreEntriesOf(BuzzSequence s, {int unitMs = 125}) {
  final code = s.notes;
  if (code != null) {
    try {
      return PatternTranscript.parseCode(code).entries;
    } on FormatException {
      // Fall through to the taps: a score is drawn from what can be read.
    } on ArgumentError {
      // Same.
    }
  }
  return notesFromTaps(s, unitMs: unitMs);
}
