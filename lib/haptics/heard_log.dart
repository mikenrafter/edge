// 8AC: the output side of the pattern probe. The probe writes one "Pattern
// probe heard N/M, <description>: A = <prose> (<code>); B = ...; played K×."
// line per transcribed test into the lab log; this reads those lines back into
// transcripts so a device profile can be checked against what was written
// down. Pure Dart.

import '../gestures/pattern_transcript.dart';

/// One test as transcribed: both renditions, whether the wearer flagged it
/// unstable (A and B are then its shortest and longest), and how often it was
/// played.
class HeardTest {
  const HeardTest({
    required this.test,
    required this.description,
    required this.a,
    required this.b,
    required this.unstable,
    required this.plays,
  });

  /// The 1-based test number.
  final int test;
  final String description;
  final List<PatternEntry> a;
  final List<PatternEntry> b;
  final bool unstable;
  final int plays;

  /// A note in either rendition is still `*`: written from taps and never
  /// rated, so nothing was recorded about its loudness. A vocabulary is not
  /// built from such a test.
  bool get unrated => [...a, ...b].any(
      (e) => e.note && e.dynamic == PatternDynamic.any);
}

final RegExp _heard = RegExp(
  r'Pattern probe heard (\d+)/\d+, (.*?)'
  r'(, unstable \(A and B are the shortest and longest\))?'
  r': A = (.*?); B = (.*?); played (\d+)×\.',
);

final RegExp _trailingCode = RegExp(r'\(([^()]*)\)\s*$');

/// The entries of one rendition: "—" is empty; otherwise the code in the
/// last parentheses.
List<PatternEntry> _rendition(String text) {
  final m = _trailingCode.firstMatch(text);
  if (m == null) return const [];
  final entries = PatternTranscript.parseCode(m[1]!).entries;
  return entries;
}

/// The legacy unstable flag: a rendition that ends with a 16th, an eighth and
/// a quarter rest.
bool _flagged(List<PatternEntry> es) {
  if (es.length < 3) return false;
  final tail = es.sublist(es.length - 3);
  const flag = [1, 2, 4];
  for (var i = 0; i < 3; i++) {
    if (tail[i].note || tail[i].length != flag[i]) return false;
  }
  return true;
}

List<PatternEntry> _stripped(List<PatternEntry> es) =>
    _flagged(es) ? es.sublist(0, es.length - 3) : es;

/// Every heard line in [logText], the last line per test, in test order. A
/// test is unstable when its line says so or a rendition ends with R1 R2 R4
/// (those three rests are then dropped from it).
List<HeardTest> parseHeardLines(String logText) {
  final last = <int, HeardTest>{};
  for (final line in logText.split('\n')) {
    final m = _heard.firstMatch(line);
    if (m == null) continue;
    final a = _rendition(m[4]!);
    final b = _rendition(m[5]!);
    final test = int.parse(m[1]!);
    last[test] = HeardTest(
      test: test,
      description: m[2]!,
      a: _stripped(a),
      b: _stripped(b),
      unstable: m[3] != null || _flagged(a) || _flagged(b),
      plays: int.parse(m[6]!),
    );
  }
  return [for (final t in (last.keys.toList()..sort())) last[t]!];
}
