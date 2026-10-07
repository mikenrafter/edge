// A haptic pattern as a line of music: which note value each beat or rest is
// drawn as, and where it sits along the staff. Pure Dart, no Flutter.
//
// One pitch, so a glyph has no height; only its value, its dots, its ties and
// its x matter. A length that is not one note value (5 sixteenths) is split
// into the largest values that fit, greedily, and the notes are tied
// (N5 -> quarter tied to sixteenth). A rest is split the same way and never
// tied. Values by length in sixteenths: 1 sixteenth, 2 eighth, 3 dotted
// eighth, 4 quarter, 6 dotted quarter, 8 half, 12 dotted half, 16 whole.
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
  });

  final bool rest;
  final NoteValue value;
  final bool dotted;

  /// The sixteenths this glyph covers alone (a tied note's pieces add up to
  /// the entry's length).
  final int units;

  /// Sixteenths from the start of the pattern to the start of this glyph.
  final int startUnit;

  /// Left edge, `startUnit * unitWidth`.
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
}

class ScoreLayout {
  const ScoreLayout(this.glyphs, this.totalUnits, this.unitWidth);

  final List<ScoreGlyph> glyphs;

  /// Every entry's length added up, leading and trailing rests included.
  final int totalUnits;
  final double unitWidth;

  /// `totalUnits * unitWidth`.
  double get width => totalUnits * unitWidth;

  /// The glyphs of [notes], in order, [unitWidth] logical pixels per
  /// sixteenth. The glyphs of one entry sit end to end with no gap. An entry
  /// of length 0 or less gives nothing.
  static ScoreLayout of(List<PatternEntry> notes, {double unitWidth = 8}) {
    final glyphs = <ScoreGlyph>[];
    var at = 0;
    for (var i = 0; i < notes.length; i++) {
      final e = notes[i];
      var left = e.length;
      var first = true;
      while (left > 0) {
        final (units, value, dotted) =
            _shapes.firstWhere((s) => s.$1 <= left);
        left -= units;
        glyphs.add(ScoreGlyph(
          rest: !e.note,
          value: value,
          dotted: dotted,
          units: units,
          startUnit: at,
          x: at * unitWidth,
          entryIndex: i,
          dynamic: e.note ? e.dynamic : null,
          tiedFromPrev: e.note && !first,
          tiedToNext: e.note && left > 0,
        ));
        at += units;
        first = false;
      }
    }
    return ScoreLayout(glyphs, at, unitWidth);
  }
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
