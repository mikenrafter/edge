// A haptic pattern drawn as music: a three-line staff, 4/4, one pitch, so
// every note sits in the same space and every rest on the middle line. Note
// values are the beats' lengths and rests are the gaps; dynamics (mp, mf, f,
// ff) are written under the notes. A double bar opens the score and another
// closes it; what does not fit the row wraps by whole measures.
//
// Colour is command: every band command the pattern is sent as has its own
// colour, cycling a palette, and the notes one command plays share it, so the
// wearer sees where one command ends and the next begins (a variable wait sits
// there) and how many commands the pattern spends. Rests stay ink. Which
// command plays which note is decided in haptics/haptic_player.dart
// (bandCommandOfEntries), the same plan that is sent and budgeted; this file
// only paints it.
//
// Where the clef would be, the pattern's length is written as "~x.xs". The
// layout is ScoreLayout (pure); this file paints it.

import 'package:flutter/material.dart';

import '../gestures/pattern_transcript.dart';
import '../haptics/haptic_compiler.dart' show maxRuntimeFor;
import '../haptics/haptic_player.dart'
    show bandCommandOfEntries, scoreDurationMs;
import '../haptics/haptic_profile.dart';
import '../haptics/score_layout.dart';
import '../l10n/app_localizations.dart';
import '../notify/buzz_sequence.dart';
import 'theme.dart';

/// The colour of band command [command] (0 based) on theme [p]: a palette
/// that cycles, every entry at least 3:1 against the card in light and dark.
/// Consecutive commands, and a command and the one after a full cycle, differ.
Color commandColor(int command, P p) {
  final accents = _kCommandAccents;
  return p.on(accents[command % accents.length]);
}

// Hues far apart, so neighbours never look alike. p.on() brings each to a
// readable contrast on the card in light and dark.
const List<Color> _kCommandAccents = [
  C.blue,
  C.orange,
  C.green,
  C.purple,
  C.pink,
  C.teal,
  C.yellow,
  C.red,
];

/// Paints the staff lines, bars, notes, rests, ties and dots of [layout].
class HapticScorePainter extends CustomPainter {
  const HapticScorePainter(this.layout,
      {required this.ink, required this.commandColor});

  final ScoreLayout layout;
  final Color ink;

  /// The colour of command n; notes with no command are drawn in [ink].
  final Color Function(int command) commandColor;

  Color _of(ScoreGlyph g) =>
      g.command == null ? ink : commandColor(g.command!);

  @override
  void paint(Canvas canvas, Size size) {
    final m = layout.metrics;
    final s = m.staffSpace;
    // Heads shrink with the score when a measure did not fit at full size.
    final r = s * .55 * layout.scale;
    final lineP = Paint()
      ..color = ink.withValues(alpha: .35)
      ..strokeWidth = 1;
    final bar = Paint()
      ..color = ink.withValues(alpha: .6)
      ..strokeWidth = 1;
    final heavy = Paint()
      ..color = ink.withValues(alpha: .6)
      ..strokeWidth = 2.4;

    for (final line in layout.lines) {
      // The staff starts after the room kept for the length, on every line.
      final from = line.left + m.leadWidth;
      for (final y in line.staffY) {
        canvas.drawLine(Offset(from, y), Offset(line.right, y), lineP);
      }
      final top = line.staffY.first, bottom = line.staffY.last;
      void vbar(double x, Paint p) =>
          canvas.drawLine(Offset(x, top), Offset(x, bottom), p);
      final first = line.measures.first;
      if (line.startDoubleBar) {
        // Thin then thick, just before the first measure.
        vbar(first.x - m.doubleBarWidth + 1, bar);
        vbar(first.x - 1.2, heavy);
      } else {
        vbar(first.x, bar);
      }
      for (final ms in line.measures) {
        final x = ms.x + ms.width;
        if (line.endDoubleBar && ms == line.measures.last) {
          vbar(x, bar);
          vbar(x + m.doubleBarWidth - 1.2, heavy);
        } else {
          vbar(x, bar);
        }
      }
    }

    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    double headX(ScoreGlyph g) =>
        g.x + (g.width - (g.dotted ? m.dotWidth * layout.scale : 0)) / 2;

    final glyphs = layout.glyphs;
    for (var i = 0; i < glyphs.length; i++) {
      final g = glyphs[i];
      final cx = headX(g);
      final y = g.y;
      if (g.rest) {
        _rest(canvas, g, cx, y, r, stroke..color = ink, fill..color = ink);
        continue;
      }
      final color = _of(g);
      stroke.color = color;
      fill.color = color;
      final head =
          Rect.fromCenter(center: Offset(cx, y), width: r * 2.2, height: r * 1.6);
      final open = g.value == NoteValue.half || g.value == NoteValue.whole;
      canvas.drawOval(head, open ? stroke : fill);
      if (g.value != NoteValue.whole) {
        final stemX = cx + r * 1.1;
        final stemTop = y - 3.5 * s;
        canvas.drawLine(Offset(stemX, y), Offset(stemX, stemTop), stroke);
        final flags = g.value == NoteValue.sixteenth
            ? 2
            : g.value == NoteValue.eighth
                ? 1
                : 0;
        for (var f = 0; f < flags; f++) {
          final fy = stemTop + f * r * 1.1;
          canvas.drawLine(
              Offset(stemX, fy), Offset(stemX + r * 1.6, fy + r * 1.4), stroke);
        }
      }
      if (g.dotted) {
        canvas.drawCircle(Offset(cx + r * 2, y - r * .3), 1.1, fill);
      }
      if (g.tiedToNext) {
        // The tie under the heads: to the next piece, or to the end of the
        // line when that one starts the next line.
        final next = i + 1 < glyphs.length ? glyphs[i + 1] : null;
        final toX = next != null && next.line == g.line
            ? headX(next)
            : layout.lines[g.line].right - 2;
        _tie(canvas, cx, toX, y + r, r, stroke);
      }
      if (g.tiedFromPrev && i > 0 && glyphs[i - 1].line != g.line) {
        // The other half of a tie that wrapped: from the line's start.
        _tie(canvas, layout.lines[g.line].measures.first.x + 2, cx, y + r, r,
            stroke);
      }
    }
  }

