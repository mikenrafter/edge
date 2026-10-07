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
// STUB (red phase): everything here throws until implemented.

import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';

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
  double get width => throw UnimplementedError('ScoreLayout.width');

  /// The glyphs of [notes], in order, [unitWidth] logical pixels per
  /// sixteenth. The glyphs of one entry sit end to end with no gap. An entry
  /// of length 0 or less gives nothing.
  static ScoreLayout of(List<PatternEntry> notes, {double unitWidth = 8}) =>
      throw UnimplementedError('ScoreLayout.of');
}

/// The notes and rests that draw [s]: its `notes` code when it has one, else
/// the taps as notes (any loudness, [unitMs] per sixteenth).
List<PatternEntry> scoreEntriesOf(BuzzSequence s, {int unitMs = 125}) =>
    throw UnimplementedError('scoreEntriesOf');
