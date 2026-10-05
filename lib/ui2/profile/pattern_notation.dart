// The notation widgets of the pattern probe, shared with the
// haptic pattern editor: a length drawn as a note or rest symbol above
// one coloured dash per sixteenth, the entry row of the wheel, and the length,
// Dot and dynamics buttons.

import 'package:flutter/material.dart';

import '../../gestures/pattern_transcript.dart';
import '../ui2.dart';

/// The metronome's four beat colours A, C, D, E. The dot and the dashes both
/// read this, so they cannot drift apart: a sixteenth in beat b uses colour b.
const List<Color> kPatternUnitColours = [C.blue, C.green, C.orange, C.purple];

/// The height of one wheel row.
const double kPatternRowExtent = 52;

const _lengthNames = {
  1: '16th',
  2: 'eighth',
  3: 'dotted eighth',
  4: 'quarter',
  6: 'dotted quarter',
  8: 'half',
  12: 'dotted half',
};

/// What a length button shows; the long name goes in its semantics.
const _lengthShort = {
  1: '16th',
  2: '8th',
  3: '8th.',
  4: '4th',
  6: '4th.',
  8: 'Half',
  12: 'Half.',
};

/// Beat [b]'s colour, at a third of the saturation unless [note].
Color patternBeatColour(int b, {required bool note}) {
  final c = kPatternUnitColours[b % kPatternUnitColours.length];
  if (note) return c;
  final hsl = HSLColor.fromColor(c);
  return hsl.withSaturation(hsl.saturation / 3).toColor();
}

/// Dash [k] (1-based) of a length: the colour of the beat it falls in (four
/// sixteenths to a beat), at a third of the saturation for a rest.
Color _dashColour(int k, bool note) => patternBeatColour((k - 1) ~/ 4, note: note);

/// A length as music: the note or rest symbol above one coloured dash per
/// sixteenth.
class PatternNotation extends StatelessWidget {
  const PatternNotation({super.key, required this.length, required this.note});
  final int length;
  final bool note;

