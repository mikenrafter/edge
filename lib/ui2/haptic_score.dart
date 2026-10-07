// A haptic pattern drawn as one line of music: a single pitch, so every note
// sits on the same staff line; note values are the beats' lengths and rests
// are the gaps; dynamics (mp, mf, f, ff) are written under the notes. The app
// logo stands where the clef would be.
//
// The logo is an SVG (flutter_svg is a dependency). The rebrand is pending, so
// the asset path is one constant to swap. STUB (red phase): build throws.

import 'package:flutter/widgets.dart';

import '../haptics/score_layout.dart';
import '../notify/buzz_sequence.dart';

/// The logo drawn in place of a clef. Replace this file for the rebrand.
const String kClefLogoAsset = 'assets/brand/clef_logo.svg';

/// Paints the staff line, the notes, rests, ties and dots of [layout].
class HapticScorePainter extends CustomPainter {
  const HapticScorePainter(this.layout);
  final ScoreLayout layout;

  @override
  void paint(Canvas canvas, Size size) =>
      throw UnimplementedError('HapticScorePainter.paint');

  @override
  bool shouldRepaint(HapticScorePainter old) => old.layout != layout;
}

class HapticScore extends StatelessWidget {
  const HapticScore(this.pattern, {super.key, this.unitMs = 125});

  final BuzzSequence pattern;

  /// Milliseconds per sixteenth, for the spoken length.
  final int unitMs;

  @override
  Widget build(BuildContext context) =>
      throw UnimplementedError('HapticScore.build');
}
