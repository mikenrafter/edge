// A haptic pattern drawn as one line of music: a single pitch, so every note
// sits on the same staff line; note values are the beats' lengths and rests
// are the gaps; dynamics (mp, mf, f, ff) are written under the notes. The app
// logo stands where the clef would be.
//
// The logo is an SVG (flutter_svg is a dependency). The rebrand is pending, so
// the asset path is one constant to swap. The layout is ScoreLayout (pure); this
// file only paints it.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../gestures/pattern_transcript.dart';
import '../haptics/score_layout.dart';
import '../l10n/app_localizations.dart';
import '../notify/buzz_sequence.dart';
import 'theme.dart';

/// The logo drawn in place of a clef. Replace this file for the rebrand.
const String kClefLogoAsset = 'assets/brand/clef_logo.svg';

const double _kStaffHeight = 30;
const double _kDynamicsHeight = 16;

/// Paints the staff line, the notes, rests, ties and dots of [layout].
class HapticScorePainter extends CustomPainter {
  const HapticScorePainter(this.layout, {required this.ink});

  final ScoreLayout layout;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = ink.withValues(alpha: .35)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);

    final w = layout.unitWidth;
    final r = (w * .9).clamp(2.0, 3.5);
    final stroke = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = ink;
    final tie = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    ScoreGlyph? prev;
    for (final g in layout.glyphs) {
      final cx = g.x + r;
      if (g.rest) {
        _rest(canvas, g, cx, y, r, stroke, fill);
      } else {
        final head = Rect.fromCenter(
            center: Offset(cx, y), width: r * 2.2, height: r * 1.6);
        final open = g.value == NoteValue.half || g.value == NoteValue.whole;
        canvas.drawOval(head, open ? stroke : fill);
        if (g.value != NoteValue.whole) {
          final stemX = cx + r * 1.1;
          final top = y - r * 4.5;
          canvas.drawLine(Offset(stemX, y), Offset(stemX, top), stroke);
          final flags = g.value == NoteValue.sixteenth
              ? 2
              : g.value == NoteValue.eighth
                  ? 1
                  : 0;
          for (var i = 0; i < flags; i++) {
            final fy = top + i * r * 1.1;
            canvas.drawLine(
                Offset(stemX, fy), Offset(stemX + r * 1.6, fy + r * 1.4), stroke);
          }
        }
        if (g.dotted) {
          canvas.drawCircle(Offset(cx + r * 2, y - r * .3), 1.1, fill);
        }
        if (g.tiedFromPrev && prev != null) {
          final from = prev.x + r;
          final path = Path()
            ..moveTo(from, y + r)
            ..quadraticBezierTo((from + cx) / 2, y + r * 3, cx, y + r);
          canvas.drawPath(path, tie);
        }
      }
      prev = g;
    }
  }

  void _rest(Canvas canvas, ScoreGlyph g, double cx, double y, double r,
      Paint stroke, Paint fill) {
    switch (g.value) {
      case NoteValue.whole:
        canvas.drawRect(Rect.fromLTWH(cx - r, y, r * 2, r * .8), fill);
      case NoteValue.half:
        canvas.drawRect(Rect.fromLTWH(cx - r, y - r * .8, r * 2, r * .8), fill);
      default:
        final n = g.value == NoteValue.quarter ? 3 : 2;
        final path = Path()..moveTo(cx - r * .6, y - r * 2);
        for (var i = 1; i <= n; i++) {
          path.lineTo(cx + (i.isOdd ? r * .6 : -r * .6), y - r * 2 + i * r * 1.3);
        }
        canvas.drawPath(path, stroke);
    }
    if (g.dotted) {
      canvas.drawCircle(Offset(cx + r * 1.6, y - r * .3), 1.1, fill);
    }
  }

  @override
  bool shouldRepaint(HapticScorePainter old) =>
      old.layout != layout || old.ink != ink;
}

class HapticScore extends StatelessWidget {
  const HapticScore(this.pattern, {super.key, this.unitMs = 125});

  final BuzzSequence pattern;

  /// Milliseconds per sixteenth, for the spoken length.
  final int unitMs;

  // "1.5", "2", "0.75": up to two decimals, none that are zero.
  static String _seconds(int ms) {
    final s = (ms / 1000).toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _label(AppLocalizations? l, List<PatternEntry> entries, int units) {
    final notes = entries.where((e) => e.note).length;
    final ms = units * unitMs;
    final notesText = l?.hapticScoreNotes(notes) ??
        (notes == 1 ? '1 note' : '$notes notes');
    final lengthText = ms == 1000
        ? (l?.hapticScoreOneSecond ?? '1 second')
        : (l?.hapticScoreSeconds(_seconds(ms)) ?? '${_seconds(ms)} seconds');
    return l?.hapticScoreSemantics(notesText, lengthText) ??
        '$notesText, $lengthText';
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final entries = scoreEntriesOf(pattern, unitMs: unitMs);
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _label(
        AppLocalizations.of(context),
        entries,
        entries.fold<int>(0, (n, e) => n + e.length),
      ),
      child: Row(
        children: [
          SizedBox(
            key: const ValueKey('haptic-score-clef'),
            width: 20,
            height: _kStaffHeight,
            child: SvgPicture.asset(
              kClefLogoAsset,
              colorFilter: ColorFilter.mode(p.ink2, BlendMode.srcIn),
            ),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final units = entries.fold<int>(0, (n, e) => n + e.length);
              final unitWidth = box.maxWidth.isFinite && units > 0
                  ? (box.maxWidth / units).clamp(2.0, 10.0)
                  : 8.0;
              final layout = ScoreLayout.of(entries, unitWidth: unitWidth);
              return SizedBox(
                height: _kStaffHeight + _kDynamicsHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomPaint(
                      key: const ValueKey('haptic-score-staff'),
                      size: Size(
                        box.maxWidth.isFinite ? box.maxWidth : layout.width,
                        _kStaffHeight,
                      ),
                      painter: HapticScorePainter(layout, ink: p.ink),
                    ),
                    for (final g in layout.glyphs)
                      if (!g.rest &&
                          !g.tiedFromPrev &&
                          g.dynamic != null &&
                          g.dynamic != PatternDynamic.any)
                        Positioned(
                          left: g.x,
                          top: _kStaffHeight,
                          child: Text(g.dynamic!.code,
                              style: F.over.copyWith(color: p.ink3)),
                        ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