  @override
  Widget build(BuildContext c) {
    final ink = P.of(c).ink;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${_lengthNames[length]} '
              '${note ? 'note' : 'rest'}',
          child: CustomPaint(
            key: const ValueKey('pattern-symbol'),
            size: const Size(24, 28),
            painter: _SymbolPainter(length: length, note: note, color: ink),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A dotted half is twelve dashes: thinner so they fit a button.
            for (var k = 1; k <= length; k++) ...[
              if (k > 1) SizedBox(width: length > 8 ? 1 : 2),
              SizedBox(
                width: length > 8 ? 3 : 4,
                height: S.x1,
                child: DecoratedBox(
                  key: ValueKey('dash-$k'),
                  decoration: BoxDecoration(
                    color: _dashColour(k, note),
                    borderRadius: R.rPill,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Draws a 16th, eighth, quarter or half note, or the matching rest, with a dot
/// after it for the dotted lengths 3, 6 and 12, in a 24 x 28 box. Painted, not a font glyph: Android fonts may not
/// have the music block.
class _SymbolPainter extends CustomPainter {
  const _SymbolPainter({
    required this.length,
    required this.note,
    required this.color,
  });
  final int length;
  final bool note;
  final Color color;

  /// 3, 6 and 12 are the dotted 2, 4 and 8.
  bool get _dotted => length == 3 || length == 6 || length == 12;
  int get _base => _dotted ? length * 2 ~/ 3 : length;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (note) {
      _paintNote(canvas, fill, line);
    } else {
      _paintRest(canvas, fill, line);
    }
  }

  void _paintNote(Canvas canvas, Paint fill, Paint line) {
    const cx = 7.0, cy = 22.0;
    final head = Rect.fromCenter(center: Offset.zero, width: 10, height: 7.4);
    canvas
      ..save()
      ..translate(cx, cy)
      ..rotate(-0.35);
    // A half note's head is hollow; the others are filled.
    canvas.drawOval(head, _base == 8 ? line : fill);
    canvas.restore();
    const stemX = cx + 4.4;
    canvas.drawLine(const Offset(stemX, cy - 1), const Offset(stemX, 2), line);
    // An eighth has one flag, a 16th two.
    if (_base == 2) _flag(canvas, line, stemX, 2.5, 1);
    if (_base == 1) {
      _flag(canvas, line, stemX, 2.5, .6);
      _flag(canvas, line, stemX, 9, .6);
    }
    if (_dotted) canvas.drawCircle(const Offset(cx + 11, cy - 1), 1.7, fill);
  }

  void _flag(Canvas canvas, Paint line, double x, double y, double k) {
    canvas.drawPath(
      Path()
        ..moveTo(x, y)
        ..cubicTo(x + 2, y + 6.5 * k, x + 9, y + 7.5 * k, x + 5, y + 15.5 * k),
      line,
    );
  }

  void _paintRest(Canvas canvas, Paint fill, Paint line) {
    switch (_base) {
      case 1:
        // A 16th rest: two dots with hooks on a slanted stem.
        canvas.drawCircle(const Offset(8, 9), 2.3, fill);
        canvas.drawCircle(const Offset(6, 16), 2.3, fill);
        canvas.drawPath(
          Path()
            ..moveTo(8, 9)
            ..quadraticBezierTo(12, 11, 15, 5)
            ..lineTo(8, 27)
            ..moveTo(6, 16)
            ..quadraticBezierTo(10, 18, 13, 12),
          line,
        );
      case 2:
        // An eighth rest: a dot with a flag on a slanted stem.
        canvas.drawCircle(const Offset(8, 9), 2.3, fill);
        canvas.drawPath(
          Path()
            ..moveTo(8, 9)
            ..quadraticBezierTo(12, 11, 15, 5)
            ..lineTo(9, 25),
          line,
        );
        if (_dotted) canvas.drawCircle(const Offset(19, 17), 1.7, fill);
      case 8:
        // A half rest: a block sitting on the line.
        canvas.drawLine(const Offset(3, 15), const Offset(21, 15), line);
        canvas.drawRect(const Rect.fromLTRB(7, 9.5, 17, 14.5), fill);
        if (_dotted) canvas.drawCircle(const Offset(20.5, 12), 1.7, fill);
      default:
        // A quarter rest: the zigzag.
        canvas.drawPath(
          Path()
            ..moveTo(8, 3)
            ..lineTo(14, 10)
            ..lineTo(9, 15.5)
            ..lineTo(14, 21)
            ..cubicTo(8, 20, 7, 27, 12.5, 26),
          line,
        );
        if (_dotted) canvas.drawCircle(const Offset(19, 11), 1.7, fill);
    }
  }

  @override
  bool shouldRepaint(_SymbolPainter o) =>
      o.length != length || o.note != note || o.color != color;
}

/// One footer button: writes [length] as the kind of entry it shows.
class PatternLengthButton extends StatelessWidget {
  const PatternLengthButton({
    super.key,
    required this.length,
    required this.note,
    required this.onTap,
  });
  final int length;
  final bool note;

  /// Null: the button is disabled (a 16th while the Dot is on).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    // The symbol names the button ("eighth rest"); the short text is for eyes.
    return Pressable(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? .4 : 1,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: S.x1, horizontal: 2),
          decoration: BoxDecoration(
            color: p.wash(note ? C.blue : C.n400),
            borderRadius: R.rMd,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PatternNotation(length: length, note: note),
              const SizedBox(height: S.x1),
              ExcludeSemantics(
                child: Text(
                  _lengthShort[length]!,
                  style: F.cap.copyWith(
                    color: p.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Dot toggle beside the length buttons: the next length is 3/2 as long.
/// Outlined and washed while on; it fills the row's height like its neighbours.
class PatternDotButton extends StatelessWidget {
  const PatternDotButton({super.key, required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: 'Dot',
        child: Container(
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? p.wash(C.blue) : p.card,
            borderRadius: R.rMd,
            border: Border.all(
              color: selected ? C.blue : p.ink3,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.ink),
              ),
              const SizedBox(height: S.x1),
              Text(
                'Dot',
                style: F.cap.copyWith(
                  color: p.ink,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One dynamics button. The chosen one is outlined and washed; while the toggle
/// is on Rest they all look faded, but they still work (the choice is kept for
/// the next note).
class PatternDynamicButton extends StatelessWidget {
  const PatternDynamicButton({
    super.key,
    required this.dynamic,
    required this.selected,
    required this.dim,
    required this.onTap,
  });
  final PatternDynamic dynamic;
  final bool selected;
  final bool dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: dynamic == PatternDynamic.any
            ? 'Dynamic any loudness'
            : 'Dynamic ${dynamic.name}',
        child: Opacity(
          opacity: dim ? .45 : 1,
          child: Container(
            width: double.infinity,
            height: S.tap,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? p.wash(C.blue) : p.card,
              borderRadius: R.rMd,
              border: Border.all(
                color: selected ? C.blue : p.ink3,
                width: selected ? 2 : 1,
              ),
            ),
            child: Text(
              dynamic.code,
              style: F.body.copyWith(
                color: p.ink,
                fontWeight: FontWeight.w700,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One wheel row: kind, index, the notation. [length] null is the empty next
/// slot. [playing] marks the entry the march is on.
class PatternEntryRow extends StatelessWidget {
  const PatternEntryRow({
    super.key,
    required this.index,
    required this.note,
    required this.length,
    required this.dynamic,
    required this.selected,
    required this.playing,
  });
  final int index;
  final bool note;
  final int? length;
  final PatternDynamic? dynamic;
  final bool selected;
  final bool playing;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final kind = note ? 'Note' : 'Rest';
    final label = length == null ? 'Next entry ($kind)' : kind;
    final said = length == null
        ? label
        : '${_lengthNames[length]} ${note ? 'note' : 'rest'}'
              '${dynamic == null ? '' : dynamic == PatternDynamic.any ? ', any loudness' : ' ${dynamic!.name}'}, entry ${index + 1}';
    return Semantics(
      selected: selected,
      label: playing ? 'playing entry ${index + 1}, $said' : said,
      excludeSemantics: true,
      child: Container(
        key: playing ? const ValueKey('pattern-playhead') : null,
        margin: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x1),
        padding: const EdgeInsets.symmetric(horizontal: S.x4),
        decoration: BoxDecoration(
          color: playing || selected
              ? p.wash(note ? C.blue : C.n400)
              : p.card,
          borderRadius: R.rMd,
          border: playing
              ? Border.all(color: C.blue, width: 2)
              : selected
              ? Border.all(color: p.ink3)
              : null,
        ),
        child: Row(
          children: [
            SizedBox(
              width: S.x8,
              child: Text('${index + 1}', style: F.cap.copyWith(color: p.ink3)),
            ),
            Expanded(
              child: Text(
                label,
                style: F.body.copyWith(
                  color: length == null ? p.ink2 : p.ink,
                  fontWeight: selected || playing
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (dynamic != null) ...[
              Text(
                dynamic!.code,
                style: F.body.copyWith(
                  color: p.ink,
                  fontWeight: FontWeight.w700,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(width: S.x3),
            ],
            if (length != null) PatternNotation(length: length!, note: note),
          ],
        ),
      ),
    );
  }
}