  void _tie(Canvas canvas, double from, double to, double y, double r,
      Paint stroke) {
    final path = Path()
      ..moveTo(from, y)
      ..quadraticBezierTo((from + to) / 2, y + r * 2, to, y);
    canvas.drawPath(path, stroke);
  }

  void _rest(Canvas canvas, ScoreGlyph g, double cx, double y, double r,
      Paint stroke, Paint fill) {
    switch (g.value) {
      case NoteValue.whole:
        // Hangs from the line above the middle one.
        canvas.drawRect(Rect.fromLTWH(cx - r, y - r * 1.6, r * 2, r * .8), fill);
      case NoteValue.half:
        // Sits on the middle line.
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
  const HapticScore(this.pattern,
      {super.key, this.unitMs = 125, this.profile, this.allowLong = false});

  final BuzzSequence pattern;

  /// The connected band's haptic vocabulary; null on a 4.0. With it the notes
  /// are coloured by the command that plays them (`bandCommandOfEntries`).
  final HapticDeviceProfile? profile;

  /// Whether the 10 s cap is lifted (it decides how a long rhythm is sent).
  final bool allowLong;

  /// Milliseconds per sixteenth of the notes a tapped rhythm is drawn as (the
  /// printed length is not from this: it is how long the rhythm plays).
  final int unitMs;

  // "1.5", "2", "0.75": up to two decimals, none that are zero.
  static String _seconds(int ms) {
    final s = (ms / 1000).toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  // "2.0": the one decimal the printed length has.
  static String _tenths(int ms) => (ms / 1000).toStringAsFixed(1);

  String _label(AppLocalizations? l, List<PatternEntry> entries, int ms) {
    final notes = entries.where((e) => e.note).length;
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
    final l = AppLocalizations.of(context);
    final entries = scoreEntriesOf(pattern, unitMs: unitMs);
    // One duration for the printed and the spoken length, and the commands the
    // notes are coloured by: both from the plan this band is actually sent
    // (its device, its cap), see haptics/haptic_player.dart.
    final cap = maxRuntimeFor(allowLong: allowLong);
    final ms = scoreDurationMs(pattern, profile, maxRuntime: cap);
    final commands =
        bandCommandOfEntries(pattern, entries, profile, maxRuntime: cap);

    // The printed length is a label on a drawing, not running text: it grows
    // with the text size up to a point, then the drawing keeps its size.
    final lengthText =
        l?.hapticScoreLength(_tenths(ms)) ?? '~${_tenths(ms)}s';
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    final lengthStyle = F.over.copyWith(color: p.ink2);
    final measured = TextPainter(
      text: TextSpan(text: lengthText, style: lengthStyle),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final metrics = ScoreMetrics(leadWidth: measured.width + S.x2);
    measured.dispose();

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: _label(l, entries, ms),
      child: LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : 600.0;
        final layout = ScoreLayout.fit(entries,
            width: width, metrics: metrics, commands: commands);
        final s = metrics.staffSpace;
        return SizedBox(
          width: box.maxWidth.isFinite ? width : layout.contentWidth,
          height: layout.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CustomPaint(
                key: const ValueKey('haptic-score-staff'),
                size: Size(width, layout.height),
                painter: HapticScorePainter(
                  layout,
                  ink: p.ink,
                  commandColor: (c) => commandColor(c, p),
                ),
              ),
              if (layout.lines.isNotEmpty)
                Positioned(
                  left: 0,
                  top: layout.lines.first.staffY[1] - 2 * s,
                  width: metrics.leadWidth - S.x1,
                  height: 4 * s,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      lengthText,
                      maxLines: 1,
                      softWrap: false,
                      textScaler: scaler,
                      style: lengthStyle,
                    ),
                  ),
                ),
              for (final g in layout.glyphs)
                if (!g.rest &&
                    !g.tiedFromPrev &&
                    g.dynamic != null &&
                    g.dynamic != PatternDynamic.any)
                  Positioned(
                    left: g.x,
                    top: layout.lines[g.line].staffY[2] + s * .2,
                    width: g.width,
                    height: s * 1.8,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(g.dynamic!.code,
                          textScaler: TextScaler.noScaling,
                          style: F.over.copyWith(color: p.ink3)),
                    ),
                  ),
            ],
          ),
        );
      }),
    );
  }
}
